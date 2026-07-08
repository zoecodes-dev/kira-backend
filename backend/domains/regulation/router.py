"""
backend/domains/regulation/router.py  (담당: 팀원 C — 은지)

★ [B1] regulation 도메인 REST API 엔드포인트

[이 파일의 역할]
  규제 관련 HTTP 엔드포인트를 정의한다.
  비즈니스 로직은 service.py에 위임하고,
  이 파일은 HTTP 요청 파싱 + 응답 직렬화만 담당한다.

  [정리] 규제 마스터데이터 목록/단건/적용규제/필수필드 조회(구 /regulations 라우터)와
  /regulation/violations 는 프론트 호출이 전혀 없어 제거됨(2026-07 전수조사). 단,
  이 엔드포인트들이 감싸던 service.py 함수(get_applicable_regulations 등)는
  supplychain.get_gaps()가 내부적으로 여전히 직접 호출하므로 service.py는 그대로 둔다.

[엔드포인트 목록]
  GET  /regulation/materials/regulation-results  규제 판정 목록 §7.1

[레이어 규칙]
  여기(router.py) → service.py → repository.py → models.py  (단방향)
  - router는 db.commit() 하지 않는다.
  - router는 비즈니스 로직을 직접 구현하지 않는다.

[main.py 등록 방법]
  from backend.domains.regulation.router import compliance_router
  app.include_router(compliance_router)
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query, Response
from sqlalchemy.ext.asyncio import AsyncSession

from backend.domains.regulation import service as reg_service
from backend.infrastructure.auth import CurrentUser, get_current_user
from backend.infrastructure.database import get_db
from backend.infrastructure.pagination import set_total_count

# prefix를 /regulation(단수)으로 분리해 기존 /regulations와 충돌 없이 공존
compliance_router = APIRouter(
    prefix="/regulation",
    tags=["Regulation — Compliance Results"],
)


# ============================================================
# [신규 §7.1] GET /regulation/materials/regulation-results
# ============================================================

@compliance_router.get(
    "/materials/regulation-results",
    summary="규제 판정 전체 목록 조회 §7.1",
)
async def list_regulation_results(
    response: Response,
    page: int = Query(1, ge=1, description="페이지 번호 (1-base)"),
    size: int = Query(20, ge=1, le=100, description="페이지 크기"),
    current_user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    compliance_results 전체 조회. HITL 후보(confidence < 0.85) 포함.

    [보안]
      - get_current_user: 미인증 요청 차단 (401)
      - tenant 격리: batches INNER JOIN (get_violations와 동일 패턴)

    [응답 필드]
      result_id, material, supplier_id, supplier_name, regulation,
      verdict(passed/violation/warning/reject), confidence,
      needs_human_review(bool), evidence(배열)

    [응답]
      bare array. 빈 결과 = []. X-Total-Count 헤더 포함.
    """
    items = await reg_service.list_regulation_results(
        db,
        tenant_id=current_user.tenant_id,
        page=page,
        size=size,
    )
    total = await reg_service.count_regulation_results(
        db,
        tenant_id=current_user.tenant_id,
    )
    set_total_count(response, total)
    return items  # bare array


# ============================================================
# [목표3] POST /regulation/analyze-carbon — RAG 기반 탄소 규제 준수 진단 (자동 트리거)
# ============================================================
from pydantic import BaseModel as _BaseModel


class CarbonAnalyzeRequest(_BaseModel):
    carbon_intensity: Optional[float] = None
    energy_source: Optional[str] = None


@compliance_router.post("/analyze-carbon", summary="탄소집약도·에너지원 RAG 규제 준수 진단")
async def analyze_carbon_endpoint(
    body: CarbonAnalyzeRequest,
    db: AsyncSession = Depends(get_db),
    current_user: CurrentUser = Depends(get_current_user),
):
    """추출된 탄소집약도·에너지원을 EU 배터리법 Article 7 조항과 RAG 비교해 위반 여부를 진단한다.
    반환: {verdict, regulation_name, citation, clause_text, reasoning}."""
    from backend.agents.compliance import analyze_carbon_compliance
    return await analyze_carbon_compliance(body.carbon_intensity, body.energy_source, db)


# ============================================================
# [작업1] POST /regulation/analyze-saq — RAG 기반 CSDDD 실사(SAQ) 준수 진단 (자동 트리거)
# ============================================================


class SaqAnalyzeRequest(_BaseModel):
    # 파싱된 SAQ 항목(고충처리 채널·강제노동 징후·준수등급·평가표준·점수 등) 자유 dict.
    saq_fields: dict = {}


@compliance_router.post("/analyze-saq", summary="실사 자가진단(SAQ) RAG 기반 CSDDD 준수 진단")
async def analyze_saq_endpoint(
    body: SaqAnalyzeRequest,
    db: AsyncSession = Depends(get_db),
    current_user: CurrentUser = Depends(get_current_user),
):
    """파싱된 SAQ 항목을 CSDDD(공급망 실사 지침) 조항과 RAG 비교해 인권/환경 실사 위반 여부를 진단한다.
    반환: {verdict, regulation_name, citation, clause_text, reasoning}."""
    from backend.agents.compliance import analyze_saq_compliance
    return await analyze_saq_compliance(body.saq_fields, db)