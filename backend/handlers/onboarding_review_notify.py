"""
handlers/onboarding_review_notify.py — 협력사 온보딩(제3자 동의서) 제출 시 원청에 검토 요청 알림

흐름: "협력사가 온보딩을 제출(동의서 회신, SupplierStatusChanged → supplier_review)하면
[원청]이 STEP4(제3자 동의서 수신 확인)에서 확인해야 함을 알림으로 안내받는다."

submission_submitted_notify.py(자료 제출 완료 알림)와 동일 패턴 — 다만 트리거가 더 이른
단계(온보딩/동의서 자체)라는 점만 다르다.

멱등: dedup_key(onboarding_review:{supplier_id}:{user})로 협력사·수신자당 1회.
"""
import logging

from sqlalchemy import text

from backend.infrastructure.database import AsyncSessionLocal
from backend.infrastructure.queue import enqueue, NOTIFICATION_QUEUE

logger = logging.getLogger(__name__)

# 원청(발주사) 역할 — submission_submitted_notify.py의 _PRIME_ROLES와 동일.
_PRIME_ROLES = ("owner_esg", "owner_purchasing", "admin")


async def notify_onboarding_review_needed(payload: dict) -> None:
    """SupplierStatusChanged 수신 → to_status가 'supplier_review'일 때만 원청에 알림."""
    if payload.get("to_status") != "supplier_review":
        return

    supplier_id = payload.get("supplier_id")
    if not supplier_id:
        return

    async with AsyncSessionLocal() as db:
        row = (await db.execute(
            text("SELECT company_name, tenant_id FROM suppliers WHERE supplier_id = :s"),
            {"s": str(supplier_id)},
        )).first()
        if not row:
            return
        company_name, tenant_id = row[0], row[1]

        if not tenant_id:
            logger.warning("[onboarding_review] tenant_id 없음 (supplier_id=%s)", supplier_id)
            return

        roles_sql = ", ".join(f"'{r}'" for r in _PRIME_ROLES)
        rows = (await db.execute(
            text(f"""
                SELECT user_id FROM users
                WHERE tenant_id = :t AND role IN ({roles_sql}) AND is_active = TRUE
            """),
            {"t": str(tenant_id)},
        )).fetchall()
        recipients = [str(r[0]) for r in rows]

        # 이 협력사가 물려있는 맵(가장 최근 엣지 기준) — 있으면 STEP4 화면으로 바로 딥링크.
        # (target이 없으면 프론트가 notification_type 기반 기본 딥링크로 폴백하는데,
        #  approval_needed의 기본 딥링크는 협력사 포털용 'ai-parsing'이라 원청 화면엔 안 맞는다.)
        map_row = (await db.execute(
            text("""
                SELECT sm.product_id, scm.bom_version_id
                FROM supply_chain_map scm
                JOIN supply_chain_maps sm ON sm.bom_version_id = scm.bom_version_id
                WHERE scm.child_supplier_id = :s
                ORDER BY scm.created_at DESC
                LIMIT 1
            """),
            {"s": str(supplier_id)},
        )).first()

    if not recipients:
        logger.warning("[onboarding_review] 수신 원청 없음 (supplier_id=%s)", supplier_id)
        return

    target = None
    if map_row and map_row[0]:
        target = {
            "productId": str(map_row[0]),
            "bomVersionId": str(map_row[1]) if map_row[1] else None,
            "focusSupplierId": str(supplier_id),
        }

    label = company_name or "협력사"
    for uid in recipients:
        await enqueue(
            NOTIFICATION_QUEUE,
            "process_notification",
            user_id=uid,
            channel="in-app",
            notification_type="approval_needed",
            subject=f"제3자 동의서 회신 — {label}",
            body=f"{label}가 제3자 정보 확인 동의서에 회신하고 온보딩을 제출했습니다. STEP4에서 수신을 확인해 주세요.",
            dedup_key=f"onboarding_review:{supplier_id}:{uid}",
            target=target,
        )
    logger.info("[onboarding_review] 동의서 회신 알림 enqueue supplier=%s users=%d", supplier_id, len(recipients))
