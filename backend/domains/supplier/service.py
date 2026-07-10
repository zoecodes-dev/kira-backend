"""
domains/supplier/service.py  (담당: 팀원 B)

★ W2 "이벤트 발행 레퍼런스". 다른 도메인(product/submission/...)이 이 패턴을 복사한다.

레이어 규칙 (PROJECT_CORE 5-1):
  router → service → repository → models  (단방향)
  - service는 비즈니스 로직 + 이벤트 발행만. 직접 SQL 금지(그건 repository).
  - 다른 도메인을 import하지 않는다. 통신은 events/types.py 이벤트 + publish()로만.

이벤트 발행 규칙 (PROJECT_CORE 5-2):
  - publish(event_name, payload)  ← 2-인자. db를 넘기지 않는다.
  - payload는 dataclasses.asdict(이벤트객체)로 만든 dict.
  - ★ 발행은 "DB 커밋이 성공한 뒤"에 한다.
"""
import dataclasses
from datetime import datetime, timedelta, timezone
from typing import List, Optional
from uuid import UUID

from sqlalchemy import text, update
from sqlalchemy.ext.asyncio import AsyncSession

from backend.domains.supplier import repository
from backend.domains.supplier.models import (
    GeoPoint,
    MasterFormContact,
    MasterFormFactory,
    MasterFormRequest,
    OnboardingSubmitRequest,
    Supplier,
    SupplierOnboarding,
    SupplierRiskProfile,
)
from backend.events.types import (
    MasterFormSubmittedEvent,
    RiskProfileUpdatedEvent,
    SupplierInvitedEvent,
    SupplierStatusChangedEvent,
    SupplierDocumentUploadedEvent,
)
from backend.infrastructure import geocode, storage
from backend.infrastructure.event_bus import publish
from backend.infrastructure.trace import trace_node
# AP: 추출결과 read는 E 제공(submission repository), 마스터폼 prefill 변환은 B(supplier)
#   masterform_prefill. 둘 다 무거운 LLM 스택을 끌어오지 않는 가벼운 호출이다.
from backend.domains.submission import repository as submission_repo
from backend.domains.supplier import masterform_prefill
# [회원가입 — 결정 #4] 온보딩 제출은 "제출→즉시 로그인 / 중복 즉시 409"라 이벤트가 아니라
#   동기 처리한다. 도메인 격리는 users repository '재사용 + 단일 커밋'으로 지킨다(새 계정
#   생성 책임은 users 의 것이되, 온보딩의 단일 트랜잭션 안에서 한 번에 커밋).
from backend.domains.users.repository import UserRepository
from backend.infrastructure.security import get_password_hash
# [회원가입 — 결정 #4 동일 패턴] 온보딩 진입/제출에서 대기중 제3자 정보제공 동의서(데이터 계약)를
#   원문 표시·기록하려면 data_consent 테이블 접근이 필요하다. 조회/기록은 해당 도메인 repository를
#   '재사용 + 온보딩 단일 커밋'으로 처리(새 트랜잭션·커밋을 열지 않는다).
import hashlib
from backend.domains.data_consent import repository as consent_repo
from backend.domains.data_consent.models import ConsentUpdateBody

# ── 정책 상수 ───────────────────────────────────────────────
# 협력사 온보딩 SLA. PROJECT_CORE: 14일 미응답 → Reminder, 21일 → Escalation.
SUPPLIER_SLA_DAYS = 14


async def create_supplier_and_invite(
    db: AsyncSession,
    supplier_data: dict,
    email: str,
    inviter_supplier_id: Optional[UUID] = None,
    contacts: Optional[list] = None,
) -> Supplier:
    """
    협력사를 생성하고 초대 이벤트를 발행한다. (B-9 완료기준: CTI/onboarding/SLA/발행을
    단일 트랜잭션으로)

    [G1 협력사→협력사 초대 — contract-first 착수]
      inviter_supplier_id: 이 협력사를 '초대한' 상위 협력사(이동 주체). 원청 직접
      등록이면 None. 값이 있으면 SupplierInvited 이벤트에 실어 발행하고, D(supplychain)
      가 이를 수신해 supply_chain_map.discovered_via 에 기록한다(빈 상태→pool 구축).
      ※ 도메인 경계: B는 supply_chain_map에 직접 쓰지 않는다(D 도메인). 이벤트로만 전달.

    ★ 이벤트 발행 순서 (다른 도메인이 그대로 따른다):
      1) repository로 DB 변경  2) await db.commit()  3) 커밋 성공 후에만 publish()
      이유: publish()는 별도 커넥션으로 NOTIFY를 즉시 보낸다. 커밋 전 발행하면
      롤백 시 "이벤트는 나갔는데 데이터는 없는" 불일치가 생긴다.

    ※ @trace_node 미적용: audit_trail은 batch_id 기반 해시 체인인데, 협력사 생성은
      AI 배치 파이프라인 '밖'이라 batch_id가 없다.
    """
    # 1) 협력사 INSERT
    supplier = await repository.create_supplier(db, supplier_data)

    # 1-b) 기본 리스크 프로필 초기화(조회 시 값 없음 방지)
    db.add(SupplierRiskProfile(
        supplier_id=supplier.supplier_id,
        overall_risk_score=0,
        risk_level="low",
        is_high_risk_flag=False,
    ))

    # 1-c) 온보딩 row는 DB 트리거(trg_supplier_onboarding_autocreate)가 suppliers INSERT
    #      직후 자동 생성한다(consent_status='consent_pending' 기본값) — seed/수동 SQL 등
    #      애플리케이션을 거치지 않는 경로에서도 온보딩 row 누락(require_supplier_consent가
    #      영구 CONSENT_REQUIRED로 막던 문제)이 없도록 트리거가 구조적으로 보장한다.
    #      여기서는 그 위에 SLA 마감·초대 시각만 채운다(B-9: 등록과 동시에 sla_due_date).
    sla_due_date = datetime.now(timezone.utc) + timedelta(days=SUPPLIER_SLA_DAYS)
    await db.execute(
        update(SupplierOnboarding)
        .where(SupplierOnboarding.supplier_id == supplier.supplier_id)
        .values(last_invited_at=datetime.now(timezone.utc), sla_due_date=sla_due_date)
    )

    # 1-d) 하위 PIC(담당자 3명) 저장 — stub 과 같은 트랜잭션. 다음 화면 재표기용
    #      (supplier_contacts). 초대만 되고 아직 가입 전이어도 정보는 남는다.
    if contacts:
        await repository.write_master_form_contacts(db, supplier.supplier_id, contacts, [])

    # 2) 커밋 — 영속화 확정 (repository는 flush만, 커밋은 service 책임)
    await db.commit()
    await db.refresh(supplier)

    # 3) 커밋 성공 후 이벤트 발행 (G1: inviter 동봉 → D가 discovered_via 기록)
    event = SupplierInvitedEvent(
        supplier_id=supplier.supplier_id,
        email=email,
        sla_due_date=sla_due_date,
        inviter_supplier_id=inviter_supplier_id,
    )
    await publish("SupplierInvited", dataclasses.asdict(event))

    return supplier


async def get_supplier(
    db: AsyncSession, supplier_id: UUID, tenant_id: Optional[UUID] = None
) -> Optional[Supplier]:
    """단건 조회. 비즈니스 로직 없이 repository에 위임. tenant_id 지정 시 소유 테넌트만(§0.2)."""
    return await repository.get_supplier_by_id(db, supplier_id, tenant_id)


async def supplier_in_tenant(
    db: AsyncSession, supplier_id: UUID, tenant_id: Optional[UUID]
) -> bool:
    """소유권 게이트(§0.2). 하위 리소스 조회 전 라우터가 호출. repository에 위임."""
    return await repository.supplier_in_tenant(db, supplier_id, tenant_id)


class MasterFormOnBehalfError(Exception):
    """다른 협력사(예: 제련소)가 광산의 마스터폼을 대행 제출하려는데 권한/범위 조건을
    충족하지 못했을 때. router가 403으로 매핑."""


