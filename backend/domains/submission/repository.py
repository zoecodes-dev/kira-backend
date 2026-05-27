"""
Submission 도메인 Data Access 계층 (Repository)

[설계 의도]
이곳에는 SQLAlchemy를 이용한 순수한 DB I/O(SELECT, INSERT) 로직만 위치합니다.
비즈니스 로직이나 복잡한 상태 전이(상태 머신 호출)는 포함하지 않음으로써,
데이터베이스 접근 로직과 비즈니스 룰을 명확히 분리(Separation of Concerns)합니다.
"""
import uuid
from typing import Optional
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from backend.domains.submission.models import DataRequestLog

async def create_data_request(db: AsyncSession, log_record: DataRequestLog) -> DataRequestLog:
    """
    [INSERT] 새로운 공급망 데이터 요청(DataRequestLog) 마스터 기록을 DB에 삽입합니다.
    * 주의: 초기 PENDING 상태 삽입 목적으로만 사용합니다.
      이후의 상태 전이(UPDATE)는 반드시 state_machine.py의 transition_submission()을 거쳐야 
      submission_status_history에 감사 이력이 남습니다.
    """
    db.add(log_record)
    await db.flush()
    return log_record

async def get_data_request(db: AsyncSession, request_id: uuid.UUID) -> Optional[DataRequestLog]:
    """
    [SELECT] 단건 데이터 요청 내역을 PK(request_id) 기반으로 조회합니다.
    상태 변경 전후로 최신 상태를 불러오거나 상세 페이지를 렌더링할 때 사용됩니다.
    """
    stmt = select(DataRequestLog).where(DataRequestLog.request_id == request_id)
    result = await db.execute(stmt)
    return result.scalar_one_or_none()

async def list_data_requests(
    db: AsyncSession,
    supplier_id: Optional[uuid.UUID] = None,
    status: Optional[str] = None,
    skip: int = 0,
    limit: int = 100
) -> list[DataRequestLog]:
    """
    [SELECT] 조건에 맞는 데이터 요청 목록을 필터링하여 조회합니다.
    - 프론트엔드 UI의 협력사 리스트 필터링 및 페이징 처리를 위해 동적으로 WHERE 절을 구성합니다.
    - 최신 요청이 먼저 보이도록 requested_at 기준 내림차순 정렬을 기본으로 적용합니다.
    """
    stmt = select(DataRequestLog)
    if supplier_id:
        stmt = stmt.where(DataRequestLog.target_supplier_id == supplier_id)
    if status:
        stmt = stmt.where(DataRequestLog.submission_status == status)
    stmt = stmt.order_by(DataRequestLog.requested_at.desc()).offset(skip).limit(limit)
    
    result = await db.execute(stmt)
    return list(result.scalars().all())
