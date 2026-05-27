import uuid
from typing import Optional
from dataclasses import asdict
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from sqlalchemy.exc import IntegrityError
from backend.infrastructure.trace import trace_node
from backend.infrastructure.event_bus import publish
from backend.domains.submission.models import SubmissionStatus, SUBMISSION_TRANSITIONS, DataRequestLog, SubmissionStatusHistory
from backend.events.types import SubmissionStatusChangedEvent

@trace_node("transition_submission", "agent")
async def transition_submission(
    db: AsyncSession,
    request_id: uuid.UUID,           # 데이터 수집 및 제출 요청건의 유니크 ID (마스터 테이블 외래키)
    to_status: SubmissionStatus,     # 전이하고자 하는 목표 변경 상태 코드 (SubmissionStatus Enum)
    actor_id: uuid.UUID,             # 본 상태 전이 트랜잭션을 발생시킨 실행 주체자 ID (User ID)
    reason: Optional[str] = None,    # 상태 전이 사유 (특히 REVIEW 단계에서 REJECTED 처리 시 반려 근거 기록)
    batch_id: Optional[str] = None   # Provenance 감사 추적 체인 연동을 위한 인프라 전용 식별 파라미터
) -> DataRequestLog:
    """
    Pipeline Coordinator: Submission 상태 전이를 제어하는 비즈니스 로직
    """
    
    stmt = select(DataRequestLog).where(DataRequestLog.request_id == request_id).with_for_update()
    result = await db.execute(stmt)
    log_record = result.scalar_one_or_none()
    
    if not log_record:
        raise ValueError("Data request not found")
        
    current_status = log_record.submission_status
    allowed_transitions = SUBMISSION_TRANSITIONS.get(current_status, [])
    
    if to_status not in allowed_transitions:
        raise ValueError(f"Invalid transition from {current_status} to {to_status}")
        
    if to_status == SubmissionStatus.REJECTED and not reason:
        raise ValueError("반려(REJECTED) 상태 전이 시 사유(reason)는 필수입니다.")

    log_record.submission_status = to_status
    
    history = SubmissionStatusHistory(
        request_id=request_id, 
        from_status=current_status, 
        to_status=to_status, 
        actor_id=actor_id, 
        reason=reason
    )
    
    try:
        db.add(history)
        await db.flush()
    except IntegrityError as e:
        raise ValueError("참조 무결성 위반: 존재하지 않는 사용자(actor_id)입니다.") from e


    event = SubmissionStatusChangedEvent(
        request_id=request_id,
        old_status=current_status.value if current_status else None,
        new_status=to_status.value
    )
    # db 객체를 넘기지 않는 2-인자 인프라 호출 스펙 엄수
    await publish("SubmissionStatusChanged", asdict(event))
    
    return log_record
