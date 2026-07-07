from datetime import datetime, timezone

from backend.domains.risk.models import RiskProfile


def calculate_risk_level(score: int) -> str:
    """
    위험 점수(0~100)를 기반으로 리스크 레벨 구간을 판정합니다.
    가점식이며 높을수록 위험합니다.
    - 70~100: critical
    - 50~69: high
    - 30~49: medium
    - 0~29: low
    """
    if score >= 70:
        return "critical"
    elif score >= 50:
        return "high"
    elif score >= 30:
        return "medium"
    return "low"


def update_risk_profile_state(profile: RiskProfile, new_score: int, additional_reasons: list[str]) -> bool:
    """
    리스크 프로필의 상태(점수, 레벨, 플래그, 사유)를 일관되게 전이합니다.
    에스컬레이션(HITL 강제 회부)이 필요한 critical 상태인 경우 True를 반환합니다.
    """
    profile.overall_risk_score = min(100, max(0, new_score))
    profile.risk_level = calculate_risk_level(profile.overall_risk_score)
    
    # risk_level이 high 또는 critical이면 고위험 플래그 활성화
    profile.is_high_risk_flag = profile.risk_level in ("high", "critical")
    profile.high_risk_reasons = additional_reasons
    
    # 70점(critical) 이상이면 에스컬레이션(HITL) 필요
    return profile.risk_level == "critical"


def resolve_risk_profile(profile: RiskProfile, resolved_note: str | None = None) -> None:
    """
    리스크 종결(닫기). 가점식 점수라 '내리는' 경로가 없어, 종결 시 점수를 0으로
    리셋해 low 레벨로 전이하고 고위험 플래그를 해제한다. last_risk_review_at 에
    종결 시각을 남겨 '언제 사람이 리스크를 닫았는지' 감사 가능하게 한다.

    (다음 파이프라인에서 새 위반이 적재되면 점수는 다시 가점식으로 누적된다 —
     이 종결은 '이번 리스크 에피소드를 닫는' 의미다.)
    """
    profile.overall_risk_score = 0
    profile.risk_level = calculate_risk_level(0)  # low
    profile.is_high_risk_flag = False
    profile.high_risk_reasons = [f"resolved: {resolved_note}"] if resolved_note else ["resolved"]
    profile.last_risk_review_at = datetime.now(timezone.utc)