async def _assert_on_behalf_edit_allowed(
    db: AsyncSession, caller_supplier_id: UUID, target: Supplier
) -> None:
    """제련소 등 상위 협력사가 하위 광산의 마스터폼을 '대신' 제출할 때의 권한 게이트.

    광산은 시스템상 자기 계정으로도 편집 불가(입력 주체 아님)라, 연결된 상위 협력사가
    공장(사이트) 정보만 대신 입력할 수 있게 한다(§_classify_fields 'factories.mine_*').
    범위 제한(company/contacts/manufacturing/self_reported_risk_level 불가)은 여기서
    payload를 검증하지 않고 submit_master_form이 해당 섹션의 write를 아예 호출하지 않는
    방식으로 구조적으로 보장한다 — 프론트가 무엇을 보내든 영향을 줄 수 없다.
    """
    if target.provider_type != "miner":
        raise MasterFormOnBehalfError("대행 입력은 광산 협력사에만 허용됩니다.")
    # 동기 조회 read(CLAUDE.md 아키텍처 규칙 4-①) — 대행 입력 권한 판정은 이벤트로 대체
    # 불가능한 실시간 조회이며, supplychain 도메인의 공급망 연결 여부를 확인해야 한다.
    from backend.domains.supplychain.repository import SupplyChainRepository

    connected = await SupplyChainRepository(db).is_ancestor(str(caller_supplier_id), str(target.supplier_id))
    if not connected:
        raise MasterFormOnBehalfError("공급망으로 연결된 협력사만 대행 입력할 수 있습니다.")


async def submit_master_form(
    db: AsyncSession, supplier_id: UUID, form: MasterFormRequest, caller_supplier_id: Optional[UUID] = None
) -> Optional[dict]:
    """
    마스터폼(표준화된 단일 입력양식) 제출 진입점 — POST /suppliers/{id}/master-form. (§4)

    협력사가 보는 '하나의 양식'을 통째로 받아, service가 섹션별로 쪼개 각 도메인의
    write 함수를 호출하고 ★단일 트랜잭션으로 commit(atomic)★ 한다. 한 섹션이라도
    실패하면 commit에 도달하지 않고 전체 롤백된다(부분 저장 금지).

    섹션 → 저장 책임:
      0 회사·공장·PIC      B (repository.write_master_form_*)
      1 탄소발자국         B (manufacturer_details + factory_carbon_declarations)

    caller_supplier_id가 path의 supplier_id와 다르면(제련소가 광산을 대행 제출) 대행
    권한 게이트(_assert_on_behalf_edit_allowed)를 통과해야 하고(위반 시
    MasterFormOnBehalfError → router 403), 통과하더라도 공장(factories) 섹션만 저장한다
    — company/contacts/manufacturing/self_reported_risk_level은 프론트가 무엇을 보내든
    무시한다(대행 입력 범위를 구조적으로 제한, payload 검증이 아니라 write 자체를 스킵).

    반환: 저장된 섹션 키 목록을 담은 dict. 없는 supplier_id면 None(→ router 404).
    """
    # 존재 확인 — 없는 supplier_id로 분배 저장(FK 위반 직전까지 진행) 방지.
    target = await repository.get_supplier_by_id(db, supplier_id)
    if target is None:
        return None
    on_behalf = caller_supplier_id is not None and caller_supplier_id != supplier_id
    if on_behalf:
        await _assert_on_behalf_edit_allowed(db, caller_supplier_id, target)

    sections_saved: List[str] = []
    try:
        # ── 섹션 0: 회사·공장·PIC (B) — 공장 먼저 생성해 factory_ids 확보 ──────
        if not on_behalf:
            await repository.write_master_form_company(db, supplier_id, form.company)
            sections_saved.append("company")

        # ── 지오코딩: 좌표가 없는 공장은 주소(region)로 좌표를 채운다 ──────────
        #   - 프론트가 좌표를 직접 보냈으면(coordinates != None) 그대로 존중.
        #   - 좌표가 없고 address/region이 있으면 geocode로 보충.
        #   - geocode 실패(None)면 coordinates는 그대로 None → location NULL 저장.
        #   ※ 외부 API 호출이므로 DB write 전에 끝낸다(트랜잭션 짧게 유지).
        for f in form.factories:
            if f.coordinates is None and (f.address or f.region):
                latlng = await geocode.geocode_address(f.address, f.country, f.region)
                if latlng is not None:
                    f.coordinates = GeoPoint(latitude=latlng[0], longitude=latlng[1])

        factory_ids = await repository.write_master_form_factories(db, supplier_id, form.factories)
        if form.factories:
            sections_saved.append("factories")

        if not on_behalf:
            await repository.write_master_form_contacts(db, supplier_id, form.contacts, factory_ids)
            if form.contacts:
                sections_saved.append("contacts")

            # ── 섹션 1: 탄소발자국 (B) — 탄소선언이 factory_ids를 FK로 참조 ────────
            if form.manufacturing is not None:
                await repository.write_master_form_manufacturing(
                    db, supplier_id, factory_ids, form.manufacturing
                )
                sections_saved.append("manufacturing")

            # ── 규제: 실사 자가진단 결과 → supplier_risk_profiles.self_reported_risk_level ──
            if form.self_reported_risk_level is not None:
                await repository.set_self_reported_risk_level(
                    db, supplier_id, form.self_reported_risk_level
                )
                sections_saved.append("self_assessment")

        # ── 단일 커밋 (atomic) — 여기 도달해야만 영속화 ───────────────────────
        await db.commit()
    except Exception:
        # 한 섹션이라도 실패하면 전체 롤백(부분 저장 방지). 원인은 그대로 올린다.
        await db.rollback()
        raise

    # 커밋 성공 후에만 발행(규칙 #3) — 원청에 '협력사 제출' 알림(master_form_submitted_notify).
    #   실제로 저장된 섹션이 있을 때만(빈 제출 방지). 대행 제출(on_behalf)도 대상 협력사
    #   기준으로 알린다 — 원청은 누가 입력했는지보다 그 협력사 정보가 갱신됐는지가 중요하다.
    if sections_saved:
        await publish(
            "MasterFormSubmitted",
            dataclasses.asdict(MasterFormSubmittedEvent(supplier_id=supplier_id)),
        )

    return {
        "supplier_id": supplier_id,
        "status": "submitted",
        "sections_saved": sections_saved,
    }


async def get_master_form_prefill(db: AsyncSession, supplier_id: UUID) -> Optional[dict]:
    """
    AP(AI 자동 채움): 협력사 보완 문서의 추출결과를 모아 마스터폼 prefill 초안을 만든다.

    경로: 협력사 문서 업로드 → (E enqueue) document_parse_worker → parse_document
      (마스터폼 필드 인식형 추출) → document_extraction_results 적재 → 이 함수가
      supplier의 추출결과를 모아 마스터폼 섹션 구조로 되돌린다.

    여러 문서에 같은 필드가 있으면 '신뢰도 높은 값'을 채택한다. 신뢰도 임계치 미만
    필드는 prefill에 채우되 low_confidence_fields로 함께 반환해 협력사 확인을 유도한다.

    반환: prefill 초안 dict. 없는 supplier_id면 None(→ router 404).
          추출결과가 0건이면 prefill은 비고 document_count=0(업로드 전 정상 상태).
    """
    if await repository.get_supplier_by_id(db, supplier_id) is None:
        return None

    results = await submission_repo.list_extraction_results_by_suppliers(db, [supplier_id])

    merged_fields: dict = {}
    merged_conf: dict = {}
    unconfirmed = 0
    for record, _provider_type, _sid in results:
        parsed = record.parsed_fields or {}
        cmap = record.confidence_map or {}
        for key, value in parsed.items():
            try:
                conf = float(cmap.get(key, 0.0))
            except (TypeError, ValueError):
                conf = 0.0
            # 같은 필드가 여러 문서에 → 더 높은 신뢰도 값으로 갱신(최선값 채택).
            if key not in merged_conf or conf > merged_conf[key]:
                merged_fields[key] = value
                merged_conf[key] = conf
        if not record.supplier_confirmed:
            unconfirmed += 1

    assembled = masterform_prefill.to_master_form_prefill(merged_fields, merged_conf)
    return {
        "supplier_id": supplier_id,
        "document_count": len(results),
        "unconfirmed_documents": unconfirmed,
        "prefill": assembled["prefill"],
        "low_confidence_fields": assembled["low_confidence_fields"],
    }


# 원청(prime, tier0) 노드 — manufacturer지만 CTI 수집 대상 아님 → 점검 예외.
_PRIME_SUPPLIER_ID = UUID("a0000000-0000-4000-8000-000000000000")

