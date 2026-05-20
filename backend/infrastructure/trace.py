import functools
import hashlib
import json
import logging
from datetime import datetime
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
    inputs: Dict[str, Any],
    outputs: Dict[str, Any]
) -> None:
    """이전 해시 조회와 새 감사 로그 삽입을 단일 트랜잭션으로 묶어 원자성을 보장합니다."""
    async with async_session_maker() as session:
        async with session.begin():
            try:
                # 1. 이전 해시 조회 (하나의 트랜잭션 컨텍스트)
                select_query = text("""
                    SELECT output_hash 
                    FROM audit_trail 
                    WHERE batch_id = :batch_id 
                    ORDER BY created_at DESC, id DESC 
                    LIMIT 1
                """)
                result = await session.execute(select_query, {"batch_id": batch_id})
                row = result.fetchone()
                prev_hash = row[0] if row else None

                # 2. 새 감사 로그 적재
                insert_query = text("""
                    INSERT INTO audit_trail (
                        batch_id, node_name, node_type, 
                        input_hash, output_hash, prev_hash, 
                        input_payload, output_payload, created_at
                    ) VALUES (
                        :batch_id, :node_name, :node_type, 
                        :input_hash, :output_hash, :prev_hash, 
                        :input_payload, :output_payload, :created_at
                    )
                """)
                await session.execute(
                    insert_query,
                    {
                        "batch_id": batch_id,
                        "node_name": node_name,
                        "node_type": node_type,
                        "input_hash": input_hash,
                        "output_hash": output_hash,
                        "prev_hash": prev_hash,
                        "input_payload": json.dumps(_clean_payload(inputs), default=str),
                        "output_payload": json.dumps(_clean_payload(outputs), default=str),
                        "created_at": datetime.utcnow()
                    }
                )
            except Exception as e:
                # 에이전트 파이프라인 무정지 원칙
                logger.critical(f"[Provenance Critical Error] Audit Trail integration failed: {e}")

def trace_node(node_name: str, node_type: str = "AGENT_NODE") -> Callable:
    """
    LangGraph 노드 및 도메인 핵심 비즈니스 로직에 적용하는 Provenance 데코레이터입니다.
    """
    def decorator(func: Callable) -> Callable:
        @functools.wraps(func)
        async def async_wrapper(*args: Any, **kwargs: Any) -> Any:
            batch_id: Optional[str] = kwargs.get("batch_id")
            
            if not batch_id and args:
                if isinstance(args[0], dict):
                    batch_id = args[0].get("batch_id")
                elif hasattr(args[0], "batch_id"):
                    batch_id = getattr(args[0], "batch_id")

            # batch_id가 없는 단위 테스트 등에서는 해시 추적 생략
            if not batch_id:
                if functools.iscoroutinefunction(func):
                    return