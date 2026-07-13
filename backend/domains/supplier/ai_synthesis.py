"""
domains/supplier/ai_synthesis.py  (담당: 팀원 B · 은진)

소재구성(material_composition) · 탄소발자국(carbon_footprint_declaration) ·
SAQ(dd_audit_report) 3종 AI 처리 결과를 종합해 협력사가 읽을 한국어 결론
1건을 만든다.

트리거: document_parse_worker가 문서 하나를 파싱할 때마다
maybe_synthesize_compliance_summary를 호출한다(대상 3종 카테고리일 때만).
3종을 전부 기다리지 않고, 이 시점까지 파싱된 카테고리가 하나라도 있으면
그것만으로 종합한다(미제출 카테고리는 "아직 제출되지 않음"으로 명시).
문서가 새로 파싱될 때마다(카테고리가 늘거나 재파싱되거나) 매번 다시 종합해
suppliers.ai_compliance_summary(+generated_at)를 갱신한다 — 프론트는
generated_at 값 변경을 감지해 팝업을 다시 띄운다(SupplierGeneralReview.tsx
hasUnseenAiSummary). commit은 호출부(document_parse_worker) 책임 —
여기서는 flush까지만(repository 계층 규약과 동일선상).

AI 호출 지점: get_llm_for_agent("lightweight")(Haiku) 사용. 구조화 추출(JSON)이
아니라 협력사가 그대로 읽을 한국어 산문 결론이라 경량 모델로 충분하다.
[CLAUDE.md 갱신 필요] 이 모듈이 프로젝트의 3번째 AI 호출 지점이다
(기존: data_gateway 추출, compliance RAG+judge).
"""
import logging
from typing import Optional
from uuid import UUID

from langchain_core.messages import HumanMessage, SystemMessage
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from backend.llm.bedrock_factory import get_llm_for_agent

logger = logging.getLogger(__name__)

# 종합 대상 3종 — masterform_prefill.FIELD_CATALOG의 materials/manufacturing(carbon)/saq
# 세 섹션과 1:1 대응하는 문서 카테고리(submission_documents.doc_category).
SYNTHESIS_TARGET_CATEGORIES = frozenset({
    "material_composition", "carbon_footprint_declaration", "dd_audit_report",
})

_CATEGORY_LABEL = {
    "material_composition": "소재 구성(핵심광물 함량)",
    "carbon_footprint_declaration": "탄소발자국",
    "dd_audit_report": "인권/안전 실사 자가진단(SAQ)",
}

_SYNTHESIS_SYSTEM = (
    "당신은 배터리 공급망 플랫폼(KIRA)에서 협력사 담당자에게 제출 자료 검토 결과를 "
    "알기 쉽게 설명하는 역할입니다. 협력사가 제출한 문서(소재 구성, 탄소발자국, 인권/안전 "
    "실사 자가진단 중 지금까지 제출된 것)의 AI 추출 결과를 아래에서 받습니다. 아직 "
    "제출되지 않은 항목은 '(아직 제출되지 않음)'으로 표시되어 있습니다. 이를 바탕으로 "
    "규제·컴플라이언스 지식이 없는 담당자도 한 번에 이해할 수 있는 쉬운 한국어 설명을 "
    "3~4문장으로 작성하세요.\n"
    "- 전문 용어나 규제 약어(예: CSDDD, SAQ, RMI 등)는 쓰지 말고 일상적인 말로 풀어서 "
    "설명하세요.\n"
    "- 문장 끝은 '-습니다/-입니다'체(격식체)로 통일하고 '-예요/-해요' 같은 구어체는 "
    "쓰지 마세요.\n"
    "- 한 문장에 한 가지 내용만 담아 짧고 명확하게 쓰세요.\n"
    "- 확인된 좋은 점(있다면)과 확인이 더 필요한 부분을 구분해서 언급하세요.\n"
    "- 문서에 없는 값은 추측하지 말고 '확인되지 않았습니다'처럼 표현하세요.\n"
    "- 아직 제출되지 않은 문서가 있다면 그 사실도 짧게 언급하세요.\n"
    "- 마지막 문장은 다음에 무엇을 하면 되는지 알려주는 행동 제안으로 마무리하세요.\n"
    "- 별표(**)·제목·글머리표·마크다운 서식을 절대 쓰지 마세요. 화면에 그대로 표시되는 "
    "일반 텍스트이므로 강조나 굵게 표시가 필요 없습니다 — 프롬프트·JSON 없이 자연스러운 "
    "한국어 문단만 출력하세요."
)