# provider_type → 채워야 할 CTI relationship 속성명 매핑
_CTI_ATTR_BY_TYPE = {
    "manufacturer": "manufacturer_detail",
    "miner": "miner_detail",
}

# 국가명 → ISO 3166-1 alpha-2. suppliers.country 는 VARCHAR(2)라, 입력 경로(AI 파싱
# 배선·자료제출·회원가입)가 '대한민국'·'China'·'대한민국 (KR)' 같은 자유 표기를 보내면
# 영속화 직전에 코드로 정규화한다(_normalize_country_to_iso2). 국가 추가는 여기 한 줄.
_COUNTRY_NAME_TO_ISO2 = {
    "대한민국": "KR", "한국": "KR", "southkorea": "KR", "korea": "KR", "republicofkorea": "KR",
    "중국": "CN", "china": "CN", "prchina": "CN", "peoplesrepublicofchina": "CN",
    "미국": "US", "usa": "US", "us": "US", "unitedstates": "US",
    "unitedstatesofamerica": "US", "america": "US",
    "일본": "JP", "japan": "JP",
    "호주": "AU", "australia": "AU",
    "칠레": "CL", "chile": "CL",
    "콩고민주공화국": "CD", "콩고민주": "CD", "콩고": "CD",
    "drc": "CD", "democraticrepublicofthecongo": "CD", "congo": "CD",
    "인도네시아": "ID", "indonesia": "ID",
    "필리핀": "PH", "philippines": "PH",
    "베트남": "VN", "vietnam": "VN",
    "캐나다": "CA", "canada": "CA",
    "아르헨티나": "AR", "argentina": "AR",
    "볼리비아": "BO", "bolivia": "BO",
    "페루": "PE", "peru": "PE",
    "독일": "DE", "germany": "DE", "deutschland": "DE",
    "프랑스": "FR", "france": "FR",
    "영국": "GB", "uk": "GB", "unitedkingdom": "GB", "britain": "GB",
    "폴란드": "PL", "poland": "PL",
    "핀란드": "FI", "finland": "FI",
    "스웨덴": "SE", "sweden": "SE",
    "노르웨이": "NO", "norway": "NO",
    "모로코": "MA", "morocco": "MA",
    "남아프리카공화국": "ZA", "남아공": "ZA", "southafrica": "ZA",
    "짐바브웨": "ZW", "zimbabwe": "ZW",
    "브라질": "BR", "brazil": "BR",
    "멕시코": "MX", "mexico": "MX",
    "인도": "IN", "india": "IN",
    "대만": "TW", "taiwan": "TW",
}
_KNOWN_ISO2 = set(_COUNTRY_NAME_TO_ISO2.values())


def _normalize_country_to_iso2(value: Optional[str]) -> Optional[str]:
    """국가 표기 → ISO 3166-1 alpha-2. 코드면 그대로(대문자), '대한민국 (KR)'면 괄호 코드
    우선, 한/영 국가명이면 매핑. 해석 불가하면 None."""
    if not value:
        return None
    raw = value.strip()
    if not raw:
        return None
    # 괄호 안 alpha-2 우선: "대한민국 (KR)" → KR
    start, end = raw.find("("), raw.find(")")
    if start != -1 and end == start + 3:
        code = raw[start + 1:end].upper()
        if code.isalpha() and code in _KNOWN_ISO2:
            return code
    # 입력 자체가 alpha-2 코드
    if len(raw) == 2 and raw.isalpha() and raw.upper() in _KNOWN_ISO2:
        return raw.upper()
    # 이름 매핑(소문자·공백/구두점 제거)
    key = "".join(ch for ch in raw.lower() if ch not in " \t.()")
    return _COUNTRY_NAME_TO_ISO2.get(key)


async def update_supplier_detail(
    db: AsyncSession, supplier_id: UUID, tenant_id: Optional[UUID], fields: dict
) -> Optional[Supplier]:
    """
    협력사 '자료 제출' — 기업 기본정보 수정. 소유 테넌트만(§0.2, 아니면 None→404).
    repository로 변경 후 여기서 커밋(서비스 일원화). 갱신된 상세를 반환한다.
    """
    supplier = await repository.get_supplier_by_id(db, supplier_id, tenant_id)
    if supplier is None:
        return None
    # 필요문서 URL 컬럼의 '커밋 전' 값을 미리 떠둔다 — 새 S3 키로 바뀐 것만
    # 커밋 후 SupplierDocumentUploaded로 발행해 파싱 파이프라인을 태우기 위함.
    # (필드명 → 이벤트 doc_kind 코드)
    doc_url_kinds = {
        "business_reg_doc_url": "business_reg",
        "environmental_report_url": "environmental_report",
        "self_assessment_doc_url": "self_assessment",
        "material_composition_doc_url": "material_composition",
        "carbon_footprint_doc_url": "carbon_footprint",
    }
    prev_doc_urls = {col: getattr(supplier, col, None) for col in doc_url_kinds}
    # 입력 양식 영속화 — 테이블별로 분배(보낸 필드만).
    fields = dict(fields)
    # 국가 정규화 — suppliers.country 는 VARCHAR(2)(alpha-2). 자유 표기('대한민국' 등)를
    # 코드로 변환. 해석 불가하면 country를 빼서(=쓰지 않음) 잘못된 값으로 덮어쓰지 않는다.
    if "country" in fields:
        iso = _normalize_country_to_iso2(fields.get("country"))
        if iso:
            fields["country"] = iso
        else:
            fields.pop("country")
    manuf = {k: fields.pop(k) for k in ("carbon_intensity", "energy_source") if k in fields}
    self_risk = fields.pop("self_reported_risk_level", None)
    submitted = fields.pop("submitted", None)  # suppliers 컬럼 아님 — 원청 알림 트리거 신호만
    # 탄소발자국 문서 — suppliers에 대응 컬럼이 없으므로(스키마 무수정) update로 보내지 않고
    # 커밋 후 파싱 이벤트만 발행한다(핸들러가 doc_category=carbon_footprint_declaration로 매핑).
    carbon_doc = fields.pop("carbon_footprint_doc_url", None)
    if fields:                         # 나머지는 suppliers 컬럼(core_minerals 포함)
        await repository.update_supplier_fields(db, supplier_id, fields)
    # [§8-J 가드] carbon_intensity/energy_source 는 supplier_manufacturer_details 소유다.
    #   provider_type 검사 없이 upsert하면 비제조사(miner 등)가 carbon을 보낼 때 엉뚱한
    #   manufacturer_details 행이 생긴다(도메인 의미 위반). manufacturer 일 때만 쓴다.
    #   비제조사가 보낸 carbon은 저장 위치가 없어 무시(추측 저장 금지).
    if manuf and supplier.provider_type == "manufacturer":
        await repository.upsert_manufacturer_fields(db, supplier_id, manuf)
    if self_risk is not None:          # 실사 자가진단 → risk_profiles
        await repository.set_self_reported_risk_level(db, supplier_id, self_risk)
    await db.commit()

    # ── 커밋 성공 후 발행 (PROJECT_CORE 5-2) ──────────────────────────────
    # 새로 들어온(이전 값과 다른) 비어있지 않은 필요문서 S3 키만 발행 → 중복 파싱 방지.
    for col, kind in doc_url_kinds.items():
        new_val = fields.get(col)
        if new_val and new_val != prev_doc_urls.get(col):
            await publish(
                "SupplierDocumentUploaded",
                dataclasses.asdict(SupplierDocumentUploadedEvent(
                    supplier_id=supplier_id,
                    s3_key=new_val,
                    file_name=new_val.rsplit("/", 1)[-1] if "/" in new_val else new_val,
                    doc_kind=kind,
                )),
            )
    # 탄소발자국 문서 — 대응 suppliers 컬럼이 없어 위 루프(fields 기반)로는 안 잡히므로 별도 발행.
    if carbon_doc:
        await publish(
            "SupplierDocumentUploaded",
            dataclasses.asdict(SupplierDocumentUploadedEvent(
                supplier_id=supplier_id,
                s3_key=carbon_doc,
                file_name=carbon_doc.rsplit("/", 1)[-1] if "/" in carbon_doc else carbon_doc,
                doc_kind="carbon_footprint",
            )),
        )

    # AI 처리 확인(ExtractionTable) "원청사로 제출" — submitted=True로 명시했을 때만
    # 원청에 알림(submit_master_form과 동일 이벤트/수신자 로직 재사용).
    if submitted:
        await publish(
            "MasterFormSubmitted",
            dataclasses.asdict(MasterFormSubmittedEvent(supplier_id=supplier_id)),
        )

    return await get_supplier_detail(db, supplier_id, tenant_id)


