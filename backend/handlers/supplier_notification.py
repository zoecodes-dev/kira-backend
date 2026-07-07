"""
handlers/supplier_notification.py — 협력사 통지/자진신고 이벤트 → in-app 알림 배선

supplychain 도메인이 발행하는 두 이벤트를 notifications(in-app) 행 생성으로 잇는다.
프론트(협력사 벨 / 원청 인박스)는 GET /notifications 로 폴링한다.
(handlers/final_validation_notify 와 동일한 '통합 슬롯' 패턴: 이벤트 수신 → 대상 유저
조회 → 알림은 큐로 위임. 도메인 경계를 넘는 배선은 여기 한곳에 둔다.)

  - supplier.notification_sent       → 대상 협력사 계정에 '시정 요청'(violation) 알림
  - supplier.source_change_declared  → 원청(OEM) 담당자에 '재검증 필요'(approval_needed) 알림

멱등: dedup_key 로 notifications.dedup_key UNIQUE 가 중복 INSERT 를 막는다.
"""
import logging

from sqlalchemy import text

from backend.infrastructure.database import AsyncSessionLocal
from backend.infrastructure.queue import enqueue, NOTIFICATION_QUEUE

logger = logging.getLogger(__name__)

# 협력사 포털 계정 역할 — users.supplier_id 로 본인 협력사에 스코프됨.
_SUPPLIER_ROLES = ("supplier_ceo", "supplier_esg")
# 원청(발주사) 역할 — 자진신고 재검증 알림 수신 대상. (협력사 역할 supplier_* 제외)
_OEM_ROLES = ("owner_esg", "owner_purchasing", "admin")


async def notify_supplier_correction(payload: dict) -> None:
    """supplier.notification_sent 수신 → 대상 협력사 계정에 시정 요청 in-app 알림."""
    target_supplier_id = payload.get("target_supplier_id")
    if not target_supplier_id:
        return

    reason = payload.get("reason") or "시정이 필요한 항목이 있습니다."
    due_date = payload.get("due_date")
    required_docs = payload.get("required_documents") or []
    sent_at = payload.get("sent_at") or ""

    async with AsyncSessionLocal() as db:
        roles_sql = ", ".join(f"'{r}'" for r in _SUPPLIER_ROLES)
        rows = (await db.execute(
            text(f"""
                SELECT user_id FROM users
                WHERE supplier_id = :sid AND role IN ({roles_sql}) AND is_active = TRUE
            """),
            {"sid": str(target_supplier_id)},
        )).fetchall()

    if not rows:
        logger.warning("[supplier_correction] 협력사 계정 없음 (supplier_id=%s)", target_supplier_id)
        return

    due_txt = f" (기한 {due_date})" if due_date else ""
    docs_txt = f" 필요서류: {', '.join(required_docs)}." if required_docs else ""
    for r in rows:
        uid = str(r[0])
        await enqueue(
            NOTIFICATION_QUEUE,
            "process_notification",
            user_id=uid,
            channel="in-app",
            notification_type="violation",
            subject="원청 시정 요청",
            body=f"{reason}{due_txt}.{docs_txt}",
            # sent_at 별로 1건 — 같은 통지 이벤트의 재처리 중복만 차단.
            dedup_key=f"supplier_correction:{target_supplier_id}:{sent_at}:{uid}",
        )
    logger.info("[supplier_correction] 알림 enqueue supplier=%s users=%d", target_supplier_id, len(rows))


async def notify_source_change_declared(payload: dict) -> None:
    """supplier.source_change_declared 수신 → 원청(OEM) 담당자에 재검증 필요 알림."""
    bom_version_id = payload.get("bom_version_id")
    child_supplier_id = payload.get("child_supplier_id")
    if not bom_version_id:
        # 원청 테넌트는 bom_version → product → tenant 로 해석한다. 없으면 대상 불명.
        logger.warning("[source_change] bom_version_id 누락 — 원청 테넌트 확인 불가")
        return

    async with AsyncSessionLocal() as db:
        tenant_id = (await db.execute(
            text("""
                SELECT p.tenant_id
                FROM bom_versions bv
                JOIN products p ON p.product_id = bv.product_id
                WHERE bv.bom_version_id = :bv
            """),
            {"bv": str(bom_version_id)},
        )).scalar()
        if not tenant_id:
            logger.warning("[source_change] 제품/테넌트 확인 불가 (bom_version_id=%s)", bom_version_id)
            return

        roles_sql = ", ".join(f"'{r}'" for r in _OEM_ROLES)
        rows = (await db.execute(
            text(f"""
                SELECT user_id FROM users
                WHERE tenant_id = :t AND role IN ({roles_sql}) AND is_active = TRUE
            """),
            {"t": str(tenant_id)},
        )).fetchall()

    if not rows:
        logger.warning("[source_change] 원청 담당자 없음 (tenant=%s)", tenant_id)
        return

    reason = payload.get("reason") or "공급원 변경이 신고되었습니다."
    for r in rows:
        uid = str(r[0])
        await enqueue(
            NOTIFICATION_QUEUE,
            "process_notification",
            user_id=uid,
            channel="in-app",
            notification_type="approval_needed",
            subject="공급원 변경 자진신고 — 재검증 필요",
            body=(
                f"협력사가 공급원 변경을 자진신고했습니다. 상위 BOM 재검증이 필요합니다. "
                f"(사유: {reason})"
            ),
            dedup_key=f"source_change:{bom_version_id}:{child_supplier_id or '-'}:{uid}",
        )
    logger.info("[source_change] 재검증 알림 enqueue bom=%s users=%d", bom_version_id, len(rows))
