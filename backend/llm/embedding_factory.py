"""
KIRA — Bedrock 임베딩 팩토리
===========================
RAG용 벡터 임베딩 생성기. pgvector에 저장할 임베딩을 만든다.

대상 데이터: 공개 법률/규제 문서 (민감 공급망 데이터는 임베딩하지 않음).
인증: EC2 IAM Role(KIRA-EC2-Bedrock-Role)이 자동 처리 — 키 없음.

모델: Cohere Embed v4 (다국어/한국어 검색 안정적).
      교체 시 EMBED_MODEL_ID 한 곳만 바꾸면 된다.

차원 주의: pgvector 컬럼의 VECTOR(n) 차원과 임베딩 출력 차원이
          반드시 일치해야 한다. 모델 교체 시 schema.sql의 벡터 컬럼
          차원도 함께 확인할 것.
"""

from __future__ import annotations

from functools import lru_cache

from langchain_aws import BedrockEmbeddings


AWS_REGION = "ap-northeast-2"

# 임베딩 모델 — 교체 지점. Cohere Embed v4 (서울 리전 확인됨).
# 대안: "amazon.titan-embed-text-v2:0" (더 저렴, 다국어 약간 약함)
EMBED_MODEL_ID = "global.cohere.embed-v4:0"


@lru_cache(maxsize=2)
def get_embedder() -> BedrockEmbeddings:
    """
    Bedrock 임베딩 인스턴스 반환 (캐시 재사용).
    인증은 IAM Role이 자동 처리 — credentials 인자 없음.
    """
    return BedrockEmbeddings(
        model_id=EMBED_MODEL_ID,
        region_name=AWS_REGION,
    )


def embed_documents(texts: list[str]) -> list[list[float]]:
    """여러 문서를 임베딩. pgvector 적재용."""
    return get_embedder().embed_documents(texts)


def embed_query(text: str) -> list[float]:
    """검색 쿼리 하나를 임베딩. 유사도 검색용."""
    return get_embedder().embed_query(text)


# ─────────────────────────────────────────────────────────
# 연결 + 차원 확인용 (배포 직후 임베딩 호출 + 차원 검증)
# 실행:  python -m backend.llm.embedding_factory
# ─────────────────────────────────────────────────────────
if __name__ == "__main__":
    import sys

    print(f"[KIRA] Bedrock 임베딩 테스트 (model={EMBED_MODEL_ID}, region={AWS_REGION})")
    try:
        vec = embed_query("UFLPA 강제노동 관련 수입 금지 규정")
        print("─" * 50)
        print(f"✅ 임베딩 호출 성공 — IAM Role 인증 정상")
        print(f"   출력 차원: {len(vec)}")
        print(f"   ⚠️ schema.sql의 VECTOR({len(vec)}) 차원과 일치하는지 확인할 것")
        print("─" * 50)
    except Exception as e:
        print("❌ 임베딩 호출 실패")
        print(f"   에러: {type(e).__name__}: {e}")
        print("   점검: 1) IAM 정책에 cohere.embed-v4 권한 추가했는지")
        print("        2) 첫 호출 시 use case 입력 필요할 수 있음(콘솔)")
        sys.exit(1)