async def promote_extraction_to_details(
    db: AsyncSession,
    supplier_id: UUID,
    provider_type: Optional[str],
    parsed_fields: dict,
    confidence_map: dict,
) -> List[str]:
    """[§8-A 승격] 배치 게이트(data_gateway) 통과 시, 협력사 확정 AI 추출값을
    provider_type별 상세테이블로 승격한다.

    masterform_prefill(SSOT 매핑)로 flat 추출값을 섹션 구조로 되돌린 뒤, '저장 위치가
    있고 갭분석이 읽는' 필드만 기존 writer로 쓴다. 현재 대상: manufacturing carbon
    (carbon_intensity/energy_source → supplier_manufacturer_details).
    company 식별필드는 AI 추측으로 덮어쓰면 위험해 승격에서 제외(협력사 직접입력 유지).

    게이트 통과 = supplier_confirmed=True + 고신뢰라, 이 값은 협력사 확정값과 일치(무회귀).
    flush만 — 커밋은 호출부(data_gateway가 배치 전체를 일괄 커밋). 반환: 승격된 섹션 키.
    """
    prefill = masterform_prefill.to_master_form_prefill(
        parsed_fields or {}, confidence_map or {}
    )["prefill"]
    promoted: List[str] = []

    # manufacturing carbon → supplier_manufacturer_details (§8-J 가드: manufacturer만)
    manufacturing = prefill.get("manufacturing") or {}
    if manufacturing and provider_type == "manufacturer":
        manuf = {
            k: manufacturing[k]
            for k in ("carbon_intensity", "energy_source")
            if k in manufacturing
        }
        if manuf:
            await repository.upsert_manufacturer_fields(db, supplier_id, manuf)
            promoted.append("manufacturing")

    return promoted


async def get_supplier_detail(
    db: AsyncSession, supplier_id: UUID, tenant_id: Optional[UUID] = None
) -> Optional[Supplier]:
    """
    단건 상세 조회 (CTI 상세 포함). repository가 selectinload로 4종 CTI를 미리 로드한다.
    [목요일 연결 점검] provider type과 실제 적재된 CTI가 불일치하면 경고 로그를 남긴다
    (예: provider_type='manufacturer'인데 manufacturer_detail이 없음 = 자료 미수집).
    엣지 케이스를 삼키지 않고 드러내기 위한 점검이며, 응답 자체는 정상 반환한다.
    """
    supplier = await repository.get_supplier_by_id(db, supplier_id, tenant_id)
    if supplier is None:
        return None

    expected_attr = _CTI_ATTR_BY_TYPE.get(supplier.provider_type)
    if supplier_id != _PRIME_SUPPLIER_ID and expected_attr is not None and getattr(supplier, expected_attr, None) is None:
        print(
            f"[CTI 점검] supplier {supplier_id} type={supplier.provider_type} "
            f"이지만 {expected_attr} 미적재 (자료 미수집 가능)"
        )
    return supplier


async def list_suppliers(
    db: AsyncSession,
    status: Optional[str] = None,
    risk_level: Optional[str] = None,
    page: int = 1,
    size: int = 20,
    tenant_id: Optional[UUID] = None,
) -> List[Supplier]:
    """목록 조회(필터 + 페이지네이션). tenant_id 지정 시 소유 테넌트만(§0.2)."""
    return await repository.get_suppliers(
        db, status, risk_level, page, size, tenant_id
    )


async def count_suppliers(
    db: AsyncSession,
    status: Optional[str] = None,
    risk_level: Optional[str] = None,
    tenant_id: Optional[UUID] = None,
) -> int:
    """목록 전체 건수(필터 동일, 페이지 무관). X-Total-Count 헤더용(§0.6)."""
    return await repository.count_suppliers(
        db, status, risk_level, tenant_id
    )


def _score_to_risk_level(score: int) -> str:
    """
    overall_risk_score 구간을 risk_level로 변환 (가점식, 높을수록 위험).
    schema.sql / 3-4절 기준: 0~29 low / 30~49 medium / 50~69 high / 70~100 critical.
    """
    if score >= 70:
        return "critical"
    if score >= 50:
        return "high"
    if score >= 30:
        return "medium"
    return "low"


@trace_node(node_name="upsert_risk_score", node_type="agent")
async def upsert_risk_score(
    supplier_id: UUID,
    score: int,
    db: AsyncSession,
    batch_id: str = None,
) -> SupplierRiskProfile:
    """
    Verification/Risk Domain(E)에서 검증 완료 시 호출.
    1) supplier_risk_profiles upsert  2) overall_risk_score → risk_level 자동 재계산
    3) suppliers.risk_level 비정규화 캐시 동기화  4) 커밋  5) RiskProfileUpdated 발행
    """
    score = max(0, min(100, score))   # 0~100 클램프
    new_level = _score_to_risk_level(score)

    # 변경 전 값 캡처 (append-only 감사 이력의 from_*)
    prior = await repository.get_risk_profile_by_supplier(db, supplier_id)
    from_score = prior.overall_risk_score if prior else None
    from_level = prior.risk_level if prior else None

    profile = await repository.upsert_risk_profile(
        db,
        supplier_id=supplier_id,
        overall_risk_score=score,
        risk_level=new_level,
        last_risk_review_at=datetime.now(timezone.utc),
    )
    await repository.update_supplier_risk_level(db, supplier_id, new_level)

    # 리스크 변경 감사 이력 — supplier_risk_profiles 는 단일행 덮어쓰기라 별도 append-only 기록.
    #   같은 트랜잭션에서 커밋되어 프로필 변경과 원자적으로 남는다. (자동 산정 → changed_by NULL)
    if from_score != score or from_level != new_level:
        await db.execute(
            text("""
                INSERT INTO risk_score_history
                    (supplier_id, from_score, to_score, from_level, to_level, reason, changed_by)
                VALUES (:sid, :fs, :ts, :fl, :tl, :reason, NULL)
            """),
            {"sid": str(supplier_id), "fs": from_score, "ts": score,
             "fl": from_level, "tl": new_level, "reason": "검증 완료 리스크 점수 반영"},
        )

    await db.commit()
    await db.refresh(profile)

    event = RiskProfileUpdatedEvent(
        supplier_id=supplier_id,
        overall_risk_score=score,
        risk_level=new_level,
    )
    await publish("RiskProfileUpdated", dataclasses.asdict(event))

    return profile


async def get_risk_profile(supplier_id: UUID, db: AsyncSession) -> SupplierRiskProfile | None:
    """supplier_risk_profiles 단건 조회 (하위 3개 JOIN은 W4 종합 스코어링에서 확장)."""
    return await repository.get_risk_profile_by_supplier(db, supplier_id)


# ============================================================
# BE-3: 7탭 모달 조회 (기존 테이블 SELECT 전용)
#   존재하지 않는 협력사면 None을 반환 → router가 404로 매핑.
# ============================================================
async def get_factories(db: AsyncSession, supplier_id: UUID) -> Optional[dict]:
    """사업장 탭 — 공장/광산 목록(좌표 lat/lng 포함)."""
    if await repository.get_supplier_by_id(db, supplier_id) is None:
        return None
    return {
        "supplier_id": supplier_id,
        "factories": await repository.get_factories(db, supplier_id),
    }


async def get_contacts(db: AsyncSession, supplier_id: UUID) -> Optional[dict]:
    """담당자 연락처 탭 — supplier_contacts 목록(대표 우선)."""
    if await repository.get_supplier_by_id(db, supplier_id) is None:
        return None
    return {
        "supplier_id": supplier_id,
        "contacts": await repository.get_contacts(db, supplier_id),
    }


