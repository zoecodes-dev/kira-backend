from uuid import UUID
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from pydantic import BaseModel

from backend.infrastructure.database import get_db
from backend.infrastructure.auth import CurrentUser, get_current_user
from backend.domains.risk.service import calculate_risk_score, resolve_risk
from backend.domains.risk.repository import RiskRepository
from backend.infrastructure.trace import trace_tool


router = APIRouter(prefix="/risk", tags=["Risk"])

class ViolationItem(BaseModel):
    type: str  # 'compliance_violation', 'compliance_reject', 'GeoRiskDetected', 'compliance_warning'
    reason: str

class StageRiskRequest(BaseModel):
    batch_id: UUID
    supplier_id: UUID
    violations: list[ViolationItem]

class ResolveRiskRequest(BaseModel):
    batch_id: UUID | None = None  # 종결 계기가 된 배치(선택)
    note: str | None = None       # 종결 사유 메모(감사)


@router.post("/stage-risk")
async def execute_stage_risk(req: StageRiskRequest, db: AsyncSession = Depends(get_db)):
    result = await calculate_risk_score(
        db=db,
        batch_id=req.batch_id,
        supplier_id=req.supplier_id,
        violations=[v.model_dump() for v in req.violations]
    )
    return result

@router.post("/{supplier_id}/resolve")
@trace_tool("resolve_risk")
async def resolve_risk_endpoint(
    supplier_id: UUID,
    req: ResolveRiskRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    [API] POST /risk/{supplier_id}/resolve — 협력사 리스크를 종결 처리한다.
    점수/고위험 플래그를 리셋하고 RiskResolved 이벤트를 발행한다.
    resolved_by 는 인증 사용자(감사).
    """
    return await resolve_risk(
        db,
        supplier_id=supplier_id,
        resolved_by=current_user.user_id,
        batch_id=req.batch_id,
        note=req.note,
    )

@router.get("/scores")
@trace_tool("get_risk_scores")
async def get_risk_scores(level: str | None = None, db: AsyncSession = Depends(get_db)):
    """
    [API] GET /risk/scores
    프론트엔드 대시보드를 위한 리스크 목록, 점수, 등급별 조회 API입니다.
    """
    return await RiskRepository.list_profiles(db, level=level)

@router.get("/{batch_id_or_supplier_id}")
@trace_tool("get_risk_score_detail")
async def get_risk_score_detail(batch_id_or_supplier_id: UUID, db: AsyncSession = Depends(get_db)):
    """
    [API] GET /risk/{batch_id_or_supplier_id}
    특정 협력사의 리스크 상세(감점 사유 등)를 조회합니다.
    """
    profile = await RiskRepository.get_by_supplier_id(db, batch_id_or_supplier_id)
    if not profile:
        raise HTTPException(status_code=404, detail="리스크 프로필을 찾을 수 없습니다.")
    return profile
