"""
handlers/supplychain_gap_data_request.py — SupplyChainGapDetected → 협력사 자료요청 생성

공급망 맵 gap 트리거(POST /trigger-data-requests)가 gap 노드별로 발행하는
SupplyChainGapDetected 를 수신해, submission 도메인의 data_request 를 생성한다.

배선 근거: events/types.py SupplyChainGapDetectedEvent 주석 —
  "발행: D(supplychain) → 수신: E(submission)가 create_and_request_submission 으로 생성."

도메인 경계(규칙 #4): supplychain 이 submission 을 직접 import 하던 것을 이 핸들러(조립
  계층)로 옮겼다. 핸들러는 조립·구독 계층이라 도메인 service 를 호출해도 된다. 요청 생성의
  트랜잭션·커밋은 submission service(create_and_request_submission)가 소유한다.
"""
import logging
from datetime import datetime
from uuid import UUID

from backend.infrastructure.database import AsyncSessionLocal
from backend.domains.submission.service import create_and_request_submission

logger = logging.getLogger(__name__)


async def on_supply_chain_gap_detected(payload: dict) -> None:
    """SupplyChainGapDetected 수신 → 해당 협력사에 자료 제출 요청(data_request) 생성."""
    supplier_id = payload.get("supplier_id")
    requested_data_type = payload.get("requested_data_type")
    requester_user_id = payload.get("requester_user_id")
    actor_id = payload.get("actor_id")
    if not supplier_id or not requested_data_type or not requester_user_id or not actor_id:
        logger.warning("[gap_data_request] 필수 payload 누락 → 스킵 payload=%s", payload)
        return

    # publish(default=str) 로 문자열화된 값 → 도메인 타입으로 복원.
    due_raw = payload.get("due_date")
    due_date = datetime.fromisoformat(due_raw) if due_raw else None
    # [map별 독립 제출] gap이 검출된 공급망 맵(BOM). 없으면 회사 단위 요청(레거시).
    bom_raw = payload.get("bom_version_id")
    bom_version_id = UUID(str(bom_raw)) if bom_raw else None

    async with AsyncSessionLocal() as db:
        # create_and_request_submission 이 자체 커밋 + SubmissionRequested 발행까지 수행한다.
        req_log = await create_and_request_submission(
            db=db,
            requester_user_id=UUID(str(requester_user_id)),
            target_supplier_id=UUID(str(supplier_id)),
            requested_data_type=requested_data_type,
            due_date=due_date,
            actor_id=UUID(str(actor_id)),
            bom_version_id=bom_version_id,
        )

    logger.info(
        "[gap_data_request] 자료요청 생성 supplier=%s request_id=%s types=%s",
        supplier_id, req_log.request_id, requested_data_type,
    )
