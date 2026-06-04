# backend/agents/data_gateway.py

import base64
import json
from uuid import uuid4

import asyncio
import boto3
from botocore.exceptions import ClientError

from langchain_core.messages import HumanMessage, SystemMessage
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from backend.agents.state import BatchState
from backend.infrastructure.trace import trace_node, trace_tool
from backend.llm.bedrock_factory import get_llm_for_agent
from backend.domains.submission import repository as submission_repo

CONFIDENCE_THRESHOLD = 0.85

# 모델에 "이 형식으로만 답하라"고 못박는 지시. JSON만 받아야 json.loads가 안전하다.
_EXTRACTION_SYSTEM = (
    "You are a document data-extraction engine for a battery supply-chain "
    "compliance system. Read the document and return ONLY a JSON object — "
    "no prose, no markdown fences. Schema:\n"
    '{"parsed_fields": {<field>: <value>, ...}, '
    '"confidence_map": {<field>: <0.0~1.0 float>, ...}, '
    '"unparsed_fields": [<field name you could not read>, ...]}\n'
    "confidence_map must have the same keys as parsed_fields."
)

# image 블록에 넣을 mime 매핑 (schema file_type → mime_type)
_IMAGE_MIME = {"image": "image/png"}  # 필요 시 jpg 등 세분화

# 협력사 문서 비공개 버킷 (서울). file_url 컬럼엔 이 버킷 안의 "키"가 저장된다.
#   예: "submissions/req-001/factory_cert.pdf"   (영구 URL이 아니라 키)
S3_BUCKET = "kira-documents-423937245947-ap-northeast-2-an"
AWS_REGION = "ap-northeast-2"

# boto3 client는 스레드 안전하므로 모듈 레벨에서 1회 생성해 재사용한다.
# 자격증명은 EC2 IAM Role이 자동 주입 — 키를 넘기지 않는다.
_s3_client = boto3.client("s3", region_name=AWS_REGION)

def _get_object_sync(key: str) -> bytes:
    """boto3 get_object (동기). to_thread로 감싸 호출한다."""
    resp = _s3_client.get_object(Bucket=S3_BUCKET, Key=key)
    return resp["Body"].read()


async def _load_document_bytes(s3_key: str) -> bytes:
    """
    S3 비공개 버킷에서 문서 바이트를 읽어온다.
    동기 boto3 호출이라 asyncio.to_thread로 감싸 이벤트 루프를 막지 않는다.
    s3_key: submission_documents.file_url에 저장된 버킷 내 키.
    """
    try:
        return await asyncio.to_thread(_get_object_sync, s3_key)
    except ClientError as exc:
        # 없는 키/권한 문제 등. 추측으로 채우지 않고 호출부가 미파싱 처리하도록 올린다.
        raise FileNotFoundError(f"S3 object load failed (key={s3_key}): {exc}") from exc


