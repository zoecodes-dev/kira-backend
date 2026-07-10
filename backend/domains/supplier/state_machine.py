"""
domains/supplier/state_machine.py  (담당: 팀원 B)

협력사 status 전이 엔진. 모든 status 변경은 transition_supplier_status()를 통한다
(직접 대입 금지). 전이 매트릭스로 "현재 → 갈 수 있는 상태"를 검증한다.

[정합 수정 요지]
- 상태값을 schema.sql suppliers.status 허용값(접두어 supplier_*) 7종으로 전면 교정.
  (구 'pending'/'verified' 등 바닐라 표기 → 'supplier_pending'/'supplier_verified')
- SupplierStatusChangedEvent를 from_status/to_status로 발행(types.py 정합).
- @trace_node node_type은 audit_trail.chk_audit_node_type(agent/tool/human) 중
  'agent'를 쓴다(구 'system'/'state_machine'은 허용값 아님).

[미배선 안내 — 2026-07 정리]
  실제 서비스 흐름(domains/supplier/service.py)의 status 전이는 이 파일이 아니라
  repository.set_supplier_status()(supplier_status_history 감사 기록 포함)를 직접
  호출한다. 이 파일의 함수들은 현재 어디에서도 import되지 않는 미배선 상태다.
  전이 매트릭스 검증이 필요하면 이 파일을 service.py에 연결하거나, 불필요하면
  파일 자체를 제거하는 방향을 검토할 것(둘 다 하지 않고 방치하지 말 것).
"""
import dataclasses
from typing import Any, Dict

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from backend.infrastructure.event_bus import publish
from backend.infrastructure.trace import trace_node
from backend.domains.supplier.models import Supplier
from backend.events.types import SupplierStatusChangedEvent


# ── 상태 전이 매트릭스 (schema.sql suppliers.status 7종, 전부 접두어) ──
SUPPLIER_TRANSITIONS: Dict[str, list] = {
    "supplier_pending":     ["supplier_requested"],                          # 등록 → 자료요청 발송
    "supplier_requested":   ["supplier_in_progress"],                        # 요청 → 협력사 입력중
    "supplier_in_progress": ["supplier_review"],                             # 입력완료 → 검토대기
    "supplier_review":      ["supplier_verified", "supplier_violation"],     # 검토 → 통과/위반
    "supplier_verified":    ["supplier_violation", "supplier_suspended"],    # 검증 → 사후 위반/정지
    "supplier_violation":   ["supplier_review", "supplier_suspended"],       # 위반 → 재검토/정지
    "supplier_suspended":   ["supplier_review"],                             # 정지 → 재검토 복귀
}


@trace_node(node_name="transition_supplier_status", node_type="agent")
async def transition_supplier_status(
    db: AsyncSession,
    supplier: Supplier,
    new_status: str,
    batch_id: str = None,
) -> Supplier:
    """
    협력사 status를 전이 매트릭스에 따라 변경한다.
    - 허용되지 않는 전이면 ValueError.
    - flush까지만(커밋은 호출자/service). batch_id가 있으면 @trace_node가 감사 기록.
    - SupplierStatusChanged 발행은 호출자(service)가 커밋 성공 후 수행한다
      (from_status를 잃지 않도록 전이 직전 값을 호출자가 캡처해 넘긴다).
    """
    current = supplier.status
    allowed = SUPPLIER_TRANSITIONS.get(current, [])

    if new_status not in allowed:
        raise ValueError(
            f"허용되지 않는 상태 전이: {current} → {new_status} (가능: {allowed})"
        )

    supplier.status = new_status
    db.add(supplier)
    await db.flush()
    return supplier


@trace_node(node_name="verify_supplier_node", node_type="agent")
async def verify_supplier(state: Dict[str, Any], db: AsyncSession) -> Dict[str, Any]:
    """
    [상태 전이 예시] 협력사 상태를 'supplier_verified'로 변경하고 이벤트를 발행한다.
    """
    supplier_id = state.get("supplier_id")
    if not supplier_id:
        raise ValueError("State must contain a 'supplier_id'")

    stmt = select(Supplier).where(Supplier.supplier_id == supplier_id)
    res = await db.execute(stmt)
    supplier = res.scalar_one_or_none()
    if not supplier:
        raise ValueError(f"Supplier with id {supplier_id} not found.")

    # 전이 직전 상태를 캡처(이벤트의 from_status로 사용)
    from_status = supplier.status

    # 상태 변경 (직접 대입 금지 — 반드시 transition_supplier_status 경유)
    await transition_supplier_status(
        db, supplier, "supplier_verified", batch_id=state.get("batch_id")
    )
    await db.commit()

    # 커밋 성공 후 이벤트 발행 (from_status / to_status — types.py 정합)
    event = SupplierStatusChangedEvent(
        supplier_id=supplier.supplier_id,
        from_status=from_status,
        to_status="supplier_verified",
    )
    await publish("SupplierStatusChanged", dataclasses.asdict(event))

    return state
