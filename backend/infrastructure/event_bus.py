import json
import logging
from typing import Callable, Dict

from backend.infrastructure.database import async_session_maker
from sqlalchemy import text

logger = logging.getLogger("kira.infrastructure.event_bus")

# 구독 핸들러 깡통 딕셔너리 (실제 LISTEN 루프는 W2 구현)
_subscribers: Dict[str, list[Callable]] = {}

async def publish(event_name: str, payload: dict) -> None:
    """PostgreSQL NOTIFY를 사용해 도메인 이벤트를 발행합니다."""
    async with async_session_maker() as session:
        try:
            message = json.dumps({"event": event_name, "data": payload}, default=str)
            message_escaped = message.replace("'", "''")
            
            # kira_events 단일 채널 사용
            query = text(f"NOTIFY kira_events, '{message_escaped}'")
            await session.execute(query)
            await session.commit()
            logger.info(f"[EventBus] Published: {event_name}")
        except Exception as e:
            logger.error(f"[EventBus] Failed to publish {event_name}: {e}")

def subscribe(event_name: str, handler: Callable) -> None:
    """W1 단계: 함수 등록만 수행합니다."""
    if event_name not in _subscribers:
        _subscribers[event_name] = []
    _subscribers[event_name].append(handler)
    logger.info(f"[EventBus] Subscribed to {event_name}")