import logging
import os
from typing import Any, Dict, Optional

from arq import create_pool
from arq.connections import ArqRedis, RedisSettings

logger = logging.getLogger("kira.infrastructure.queue")

# spec 1-3: Queue 이름 6종 (단일 책임 원칙)
# 한 워커가 한 큐만 처리하므로 풀도 큐별로 분리한다.
QUEUE_OCR = "ocr_queue"
QUEUE_VALIDATION = "validation_queue"
QUEUE_RISK = "risk_queue"
QUEUE_HITL = "hitl_queue"
QUEUE_NOTIFICATION = "notification_queue"
QUEUE_DPP_PUBLISH = "dpp_publish_queue"

ALLOWED_QUEUES = {
    QUEUE_OCR,
    QUEUE_VALIDATION,
    QUEUE_RISK,
    QUEUE_HITL,
    QUEUE_NOTIFICATION,
    QUEUE_DPP_PUBLISH,
}

# 큐별 풀 캐시. 첫 enqueue 호출 시 lazy 생성.
_pools: Dict[str, ArqRedis] = {}


def _redis_settings() -> RedisSettings:
    """환경변수 기반 Redis 설정.

    docker-compose 내부에서는 host='redis', 로컬 디버깅에서는 'localhost'.
    """
    return RedisSettings(
        host=os.getenv("REDIS_HOST", "localhost"),
        port=int(os.getenv("REDIS_PORT", "6379")),
        database=int(os.getenv("REDIS_DB", "0")),
    )


async def get_redis_pool(queue_name: str) -> ArqRedis:
    """큐 이름별 ArqRedis 풀을 반환한다.

    spec 5-3: Worker 단일 책임 — 한 워커가 한 큐만 처리.
    풀의 default_queue_name을 큐 이름으로 지정해야 워커 통계와 일치한다.
    """
    if queue_name not in ALLOWED_QUEUES:
        raise ValueError(
            f"[Queue] Unknown queue '{queue_name}'. "
            f"Allowed: {sorted(ALLOWED_QUEUES)}"
        )

    if queue_name not in _pools:
        _pools[queue_name] = await create_pool(
            _redis_settings(),
            default_queue_name=queue_name,
        )
        logger.info(f"[Queue] Pool created for {queue_name}")
    return _pools[queue_name]


async def enqueue(queue_name: str, func_name: str, **kwargs: Any) -> Optional[str]:
    """W1 단계: enqueue 인터페이스만 제공. 실제 워커 컨슈머는 W2.

    spec 1-3 반환 계약: job_id (202 Accepted 응답에 포함).
    Idempotency Key는 _job_id로 전달 — 같은 _job_id로 두 번 enqueue되면 중복 무시.
    """
    try:
        pool = await get_redis_pool(queue_name)
        job = await pool.enqueue_job(func_name, **kwargs)
        if job is None:
            # 같은 _job_id로 이미 enqueue된 경우 ARQ가 None을 반환 (idempotency)
            logger.info(
                f"[Queue] Duplicate suppressed for {func_name} on {queue_name}"
            )
            return None
        logger.info(
            f"[Queue] Enqueued {func_name} to {queue_name} (job_id={job.job_id})"
        )
        return job.job_id
    except Exception as e:
        logger.error(f"[Queue] Failed to enqueue {func_name} to {queue_name}: {e}")
        return None


async def close_pools() -> None:
    """FastAPI shutdown 시 호출. 모든 풀의 Redis 연결을 정리한다."""
    for queue_name, pool in list(_pools.items()):
        try:
            await pool.aclose()
            logger.info(f"[Queue] Pool closed for {queue_name}")
        except Exception as e:
            logger.warning(f"[Queue] Pool close failed for {queue_name}: {e}")
    _pools.clear()