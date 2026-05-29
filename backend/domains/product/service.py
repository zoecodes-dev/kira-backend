# domains/product/service.py
"""
Product Domain — 비즈니스 로직 레이어
계층 호출 방향: router → service → repository → models (역방향 금지)
이벤트 발행: publish(event_name, payload) 2-인자, payload=dataclasses.asdict(이벤트)
"""

from __future__ import annotations

import dataclasses
from datetime import datetime, timezone
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from backend.domains.product.models import BomVersion, Part, Product
from backend.domains.product.repository import ProductRepository
from backend.domains.product.state_machine import transition_bom_status
from backend.events.types import (
    BOMImportedEvent,
    LotImportedEvent,
    ProductImportedEvent,
)
from backend.infrastructure.event_bus import publish
from backend.infrastructure.trace import trace_node


# ──────────────────────────────────────────────
# 내부 헬퍼
# ──────────────────────────────────────────────

def _now() -> datetime:
    return datetime.now(timezone.utc)


# ──────────────────────────────────────────────
# 1. Product Ingest
# ──────────────────────────────────────────────

@trace_node("product_import", "agent")
async def import_product(
    db: AsyncSession,
    *,
    product_code: str,
    product_name: str | None = None,
    manufacturer_id: UUID | None = None,
    specs: dict | None = None,
    source_system: str = "ERP_PLM",
    external_id: str | None = None,
) -> Product:
    """
    원청 ERP/PLM에서 동기화된 제품을 upsert한다.
    product_code 중복 시 409는 router 레이어에서 처리.
    발행: ProductImported → A(Audit Trail)
    """
    repo = ProductRepository(db)

    existing = await repo.get_by_code(product_code)
    if existing:
        # 재동기화: synced_at·external_id 갱신
        existing.product_name = product_name or existing.product_name
        existing.manufacturer_id = manufacturer_id or existing.manufacturer_id
        existing.specs = specs or existing.specs
        existing.source_system = source_system
        existing.external_id = external_id
        existing.synced_at = _now()
        await db.flush()
        product = existing
    else:
        product = await repo.create_product(
            product_code=product_code,
            product_name=product_name,
            manufacturer_id=manufacturer_id,
            specs=specs,
            source_system=source_system,
            external_id=external_id,
        )

    # ── 이벤트 발행 ──────────────────────────
    # ProductImportedEvent 시그니처:
    #   product_id: Optional[UUID]
    #   external_id: Optional[str]
    #   event_name: str = "ProductImported"
    #   occurred_at: datetime
    event = ProductImportedEvent(
        product_id=product.product_id,
        external_id=product.external_id,
    )
    await publish(event.event_name, dataclasses.asdict(event))

    return product


# ──────────────────────────────────────────────
# 2. Lot(Batch) Ingest
# ──────────────────────────────────────────────

@trace_node("lot_import", "agent")
async def import_lot(
    db: AsyncSession,
    *,
    batch_id: UUID,
    product_id: UUID,
    external_id: str | None = None,
) -> None:
    """
    원청 ERP에서 배치(Lot) 동기화 시 호출.
    batches row 생성은 Ingest Worker(B)가 담당하며,
    이 함수는 Product Domain 감사 이벤트 기록 역할만 수행.
    발행: LotImported → A(Audit Trail)
    """
    # ── 이벤트 발행 ──────────────────────────
    # LotImportedEvent 시그니처:
    #   batch_id: Optional[UUID]
    #   product_id: Optional[UUID]
    #   external_id: Optional[str]
    #   event_name: str = "LotImported"
    #   occurred_at: datetime
    event = LotImportedEvent(
        batch_id=batch_id,
        product_id=product_id,
        external_id=external_id,
    )
    await publish(event.event_name, dataclasses.asdict(event))


# ──────────────────────────────────────────────
# 3. BOM Version 생성 & Ingest
# ──────────────────────────────────────────────

