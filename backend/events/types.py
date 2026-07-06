"""
events/types.py  ← 이 파일만 팀 전체가 공유 (스펙 7장 계약 + backend_md_additions I·E-1절)

도메인 간 직접 import 금지. 통신은 이 이벤트 타입 + event_bus.publish()로만.
각자 자기 이벤트 타입을 여기에 추가한다. (총 30종)

payload는 JSON 직렬화 가능해야 하며, event_bus.publish(event_name, payload)에
넣을 dict는 dataclasses.asdict()로 변환해 전달한다.

출처:
- spec 7장 본문/표: Product, Supplier, Submission, Verification, Risk,
  GeoRiskDetected, ComplianceCompleted, HITL
- backend_md_additions I·E-1절: RiskProfileUpdated, FactoryRegulationChanged,
  SubmissionStatusChanged
- 폴더·큐·도메인·state·이벤트 전부 verification으로 통일 (events/types.py 기준).
"""
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional
from uuid import UUID

from pydantic import BaseModel, field_validator

# UTC 시간 생성 헬퍼 함수
def _now_utc() -> datetime:
    return datetime.now(timezone.utc)

# ============================================================
# (Product ingest 이벤트 CustomerImported/BOMImported/ProductImported/LotImported 는
#  구독자 부재로 전부 제거됨 — import_products 는 UPSERT만 수행하고 이벤트를 발행하지 않는다.)
# ============================================================
# Supplier (B)
# ============================================================
@dataclass
class SupplierInvitedEvent:
    supplier_id: Optional[UUID] = None
    email: Optional[str] = None
    sla_due_date: Optional[datetime] = None
    # [G1] 협력사→협력사 초대 시 '이동 주체'(초대한 협력사). 직접 등록이면 None.
    #   수신: D(supplychain)가 supply_chain_map.discovered_via 에 기록 → pool 구축.
    inviter_supplier_id: Optional[UUID] = None
    event_name: str = "SupplierInvited"
    occurred_at: datetime = field(default_factory=_now_utc)


@dataclass
class SupplierConnectedEvent:
    supplier_id: Optional[UUID] = None
    tier: Optional[int] = None
    event_name: str = "SupplierConnected"
    occurred_at: datetime = field(default_factory=_now_utc)


@dataclass
class SupplierStatusChangedEvent:
    supplier_id: Optional[UUID] = None
    from_status: Optional[str] = None
    to_status: Optional[str] = None
    event_name: str = "SupplierStatusChanged"
    occurred_at: datetime = field(default_factory=_now_utc)


@dataclass
class RiskProfileUpdatedEvent:
    """
    overall_risk_score 변경 시 발행. 발행: B / 수신: A(StateGraph 참조).
    payload 핵심 필드: supplier_id, overall_risk_score (+ 수신측 편의로 risk_level 동봉).
    """
    supplier_id: Optional[UUID] = None
    overall_risk_score: Optional[int] = None
    risk_level: Optional[str] = None
    event_name: str = "RiskProfileUpdated"
    occurred_at: datetime = field(default_factory=_now_utc)


@dataclass
class SupplierDocumentUploadedEvent:
    """
    협력사가 필요문서(*_doc_url)를 새로 업로드(S3 키 변경)했을 때 발행.
    발행: B(supplier) → 수신: E(submission)가 submission_documents 행 생성 + 파싱 큐 enqueue.

    s3_key: files 버킷 내 키(영구 URL 아님). data_gateway가 이 키로 바이트를 읽어 파싱한다.
    doc_kind: 'business_reg' | 'environmental_report' | 'self_assessment' | 'material_composition'
    """
    supplier_id: Optional[UUID] = None
    s3_key: Optional[str] = None
    file_name: Optional[str] = None
    doc_kind: Optional[str] = None
    event_name: str = "SupplierDocumentUploaded"
    occurred_at: datetime = field(default_factory=_now_utc)


@dataclass
class FactoryRegulationChangedEvent:
    """
    공장의 applicable_regulations 컬럼 수정 시 발행. (backend_md_additions I절)
    발행: B → 수신: C(Compliance)
    """
    factory_id: Optional[UUID] = None
    supplier_id: Optional[UUID] = None
    applicable_regulations: list = field(default_factory=list)
    event_name: str = "FactoryRegulationChanged"
    occurred_at: datetime = field(default_factory=_now_utc)