# ============================================================
# general-review 완성도 — provider_type별 '필수 데이터 완비' 판정 로직 + 재계산
#   결과는 data_completeness_status(entity_type='supplier')에 upsert 된다.
#   ★ 폼 저장(초대/master-form/자료제출/온보딩) 커밋 '직전'에 flush로 호출 → 단일 트랜잭션 반영.
#     submission 제출 게이트(완성도 100% 미만 물리 차단)와 프론트 완성도 표시가 이 값을 읽는다.
#
# 핵심 규칙(사용자 확정):
#   - 제련소(smelter)는 '자기가 다루는 금속'만 채우면 소재구성 완비. 다루는 금속은
#     공급망(supply_chain_map)에서 그 제련소가 공급하는 파트(mineral/refined_metal)의
#     광물로 도출한다(자기신고 core_minerals가 아님 — 순환 방지: 안 채우면 0/0=100% 회피).
#   - 광산(miner)은 데이터 입력 주체가 아니다 → 완성도 판정 제외(required=0, rate=100).
#   - 사업자등록증은 필수 아님(사용자 지시). 환경성적서만 제조사에서 필수.
#
# 필드 키는 프론트 섹션과 맞춘 네임스페이스 문자열: 'company.*' · 'materials.<Metal>'|'materials.any'
#   · 'factories' · 'regulation.*' · 'documents.*'. missing_fields ⊆ required_fields.
# ============================================================

# general-review 소재구성 섹션이 추적하는 금속(모달과 일치). Mn 등은 이 화면 범위 밖.
_TRACKED_METALS = ("Li", "Co", "Ni")

# part_code → 금속 기호. 전용 컬럼이 없어 part_code 토큰으로 판정한다
#   (MIN-NI/REF-NI→Ni, MIN-CO/REF-CO→Co, MIN-LI/LIOH-REFINED→Li, MIN-MN/REF-MN→Mn).
# 호출은 material_type in ('mineral','refined_metal') 인 파트에만 하므로 조립품 오탐 없음.
_METAL_TOKENS = (("LI", "Li"), ("CO", "Co"), ("NI", "Ni"), ("MN", "Mn"))


def part_code_to_metal(part_code: Optional[str]) -> Optional[str]:
    """광물/정제금속 part_code에서 금속 기호를 뽑는다. 해석 불가하면 None."""
    u = (part_code or "").upper()
    for token, symbol in _METAL_TOKENS:
        if token in u:
            return symbol
    return None


# ─── 필드 분류: 🔴필수(제출 차단) / 🟡권장(완성도 반영·비차단) / ⚪해당없음 ───
# EU 배터리법(Annex XIII)상 소재·탄소·실사는 '필요한' 데이터라 완성도엔 계속 반영하되(권장은
# 표시상 티 내지 않음), 제출 게이트는 🔴필수만 물리 차단한다. 데이터완비 베스트프랙티스의
# 'at least one' 패턴 적용 — '모든 값'이 아니라 '핵심 최소 1개' 게이트:
#   · smelter               : 취급 금속 중 '최소 1개'면 소재구성 충족 — 🔴필수(전 금속 강제 아님)
#   · manufacturer/recycler : 광물 '최소 1개' — 🟡권장(비차단)
#   · trader                : 소재구성 없음, 공장은 🟡권장
#   · miner                 : 광산 자신은 항상 읽기전용(자기 계정으로도 편집 불가)이지만 회사명·
#     업종 외에 "원산지 국가"·"소재 구성"은 필요하다. 광산은 사이트(공장)마다 채굴 광물·소재국가가
#     다를 수 있어 회사 단위 필드(country/core_minerals)가 아니라 공장 단위로 판정 —
#     연결된 상위 협력사(제련소 등)가 그 광산의 "공장 정보"를 대행 입력하면 충족된다
#     (§submit_master_form 대행 입력 권한 참고). 사업자등록번호 등 나머지는 요구하지 않는다.
# 필드 키 네임스페이스는 프론트 섹션과 일치: 'company.*' · 'materials.*' · 'factories'
#   · 'factories.mine_country' · 'factories.mine_composition' · 'regulation.*' · 'documents.*'.

# 모든 판정대상 공통 🔴필수(회사·자가진단). ※ 사업자등록증은 필수 아님(사용자 지시).
_COMMON_BLOCKING = (
    "company.company_name",
    "company.country",
    "company.business_reg_no",
    "company.provider_type",
    "regulation.self_reported_risk_level",
)


def _classify_fields(provider_type: Optional[str], handled_metals: set) -> tuple:
    """provider_type(+제련소는 공급망 도출 금속)로 (🔴blocking, 🟡recommended) 필드 키를 만든다.
    miner는 공통 블로킹셋 대신 회사명·업종 + 공장 단위 원산지·소재구성만 요구한다."""
    pt = provider_type or ""
    if pt == "miner":
        return [
            "company.company_name", "company.provider_type",
            "factories.mine_country", "factories.mine_composition",
        ], []

    blocking = list(_COMMON_BLOCKING)
    recommended: list = []

    # 공장/사업장 — trader만 권장, 그 외(입력 주체)는 필수.
    (recommended if pt == "trader" else blocking).append("factories")

    # 소재구성(광물비율).
    if pt == "smelter":
        blocking.append("materials.handled_any")      # 취급 금속 중 최소 1개(부분 허용)
    elif pt in ("manufacturer", "recycler"):
        recommended.append("materials.any")           # 최소 1개(권장, 비차단)
    # trader → 소재구성 요구 없음

    # 탄소집약도·에너지원·환경성적서 — 제조사만, 권장(저장 가드상 제조사만 upsert 가능).
    if pt == "manufacturer":
        recommended += [
            "regulation.carbon_intensity",
            "regulation.energy_source",
            "documents.environmental_report_url",
        ]
    return blocking, recommended


def _val_present(v) -> bool:
    if v is None:
        return False
    if isinstance(v, str):
        return v.strip() != ""
    return True


# 스칼라 필드 키(접두어 제거 후) → snapshot 컬럼명.
_COMPLETENESS_COLUMN = {
    "company_name": "company_name",
    "country": "country",
    "business_reg_no": "business_reg_no",
    "provider_type": "provider_type",
    "carbon_intensity": "carbon_intensity",
    "energy_source": "energy_source",
    "business_reg_doc_url": "business_reg_doc_url",
    "environmental_report_url": "environmental_report_url",
}


def _mineral_present(cm: dict) -> bool:
    # 광물 키 아무거나 1종(흑연 포함). hazardous_substances는 광물 함량이 아니므로 제외.
    return any(_val_present(v) for k, v in cm.items() if k != "hazardous_substances")


def _field_filled(field: str, snap: dict, handled_metals: set = frozenset()) -> bool:
    cm = snap.get("core_minerals") or {}
    if field == "factories":
        return (snap.get("factory_count") or 0) > 0
    if field == "factories.mine_country":
        # 광산 공장(사이트) 중 하나라도 원산지 국가가 있으면 충족(제련소 대행 입력 포함).
        return any(_val_present(mf.get("country")) for mf in snap.get("mining_factories") or [])
    if field == "factories.mine_composition":
        # 광산 공장(사이트) 중 하나라도 소재 구성(핵심광물 함량)이 1종 이상 있으면 충족.
        return any(_mineral_present(mf.get("core_minerals") or {}) for mf in snap.get("mining_factories") or [])
    if field == "materials.any":
        # 소재구성은 회사 단위가 아니라 공장(사이트) 단위 — 활성 공장 중 하나라도
        # 핵심광물 함량이 1종 이상 있으면 충족(§factories_minerals, 광산의 factories.mine_composition과 동일 패턴).
        return any(_mineral_present(f.get("core_minerals") or {}) for f in snap.get("factories_minerals") or [])
    if field == "materials.handled_any":
        # 취급 금속(공급망 도출) 중 최소 1개가 어느 공장에든 입력돼 있으면 충족. 도출 실패(맵
        #   미구축)면 '공장 중 하나라도 최소 1종 광물'로 폴백(순환 0/0=100% 방지).
        metals = [m for m in _TRACKED_METALS if m in handled_metals]
        factories = snap.get("factories_minerals") or []
        if metals:
            return any(_val_present((f.get("core_minerals") or {}).get(m)) for f in factories for m in metals)
        return any(_mineral_present(f.get("core_minerals") or {}) for f in factories)
    if field.startswith("materials."):
        return _val_present(cm.get(field.split(".", 1)[1]))
    if field == "regulation.self_reported_risk_level":
        v = snap.get("self_reported_risk_level")
        return _val_present(v) and v != "unknown"
    key = field.split(".", 1)[1] if "." in field else field
    return _val_present(snap.get(_COMPLETENESS_COLUMN.get(key, key)))


