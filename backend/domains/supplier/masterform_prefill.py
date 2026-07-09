"""
domains/supplier/masterform_prefill.py  (담당: 팀원 B · 은진 / KIRA W5 AP)

마스터폼 'AI 자동 채움(prefill)'의 도메인 지식 SSOT.

AP(AI 파싱 강화)의 목표: 협력사가 양식을 직접 못 채워도, 보완 문서(PDF·이미지)를
업로드하면 AI(data_gateway.parse_document)가 필드를 추출하고 → 그 결과가 마스터폼
필드로 자동 채워진다. 협력사는 추출 결과만 확인·정정한다.

이 모듈은 두 가지를 한곳에 모은다(추출과 변환이 같은 필드 정의를 보게):
  1) FIELD_CATALOG — 문서에서 AI가 추출할 '마스터폼 스칼라 필드'의 정의(SSOT).
     data_gateway가 이 카탈로그로 추출 프롬프트를 만들고(=알려진 키로만 추출),
     이 모듈이 같은 카탈로그로 flat 추출결과를 마스터폼 섹션 구조로 되돌린다.
  2) to_master_form_prefill — flat parsed_fields → 섹션별 nested prefill + 신뢰도
     낮은(<임계치) 필드 목록(협력사 확인 요청 대상).

스코프: '한 문서에서 단일값으로 신뢰성 있게 뽑히는' 스칼라 필드만 자동 채움 대상이다.
다건/구조화 섹션(공장 목록·연락처·탄소 선언 다건)은 AI 단일 추출로 안전하게 못
채우므로 협력사가 직접 입력한다.
[W6] master-form에서 제거된 섹션(재활용·지분FEOC, 연관 테이블 삭제)의 필드는
저장 위치가 없으므로 카탈로그에서도 제외했다. 현재 자동 채움 대상은 company·
manufacturing 스칼라뿐이다.
[UFLPA] origin_country는 예외적으로 company 섹션에 추가한다 — 전용 저장 테이블은
W6에서 삭제됐지만, regulation_required_fields가 miner/trader에 요구하는 필드라
suppliers.country(소재 국가)를 재사용해 추출만이라도 가능하게 한다. 승격
(promote_extraction_to_details)은 company 섹션 필드라 자동 제외 대상이며 이번
스코프에도 포함하지 않는다 — 상세는 FIELD_CATALOG 내 주석 참고.
"""
from typing import Any, Dict, List, Optional, Tuple

# 신뢰도 임계치 — data_gateway.CONFIDENCE_THRESHOLD와 동일 기준(0.85).
# 이 미만 필드는 prefill에 채우되 '확인 요청' 목록에 함께 실어 협력사 검토를 유도한다.
PREFILL_CONFIDENCE_THRESHOLD = 0.85


# ── 카탈로그 항목: flat_field → (마스터폼 섹션, 파이썬 타입, 한글 라벨) ──────────
# flat_field는 섹션을 가로질러 유일하다(추출결과 parsed_fields가 평면 dict이므로).
# section 값은 MasterFormRequest의 최상위 키와 일치한다(company/manufacturing/...).
_FIELD = Tuple[str, str, str]   # (section, type, label)