# ============================================================
# Submission (E)
# ============================================================
@dataclass
class SubmissionRequestedEvent:
    request_id: Optional[UUID] = None
    supplier_id: Optional[UUID] = None
    due_date: Optional[datetime] = None
    event_name: str = "SubmissionRequested"
    occurred_at: datetime = field(default_factory=_now_utc)


@dataclass
class SubmissionStartedEvent:
    request_id: Optional[UUID] = None
    supplier_id: Optional[UUID] = None
    event_name: str = "SubmissionStarted"
    occurred_at: datetime = field(default_factory=_now_utc)


@dataclass
class SubmissionCompletedEvent:
    request_id: Optional[UUID] = None
    batch_id: Optional[UUID] = None
    submission_mode: str = "file"       # 'file' | 'form' — 폼 직접입력(파일 없음) 케이스 수용 (#9-B/#3)
    file_urls: list = field(default_factory=list)        # submission_mode='file'일 때
    confirmed_fields: dict = field(default_factory=dict) # 협력사가 AI 파싱결과를 확정한 필드 (#3 확인 루프)
    event_name: str = "SubmissionCompleted"
    occurred_at: datetime = field(default_factory=_now_utc)


@dataclass
class SubmissionRejectedEvent:
    request_id: Optional[UUID] = None
    reason: Optional[str] = None
    event_name: str = "SubmissionRejected"
    occurred_at: datetime = field(default_factory=_now_utc)


@dataclass
class SubmissionApprovedEvent:
    request_id: Optional[UUID] = None
    batch_id: Optional[UUID] = None
    event_name: str = "SubmissionApproved"
    occurred_at: datetime = field(default_factory=_now_utc)


@dataclass
class SubmissionStatusChangedEvent:
    """
    submission 상태 전이 시 자동 발행 (audit 자동 기록용).
    (backend_md_additions E-1절 / spec 7장)
    발행: E → 수신: Audit, Notification
    """
    request_id: Optional[UUID] = None
    from_status: Optional[str] = None
    to_status: Optional[str] = None
    event_name: str = "SubmissionStatusChanged"
    occurred_at: datetime = field(default_factory=_now_utc)


# ============================================================
# SupplyChain / Geo (D · 영수) — 본 도메인에서 실제 발행
# ============================================================
@dataclass
class SupplyChainGapDetectedEvent:
    """
    공급망 맵 gap→자료요청 트리거. 어떤 협력사 노드가 규제 필수 필드를 미보유해서
    '자료 제출 요청'이 필요하다는 사실을 발행한다. (노드 1개당 이벤트 1건)

    발행: D(supplychain) — POST /trigger-data-requests 는 gap을 계산해 이 이벤트만
      노드별로 발행하고 즉시 202를 반환한다(요청 생성은 동기 아님).
    수신: E(submission)가 create_and_request_submission 으로 data_request 를 생성.
      → submission 이 자기 트랜잭션·커밋 소유. supplychain 은 submission repository/service
        를 직접 import 하지 않는다(규칙 #4 정면 준수).

    requester_user_id / actor_id / due_date 는 트리거 요청 맥락(누가·언제까지)이라
      payload 에 실어 submission 이 그대로 사용한다. requested_data_type 은 미보유 필드명
      CSV(예: "carbon_intensity,mine_coordinates").
    """
    product_id: Optional[UUID] = None
    supplier_id: Optional[UUID] = None
    requested_data_type: Optional[str] = None
    requester_user_id: Optional[UUID] = None
    actor_id: Optional[UUID] = None
    due_date: Optional[datetime] = None
    event_name: str = "SupplyChainGapDetected"
    occurred_at: datetime = field(default_factory=_now_utc)


@dataclass
class GeoRiskDetectedEvent:
    """
    고위험 지역 판정 또는 좌표 불일치 발견 시 발행.
    발행: D(SupplyChain/Geo Audit) → 수신: A(Supervisor 라우팅), Risk
    spec 7장 payload 핵심 필드: batch_id, factory_id, risk_type
    """
    batch_id: Optional[UUID] = None
    factory_id: Optional[UUID] = None
    risk_type: Optional[str] = None        # "xinjiang" | "eudr" | "country_mismatch"
    supplier_id: Optional[UUID] = None
    company_name: Optional[str] = None
    coordinates: Optional[str] = None
    event_name: str = "GeoRiskDetected"
    occurred_at: datetime = field(default_factory=_now_utc)