def _compute_completeness(snapshot: dict, handled_metals: set) -> dict:
    """snapshot(필드값) + handled_metals(제련소 공급망 금속) → 완성도 집계.
    완성도 표시(rate/missing)는 🔴필수+🟡권장 전체 기준(권장 티 안 냄). 제출 차단은
    별도의 blocking_missing(🔴필수 미충족)로 판정한다.
    반환: {required, filled, rate, missing[], blocking_missing[]}.
    miner 등 비대상은 required=0 · rate=100 · blocking_missing=[]."""
    blocking, recommended = _classify_fields(snapshot.get("provider_type"), handled_metals)
    tracked = blocking + recommended
    if not tracked:
        return {"required": 0, "filled": 0, "rate": 100.0, "missing": [], "blocking_missing": []}
    missing = [f for f in tracked if not _field_filled(f, snapshot, handled_metals)]
    blocking_missing = [f for f in blocking if not _field_filled(f, snapshot, handled_metals)]
    filled = len(tracked) - len(missing)
    rate = round(filled * 100.0 / len(tracked), 2)
    return {
        "required": len(tracked), "filled": filled, "rate": rate,
        "missing": missing, "blocking_missing": blocking_missing,
    }


async def _handled_metals(db: AsyncSession, supplier_id: UUID) -> set:
    """제련소가 공급망에서 '다루는 금속' 집합(child=이 협력사 파트의 광물)."""
    part_codes = await repository.get_supply_chain_metals(db, supplier_id)
    return {m for m in (part_code_to_metal(c) for c in part_codes) if m}


async def recompute_completeness(db: AsyncSession, supplier_id: UUID) -> None:
    """general-review 완성도 재계산 → data_completeness_status upsert. flush만(커밋은 호출부).
    없는 supplier면 무동작."""
    snap = await repository.get_completeness_inputs(db, supplier_id)
    if snap is None:
        return
    result = _compute_completeness(snap, await _handled_metals(db, supplier_id))
    await repository.upsert_completeness(
        db, supplier_id,
        required=result["required"], filled=result["filled"],
        rate=result["rate"], missing=result["missing"],
    )


async def has_blocking_gaps(db: AsyncSession, supplier_id: UUID) -> bool:
    """제출 게이트용 — 🔴필수(blocking) 필드 중 미충족이 하나라도 있으면 True.
    🟡권장 미입력은 제출을 막지 않는다(완성도 표시에만 반영). 스냅샷 없으면(대상 아님) False."""
    snap = await repository.get_completeness_inputs(db, supplier_id)
    if snap is None:
        return False
    metals = await _handled_metals(db, supplier_id)
    blocking, _ = _classify_fields(snap.get("provider_type"), metals)
    return any(not _field_filled(f, snap, metals) for f in blocking)


async def get_completeness(db: AsyncSession, supplier_id: UUID) -> Optional[dict]:
    """입력 완성도 — data_completeness_status 단건. 협력사 없으면 None,
    집계 전이면 빈 기본값으로 안전 반환."""
    if await repository.get_supplier_by_id(db, supplier_id) is None:
        return None
    comp = await repository.get_completeness(db, supplier_id)
    # provider_type별 추적 필드 키(🔴필수+🟡권장 전체 — 프론트 섹션 총계·'해당 없음' 판정용).
    #   제련소는 공급망 도출 금속을 반영. 권장 필드도 포함해 완성도 표시에서 티 나지 않게 한다.
    required: List[str] = []
    snap = await repository.get_completeness_inputs(db, supplier_id)
    handled = await _handled_metals(db, supplier_id) if snap is not None else set()
    if snap is not None:
        blocking, recommended = _classify_fields(snap.get("provider_type"), handled)
        required = blocking + recommended
    if comp is None:
        # 저장된 집계가 없으면(시드/최초 집계 전) 현재 스냅샷으로 즉시 계산해 반환한다.
        #   특히 광산(miner)은 required=0 → required_field_count=0(≠null)이라야 프론트가
        #   백엔드 SSOT 경로로 '해당 없음'을 그린다(폴백 경로의 오탐 '미입력' 방지).
        if snap is not None:
            r = _compute_completeness(snap, handled)
            comp = {
                "required_field_count": r["required"],
                "filled_field_count": r["filled"],
                "completion_rate": r["rate"],
                "missing_fields": r["missing"],
                "last_updated_at": None,
            }
        else:
            comp = {
                "required_field_count": None,
                "filled_field_count": None,
                "completion_rate": None,
                "missing_fields": [],
                "last_updated_at": None,
            }
    return {"supplier_id": supplier_id, "required_fields": required, **comp}


async def get_supplied_items(db: AsyncSession, supplier_id: UUID) -> Optional[dict]:
    """공급 품목 — 이 협력사가 공급망 맵에서 공급하는 부품 distinct.
    맵(제품×BOM버전)마다 destination(EU/US/KR)을 그 맵 최상위 고객사 국가로부터 자동 계산해
    동봉한다 — 협력사가 자유 입력하던 "납품처"를 대체(§FactoryCards 화면). 같은 맵의 모든 행은
    같은 고객사로 흐르므로 destination도 동일하다."""
    if await repository.get_supplier_by_id(db, supplier_id) is None:
        return None
    items = await repository.get_supplied_items(db, supplier_id)
    # 동기 조회 read(순수 함수, DB 미접근) — supplychain 도메인 재사용. resolve_outbound_locales와
    # 동일한 "고객사 country → ..." 계열 매핑이라 그 옆에 둔다(PROJECT_CORE 5-1 도메인격리 예외 ①).
    from backend.domains.supplychain.risk_summary_templates import resolve_destination_region

    for item in items:
        item["destination"] = resolve_destination_region(item.get("customer_country"))
    return {
        "supplier_id": supplier_id,
        "items": items,
    }


async def get_carbon_declarations(db: AsyncSession, supplier_id: UUID) -> Optional[dict]:
    """환경성적서(탄소발자국) — 공장별 factory_carbon_declarations. 최종 검증(STEP4) 핵심 자료."""
    if await repository.get_supplier_by_id(db, supplier_id) is None:
        return None
    return {
        "supplier_id": supplier_id,
        "declarations": await repository.get_carbon_declarations(db, supplier_id),
    }


# doc_kind(URL 경로) → suppliers 컬럼명. update_supplier_detail의 doc_url_kinds(컬럼→kind)와 역방향 짝.
_DOC_KIND_TO_COLUMN = {
    "business_reg": "business_reg_doc_url",
    "environmental_report": "environmental_report_url",
    "self_assessment": "self_assessment_doc_url",
    "material_composition": "material_composition_doc_url",
    "carbon_footprint": "carbon_footprint_doc_url",
}


async def get_document_url(db: AsyncSession, supplier_id: UUID, doc_kind: str) -> Optional[dict]:
    """
    필요문서(사업자등록증/환경성적서 등) presigned 다운로드 URL 발급.
    잘못된 doc_kind·협력사 없음·문서 미업로드(컬럼 빈값) 모두 None(라우터가 404로 변환).
    """
    column = _DOC_KIND_TO_COLUMN.get(doc_kind)
    if column is None:
        return None
    supplier = await repository.get_supplier_by_id(db, supplier_id)
    if supplier is None:
        return None
    key = getattr(supplier, column, None)
    if not key:
        return None
    file_name = supplier.business_reg_doc_name if column == "business_reg_doc_url" else None
    if not file_name:
        file_name = key.rstrip("/").rsplit("/", 1)[-1]
    return {"url": await storage.generate_presigned_url(key), "file_name": file_name}


# ============================================================
# 협력사 회원가입(공개 온보딩) — prefill / submit (담당: 팀원 B / §4)
#   진입은 초대 링크 ?supplierId= 키잉(invite token 없음, decision #8). 무토큰 공개.
# ============================================================
class OnboardingConflictError(Exception):
    """이미 가입 완료된 supplier 재제출 또는 이메일 중복 — router 가 409 로 매핑."""


def _pending_consent(rows: List[dict]) -> Optional[dict]:
    """동의서 이력(최신순) 중 협력사가 아직 동의해야 하는 대기 건(requested/returned)을 고른다."""
    return next((r for r in rows if r["status"] in ("requested", "returned")), None)