@trace_tool("parse_document")
async def parse_document(document_id: str, db: AsyncSession) -> dict:
    """
    문서 한 개를 Bedrock(Sonnet 4.6 + Vision)으로 읽어 정형 데이터로 추출하고,
    document_extraction_results에 적재한다. db를 인자로 받으므로 audit_trail에 기록된다.
    반환: {"parsed_fields": {...}, "confidence_map": {...}, "unparsed_fields": [...]}
    """
    # ── 1) 원본 문서 메타 조회 (schema: file_url / file_name / file_type) ──────
    row = await db.execute(
        text(
            """
            SELECT request_id, file_url, file_name, file_type
            FROM submission_documents
            WHERE document_id = :document_id
            """
        ),
        {"document_id": document_id},
    )
    doc = row.first()
    if doc is None:
        return {"parsed_fields": {}, "confidence_map": {},
                "unparsed_fields": ["document_not_found"]}
    request_id, file_url, file_name, file_type = doc

    # ── 2) 파일 바이트 확보 → base64 ──────────────────────────────────────────
    # file_url 컬럼엔 S3 키가 저장돼 있다 (영구 URL 아님). 그 키로 바이트를 읽는다.
    raw_bytes = await _load_document_bytes(file_url)        # ← 저장 방식 확정 후 구현
    b64 = base64.b64encode(raw_bytes).decode("utf-8")

    # ── 3) 파일 타입별 content 블록 구성 ──────────────────────────────────────
    if file_type == "image":
        # 검증된 멀티모달 형식: text + base64 image (mime_type 필수)
        doc_block = {"type": "image", "base64": b64, "mime_type": _IMAGE_MIME["image"]}
    elif file_type == "pdf":
        # 주의: ChatBedrockConverse의 base64 PDF(document) 지원이 버전마다 다르다.
        #       Converse document 블록 형식이 확정되면 여기에 넣는다.
        #       당장 안 되면 PDF→이미지 변환(pdf2image) 후 image 블록으로 우회.
        #       (PDF 파싱 라이브러리 검토는 W3 B 과제 — 그 결과로 이 분기를 확정한다.)
        doc_block = {"type": "image", "base64": b64, "mime_type": "image/png"}  # 임시: 변환 전제
    else:
        # xlsx/csv/docx 등은 Vision 대상이 아니다. 텍스트 추출 경로가 따로 필요.
        # 추측해서 이미지로 보내면 깨지므로, 일단 미파싱으로 표시해 넘긴다.
        return {"parsed_fields": {}, "confidence_map": {},
                "unparsed_fields": [f"unsupported_for_vision:{file_type}"]}

    # ── 4) Bedrock 호출 (은진 = Sonnet 4.6, IAM Role 인증, temperature 0) ──────
    llm = get_llm_for_agent("eunjin")
    messages = [
        SystemMessage(content=_EXTRACTION_SYSTEM),
        HumanMessage(content=[
            {"type": "text",
             "text": f"Extract all compliance-relevant fields from this document "
                     f"(filename: {file_name})."},
            doc_block,
        ]),
    ]
    resp = await llm.ainvoke(messages)

    # ── 5) 응답 JSON 안전 파싱 (모델이 펜스를 붙이면 제거) ─────────────────────
    text_out = resp.content if isinstance(resp.content, str) else str(resp.content)
    cleaned = text_out.strip().removeprefix("```json").removeprefix("```").removesuffix("```").strip()
    try:
        extracted = json.loads(cleaned)
    except (json.JSONDecodeError, ValueError):
        # 모델이 JSON을 안 지키면 추측으로 채우지 않고 미파싱으로 표시
        extracted = {"parsed_fields": {}, "confidence_map": {},
                     "unparsed_fields": ["llm_non_json_response"]}

    parsed_fields = extracted.get("parsed_fields", {})
    confidence_map = extracted.get("confidence_map", {})
    unparsed_fields = extracted.get("unparsed_fields", [])

    

    # ── 6) document_extraction_results 적재 (submission repository 위임) ──────
    #   JSONB 컬럼이라 dict/list를 그대로 넘긴다 (json.dumps로 문자열화하면
    #   이중 직렬화돼서 "{...}" 문자열이 박힌다 — 넘기지 않는다).
    #   request_id는 submission_documents에서 읽은 UUID 그대로 (str 변환 불필요).
    await submission_repo.create_extraction_result(
        db,
        request_id=request_id,
        document_id=document_id,
        parsed_fields=parsed_fields,
        confidence_map=confidence_map,
        unparsed_fields=unparsed_fields,
    )
    await db.commit()   # 노드(도구)가 트랜잭션 경계 소유 — repository는 flush까지만
    
    
    return {"parsed_fields": parsed_fields,
            "confidence_map": confidence_map,
            "unparsed_fields": unparsed_fields}


@trace_node("data_gateway", "agent")
async def data_gateway_node(state: BatchState) -> BatchState:
    """
    BatchState를 받아 stage_extraction을 수행한다.
    문서 파싱은 parse_document 도구에 위임하고, 노드는 결과로 분기만 판단한다.
    """
    # state에서 파싱 대상 문서와 db를 꺼낸다.
    # (graph 결합 시 db 세션을 state로 전달하는 방식은 Day3에서 지혜 graph와 맞춘다.
    #  여기서는 state에 document_id / db가 들어온다는 전제로 도구를 부른다.)
    document_id = state.get("document_id")     # type: ignore[attr-defined]
    db = state.get("db")                       # type: ignore[attr-defined]

    if document_id is None or db is None:
        # 추측으로 채우지 않는다. 입력이 없으면 저신뢰로 표시해 사람에게 넘긴다.
        return {
            **state,
            "current_stage": "stage_extraction",
            "error_reason": "low_confidence",
            "confidence_score": 0.0,
            "extraction_result": {"parsed": False, "note": "no document_id/db in state"},
        }

    result = await parse_document(document_id, db)
    confidence_map = result.get("confidence_map", {})

    # ── 저신뢰 분기 ───────────────────────────────────────────────────────────
    # confidence_map의 최저값이 임계값 미만이면 사람이 봐야 한다.
    lowest = min(confidence_map.values()) if confidence_map else 0.0

    if lowest < CONFIDENCE_THRESHOLD:
        error_reason = "low_confidence"   # supervisor가 supplier_reverify로 라우팅
    else:
        error_reason = None               # 정상 → 다음 단계(verification)로

    # 내 칸만 바꾼다. current_stage는 stage_extraction까지만,
    # batch_status(batch_hitl_wait)는 건드리지 않는다(supervisor/interrupt 몫).
    return {
        **state,
        "current_stage": "stage_extraction",
        "confidence_score": lowest,
        "error_reason": error_reason,
        "extraction_result": {
            "parsed": True,
            "field_count": len(result.get("parsed_fields", {})),
            "unparsed": result.get("unparsed_fields", []),
            "lowest_confidence": lowest,
        },
    }