## 오늘 5월 29일입니까?? 😲 - 오후! 수정 파일!

## 📌 작업 내용
- 최신 공통 스펙(`events/types.py`, `queue.py`)에 맞춰 Submission 및 Verification 도메인 정합성 일괄 수정
- 팀 결정 로그(Decision #3, #4) 변경 사항에 따른 비즈니스 로직 및 이벤트 Payload 최신화

## 🔍 변경 사항
- **[Verification]** 구 `Validation*` 명칭을 `Verification*` 이벤트 및 큐 상수(`VERIFICATION_QUEUE`)로 전면 교체하여 충돌 해결
- **[Verification]** Decision #4 명세에 맞춰 FEOC 심사 로직 분리 (간접 지분 25% 이상 위반 시에만 HITL 검토 플래그 활성화) 및 `violated_rules` 규격 통일
- **[Submission]** 폼 직접 입력 기능(Decision #3) 추가에 따른 DTO/라우터 `confirmed_fields` 전달 오류 수정 및 `submission_mode` 식별 로직 반영
- **[Submission]** `SubmissionStatusChangedEvent` 필드 최신화 (`old/new_status` ➔ `from/to_status`)
- **[Submission]** `batch_id` 파라미터의 타입을 `UUID`로 엄격하게 일원화하여 타입 에러 원천 차단

## 📸 스크린샷 (선택)

## 🔗 관련 이슈

## ✅ 셀프 체크리스트
- [ ] 브랜치 방향이 `develop`으로 되어 있나요?
- [ ] 불필요한 주석이나 `print`문은 삭제했나요?
- [ ] 로컬에서 테스트는 돌려보셨나요?

- Close #