async def get_onboarding_prefill(db: AsyncSession, supplier_id: UUID) -> Optional[dict]:
    """공개 prefill — 비민감 필드(회사명/유형/국가) + 대기중 동의서 요약. 없는 supplier_id면 None(→404)."""
    supplier = await repository.get_supplier_by_id(db, supplier_id)
    if supplier is None:
        return None
    # 대기중 제3자 정보제공 동의서(있으면) — 프론트가 이 조건으로 원문을 재조립해 보여준다.
    #   온보딩은 무토큰이라 tenant 필터 없이 supplier 기준으로 조회한다.
    consent = None
    pending = _pending_consent(await consent_repo.list_by_supplier(db, supplier_id, None))
    if pending is not None:
        consent = {
            "consent_id": pending["consent_id"],
            "data_scope": pending["data_scope"] or [],
            "purpose": pending["purpose"],
            "third_party_sharing": pending["third_party_sharing"],
            "allowed_recipients": pending["allowed_recipients"],
            "valid_from": pending["valid_from"],
            "valid_to": pending["valid_to"],
            "revocable": pending["revocable"],
        }
    # 본인(대표) 담당자 — 이미 등록된 대표 contact가 있으면 폼에 미리 채운다(확인·최신화용).
    contacts = await repository.get_contacts(db, supplier_id)
    primary = next((c for c in contacts if c.get("is_primary")), None) or (contacts[0] if contacts else None)
    contact = None
    if primary is not None:
        contact = {
            "name": primary.get("name"),
            "email": primary.get("email"),
            "phone": primary.get("phone"),
            "department": primary.get("department"),
        }

    # 주소 — suppliers.address 우선, 없으면 본사(headquarters) 공장 주소로 폴백.
    #   (submit은 주소를 suppliers.address + supplier_factories(headquarters) 양쪽에 저장한다.)
    address = supplier.address
    if not address:
        factories = await repository.get_factories(db, supplier_id)
        hq = next((f for f in factories if f.get("factory_role") == "headquarters"), None) or (
            factories[0] if factories else None
        )
        if hq:
            address = hq.get("address")

    # 사업자등록증 — 이미 업로드돼 있으면 원본 파일명과 함께 표시(재확인용, 재업로드 없이 확인만).
    #   원본 파일명(business_reg_doc_name) 우선, 없으면(구 데이터) s3 key 끝부분으로 폴백.
    business_reg_doc = None
    if supplier.business_reg_doc_url:
        business_reg_doc = {
            "s3_key": supplier.business_reg_doc_url,
            "file_name": supplier.business_reg_doc_name or supplier.business_reg_doc_url.rsplit("/", 1)[-1],
        }

    # 환경성적서 — business_reg_doc과 동일 패턴. 원본 파일명 컬럼이 없어 s3 key 끝부분으로 표시.
    environmental_report = None
    if supplier.environmental_report_url:
        environmental_report = {
            "s3_key": supplier.environmental_report_url,
            "file_name": supplier.environmental_report_url.rsplit("/", 1)[-1],
        }

    return {
        "company_name": supplier.company_name,
        "provider_type": supplier.provider_type,
        "country": supplier.country,
        "business_reg_no": supplier.business_reg_no,
        "duns_number": supplier.duns_number,
        "address": address,
        "contact": contact,
        "business_reg_doc": business_reg_doc,
        "environmental_report": environmental_report,
        "unverified": bool(supplier.is_unverified),
        "consent": consent,
    }


def _build_onboarding_contacts(body: OnboardingSubmitRequest) -> List[MasterFormContact]:
    """PIC payload → MasterFormContact. 대표(is_primary)가 하나도 없으면 첫 명을 대표로
    승격하고, 대표에는 회사 블록의 department(본인 부서)를 보조로 채운다."""
    any_primary = any(c.is_primary for c in body.contacts)
    contacts: List[MasterFormContact] = []
    for i, c in enumerate(body.contacts):
        is_primary = c.is_primary or (not any_primary and i == 0)
        contacts.append(MasterFormContact(
            name=c.name,
            role=c.role,
            department=c.department or (body.company.department if is_primary else None),
            email=c.email,
            phone=c.phone,
            is_primary=is_primary,
        ))
    return contacts


async def _record_consent_agreement(
    db: AsyncSession, supplier_id: UUID, body: OnboardingSubmitRequest, signed_at: datetime
) -> None:
    """대기중 제3자 정보제공 동의서를 'agreed'로 기록. 대기 건이 없으면(구 데이터 등) 스킵 —
    입력 게이트(consent_status)만으로 진행한다. 커밋은 온보딩 트랜잭션이 일괄 담당."""
    pending = _pending_consent(await consent_repo.list_by_supplier(db, supplier_id, None))
    if pending is None:
        return
    primary = next((c for c in body.contacts if c.is_primary), None) or (body.contacts[0] if body.contacts else None)
    signer_name = (primary.name if primary else None) or body.company.company_name
    signer_email = (primary.email if primary else None) or body.account.email
    agreement_hash = hashlib.sha256(
        f"{pending['consent_id']}|{signer_name}|{signed_at.isoformat()}".encode("utf-8")
    ).hexdigest()[:16]
    update = ConsentUpdateBody(
        status="agreed",
        signer_name=signer_name,
        signer_email=signer_email,
        signature_method="email_form",
        form_data={"agreed_via": "onboarding", "signer_display": signer_name, "agreed_at": signed_at.isoformat()},
        agreement_hash=agreement_hash,
    )
    await consent_repo.update_status(db, pending["consent_id"], update)


