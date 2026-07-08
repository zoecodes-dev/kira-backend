from uuid import UUID
from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession
from pydantic import BaseModel

from backend.infrastructure.database import get_db
from backend.infrastructure.auth import CurrentUser, get_current_user
from backend.domains.risk.service import resolve_risk
from backend.infrastructure.trace import trace_tool

# [정리] POST /stage-risk, GET /scores, GET /{batch_id_or_supplier_id} 는 프론트 호출이
# 전혀 없어 제거됨(2026-07 전수조사). calculate_risk_score()는 agents/automation.py가
# 내부에서 직접 호출하므로 service.py는 그대로 둔다 — HTTP 래퍼만 제거.

router = APIRouter(prefix="/risk", tags=["Risk"])


class ResolveRiskRequest(BaseModel):
    batch_id: UUID | None = None  # 종결 계기가 된 배치(선택)
    note: str | None = None       # 종결 사유 메모(감사)


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