# ============================================================
# Risk (E)
# ============================================================
@dataclass
class RiskDetectedEvent:
    batch_id: Optional[UUID] = None
    risk_score: Optional[float] = None
    event_name: str = "RiskDetected"
    occurred_at: datetime = field(default_factory=_now_utc)


@dataclass
class RiskEscalatedEvent:
    batch_id: Optional[UUID] = None
    reason: Optional[str] = None
    event_name: str = "RiskEscalated"
    occurred_at: datetime = field(default_factory=_now_utc)


@dataclass
class RiskResolvedEvent:
    batch_id: Optional[UUID] = None
    resolved_by: Optional[UUID] = None
    event_name: str = "RiskResolved"
    occurred_at: datetime = field(default_factory=_now_utc)


# ============================================================
# Compliance (C)
# ============================================================
@dataclass
class ComplianceCompletedEvent:
    batch_id: Optional[UUID] = None
    verdicts: dict = field(default_factory=dict)
    event_name: str = "ComplianceCompleted"
    occurred_at: datetime = field(default_factory=_now_utc)


# ============================================================
# HITL (A)
# ============================================================
@dataclass
class HITLRequestedEvent:
    batch_id: Optional[UUID] = None
    reason: Optional[str] = None
    reviewer_id: Optional[UUID] = None
    event_name: str = "HITLRequested"
    occurred_at: datetime = field(default_factory=_now_utc)


@dataclass
class HITLAssignedEvent:
    review_id: Optional[UUID] = None
    batch_id: Optional[UUID] = None
    reviewer_id: Optional[UUID] = None
    event_name: str = "HITLAssigned"
    occurred_at: datetime = field(default_factory=_now_utc)


@dataclass
class HITLApprovedEvent:
    review_id: Optional[UUID] = None
    batch_id: Optional[UUID] = None
    reviewer_id: Optional[UUID] = None
    note: Optional[str] = None
    event_name: str = "HITLApproved"
    occurred_at: datetime = field(default_factory=_now_utc)


@dataclass
class HITLRejectedEvent:
    review_id: Optional[UUID] = None
    batch_id: Optional[UUID] = None
    reviewer_id: Optional[UUID] = None
    reason: Optional[str] = None
    event_name: str = "HITLRejected"
    occurred_at: datetime = field(default_factory=_now_utc)


# ============================================================
# ValidationResult + validate_schema (B)
# ============================================================
@dataclass
class ValidationResult:
    """스키마 검증 결과. 누락 필드와 정규화된 값을 담는다."""
    ok: bool
    missing_fields: list[str] = field(default_factory=list)
    normalized: dict = field(default_factory=dict)


# ============================================================
# [비활성화 2026-07] RecycledMaterialsSchema — 재활용 함량 판정 제거에 따라 폐기.
#   재활용 함량은 입력받는 값이 아니고(마스터폼·문서추출·전용 테이블 부재),
#   supplier_recycler_details 테이블도 스키마에 존재하지 않던 dangling 계약이었음.
#   compliance.py judge_recycled_content 비활성화와 동기화. 입력 경로가 생기면 복구할 것.
# ============================================================
# class RecycledMaterialsSchema(BaseModel):
#     """
#     supplier_recycler_details.recycled_materials JSONB 의 공식 구조.
#     key = 소문자 원소기호(co/ni/li/pb), value = 재활용 함량(%).
#     B(저장)·C(검증)가 동일 클래스를 공유해 key 불일치를 구조적으로 차단한다.
#     """
#     co: Optional[float] = None   # 코발트 함량 %
#     ni: Optional[float] = None   # 니켈 함량 %
#     li: Optional[float] = None   # 리튬 함량 %
#     pb: Optional[float] = None   # 납 함량 %
#
#     @field_validator("co", "ni", "li", "pb")
#     @classmethod
#     def _pct_range(cls, v):
#         if v is not None and not (0 <= v <= 100):
#             raise ValueError("재활용 함량은 0~100% 범위여야 합니다")
#         return v
#
#     model_config = {"extra": "forbid"}   # 정의 안 된 key 저장 시 에러 → 오타·오용 즉시 발견