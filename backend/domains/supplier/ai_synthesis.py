"""
domains/supplier/ai_synthesis.py  (담당: 팀원 B · 은진)

소재구성(material_composition) · 탄소발자국(carbon_footprint_declaration) ·
SAQ(dd_audit_report) 3종 AI 처리 결과를 종합해 협력사가 읽을 한국어 결론
1건을 만든다.

트리거: document_parse_worker가 문서 하나를 파싱할 때마다
maybe_synthesize_compliance_summary를 호출한다(대상 3종 카테고리일 때만).
그 협력사가 3종 문서를 전부 최소 1건씩 파싱받은 시점에만 실제로 LLM을
호출한다 — 그 전까지는 조회만 하고 조용히 None을 반환한다(추측 금지).

멱등: suppliers.ai_compliance_summary_generated_at 이 이미 채워져 있으면
다시 만들지 않는다(3종은 최초 제출 시 한 번이면 충분 — 재생성이 필요해지면
그때 별도 트리거를 추가한다). commit은 호출부(document_parse_worker) 책임 —
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
    "당신은 배터리 공급망 컴플라이언스 플랫폼(KIRA)의 AI 어시스턴트입니다. "
    "협력사가 제출한 세 문서(소재 구성, 탄소발자국, 인권/안전 실사 자가진단)의 "
    "AI 추출 결과를 아래에서 받습니다. 이를 종합해 협력사 담당자가 바로 읽을 "
    "한국어 결론을 3~5문장으로 작성하세요.\n"
    "- 확인된 좋은 점(있다면)과 확인이 필요한 위험 신호를 구분해서 언급하세요.\n"
    "- 문서에 없는 값은 추측하지 말고 '확인되지 않음'으로 두세요.\n"
    "- 마지막 문장은 다음 행동 제안으로 마무리하세요.\n"
    "- 프롬프트·JSON·마크다운 없이, 화면에 바로 표시할 자연스러운 한국어 문단만 출력하세요."
)


def _as_dict(value) -> dict:
    if isinstance(value, dict):
        return value
    return {}


async def maybe_synthesize_compliance_summary(db: AsyncSession, supplier_id: UUID) -> Optional[str]:
    """
    3종 카테고리가 모두 갖춰졌고 아직 종합한 적 없는 경우에만 LLM을 호출해
    suppliers.ai_compliance_summary(+generated_at)를 채운다.

    반환: 새로 생성한 요약 텍스트(신규 생성 시) 또는 None(대상 아님/이미 생성됨/협력사 없음).
    """
    row = (await db.execute(
        text("SELECT ai_compliance_summary_generated_at FROM suppliers WHERE supplier_id = :s"),
        {"s": str(supplier_id)},
    )).first()
    if row is None or row[0] is not None:
        return None  # 협력사 없음 또는 이미 생성됨(멱등 가드)

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
    if not SYNTHESIS_TARGET_CATEGORIES.issubset(found.keys()):
        return None  # 아직 3종 미충족

    blocks = []
    for cat in sorted(SYNTHESIS_TARGET_CATEGORIES):
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
