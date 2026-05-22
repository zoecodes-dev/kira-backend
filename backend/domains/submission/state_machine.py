import asyncio
import uuid
from typing import Optional
from backend.infrastructure.trace import trace_node
from backend.domains.submission.models import SubmissionStatus, SUBMISSION_TRANSITIONS

# ==============================================================================
# [ESG 공급망 데이터 백본] Submission 상태 전이 엔진 (State Machine)
# ==============================================================================

# [규제 당국 감사 대응]: 데이터 변경 이력의 위변조 방지 및 투명한 추적(Provenance)을 위해 
# 인프라 코어 레이어의 감사 데코레이터를 필수로 매핑하며, 반드시 비동기로 가동되어야 합니다.
@trace_node("transition_submission", "agent")
async def transition_submission(
    request_id: uuid.UUID,           # 데이터 수집 및 제출 요청건의 유니크 ID (마스터 테이블 외래키)
    to_status: SubmissionStatus,     # 전이하고자 하는 목표 변경 상태 코드 (SubmissionStatus Enum)
    actor_id: uuid.UUID,             # 본 상태 전이 트랜잭션을 발생시킨 실행 주체자 ID (User ID)
    reason: Optional[str] = None,    # 상태 전이 사유 (특히 REVIEW 단계에서 REJECTED 처리 시 반려 근거 기록)
    batch_id: Optional[str] = None   # Provenance 감사 추적 체인 연동을 위한 인프라 전용 식별 파라미터
) -> bool:
    """
    Submission 상태 전이를 제어하는 비즈니스 로직 (W1 금요일 깡통 프레임워크)
    
    [코어 아키텍처 규칙 준수 현황]
    1. 파일명 격리: 인계 문서 원칙에 의거, services.py가 아닌 state_machine.py에 완전히 격리 분리
    2. 감사 추적: @trace_node 공식 매핑 및 batch_id 파라미터 주입으로 audit_trail 자동 기록 완벽 대응
    3. 비동기화: 인프라 trace.py의 비동기 데코레이터 체인 요구 규격을 충족하기 위해 async def 설계 도입
    """
    
    # -------------------------------------------------------------
    # [가상 현재 상태 설정] 
    # 디버깅 및 W1 파이프라인 무결성 검증용 Stub 단계이므로, 현재 상태를 IN_PROGRESS로 가동합니다.
    # TODO (W2): 차주에 비동기 DB 엔진을 통해 실제 상태 데이터를 긁어오는 실구현 코드로 전환 예정
    # -------------------------------------------------------------
    current_status = SubmissionStatus.IN_PROGRESS  
    
    print(f"\n[상태 머신 호출] 요청 ID: {request_id}")
    print(f"-> 상태 전이 시도: {current_status.value} -> {to_status.value}")
    
    # -------------------------------------------------------------
    # 1단계: 백엔드 방어용 상태 전이 매트릭스 검증
    # [인프라 검토 반영]: 임의의 상태 도약을 차단하고, submitted -> review 단계를 
    # 필수 우회하도록 설계된 모델 레이어의 무결성 규칙을 엄격하게 강제하여 비즈니스 결함을 격리합니다.
    # -------------------------------------------------------------
    allowed_transitions = SUBMISSION_TRANSITIONS.get(current_status, [])
    
    if to_status not in allowed_transitions:
        print(f"[비즈니스 결함 차단] {current_status.value}에서 {to_status.value}(으)로의 전이는 매트릭스 규칙에 의해 불가능합니다!")
        raise ValueError(f"Invalid transition from {current_status} to {to_status}")
        
    # -------------------------------------------------------------
    # 2단계: 도메인 이벤트 발행 처리 (Print 모킹 단계)
    # TODO (W2): 차주에 backend.infrastructure.event_bus.publish() 메시지 큐 연동으로 확장 예정
    # -------------------------------------------------------------
    print(f"[EVENT PUBLISH] Submission 도메인 이벤트 발행 완료")
    print(f"   - 메타데이터: Request_ID={request_id} | Actor_ID={actor_id}")
    print(f"   - 상태 변경 완료 안내: [{current_status.value}] -> [{to_status.value}]")
    if reason:
        print(f"   - 사유(Reason): {reason}")
        
    # -------------------------------------------------------------
    # 3단계: 실제 DB 쓰기 파이프라인 설계 (W2 영속성 계층 구현 예고 주석)
    # -------------------------------------------------------------
    # TODO: 다음 주(W2)에 AsyncSession(db)을 주입받아 아래 비동기 트랜잭션 로직을 활성화합니다.
    """
    # [W2 실구현 레시피 미리보기] (db: AsyncSession 주입 필요)
    # 1) 동시성 트랜잭션 이슈 방지를 위한 마스터 데이터 조회 및 비관적 락 고려
    #    stmt = select(DataRequestLog).where(DataRequestLog.request_id == request_id).with_for_update()
    #    log_record = (await db.execute(stmt)).scalar_one()
    # 2) 수집 데이터 상태값 최신화 갱신
    #    log_record.submission_status = to_status
    # 3) 감사 정보 및 상태 변경 히스토리 이력 인스턴스 생성
    #    history = SubmissionStatusHistory(
    #        request_id=request_id, 
    #        from_status=current_status, 
    #        to_status=to_status, 
    #        actor_id=actor_id, 
    #        reason=reason
    #    )
    # 4) 영속성 컨텍스트 등록 및 비동기 커밋 수행
    #    db.add(history)
    #    await db.commit()
    """
    print("[W2 미리보기] 비동기 DB 쓰기 및 이력 누적 파이프라인 구조 스케치 완료")
    
    return True


# -------------------------------------------------------------
# 금요일 오후 자체 검증용 실행기 (비동기 처리 반영)
# -------------------------------------------------------------
if __name__ == "__main__":
    async def run_test():
        print("==== Submission 상태 머신 깡통 테스트 시작 ====")
        
        # UUID 체계 검증용 가상 ID 생성
        mock_request = uuid.uuid4()
        mock_actor = uuid.uuid4()
        
        # 1. 은진님 피드백 및 상태 전이 규칙 반영 정상 흐름 테스트
        print("\n--- TEST 1: 정상 상태 전이 검증 ---")
        try:
            await transition_submission(
                request_id=mock_request, 
                to_status=SubmissionStatus.SUBMITTED, 
                actor_id=mock_actor, 
                reason="공급망 데이터 검증 요청 전송"
            )
        except Exception as e:
            print(f"예외 발생 (실패): {e}")

        # 2. 규칙 위반 예외 상황 강제 가로채기 테스트 (IN_PROGRESS -> APPROVED 도약 시도)
        print("\n--- TEST 2: 비즈니스 규칙 위반 차단 검증 ---")
        try:
            await transition_submission(
                request_id=mock_request, 
                to_status=SubmissionStatus.APPROVED, 
                actor_id=mock_actor
            )
            print("[경고] 방어선이 뚫렸습니다. 코드를 확인하세요! (실패)")
        except ValueError:
            print("[확인] 방어선 안전하게 정상 작동! 올바르지 않은 상태 전이가 완벽하게 차단되었습니다.")
            
        print("\n==== 모든 로컬 검증 완료! ====")

    # 비동기 이벤트 루프 가동
    asyncio.run(run_test())