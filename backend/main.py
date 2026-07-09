"""
main.py — KIRA Compliance Intelligence Platform 진입점.

startup 시 PostGIS/pgvector 확장을 검증하고, 각 도메인 라우터를 등록한다.
실행: uvicorn main:app --host 0.0.0.0 --port 8000 --reload
"""
from contextlib import asynccontextmanager

from fastapi import FastAPI
from starlette.responses import PlainTextResponse

from backend.infrastructure.database import verify_extensions
from backend.agents.graph import setup_graph, teardown_graph
from backend.infrastructure.event_bus import start_event_listener, stop_event_listener, subscribe
from backend.domains.supplychain.router import router as supplychain_router, product_supply_chain_router
from backend.domains.submission.router import router as submission_router, submissions_router, submission_documents_router

from backend.domains.users.router import router as users_router
from backend.domains.product.router import router as product_router
from backend.domains.supplier.router import router as supplier_router
from backend.domains.audit.router import actions_router, audit_packages_router, router as audit_router
from backend.hitl.router import router as hitl_router
from backend.domains.batches.router import batches_router, dashboard_router
from backend.domains.regulation.router import compliance_router
from backend.domains.files.router import router as files_router
from backend.domains.data_consent.router import router as data_consent_router
from backend.domains.notifications.router import router as notifications_router

async def _register_subscriptions() -> None:
    """
    이벤트 구독 슬롯 (담당: 팀원 B — 인프라/골격).

    도메인 간 이벤트 핸들러를 한곳에서 등록하는 단일 지점이다. 각 담당은 자기
    이벤트 핸들러를 여기에 한 줄로 배선한다(handler는 자기 도메인/모듈에 둔다).
    구독은 start_event_listener()가 띄운 LISTEN 루프가 디스패치한다.

    배선 규칙:
      - handler 본체는 절대 여기에 두지 않는다(여기는 '슬롯'일 뿐). 자기 모듈에 두고
        import해서 subscribe()로 등록만 한다.
      - 같은 event_name에 여러 핸들러를 붙일 수 있다(event_bus는 다중 핸들러 지원).
    """
    # ── A1: 배치 생성 + graph 트리거 ─────────────────────────────────
    from backend.handlers.batch_trigger import on_submission_approved
    await subscribe("SubmissionApproved", on_submission_approved)
    await subscribe("SubmissionCompleted", on_submission_approved)

    # ── E: 협력사 필요문서 업로드 → 파싱 파이프라인 다리 ──────────────
    from backend.handlers.supplier_document_ingest import on_supplier_document_uploaded
    await subscribe("SupplierDocumentUploaded", on_supplier_document_uploaded)

    # ── D: 협력사 초대 → supply_chain_map.discovered_via 기록 (pool 발견 경로) ──
    #    + 초대(가입 요청) 메일 SES 발송(동일 이벤트 다중 핸들러).
    from backend.handlers.supplier_invited import (
        supplychain_record_discovered_via,
        send_supplier_invitation_email,
    )
    await subscribe("SupplierInvited", supplychain_record_discovered_via)
    await subscribe("SupplierInvited", send_supplier_invitation_email)

    # ── P4: 공급망 완결 시 원청에 '최종 검증' 알림 (SubmissionApproved 재평가) ──
    from backend.handlers.final_validation_notify import notify_final_validation_ready
    await subscribe("SubmissionApproved", notify_final_validation_ready)

    # ── P4b: 협력사 자료 제출 시 원청에 '검토 요청' 알림 (맵+협력사 노드 딥링크) ──
    from backend.handlers.submission_submitted_notify import notify_supplier_submission
    await subscribe("SubmissionCompleted", notify_supplier_submission)

    # ── P4c: 협력사 마스터폼(자가진단) 제출 시 원청에 '검토 요청' 알림 (협력사 상세 딥링크) ──
    from backend.handlers.master_form_submitted_notify import notify_master_form_submission
    await subscribe("MasterFormSubmitted", notify_master_form_submission)

    # ── E: 협력사 온보딩(제3자 동의서) 제출 시 원청에 STEP4 수신확인 알림 ──
    from backend.handlers.onboarding_review_notify import notify_onboarding_review_needed
    await subscribe("SupplierStatusChanged", notify_onboarding_review_needed)

    # ── D→E: 공급망 맵 gap 트리거 → 협력사 자료요청 생성 ──
    #    supplychain 이 submission 을 직접 호출하던 것을 이벤트로 분리(규칙 #4).
    from backend.handlers.supplychain_gap_data_request import on_supply_chain_gap_detected
    await subscribe("SupplyChainGapDetected", on_supply_chain_gap_detected)

    # ── 협력사 통지/자진신고 → in-app 알림 (프론트 벨/인박스가 GET /notifications 폴링) ──
    from backend.handlers.supplier_notification import (
        notify_supplier_correction,
        notify_source_change_declared,
    )
    await subscribe("supplier.notification_sent", notify_supplier_correction)
    await subscribe("supplier.source_change_declared", notify_source_change_declared)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # startup: 필수 확장 검증 + checkpoint DB 초기화 + 이벤트 구독 등록 + LISTEN 루프 기동
    await verify_extensions()
    await setup_graph()
    await _register_subscriptions()
    await start_event_listener()
    yield
    # shutdown: LISTEN 루프 정리 + checkpoint 풀 해제
    await stop_event_listener()
    await teardown_graph()


app = FastAPI(
    title="KIRA Compliance Intelligence Platform",
    description="N차 공급망 추적 및 Geo Audit 기반 컴플라이언스 백엔드",
    lifespan=lifespan,
)

# 도메인 라우터 등록 (도메인 추가 시 여기에 include)
app.include_router(supplychain_router)
app.include_router(product_supply_chain_router)
app.include_router(submission_router)
app.include_router(submissions_router)
app.include_router(submission_documents_router)

app.include_router(users_router)
app.include_router(supplier_router)
app.include_router(product_router)
app.include_router(audit_router)
app.include_router(actions_router)
app.include_router(audit_packages_router)
app.include_router(hitl_router)
app.include_router(batches_router)
app.include_router(dashboard_router)
app.include_router(compliance_router)
app.include_router(files_router)
app.include_router(data_consent_router)
app.include_router(notifications_router)

@app.get("/health")
async def health_check():
    return {"status": "ok", "message": "KIRA Backend is running"}

WELCOME_MSG = r"""
└[o_o]┘  Welcome Home !
   [-]    FastAPI is running...
"""

@app.get("/", response_class=PlainTextResponse)
def read_root():
    return WELCOME_MSG
