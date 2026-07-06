"""
handlers/submission_submitted_notify.py — 협력사 자료 제출 시 원청에 검토 요청 알림

흐름: "협력사가 표준 양식 자료를 제출(SubmissionCompleted)하면 [원청]이 검토/승인 알림을 받는다."

요청을 낸 원청 담당자(requester_user_id, 없으면 제품 테넌트의 원청 역할)에게 in-app 알림을
발송한다. 알림 target에 그 회차 맵(map_id/product/bom) + 제출한 협력사(focusSupplierId)를 담아,
클릭 시 해당 공급망 맵을 열고 그 협력사 노드로 스크롤·하이라이트되게 한다.

멱등: dedup_key(submission_submitted:{request_id}:{user})로 요청·수신자당 1회
     — 알림 워커의 notifications.dedup_key UNIQUE가 중복 INSERT를 막는다.
도메인 경계: 이 핸들러(통합 슬롯)는 data_request_log/batches/supply_chain_maps/suppliers를
읽고 알림은 큐로 넘긴다 (final_validation_notify·batch_trigger와 같은 통합 계층 패턴).
"""
import logging

from sqlalchemy import text

from backend.infrastructure.database import AsyncSessionLocal
from backend.infrastructure.queue import enqueue, NOTIFICATION_QUEUE

logger = logging.getLogger(__name__)

# 원청(발주사) 역할 — requester_user_id가 없을 때의 폴백 수신 대상. (협력사 역할 supplier_* 제외)
_PRIME_ROLES = ("owner_esg", "owner_purchasing", "admin")


async def notify_supplier_submission(payload: dict) -> None:
    """SubmissionCompleted 수신 → 요청을 낸 원청에 '협력사 자료 제출 완료' 알림(맵+협력사 딥링크)."""
    request_id = payload.get("request_id")
    if not request_id:
        return

    async with AsyncSessionLocal() as db:
        # 요청 → 대상 협력사 / 요청자 / 배치
        req = (await db.execute(
            text("""
                SELECT target_supplier_id, requester_user_id, batch_id
                FROM data_request_log WHERE request_id = :r
            """),
            {"r": str(request_id)},
        )).first()
        if not req:
            return
        supplier_id = str(req[0]) if req[0] else None
        requester_user_id = str(req[1]) if req[1] else None
        batch_id = payload.get("batch_id") or (str(req[2]) if req[2] else None)

        # 배치 → 제품/BOM/테넌트 (맵 좌표)
        product_id = bom_version_id = tenant_id = None
        if batch_id:
            brow = (await db.execute(
                text("SELECT product_id, bom_version_id, tenant_id FROM batches WHERE batch_id = :b"),
                {"b": str(batch_id)},
            )).first()
            if brow:
                product_id = str(brow[0]) if brow[0] else None
                bom_version_id = str(brow[1]) if brow[1] else None
                tenant_id = str(brow[2]) if brow[2] else None

        # bom_version_id → map_id (supply_chain_maps.UNIQUE(bom_version_id)라 1:1)
        map_id = None
        if bom_version_id:
            map_id = (await db.execute(
                text("SELECT map_id FROM supply_chain_maps WHERE bom_version_id = :b"),
                {"b": bom_version_id},
            )).scalar()

        # 협력사명 (알림 본문/제목)
        supplier_name = None
        if supplier_id:
            supplier_name = (await db.execute(
                text("SELECT company_name FROM suppliers WHERE supplier_id = :s"),
                {"s": supplier_id},
            )).scalar()

        # 수신자: 요청을 낸 원청 담당자 우선, 없으면 제품 테넌트의 원청 역할 전원.
        if requester_user_id:
            recipients = [requester_user_id]
        elif tenant_id:
            roles_sql = ", ".join(f"'{r}'" for r in _PRIME_ROLES)
            rows = (await db.execute(
                text(f"""
                    SELECT user_id FROM users
                    WHERE tenant_id = :t AND role IN ({roles_sql}) AND is_active = TRUE
                """),
                {"t": tenant_id},
            )).fetchall()
            recipients = [str(r[0]) for r in rows]
        else:
            recipients = []

    if not recipients:
        logger.warning("[submission_submitted] 수신 원청 없음 (request=%s)", request_id)
        return

    # 맵 딥링크 target — 제품이 있어야 맵을 연다. focusSupplierId로 그 협력사 노드를 포커스.
    target = None
    if product_id:
        target = {"productId": product_id}
        if bom_version_id:
            target["bomVersionId"] = bom_version_id
        if map_id:
            target["mapId"] = str(map_id)
        if supplier_id:
            target["focusSupplierId"] = supplier_id

    label = supplier_name or "협력사"
    for uid in recipients:
        await enqueue(
            NOTIFICATION_QUEUE,
            "process_notification",
            user_id=uid,
            channel="in-app",
            notification_type="approval_needed",
            subject=f"협력사 자료 제출 완료 — {label}",
            body=f"{label}가 요청하신 자료 입력을 완료했습니다. 맵의 해당 협력사에서 내용을 검토·승인해 주세요.",
            dedup_key=f"submission_submitted:{request_id}:{uid}",
            target=target,
        )
    logger.info("[submission_submitted] 제출 완료 알림 enqueue request=%s users=%d", request_id, len(recipients))