FIELD_CATALOG: Dict[str, _FIELD] = {
    # 섹션 0 — 회사 (suppliers)
    "company_name":        ("company", "str", "회사 정식 상호"),
    "company_name_en":     ("company", "str", "영문 상호"),
    "business_reg_no":     ("company", "str", "사업자등록번호"),
    "corporate_reg_no":    ("company", "str", "법인등록번호"),
    "duns_number":         ("company", "str", "DUNS 번호"),
    "tax_number":          ("company", "str", "납세자번호(VAT 등)"),
    "website":             ("company", "str", "웹사이트"),
    "established_year":    ("company", "int", "설립연도"),
    "employee_count":      ("company", "int", "임직원 수"),
    "provider_type":       ("company", "str", "공급자 유형(manufacturer/recycler/trader/miner)"),

    # UFLPA(miner/trader 필수) — 전용 detail 테이블이 없어 suppliers.country(소재 국가)를
    # 재사용한다. "country"(회사 소재지)와는 의미가 다른 별개 개념(특히 trader는 원산지가
    # 자사 소재국과 다를 수 있음)이라 별도 키로 둔다. ISO 코드 정규화는 이번 범위 밖.
    "origin_country":      ("company", "str", "원산지 국가(ISO 3166-1 alpha-2 또는 국가명)"),

    # UFLPA(miner/trader 필수) — 전용 detail 테이블이 없어 suppliers.country(소재 국가)를
    # 재사용한다. "country"(회사 소재지)와는 의미가 다른 별개 개념(특히 trader는 원산지가
    # 자사 소재국과 다를 수 있음)이라 별도 키로 둔다. ISO 코드 정규화는 이번 범위 밖.
    "origin_country":      ("company", "str", "원산지 국가(ISO 3166-1 alpha-2 또는 국가명)"),

    # 섹션 1 — 탄소발자국 (supplier_manufacturer_details)
    "manufacturing_process": ("manufacturing", "str",   "제조 공정 설명"),
    "energy_source":         ("manufacturing", "str",   "에너지원"),
    "capacity":              ("manufacturing", "str",   "생산 능력"),
    "carbon_intensity":      ("manufacturing", "float", "탄소집약도(kgCO2eq/kg)"),
    "verification_status":   ("manufacturing", "str",   "제3자 검증 여부(예: third-party verified / self-declared / not verified) — 명시된 경우만 추출, 미명시 시 unparsed_fields에 포함"),

    # [작업1] 섹션 2 — 인권/안전 실사 자가진단(SAQ, dd_audit_report). CSDDD RAG 판정 입력.
    #   전용 스칼라 컬럼이 없어 master-form 저장 대상은 아니지만(prefill 'saq' 섹션은 프론트가 무시),
    #   parsed_fields JSONB로 추출돼 SAQ 카드 표시 + CSDDD 준수 진단(analyze_saq_compliance)에 쓰인다.
    "saq_standard":          ("saq", "str", "평가 표준(예: SA8000, RBA VAP, ISO 45001)"),
    "saq_score":             ("saq", "str", "자가진단 종합 평가 점수 또는 등급"),
    "saq_assessed_at":       ("saq", "str", "자가진단 평가 일자(평가 수행일, YYYY-MM-DD)"),
    "saq_valid_until":       ("saq", "str", "자가진단 유효기간(만료일, YYYY-MM-DD)"),
    "saq_risk_level":        ("saq", "str", "종합 리스크 등급(low/medium/high)"),
    "grievance_mechanism":   ("saq", "str", "고충 처리 채널(grievance mechanism) 운영 여부(있음/없음 또는 yes/no)"),
    "forced_labor_risk":     ("saq", "str", "강제노동 징후 여부(있음/없음 또는 설명)"),
    "child_labor_risk":      ("saq", "str", "아동노동 징후 여부(있음/없음 또는 설명)"),
    "iso_45001_certified":   ("saq", "str", "안전보건경영시스템(ISO 45001 등) 인증 여부(있음/없음 또는 인증명)"),
    "iso_14001_certified":   ("saq", "str", "환경경영시스템(ISO 14001 등) 인증 여부(있음/없음 또는 인증명)"),
    "compliance_grade":      ("saq", "str", "실사 준수 등급(예: 준수/개선필요/위반)"),

    # [W6 정리] 재활용(recycling)·원산지(origin)·지분FEOC(ownership) 섹션은 master-form에서
    # 제거됨(연관 테이블 삭제) → 저장 위치가 없는 필드는 AI 추출 대상에서도 제외한다.
    # (원산지는 위 origin_country로 suppliers.country를 재사용해 예외적으로 추출한다.)

    # 섹션 3 — 소재 구성(핵심광물 함량). 저장 위치: supplier_factories.core_minerals(JSONB,
    #   공장 단위). 프론트(FactoryCards의 소재구성 문서 업로드·AiParsingView의 MATERIAL_DOC_CATALOG)는
    #   이미 이 필드명으로 파싱 결과를 기대하고 있었으나, 카탈로그에 없어 추출이 항상 비어 있었다.
    "li_content":                 ("materials", "float", "Li(리튬) 함량(%)"),
    "co_content":                 ("materials", "float", "Co(코발트) 함량(%)"),
    "ni_content":                 ("materials", "float", "Ni(니켈) 함량(%)"),
    "mn_content":                 ("materials", "float", "Mn(망간) 함량(%)"),
    "natural_graphite_content":   ("materials", "float", "천연흑연 함량(%)"),
    "synthetic_graphite_content": ("materials", "float", "인조흑연(인조흑연/artificial graphite) 함량(%)"),
}


