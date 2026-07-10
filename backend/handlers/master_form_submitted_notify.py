"""
handlers/master_form_submitted_notify.py — 협력사 마스터폼(자가진단) 제출 시 원청에 알림

흐름: 협력사가 자기 정보 확인·표준 양식(check-info)을 "제출"하면(MasterFormSubmitted),
[원청]이 검토 알림을 받는다. submission_submitted_notify.py(정식 자료요청 회차 응답)와 달리
이 제출은 특정 data_request_log에 매이지 않는(상시 자가진단) 흐름이라 request_id로 요청자를
찾을 수 없다 — 그 협력사가 속한 tenant의 원청 역할(_PRIME_ROLES) 전원에게 보낸다.

딥링크: 이 제출은 특정 제품/공급망 맵에 매이지 않으므로 맵 좌표(target.productId) 대신
focusSupplierId만 채운다 — 프론트 buildMapDeepLink가 productId 없이 focusSupplierId만
있으면 /suppliers/check-info?supplierId=...(협력사 상세 리뷰)로 보낸다.

멱등: dedup_key(master_form_submitted:{supplier_id}:{user}:{날짜}) — 같은 날 여러 번
     제출(재저장 등)해도 알림 row는 하루 1건으로 묶는다. 단 resurface=True로 enqueue해,
     재제출 때마다(같은 dedup_key라도) 알림 워커가 DO UPDATE로 status를 pending으로
     되돌린다 — 원청이 이미 읽은 뒤에도 재제출이 있으면 다시 미확인으로 뜬다
     (workers/notification_worker.py process_notification 참고).
"""
import logging
from datetime import date

from sqlalchemy import text

from backend.infrastructure.database import AsyncSessionLocal
from backend.infrastructure.queue import enqueue, NOTIFICATION_QUEUE

logger = logging.getLogger(__name__)

# 원청(발주사) 역할 — 이 제출은 요청자가 없으므로 항상 tenant 전원이 대상. (협력사 역할 제외)
_PRIME_ROLES = ("owner_esg", "owner_purchasing", "admin")


async def notify_master_form_submission(payload: dict) -> None:
    """MasterFormSubmitted 수신 → 그 협력사가 속한 tenant의 원청 담당자 전원에게 알림."""
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
        supplier_name, tenant_id = row[0], (str(row[1]) if row[1] else None)
        if not tenant_id:
            logger.warning("[master_form_submitted] tenant_id 없음 (supplier=%s)", supplier_id)
            return

        roles_sql = ", ".join(f"'{r}'" for r in _PRIME_ROLES)
        rows = (await db.execute(
            text(f"""
                SELECT user_id FROM users
                WHERE tenant_id = :t AND role IN ({roles_sql}) AND is_active = TRUE
            """),
            {"t": tenant_id},
        )).fetchall()
        recipients = [str(r[0]) for r in rows]

    if not recipients:
        logger.warning("[master_form_submitted] 수신 원청 없음 (supplier=%s)", supplier_id)
        return

    label = supplier_name or "협력사"
    target = {"focusSupplierId": str(supplier_id)}
    today = date.today().isoformat()
    for uid in recipients:
        await enqueue(
            NOTIFICATION_QUEUE,
            "process_notification",
            user_id=uid,
            channel="in-app",
            notification_type="approval_needed",
            subject=f"협력사 정보 제출 — {label}",
            body=f"{label}가 자가진단/기업정보를 제출했습니다. 협력사 상세에서 내용을 검토해 주세요.",
            dedup_key=f"master_form_submitted:{supplier_id}:{uid}:{today}",
            target=target,
            resurface=True,
        )
    logger.info("[master_form_submitted] 제출 알림 enqueue supplier=%s users=%d", supplier_id, len(recipients))
