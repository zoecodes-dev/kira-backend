"""
handlers/supplier_invited.py — SupplierInvited → supply_chain_map 편입/discovered_via 기록

협력사→협력사 초대(상위가 하위를 풀에 편입)가 일어나면 supplier 도메인이
SupplierInvited 이벤트를 발행한다. 여기서 그 '발견 경로'(누가 초대했는지)를
supply_chain_map.discovered_via 에 백필하고, 엣지가 아직 없으면(캐스케이드 초대 등)
초대한 상위 협력사가 연결된 bom_version에 하위를 자동으로 엣지 편입시킨다.

배선 근거: events/types.py SupplierInvitedEvent 주석 —
  "수신: D(supplychain)가 supply_chain_map.discovered_via 에 기록 → pool 구축."

도메인 경계: 이 핸들러(슬롯)는 supplychain 소유 테이블(supply_chain_map)에만 쓴다.
  supplier 도메인은 SupplierInvited 이벤트만 발행하고 직접 쓰지 않는다.

멱등성: discovered_via 가 이미 채워진 엣지는 건드리지 않는다(NULL 인 것만 백필).
  자동 편입도 (bom_version, child) 조합이 이미 있으면 건너뛴다(중복 엣지 방지).
"""
import logging
from datetime import datetime, timezone

from sqlalchemy import text

from backend.core.config import config
from backend.infrastructure.database import AsyncSessionLocal
from backend.infrastructure.mail import send_email
from backend.domains.supplychain.repository import SupplyChainRepository
from backend.domains.supplychain.service import SupplyChainService

logger = logging.getLogger(__name__)


async def supplychain_record_discovered_via(payload: dict) -> None:
    """SupplierInvited 수신 → 초대한 상위 협력사를 하위 엣지 discovered_via 에 기록.

    엣지가 이미 있으면(=하위가 다른 경로로 먼저 연결된 경우) discovered_via만 백필.
    엣지가 아직 없으면(캐스케이드 초대 등으로 갓 생성된 협력사) — 초대한 상위 협력사가
    이미 연결돼 있는 모든 bom_version에 하위를 자동으로 편입시킨다(부품도 필요하면 자동 생성).
    상위가 아직 어느 맵에도 연결 안 됐으면(상위도 고아) 자동 편입할 기준이 없어 건너뛴다.
    """
    invitee_supplier_id = payload.get("supplier_id")
    inviter_supplier_id = payload.get("inviter_supplier_id")

    # 직접 등록(초대자 없음)이면 기록할 발견 경로도, 편입시킬 상위 엣지도 없다.
    if not invitee_supplier_id or not inviter_supplier_id:
        return

    async with AsyncSessionLocal() as db:
        repo = SupplyChainRepository(db)
        updated = await repo.record_discovered_via(
            invitee_supplier_id=str(invitee_supplier_id),
            inviter_supplier_id=str(inviter_supplier_id),
        )

        connected_bom_versions: list[str] = []
        if updated == 0:
            target_bom_versions = await repo.get_unconnected_parent_bom_versions(
                parent_supplier_id=str(inviter_supplier_id),
                child_supplier_id=str(invitee_supplier_id),
            )
            service = SupplyChainService(repo)
            for bom_version_id in target_bom_versions:
                try:
                    await service.connect_child_supplier(
                        bom_version_id=bom_version_id,
                        parent_supplier_id=str(inviter_supplier_id),
                        child_supplier_id=str(invitee_supplier_id),
                    )
                    connected_bom_versions.append(bom_version_id)
                except Exception:
                    logger.exception(
                        "[supplier_invited] 자동 편입 실패 invitee=%s inviter=%s bom_version=%s",
                        invitee_supplier_id, inviter_supplier_id, bom_version_id,
                    )

        await db.commit()

    logger.info(
        "[supplier_invited] discovered_via 백필 invitee=%s inviter=%s edges=%d 자동편입=%s",
        invitee_supplier_id, inviter_supplier_id, updated, connected_bom_versions,
    )


async def send_supplier_invitation_email(payload: dict) -> None:
    """SupplierInvited 수신 → 초대(가입 요청) 메일을 SES로 발송.

    수신자는 아직 계정이 없을 수 있는 협력사(미가입 n차)라, user_id 기반 notifications
    가 아니라 payload 의 email 로 직접 발송한다.

    동일일자 중복발송 방지(#4): 새 테이블 없이 기존 멱등 원장(processed_jobs)에
      'invite_email:{supplier_id}:{YYYY-MM-DD}' 키를 선점(ON CONFLICT DO NOTHING)한다.
      선점 성공(첫 발송)일 때만 실제 발송한다.
    """
    invitee_supplier_id = payload.get("supplier_id")
    email = payload.get("email")
    if not invitee_supplier_id or not email:
        return

    today = datetime.now(timezone.utc).date().isoformat()
    dedup_key = f"invite_email:{invitee_supplier_id}:{today}"

    async with AsyncSessionLocal() as db:
        claimed = (
            await db.execute(
                text("""
                    INSERT INTO processed_jobs (idempotency_key, queue_name, status)
                    VALUES (:key, 'notification_queue', 'done')
                    ON CONFLICT (idempotency_key) DO NOTHING
                    RETURNING idempotency_key
                """),
                {"key": dedup_key},
            )
        ).first()
        await db.commit()

    # 오늘 이미 발송(선점 실패)했으면 조용히 스킵.
    if claimed is None:
        logger.info("[supplier_invited] 동일일자 중복발송 스킵 key=%s", dedup_key)
        return

    # /supplier/* 는 /partner/* 리다이렉트 별칭으로만 남음(프론트 2026-07 이동) — 직접 새 경로 사용.
    signup_url = f"{config.FRONTEND_BASE_URL}/partner/onboarding?supplierId={invitee_supplier_id}"
    subject = "[KIRA] 공급망 정보 제공 협조 요청 (회원가입 및 자료 입력)"
    body_text = (
        "안녕하세요, KIRA 공급망 데이터 플랫폼입니다.\n\n"
        "귀사가 상위 협력사의 공급망 맵에 포함되어, 회원가입 및 공급망 정보 입력을 요청드립니다.\n"
        "아래 링크로 접속하시면 제3자 정보제공 동의 후 자료 입력을 진행하실 수 있습니다.\n\n"
        f"접속 링크: {signup_url}\n\n"
        "※ 본 메일은 표준 템플릿으로 발송되었습니다.\n"
    )
    await send_email(email, subject, body_text=body_text)
    logger.info("[supplier_invited] 초대 메일 발송 시도 to=%s supplier=%s", email, invitee_supplier_id)