async def submit_onboarding(
    db: AsyncSession, supplier_id: UUID, body: OnboardingSubmitRequest
) -> Optional[dict]:
    """
    공개 submit — 회사정보 + 문서 + PIC + 동의 전이 + 활성 계정 생성을 ★단일 트랜잭션·
    단일 커밋★ 으로 영속화(§4). 없는 supplier_id면 None(→404). 재제출/이메일 중복은
    OnboardingConflictError(→409). 응답 onboarding_complete=True.

    ※ 도메인 격리(결정 #4): users 의 계정 생성을 동기 호출하되, 커밋은 이 트랜잭션 한 번.
      이벤트가 아니라 동기인 이유 = "제출→즉시 로그인 / 중복 즉시 409".
    """
    supplier = await repository.get_supplier_by_id(db, supplier_id)
    if supplier is None:
        return None
    from_status = supplier.status

    users = UserRepository(db)
    # 1) 재제출 가드 — 이미 활성 계정이 있는 supplier 면 409(decision #8).
    if await users.get_active_by_supplier_id(supplier_id) is not None:
        raise OnboardingConflictError("이미 가입이 완료된 협력사입니다.")
    # 2) 이메일 중복 — users.email UNIQUE 선검사 → 409.
    if await users.get_by_email(body.account.email) is not None:
        raise OnboardingConflictError("이미 사용 중인 이메일입니다.")

    try:
        # 3) 회사정보 — suppliers 갱신(보낸 것만; country 는 ISO2 정규화).
        company_fields: dict = {
            "company_name": body.company.company_name,
            "business_reg_no": body.company.business_reg_no,
            "duns_number": body.company.duns_number,
            "is_unverified": body.unverified,
        }
        iso = _normalize_country_to_iso2(body.company.country)
        if iso:
            company_fields["country"] = iso
        if body.business_reg_doc is not None:
            company_fields["business_reg_doc_url"] = body.business_reg_doc.s3_key
        if body.environmental_report is not None:
            company_fields["environmental_report_url"] = body.environmental_report.s3_key
        # None 은 제거(빈값으로 덮어쓰지 않음). is_unverified=False 는 bool 이라 보존.
        company_fields = {k: v for k, v in company_fields.items() if v is not None}
        await repository.update_supplier_fields(db, supplier_id, company_fields)

        # 3-b) 회사 주소 — PROJECT_CORE/README §2.2: 회사 주소는 suppliers 컬럼이 아니라
        #   '공장(본사)' 단위로 보존(supplier_factories, factory_role='headquarters').
        #   원산지·규제 판정의 최소 단위가 공장이라는 코어 원칙. 신규 supplier라 replace-all OK.
        if body.company.address:
            await repository.write_master_form_factories(db, supplier_id, [
                MasterFormFactory(
                    factory_name=body.company.company_name,
                    address=body.company.address,
                    country=iso,
                    factory_role="headquarters",
                )
            ])

        # 4) PIC — supplier_contacts replace-all(대표 1명 is_primary).
        await repository.write_master_form_contacts(
            db, supplier_id, _build_onboarding_contacts(body), []
        )

        # 5) 동의 전이 — supplier_onboarding.consent_status='consent_agreed'.
        signed_at = datetime.now(timezone.utc)
        await repository.mark_consent_agreed(db, supplier_id, signed_at)
        # 제3자 정보제공 동의서(data_consent)를 'agreed'로 — 서명자·서명방식·해시 등 감사추적 기록(플래그와 별개).
        if body.consent_agreed:
            await _record_consent_agreement(db, supplier_id, body, signed_at)

        # 6) 상태 전이 — suppliers.status='supplier_review'(원청 승인 대기). (감사 이력 자동 기록)
        await repository.set_supplier_status(
            db, supplier_id, "supplier_review", reason="온보딩 제출 — 원청 승인 대기"
        )

        # 7) 활성 계정 생성 — tenant_id=초대한 원청, role=supplier_ceo(결정 #3).
        primary = next((c for c in body.contacts if c.is_primary), None)
        if primary is None and body.contacts:
            primary = body.contacts[0]
        await users.create_user(
            email=body.account.email,
            password_hash=get_password_hash(body.account.password),
            role="supplier_ceo",
            supplier_id=supplier_id,
            tenant_id=supplier.tenant_id,
            name=primary.name if primary else None,
        )

        # 7-c) [FIX] 하위협력사 캐스케이드 초대(STEP3) — 예전엔 프론트 로컬 state로만 남고
        #   어디에도 저장되지 않았다(PM 확인 후 정식 연결). 무토큰 공개 submit 트랜잭션
        #   안에서 create_supplier_and_invite 와 동일한 절차(협력사+리스크프로필+온보딩행+
        #   PIC+완성도)를 그대로 반복하되, 커밋은 이 트랜잭션 한 번으로 묶는다.
        invited_sub_suppliers: list[dict] = []
        for sub in body.sub_suppliers:
            # 이미 같은 테넌트에 이름이 완전히 같은 협력사가 있으면(ERP/맵 시드 등으로 이미
            # 알려진 협력사) 새로 만들지 않고 그 협력사를 재사용한다 — 안 그러면 이름은 같고
            # ID만 다른 중복 협력사가 생겨 공급망 트리에 유령처럼 남는다.
            existing = await repository.get_supplier_by_name(db, supplier.tenant_id, sub.company_name)
            if existing is not None:
                sub_supplier = existing
            else:
                sub_supplier = await repository.create_supplier(db, {
                    "company_name": sub.company_name,
                    "provider_type": "manufacturer",  # STEP3 화면엔 유형 선택이 없어 기본값(원청이 추후 조정 가능)
                    "tenant_id": supplier.tenant_id,
                    "status": "supplier_pending",
                })
            if await repository.get_risk_profile_by_supplier(db, sub_supplier.supplier_id) is None:
                db.add(SupplierRiskProfile(
                    supplier_id=sub_supplier.supplier_id,
                    overall_risk_score=0,
                    risk_level="low",
                    is_high_risk_flag=False,
                ))
            sub_sla_due = datetime.now(timezone.utc) + timedelta(days=SUPPLIER_SLA_DAYS)
            if existing is None:
                # 온보딩 row는 트리거(trg_supplier_onboarding_autocreate)가 create_supplier
                # 시점에 이미 만들어놨다(consent_status='consent_pending' 기본값) — 여기서는
                # SLA 마감·초대 시각만 채운다. 재사용된 협력사(existing)는 이미 자기 온보딩
                # 이력이 있으므로 손대지 않는다(기존 동작 유지).
                await db.execute(
                    update(SupplierOnboarding)
                    .where(SupplierOnboarding.supplier_id == sub_supplier.supplier_id)
                    .values(last_invited_at=datetime.now(timezone.utc), sla_due_date=sub_sla_due)
                )
            # 아래(PIC 저장·동의서/자료요청 자동 생성)는 진짜 신규 협력사일 때만 한다.
            # 재사용된 협력사(existing)는 이미 실제 담당자·이력이 따로 있을 수 있고,
            # 특히 동의서를 여기서 미리 만들어버리면 원청이 STEP3에서 실제로 메일을
            # 보내기도 전에 '이미 발송됨'으로 잘못 표시된다(차수 노출 게이트 오작동).
            if existing is None:
                await repository.write_master_form_contacts(db, sub_supplier.supplier_id, [
                    MasterFormContact(name=sub.name, email=sub.email, phone=sub.phone, is_primary=True),
                ], [])
                await recompute_completeness(db, sub_supplier.supplier_id)
            # [FIX] 동의서/자료요청은 여기서 미리 만들지 않는다(신규·재사용 공통) — 미리
            # 만들면 이 하위 협력사가 맵에 노출되자마자 '이미 메일 발송됨'으로 잘못 표시돼
            # STEP3(원청이 실제로 메일을 보내야 하는 단계)→STEP4 차수 노출 게이트가 깨진다.
            # 온보딩 폼 자체의 '정보 입력 시작' 게이트는 supplier_onboarding.consent_status
            # 컬럼(항상 생성됨)만 보므로 이걸 안 만들어도 캐스케이드 협력사는 그대로 온보딩
            # 진행이 가능하다 — 원청이 STEP3에서 메일을 보내야 동의서·자료요청이 생긴다.
            invited_sub_suppliers.append({
                "supplier_id": sub_supplier.supplier_id, "email": sub.email, "sla_due_date": sub_sla_due,
            })

        # 8) 단일 커밋(atomic) — 여기 도달해야만 전체 영속화.
        await db.commit()
    except OnboardingConflictError:
        raise
    except Exception:
        await db.rollback()
        raise

    # 9) 커밋 성공 후에만 이벤트 발행(G1과 동일 규칙) — 하위협력사마다 SupplierInvited.
    for inv in invited_sub_suppliers:
        event = SupplierInvitedEvent(
            supplier_id=inv["supplier_id"], email=inv["email"], sla_due_date=inv["sla_due_date"],
            inviter_supplier_id=supplier_id,
        )
        await publish("SupplierInvited", dataclasses.asdict(event))

    # 9-b) 이 협력사(모든 차수 공통) 자신의 온보딩 제출 — 원청에 STEP4 수신확인 알림
    #   (onboarding_review_notify.py가 to_status=='supplier_review'일 때만 처리).
    status_event = SupplierStatusChangedEvent(
        supplier_id=supplier_id, from_status=from_status, to_status="supplier_review",
    )
    await publish("SupplierStatusChanged", dataclasses.asdict(status_event))

    return {
        "supplier_id": supplier_id,
        "status": "supplier_review",
        "onboarding_complete": True,
    }


async def get_reliability(db: AsyncSession, supplier_id: UUID) -> Optional[dict]:
    """
    Reliability(신뢰도) 탭 — 완성도 + 리스크 프로필 + 온보딩 SLA + 실사 요약.
    리스크 프로필/온보딩이 아직 없을 수 있으므로 각 필드는 안전하게 None fallback.
    """
    supplier = await repository.get_supplier_by_id(db, supplier_id)
    if supplier is None:
        return None

    profile = await repository.get_risk_profile_by_supplier(db, supplier_id)
    onboarding = await repository.get_onboarding_by_supplier(db, supplier_id)
    audits = await repository.get_audit_records(db, supplier_id)
    # 실사 기록은 audit_date 내림차순 → 첫 행이 최신.
    latest_audit = audits[0] if audits else None

    return {
        "supplier_id": supplier_id,
        "completeness_score": supplier.completeness_score,
        "overall_risk_score": profile.overall_risk_score if profile else None,
        "risk_level": profile.risk_level if profile else None,
        "is_high_risk_flag": profile.is_high_risk_flag if profile else None,
        "last_risk_review_at": profile.last_risk_review_at if profile else None,
        "consent_status": onboarding.consent_status if onboarding else None,
        "agreement_status": onboarding.agreement_status if onboarding else None,
        "sla_due_date": onboarding.sla_due_date if onboarding else None,
        "reminder_count": onboarding.reminder_count if onboarding else None,
        "last_reminded_at": onboarding.last_reminded_at if onboarding else None,
        "total_audits": len(audits),
        "last_audit_date": latest_audit.audit_date if latest_audit else None,
        "last_audit_result": latest_audit.result if latest_audit else None,
    }