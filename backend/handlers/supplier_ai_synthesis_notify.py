"""
handlers/supplier_ai_synthesis_notify.py — 3종(소재구성·탄소발자국·SAQ) AI 처리 종합
완료 시 원청에 알림.

SupplierAiSynthesisReady 수신 → suppliers.ai_compliance_summary(직전에 이미 채워짐)를
읽어 원청 tenant 담당자(master_form_submitted_notify.py와 동일 역할군)에게 짧은 확인
요청을 발행한다.

[UX 변경] 협력사 본인에게는 더 이상 알림 패널(in-app notifications)로 보내지 않는다 —
결론 본문은 협력사가 '제출하기'를 누르는 시점에 경고 팝업으로 직접 보여준다
(app/suppliers/check-info/SupplierGeneralReview.tsx handleSubmitClick, GET
.../detail 응답의 aiComplianceSummary를 그 자리에서 읽는다). 알림 큐를 거치면 협력사가
자기 화면과 무관한 알림함에서 뒤늦게 발견하게 되어 '제출' 흐름과 끊어진다는 피드백 반영.

멱등: 종합 자체가 협력사당 1회만 생성되므로(ai_synthesis.py의 generated_at 가드)
이 핸들러도 자연히 1회만 호출된다. dedup_key는 수신자 단위로도 붙여 재시도/중복
enqueue에 대비한다(notifications.dedup_key UNIQUE + ON CONFLICT DO NOTHING).
"""
import logging

from sqlalchemy import text

from backend.infrastructure.database import AsyncSessionLocal
from backend.infrastructure.queue import enqueue, NOTIFICATION_QUEUE

logger = logging.getLogger(__name__)

_PRIME_ROLES = ("owner_esg", "owner_purchasing", "admin")


async def notify_ai_synthesis_ready(payload: dict) -> None:
    """SupplierAiSynthesisReady 수신 → 원청(확인 요청) 알림. 협력사 본인은 제출 시점 팝업으로 대체."""
    supplier_id = payload.get("supplier_id")
    if not supplier_id:
        return

    async with AsyncSessionLocal() as db:
        row = (await db.execute(
            text("""
                SELECT company_name, tenant_id, ai_compliance_summary
                FROM suppliers WHERE supplier_id = :s
            """),
            {"s": str(supplier_id)},
        )).first()
        if not row or not row[2]:
            logger.warning("[ai_synthesis_notify] 협력사/요약 없음 (supplier=%s)", supplier_id)
            return
        supplier_name, tenant_id = row[0], (str(row[1]) if row[1] else None)

        prime_users = []
        if tenant_id:
            prime_roles_sql = ", ".join(f"'{r}'" for r in _PRIME_ROLES)
            prime_users = (await db.execute(
                text(f"""
                    SELECT user_id FROM users
                    WHERE tenant_id = :t AND role IN ({prime_roles_sql}) AND is_active = TRUE
                """),
                {"t": tenant_id},
            )).fetchall()

    label = supplier_name or "협력사"
    target = {"focusSupplierId": str(supplier_id)}

    for (uid,) in prime_users:
        await enqueue(
            NOTIFICATION_QUEUE, "process_notification",
            user_id=str(uid), channel="in-app", notification_type="approval_needed",
            subject=f"AI 종합 진단 완료 — {label}",
            body=(
                f"{label}의 소재구성·탄소발자국·실사 자가진단 3종 AI 처리가 모두 끝나 "
                "종합 결론이 준비됐습니다. 협력사 상세에서 확인해 주세요."
            ),
            dedup_key=f"ai_synthesis_prime:{supplier_id}:{uid}",
            target=target,
        )
    logger.info(
        "[ai_synthesis_notify] enqueue 완료 supplier=%s prime_users=%d",
        supplier_id, len(prime_users),
    )