def catalog_prompt_lines() -> str:
    """
    추출 프롬프트에 끼울 '대상 필드 목록' 문자열을 만든다(섹션별 그룹핑·한글 라벨 포함).
    data_gateway가 이 목록을 system 프롬프트에 넣어 '알려진 키로만' 추출하게 한다.
    """
    by_section: Dict[str, List[str]] = {}
    for field, (section, ftype, label) in FIELD_CATALOG.items():
        by_section.setdefault(section, []).append(f'    "{field}" ({ftype}) — {label}')
    blocks = []
    for section, lines in by_section.items():
        blocks.append(f"  [{section}]\n" + "\n".join(lines))
    return "\n".join(blocks)


def _coerce(value: Any, ftype: str) -> Optional[Any]:
    """
    추출값(문자열일 수 있음)을 카탈로그 타입으로 안전 변환. 실패하면 None.
    None을 반환하면 호출부가 '읽지 못한 값'으로 간주해 prefill에 넣지 않는다(추측 금지).
    """
    if value is None:
        return None
    if ftype == "str":
        s = str(value).strip()
        return s or None
    # float/int: 숫자/단위 섞인 문자열("36.5 kgCO2eq/kg")에서 앞쪽 숫자만 취한다.
    if isinstance(value, (int, float)):
        num: Any = value
    else:
        import re
        m = re.search(r"-?\d+(?:\.\d+)?", str(value))
        if not m:
            return None
        num = m.group(0)
    try:
        return int(float(num)) if ftype == "int" else float(num)
    except (TypeError, ValueError):
        return None


def to_master_form_prefill(
    parsed_fields: Dict[str, Any],
    confidence_map: Dict[str, Any],
    threshold: float = PREFILL_CONFIDENCE_THRESHOLD,
) -> Dict[str, Any]:
    """
    flat 추출결과(parsed_fields/confidence_map) → 마스터폼 섹션 구조 prefill.

    반환:
      {
        "prefill": { "company": {...}, "manufacturing": {...}, ... },  # 채워진 섹션만
        "low_confidence_fields": [
            {"section","field","label","value","confidence"}, ...      # < threshold
        ],
      }

    카탈로그에 없는 추출 키는 무시한다(마스터폼에 자리가 없는 잡필드 방지).
    타입 변환 실패값도 넣지 않는다(추측 저장 금지). 신뢰도 낮은 값은 채우되
    low_confidence_fields에 실어 협력사 확인을 유도한다.
    """
    prefill: Dict[str, Dict[str, Any]] = {}
    low_confidence: List[Dict[str, Any]] = []

    for field, (section, ftype, label) in FIELD_CATALOG.items():
        if field not in parsed_fields:
            continue
        coerced = _coerce(parsed_fields[field], ftype)
        if coerced is None:
            continue
        prefill.setdefault(section, {})[field] = coerced

        try:
            conf = float(confidence_map.get(field, 0.0))
        except (TypeError, ValueError):
            conf = 0.0
        if conf < threshold:
            low_confidence.append({
                "section": section,
                "field": field,
                "label": label,
                "value": coerced,
                "confidence": conf,
            })

    return {"prefill": prefill, "low_confidence_fields": low_confidence}
