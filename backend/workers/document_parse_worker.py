"""
workers/document_parse_worker.py  (담당: 팀원 B · 은진)

document_parse_queue 컨슈머. 협력사가 업로드한 문서를 파싱해
document_extraction_results에 적재한다. (spec 3-5 라이프사이클 1~2단계)

[트리거] 협력사가 포털에 문서를 업로드하는 순간 submission 측(E)이
  enqueue(DOCUMENT_PARSE_QUEUE, "process_document_parse", document_id=...)로 적재.
  (SubmissionCompleted 수신 시점이 아님 — spec 3-5 #1 명시.)

[역할 분리]
  - 이 워커: file → parse_document(Bedrock Vision) → create_extraction_result 적재
  - data_gateway_node: 적재된 결과를 batch 파이프라인에서 조회+검증 (별개)

  한 워커 = 한 Queue (spec 5-3).

[AP — 마스터폼 자동 채움 경로]
  parse_document는 이제 '마스터폼 필드 인식형'으로 추출한다(키 = 마스터폼 필드명).
  그 결과가 document_extraction_results에 쌓이면, 협력사는
  GET /suppliers/{id}/master-form/prefill 로 섹션별 prefill 초안을 받아
  검토·정정 후 제출한다. 즉 '문서 업로드만으로 마스터폼 필드가 채워지는' 경로의
  적재 단계가 이 워커다(변환·노출은 supplier.service.get_master_form_prefill).

[SAQ 리스크등급 자동 반영]
  doc_category='dd_audit_report'(실사 자가진단)로 분류된 문서는 parsed_fields.saq_risk_level
  (low/medium/high/critical)을 supplier_risk_profiles.self_reported_risk_level에 그대로
  동기화한다. 예전엔 이 컬럼이 마스터폼의 수동 드롭다운으로만 채워져서, SAQ 문서를 올려
  AI 진단까지 '이상 없음'으로 나와도 완성도 화면엔 계속 '미입력'으로 남는 불일치가 있었다
  (SAQ 카드 표시용 파싱과 완성도 게이트용 컬럼이 서로 다른 경로였음). 값이 enum 밖이거나
  없으면 손대지 않는다(추측 저장 금지 — 기존 unknown 유지).
"""
import dataclasses
import uuid

from arq.connections import RedisSettings
from arq.cron import cron
from sqlalchemy import text

from backend.core.config import config
from backend.agents.data_gateway import parse_document
from backend.domains.submission import repository as submission_repo
from backend.domains.supplier import repository as supplier_repo
from backend.domains.supplier import ai_synthesis
from backend.events.types import SupplierAiSynthesisReadyEvent
from backend.infrastructure.database import AsyncSessionLocal
from backend.infrastructure.event_bus import publish
from backend.infrastructure.queue import DOCUMENT_PARSE_QUEUE, enqueue

_SELF_RISK_LEVELS = {"low", "medium", "high", "critical"}