def _as_dict(value) -> dict:
    if isinstance(value, dict):
        return value
    return {}


def _strip_markdown(text_str: str) -> str:
    """LLM이 지침을 어기고 강조 표시를 넣어도 화면엔 일반 텍스트만 나가도록 최종 방어.
    굵게(**text**)만 벗기고 원문 텍스트는 그대로 둔다 — 내용 자체를 바꾸지 않는다."""
    import re
    return re.sub(r"\*\*(.+?)\*\*", r"\1", text_str).replace("**", "").strip()


async def maybe_synthesize_compliance_summary(db: AsyncSession, supplier_id: UUID) -> Optional[str]:
    """
    이 시점까지 파싱된 대상 카테고리가 하나라도 있으면 LLM을 호출해
    suppliers.ai_compliance_summary(+generated_at)를 (재)생성한다. 3종을
    전부 기다리지 않는다 — 미제출 카테고리는 "아직 제출되지 않음"으로
    프롬프트에 명시해 LLM이 추측하지 않게 한다.

    반환: 새로 생성한 요약 텍스트, 또는 None(대상 문서 전무/협력사 없음).
    """
    row = (await db.execute(
        text("SELECT 1 FROM suppliers WHERE supplier_id = :s"),
        {"s": str(supplier_id)},
    )).first()
    if row is None:
        return None  # 협력사 없음

    rows = (await db.execute(
        text("""
            SELECT DISTINCT ON (sd.doc_category)
                   sd.doc_category, e.parsed_fields, e.evidence_summary
            FROM document_extraction_results e
            JOIN submission_documents sd ON sd.document_id = e.document_id
            JOIN data_request_log d ON d.request_id = e.request_id
            WHERE d.target_supplier_id = :s
              AND sd.doc_category = ANY(:cats)
            ORDER BY sd.doc_category, e.created_at DESC
        """),
        {"s": str(supplier_id), "cats": list(SYNTHESIS_TARGET_CATEGORIES)},
    )).all()

    found = {r[0]: (_as_dict(r[1]), r[2] or "") for r in rows}
    if not found:
        return None  # 아직 대상 문서가 하나도 파싱되지 않음

    blocks = []
    for cat in sorted(SYNTHESIS_TARGET_CATEGORIES):
        if cat not in found:
            blocks.append(f"[{_CATEGORY_LABEL[cat]}]\n(아직 제출되지 않음)")
            continue
        parsed, evidence = found[cat]
        fields = {k: v for k, v in parsed.items() if not k.startswith("__")}
        blocks.append(f"[{_CATEGORY_LABEL[cat]}]\n추출값: {fields}\n문서 요약: {evidence}")
    context = "\n\n".join(blocks)

    llm = get_llm_for_agent("lightweight")
    resp = await llm.ainvoke([
        SystemMessage(content=_SYNTHESIS_SYSTEM),
        HumanMessage(content=context),
    ])
    summary = (resp.content if isinstance(resp.content, str) else str(resp.content)).strip()
    summary = _strip_markdown(summary)
    if not summary:
        return None

    await db.execute(
        text("""
            UPDATE suppliers
            SET ai_compliance_summary = :summary,
                ai_compliance_summary_generated_at = now()
            WHERE supplier_id = :s
        """),
        {"summary": summary, "s": str(supplier_id)},
    )
    await db.flush()
    logger.info("[ai_synthesis] 종합 결론 생성 supplier=%s", supplier_id)
    return summary
