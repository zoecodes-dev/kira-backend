"""
domains/supplychain/service.py  (담당: 팀원 D · 영수)

공급망 비즈니스 로직. 이벤트 발행은 반드시 infrastructure 계층 경유.
직접 redis import 금지 (수정됨) → event_bus.publish() + queue.enqueue() 사용.
도메인 간 직접 import 금지 → events/types.py의 dataclass로만 통신.
"""
import json
from dataclasses import asdict
from typing import Any, Dict, List

from sqlalchemy.ext.asyncio import AsyncSession

from backend.events.types import GeoRiskDetectedEvent
from backend.infrastructure.event_bus import publish
from backend.infrastructure.trace import trace_node
from backend.domains.supplychain.repository import SupplyChainRepository


class SupplyChainCycleError(ValueError):
    """순환 참조를 만드는 공급망 관계 등록 시도."""


class SupplyRatioExceededError(ValueError):
    """공급 비율 합이 100을 초과."""


class SupplyChainService:
    def __init__(self, repository: SupplyChainRepository):
        self.repository = repository

    # ---------- 공급망 그래프 ----------
    async def get_supply_tree(self, product_id: str) -> List[Dict[str, Any]]:
        """product_id 기준 N차 공급망 트리 조회."""
        return await self.repository.get_n_tier_supply_chain(product_id)

    async def register_relation(
        self,
        bom_version_id: str,
        parent_supplier_id: str | None,
        child_supplier_id: str,
        part_id: str,
    ) -> Dict[str, Any]:
        """
        공급망 관계 등록. 스펙 5-1 유효성 검증:
        1. parent == child 면 거부
        2. 순환 참조 사전 검사 (재귀 CTE)
        """
        if parent_supplier_id is not None and parent_supplier_id == child_supplier_id:
            raise ValueError("parent_supplier_id와 child_supplier_id가 동일할 수 없습니다.")

        if parent_supplier_id is not None:
            if await self.repository.would_create_cycle(
                parent_supplier_id, child_supplier_id
            ):
                raise SupplyChainCycleError(
                    "해당 관계는 공급망에 순환 참조를 발생시킵니다."
                )

        return await self.repository.create_supply_relation(
            bom_version_id, parent_supplier_id, child_supplier_id, part_id
        )

    async def get_alternatives(
        self, product_id: str, part_id: str
    ) -> List[Dict[str, Any]]:
        return await self.repository.get_alternatives(product_id, part_id)

    # ---------- 협력사 통지 및 자진신고 (회사 경계 의무) ----------
    @trace_node("notify_supplier_correction", "agent")
    async def request_supplier_correction(
        self,
        sender_id: str,
        target_supplier_id: str,
        reason: str,
        due_date: str,
        required_docs: list[str]
    ) -> Dict[str, Any]:
        """원청 → 협력사 반려/시정요청 통지. 회사 경계를 넘을 때만 유효함."""
        is_cross = await self.repository.is_cross_company_boundary(sender_id, target_supplier_id)
        if not is_cross:
            raise ValueError("동일 법인 내부이거나 통지 대상이 아닙니다. (회사 경계 의무 없음)")

        payload = {
            "sender_supplier_id": sender_id,
            "target_supplier_id": target_supplier_id,
            "reason": reason,
            "due_date": due_date,
            "required_documents": required_docs,
        }
        # 알림/요청 저장은 Submission 도메인이 수신 후 처리
        await publish("SupplierCorrectionRequested", payload)
        return {"status": "success", "message": "협력사 시정 요청 통지 이벤트가 발행되었습니다."}

    @trace_node("declare_source_change", "agent")
    async def declare_source_change(
        self,
        bom_version_id: str,
        parent_supplier_id: str,
        new_child_supplier_id: str,
        part_id: str,
        reason: str
    ) -> Dict[str, Any]:
        """협력사 자진신고: 공급원 변경 (사후 적발 방지)"""
        if await self.repository.would_create_cycle(parent_supplier_id, new_child_supplier_id):
            raise SupplyChainCycleError("해당 관계는 공급망에 순환 참조를 발생시킵니다.")

        new_map = await self.repository.declare_new_source(
            bom_version_id, parent_supplier_id, new_child_supplier_id, part_id
        )

        # 자진신고 발생 시, 상위 BOM 검증을 위해 이벤트 발행 (Compliance/Verification 트리고)
        payload = {**new_map, "reason": reason}
        await publish("SourceChangeDeclared", payload)
        return new_map

    # ---------- Geo Audit ----------
    def _format_coords(self, geojson_str: str | None) -> list[float]:
        """프론트엔드 및 HITL 화면에서 사용하기 쉽도록 [latitude, longitude] 형태로 반환"""
        if not geojson_str:
            return []
        try:
            geo = json.loads(geojson_str)
            if geo.get("type") == "Point":
                lon, lat = geo["coordinates"]
                return [lat, lon]
        except Exception:
            pass
        return []

    @trace_node("geo_audit_execute", "agent")
    async def execute_geo_audit(self, db: AsyncSession, batch_id: str | None = None) -> List[Dict[str, Any]]:
        """
        공장 위치 기반 Geo Audit 수행. 고위험 지역(신장 등) 판정 시
        GeoRiskDetected 이벤트를 발행한다.
        db 인자는 @trace_node가 audit_trail 기록에 사용.
        """
        audit_results = await self.repository.check_geo_audit_risk_zone()
        mismatch_results = await self.repository.check_coordinate_authenticity(db)

        detected_risks: List[Dict[str, Any]] = []
        for result in audit_results:
            if result.get("is_in_risk_zone"):
                formatted_coords = self._format_coords(result["coordinates"])
                event = GeoRiskDetectedEvent(
                    batch_id=batch_id,
                    factory_id=result["factory_id"],
                    risk_type="xinjiang",
                    supplier_id=result["supplier_id"],
                    company_name=result["company_name"],
                    coordinates=formatted_coords,
                )
                await self._publish_geo_risk(event)
                detected_risks.append(asdict(event))

        for result in mismatch_results:
            if not result.get("country_match"):
                formatted_coords = self._format_coords(result["coordinates"])
                event = GeoRiskDetectedEvent(
                    batch_id=batch_id,
                    factory_id=result["factory_id"],
                    risk_type="country_mismatch",
                    supplier_id=result["supplier_id"],
                    company_name=result["company_name"],
                    coordinates=formatted_coords,
                )
                await self._publish_geo_risk(event)
                detected_risks.append(asdict(event))

        return detected_risks

    async def _publish_geo_risk(self, event: GeoRiskDetectedEvent) -> None:
        """
        GeoRiskDetected 이벤트 발행 (후속 처리는 risk_worker가 통합 처리)
        """
        payload = asdict(event)
        await publish(event.event_name, payload)
