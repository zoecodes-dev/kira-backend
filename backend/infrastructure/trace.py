import functools
import hashlib
import json
import logging
import time
from typing import Any, Callable, Dict, Optional

# 인프라 레이어 의존성 주입
from backend.infrastructure.database import async_session_maker
from sqlalchemy import text

logger = logging.getLogger("kira.infrastructure.trace")


def _clean_payload(data: Any) -> Any:
    """비결정론적 객체(DB 세션, 소켓 등) 및 민감 정보를 제거하여 해시 결정론을 보장합니다."""
    if isinstance(data, dict):
        # 패스워드 마스킹 및 메모리 주소(<...>)를 포함하는 인스턴스 문자열 필터링
        return {
            k: _clean_payload(v)
            for k, v in data.items()
            if "password" not in k.lower() and not str(v).startswith("<")
        }
    elif isinstance(data, list) or isinstance(data, tuple):
        return [_clean_payload(v) for v in data]
    elif hasattr(data, '__dict__'):
        return _clean_payload(data.__dict__)
    return data


def _generate_hash(data: Any) -> str:
    """객체를 결정론적인 JSON 문자열로 직렬화한 후 SHA-256 해시를 생성합니다."""
    try:
        cleaned = _clean_payload(data)
        serialized = json.dumps(cleaned, sort_keys=True, default=str, ensure_ascii=False)
    except Exception as e:
        logger.warning(f"[Trace] Serialization failed for hashing: {e}")
        serialized = str(data)
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()


async def _append_to_audit_trail(
    batch_id: str,
    node_name: str,
    node_type: str,
    input_hash: str,
    output_hash: str,
    duration_ms: int,
    decision_text: Optional[str] = None,
) -> None:
    """이전 step 조회 + 새 감사 로그 삽입을 단일 트랜잭션으로 묶어 원자성을 보장합니다.

    스키마: audit_trail (audit_id, batch_id, step_number, timestamp, node_type,
                         node_name, model_version, prompt_version, duration_ms,
                         input_hash, output_hash, prev_hash, decision_text, citations)
    - timestamp는 DEFAULT now() 위임
    - citations는 Compliance Agent(은지)가 채우는 영역이라 여기선 NULL
    - step_number는 같은 batch_id의 MAX(step_number)+1
    """
    async with async_session_maker() as session:
        async with session.begin():
            try:
                # 1. 같은 batch_id의 마지막 step 조회 (prev_hash + step_number 동시 획득)
                select_query = text("""
                    SELECT output_hash, step_number
                    FROM audit_trail
                    WHERE batch_id = :batch_id
                    ORDER BY step_number DESC
                    LIMIT 1
                """)
                result = await session.execute(select_query, {"batch_id": batch_id})
                row = result.fetchone()
                if row:
                    prev_hash = row[0]
                    next_step = (row[1] or 0) + 1
                else:
                    prev_hash = None
                    next_step = 1

                # 2. 새 감사 로그 적재
                insert_query = text("""
                    INSERT INTO audit_trail (
                        batch_id, step_number, node_type, node_name,
                        duration_ms, input_hash, output_hash, prev_hash,
                        decision_text
                    ) VALUES (
                        :batch_id, :step_number, :node_type, :node_name,
                        :duration_ms, :input_hash, :output_hash, :prev_hash,
                        :decision_text
                    )
                """)
                await session.execute(
                    insert_query,
                    {
                        "batch_id": batch_id,
                        "step_number": next_step,
                        "node_type": node_type,
                        "node_name": node_name,
                        "duration_ms": duration_ms,
                        "input_hash": input_hash,
                        "output_hash": output_hash,
                        "prev_hash": prev_hash,
                        "decision_text": decision_text,
                    }
                )
            except Exception as e:
                # 에이전트 파이프라인 무정지 원칙 — Provenance 실패가 본 파이프라인을 막지 않음
                logger.critical(f"[Provenance Critical Error] Audit Trail insert failed: {e}")


def trace_node(node_name: str, node_type: str = "agent") -> Callable:
    """
    LangGraph 노드 및 도메인 핵심 비즈니스 로직에 적용하는 Provenance 데코레이터.

    schema.sql audit_trail.node_type 허용값: 'agent' / 'tool' / 'human'
    """
    def decorator(func: Callable) -> Callable:
        @functools.wraps(func)
        async def async_wrapper(*args: Any, **kwargs: Any) -> Any:
            # 1) batch_id 추출 — kwargs > 첫 인자(dict) > 첫 인자(객체 속성)
            batch_id: Optional[str] = kwargs.get("batch_id")
            if not batch_id and args:
                if isinstance(args[0], dict):
                    batch_id = args[0].get("batch_id")
                elif hasattr(args[0], "batch_id"):
                    batch_id = getattr(args[0], "batch_id")

            # 2) batch_id 없는 단위 테스트 등 — 해시 추적 생략하고 그대로 실행
            if not batch_id:
                if functools.iscoroutinefunction(func):
                    return await func(*args, **kwargs)
                return func(*args, **kwargs)

            # 3) 비동기 강제 — 모든 추적 대상은 async (FastAPI + LangGraph 일관성)
            if not functools.iscoroutinefunction(func):
                raise NotImplementedError(
                    f"[Trace Layer] Sync function '{func.__name__}' is not supported. "
                    "All traceable nodes and tools must be async."
                )

            # 4) Input 해시 — args[0]이 state dict면 그대로, 아니면 args/kwargs 묶어서
            if args and isinstance(args[0], dict):
                input_data: Dict[str, Any] = {"args": args, "kwargs": kwargs}
            else:
                input_data = {"args": args[1:] if args else (), "kwargs": kwargs}
            input_hash = _generate_hash(input_data)

            # 5) 실행 + 소요 시간 측정
            start_ts = time.perf_counter()
            result = await func(*args, **kwargs)
            duration_ms = int((time.perf_counter() - start_ts) * 1000)

            # 6) Output 해시
            output_hash = _generate_hash(result)

            # 7) 해시 체인 적재 (실패해도 본 파이프라인은 계속)
            try:
                await _append_to_audit_trail(
                    batch_id=str(batch_id),
                    node_name=node_name,
                    node_type=node_type,
                    input_hash=input_hash,
                    output_hash=output_hash,
                    duration_ms=duration_ms,
                )
            except Exception as e:
                logger.error(f"[Trace Layer Exception] Execution safe-guarded: {e}")

            return result
        return async_wrapper
    return decorator


def trace_tool(tool_name: str) -> Callable:
    """Specialist Agent가 사용하는 외부 도구(Tool) 호출 전용 경량 데코레이터.

    audit_trail.node_type = 'tool' 로 기록됨.
    """
    return trace_node(node_name=tool_name, node_type="tool")