async def process_document_parse(ctx, document_id: str, request_id: str | None = None) -> bool:
    """
    document_parse_queue 작업 함수.
    document_id로 문서를 파싱하고 결과를 document_extraction_results에 적재한다.

    Idempotency: processed_jobs PK INSERT로 선점(claim). 동일 document_id는
    한 번만 파싱(재시도/중복 enqueue 방어). 헬퍼는 E 소관(submission repository).
    """
    idempotency_key = f"document_parse:{document_id}"

    async with AsyncSessionLocal() as db:
        # ── 멱등성 선점 ───────────────────────────────────────────────────────
        claimed = await submission_repo.claim_job(
            db,
            idempotency_key=idempotency_key,
            queue_name=DOCUMENT_PARSE_QUEUE,
            job_id=ctx.get("job_id") if isinstance(ctx, dict) else None,
        )
        if not claimed:
            await db.rollback()
            print(f"[PARSE SKIP] 이미 처리된 문서: {document_id}")
            return True

        try:
            result = await parse_document(document_id, db)

            # 문서 못 찾으면 실패 표시 후 종료.
            if result.get("unparsed_fields") == ["document_not_found"]:
                await submission_repo.mark_job_failed(
                    db, idempotency_key=idempotency_key, error_text="document_not_found"
                )
                await db.commit()
                print(f"[PARSE FAIL] 문서 없음: {document_id}")
                return False

            # request_id: 업로드 시점에 아는 E가 enqueue로 넘겨준 값을 쓴다.
            rid = request_id or result.get("request_id")
            if rid is None:
                await submission_repo.mark_job_failed(
                    db, idempotency_key=idempotency_key, error_text="no_request_id"
                )
                await db.commit()
                print(f"[PARSE WARN] request_id 미확보, 적재 보류: {document_id}")
                return False

            await submission_repo.create_extraction_result(
                db,
                request_id=rid,
                document_id=document_id,
                parsed_fields=result.get("parsed_fields", {}),
                confidence_map=result.get("confidence_map", {}),
                unparsed_fields=result.get("unparsed_fields", []),
                blank_fields=result.get("blank_fields", []),
                unreadable_fields=result.get("unreadable_fields", []),
                detected_document_type=result.get("detected_document_type") or None,
                evidence_summary=result.get("evidence_summary") or None,
            )

            # [3종 AI 종합] doc_category가 소재구성/탄소발자국/SAQ 중 하나면 이 협력사의
            #   target_supplier_id를 한 번만 조회해 SAQ 리스크 동기화 + 종합 결론 생성에 재사용.
            doc_category = result.get("doc_category")
            target_supplier_id = None
            if doc_category in ai_synthesis.SYNTHESIS_TARGET_CATEGORIES:
                req = await submission_repo.get_data_request(db, uuid.UUID(str(rid)))
                if req is not None and req.target_supplier_id is not None:
                    target_supplier_id = req.target_supplier_id

            if doc_category == "dd_audit_report" and target_supplier_id is not None:
                saq_level = str((result.get("parsed_fields") or {}).get("saq_risk_level") or "").strip().lower()
                if saq_level in _SELF_RISK_LEVELS:
                    await supplier_repo.set_self_reported_risk_level(db, target_supplier_id, saq_level)

            # 3종 중 하나라도 파싱됐으면 그 시점까지 확보된 카테고리만으로 종합 결론을 (재)생성한다.
            new_summary = None
            if target_supplier_id is not None:
                new_summary = await ai_synthesis.maybe_synthesize_compliance_summary(db, target_supplier_id)

            await submission_repo.mark_job_done(db, idempotency_key=idempotency_key)
            await db.commit()   # 워커가 트랜잭션 경계 소유 (claim+적재+done+종합 원자 커밋)

            # 커밋 성공 후에만 발행(이벤트 발행 순서 규칙) — 종합 결론이 방금 새로 생겼을 때만.
            if new_summary:
                await publish(
                    "SupplierAiSynthesisReady",
                    dataclasses.asdict(SupplierAiSynthesisReadyEvent(supplier_id=target_supplier_id)),
                )

        except Exception as exc:
            await db.rollback()
            # 실패 기록은 별도 짧은 트랜잭션으로 (위 rollback이 claim까지 되돌리므로
            # 재시도 때 다시 claim 가능 — max_tries 소진 후 dead_letter_queue로).
            raise

    print(f"[PARSE DONE] {document_id} (fields={len(result.get('parsed_fields', {}))})")
    return True


async def reenqueue_missed_documents(ctx) -> int:
    """
    [보정 스위퍼 — commit-enqueue 틈 자가치유]
    업로드 플로우는 'DB commit → enqueue' 순서라, commit 직후 프로세스가 죽으면
    (배포·크래시 타이밍) submission_documents 행만 남고 파싱 작업은 영영 큐에
    안 들어간다. 이 cron이 '커밋됐는데 처리 기록(processed_jobs)이 없는' 문서를
    주기적으로 찾아 재적재해 그 틈을 메운다.

    안전장치:
      - 유예 10분: 방금 업로드돼 아직 큐/처리 중인 문서는 건드리지 않는다
        (동일 job_id면 ARQ가 중복 enqueue를 거르지만, 완료 후 keep_result TTL이
        지난 작업은 재적재될 수 있으므로 processed_jobs 부재 조건이 본선 방어).
      - 조회 24시간: mark_job_failed 없이 DLQ로 빠진 문서(예: Bedrock 연속 실패)를
        무한 재시도하지 않도록 재적재를 업로드 후 24시간 내로 한정.
      - 멱등: 재적재된 작업도 process_document_parse의 processed_jobs claim으로
        한 번만 처리된다.
    """
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(text("""
            SELECT d.document_id, d.request_id
            FROM submission_documents d
            LEFT JOIN processed_jobs pj
              ON pj.idempotency_key = 'document_parse:' || d.document_id::text
            WHERE pj.idempotency_key IS NULL
              AND d.uploaded_at < now() - interval '10 minutes'
              AND d.uploaded_at > now() - interval '24 hours'
        """))).all()

    for document_id, request_id in rows:
        await enqueue(
            DOCUMENT_PARSE_QUEUE,
            "process_document_parse",
            job_id=f"document_parse:{document_id}",
            document_id=str(document_id),
            request_id=str(request_id) if request_id else None,
        )
        print(f"[RECONCILE] 유실 문서 재적재: {document_id}")

    if rows:
        print(f"[RECONCILE] 총 {len(rows)}건 재적재")
    return len(rows)


class WorkerSettings:
    """ARQ 워커 설정. document_parse_queue 전용 (한 워커 = 한 Queue, spec 5-3)."""
    redis_settings = RedisSettings.from_dsn(config.REDIS_URL)
    queue_name = "document_parse_queue"
    functions = [process_document_parse, reenqueue_missed_documents]
    cron_jobs = [
        # 10분마다 commit-enqueue 틈 보정 (위 reenqueue_missed_documents 참고)
        cron(reenqueue_missed_documents, minute={5, 15, 25, 35, 45, 55}),
    ]
    max_tries = 3  # 지수 백오프 재시도 (spec 1-3). 3회 실패 시 dead_letter_queue.