@trace_node("bom_import", "agent")
async def import_bom_version(
    db: AsyncSession,
    *,
    product_id: UUID,
    version_number: str,
    effective_from: datetime | None = None,
    source_system: str = "ERP_PLM",
    external_id: str | None = None,
) -> BomVersion:
    """
    BOM 버전을 신규 생성(draft)하고 BOMImported 이벤트를 발행한다.
    active 전환은 별도 PATCH /bom-versions/{vid}/status 엔드포인트에서 수행.
    발행: BOMImported → A(Audit Trail)
    """
    repo = ProductRepository(db)
    bom_ver = await repo.create_bom_version(
        product_id=product_id,
        version_number=version_number,
        effective_from=effective_from,
        source_system=source_system,
        external_id=external_id,
    )

    # ── 이벤트 발행 ──────────────────────────
    # BOMImportedEvent 시그니처:
    #   product_id: Optional[UUID]
    #   bom_version_id: Optional[UUID]
    #   external_id: Optional[str]
    #   event_name: str = "BOMImported"
    #   occurred_at: datetime
    event = BOMImportedEvent(
        product_id=product_id,
        bom_version_id=bom_ver.bom_version_id,
        external_id=bom_ver.external_id,
    )
    await publish(event.event_name, dataclasses.asdict(event))

    return bom_ver


# ──────────────────────────────────────────────
# 4. BOM 상태 전이 (draft → active → deprecated)
# ──────────────────────────────────────────────

async def update_bom_status(
    db: AsyncSession,
    *,
    bom_version_id: UUID,
    new_status: str,
    actor_id: UUID,
) -> BomVersion:
    """
    BOM 버전 상태를 전이한다.
    직접 UPDATE 금지 — 반드시 state_machine.transition_bom_status 경유.
    active 전환 시 동일 product의 기존 active 버전을 자동 deprecated 처리.
    """
    return await transition_bom_status(
        db,
        bom_version_id=bom_version_id,
        new_status=new_status,
        actor_id=actor_id,
    )


# ──────────────────────────────────────────────
# 5. Part 등록
# ──────────────────────────────────────────────

@trace_node("part_create", "agent")
async def create_part(
    db: AsyncSession,
    *,
    part_code: str,
    part_name: str | None = None,
    tier_level: int | None = None,
    parent_part_id: UUID | None = None,
    hs_code: str | None = None,
    material_type: str | None = None,
    function_purpose: str | None = None,
    unit_price: float | None = None,
    purchase_unit: str | None = None,
    specs: dict | None = None,
    source_system: str = "ERP_PLM",
    external_id: str | None = None,
) -> Part:
    """
    부품 마스터를 등록한다.
    hs_code 6자리 미만이면 ValueError → router에서 422로 변환.
    part_code 중복이면 ValueError → router에서 409로 변환.
    """
    if hs_code is not None and len(hs_code.strip()) < 6:
        raise ValueError(
            f"hs_code는 최소 6자리 이상이어야 합니다. 입력값: '{hs_code}'"
        )

    repo = ProductRepository(db)
    return await repo.create_part(
        part_code=part_code,
        part_name=part_name,
        tier_level=tier_level,
        parent_part_id=parent_part_id,
        hs_code=hs_code,
        material_type=material_type,
        function_purpose=function_purpose,
        unit_price=unit_price,
        purchase_unit=purchase_unit,
        specs=specs,
        source_system=source_system,
        external_id=external_id,
    )


# ──────────────────────────────────────────────
# 6. BOM 트리 조회
# ──────────────────────────────────────────────

async def get_bom_tree(db: AsyncSession, *, product_id: UUID) -> list[dict]:
    """
    활성 BOM 버전 기준 5계층(Pack→Module→Cell→전구체→광물) 중첩 JSON 반환.
    repository의 재귀 CTE를 위임.
    """
    repo = ProductRepository(db)
    return await repo.get_bom_tree_recursive(product_id=product_id)
