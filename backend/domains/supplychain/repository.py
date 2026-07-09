"""
domains/supplychain/repository.py  (담당: 팀원 D · 영수)

공급망 그래프 데이터 접근 계층. 재귀 CTE 기반 N차 탐색 + PostGIS Geo Audit.
모든 주요 쿼리에 @trace_tool 적용 (절대 규칙 #3).
"""
import re
import unicodedata
import uuid
from typing import Any, Dict, List, Optional

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from backend.infrastructure.trace import trace_tool

# 신장 위구르 자치구 경계 (스펙 5-2). SRID 4326 기준.
XINJIANG_REGION_WKT = (
    "POLYGON((73.4 34.8, 96.4 34.8, 96.4 49.2, 73.4 49.2, 73.4 34.8))"
)

# ─────────────────────────────────────────────────────────────────────────
# 신장(UFLPA) 지구 정규 사전 — single source of truth.
#   ★왜 좌표 폴리곤과 별개로 이름 판정이 필요한가★
#   지오코딩(geo-places)이 신장 광역·하위 지구(카슈가르·허톈 등)를 좌표로 못 잡아
#   location이 NULL이 되면, 폴리곤 판정 쿼리(location IS NOT NULL)에서 빠져 UFLPA
#   최고위험지가 false negative로 통과한다. 이름으로도 잡아 누락을 막는다.
#
#   구조: 신장 14개 지구(+광역 별칭)를 '지구 1개 = 엔트리 1개'로 묶는다.
#     각 엔트리에 中(zh)·英(en_aliases)·韓(ko) 공통명칭을 함께 담아,
#     → 중국어로 쓰든, 목록에서 고르든, 영/한 어느 표기로 들어오든 같은 지구로 연결.
#     → 매칭 토큰(아래 CJK/LATIN)과 언어 간 정규화(resolve_xinjiang_region)를 여기서 파생.
#     'en'은 표준 표기(UI 라벨/정규화 결과값), 'code'는 안정 식별자(드롭다운 value).
#
#   ★매칭이 두 갈래인 이유★
#   - 한자·한글 → substring(ILIKE). CJK는 다른 단어에 우연히 박히지 않고 "新疆哈密市"
#     처럼 공백 없이 붙어 나와 단어경계가 없으므로 substring이 맞다.
#   - 로마자 → 단어경계 정규식(~* '\y…\y'). hami/ili/kashi/changji 같은 짧은 이름을
#     substring으로 넣으면 hamilton·facility·changjiang(长江)에 박혀 오탐이 폭발한다.
#     단어경계로 걸면 "Hami"는 잡고 "Hamilton"은 안 잡는다.
#   ※ resolve는 구체 지구가 광역 별칭보다 우선하도록 14개를 먼저, 광역을 맨 끝에 둔다.
# ─────────────────────────────────────────────────────────────────────────
XINJIANG_PREFECTURES: List[Dict[str, Any]] = [
    # 4 지급시(地級市)
    {"code": "urumqi",     "en": "Ürümqi",     "zh": ["乌鲁木齐"],        "en_aliases": ["Urumqi", "Urumchi"],          "ko": ["우루무치"]},
    {"code": "karamay",    "en": "Karamay",    "zh": ["克拉玛依"],        "en_aliases": ["Karamay"],                    "ko": ["카라마이"]},
    {"code": "turpan",     "en": "Turpan",     "zh": ["吐鲁番"],          "en_aliases": ["Turpan"],                     "ko": ["투루판"]},
    {"code": "hami",       "en": "Hami",       "zh": ["哈密"],            "en_aliases": ["Hami"],                       "ko": ["하미"]},
    # 5 지구(地區)
    {"code": "aksu",       "en": "Aksu",       "zh": ["阿克苏"],          "en_aliases": ["Aksu"],                       "ko": ["아커쑤", "아크수"]},
    {"code": "kashgar",    "en": "Kashgar",    "zh": ["喀什"],            "en_aliases": ["Kashgar", "Kashi"],           "ko": ["카슈가르"]},
    {"code": "hotan",      "en": "Hotan",      "zh": ["和田"],            "en_aliases": ["Hotan", "Khotan", "Hetian"],  "ko": ["허톈", "호탄"]},
    {"code": "tacheng",    "en": "Tacheng",    "zh": ["塔城"],            "en_aliases": ["Tacheng"],                    "ko": ["타청"]},
    {"code": "altay",      "en": "Altay",      "zh": ["阿勒泰"],          "en_aliases": ["Altay", "Altai"],             "ko": ["알타이"]},
    # 5 자치주(自治州)
    {"code": "kizilsu",    "en": "Kizilsu",    "zh": ["克孜勒苏"],        "en_aliases": ["Kizilsu"],                    "ko": ["키질수", "커쯔러쑤"]},
    {"code": "bortala",    "en": "Bortala",    "zh": ["博尔塔拉"],        "en_aliases": ["Bortala"],                    "ko": ["보르탈라", "보얼타라"]},
    {"code": "changji",    "en": "Changji",    "zh": ["昌吉"],            "en_aliases": ["Changji"],                    "ko": ["창지"]},
    {"code": "bayingolin", "en": "Bayingolin", "zh": ["巴音郭楞", "库尔勒"], "en_aliases": ["Bayingolin", "Bayingol", "Korla"], "ko": ["바인궈렁", "바잉골린", "쿠얼러"]},
    {"code": "ili",        "en": "Ili",        "zh": ["伊犁"],            "en_aliases": ["Ili", "Yili"],                "ko": ["이리"]},
    # 광역 별칭 — 구체 지구보다 뒤(우선순위 낮게).
    {"code": "xinjiang",   "en": "Xinjiang (autonomous region)", "zh": ["新疆", "维吾尔"], "en_aliases": ["Xinjiang", "Uyghur", "Uygur", "Uighur"], "ko": ["신장", "위구르"]},
]

def _fold_latin(s: str) -> str:
    """
    로마자 비교용 정규화: 발음기호 제거(ü→u) + 소문자.
    'Ürümqi'·'ÜRÜMQI' → 'urumqi' 로 흡수해 변형 표기를 잡는다.
    ※ 한글/한자에는 쓰지 않는다 — NFKD가 한글 음절을 자모로 분해해 매칭을 깨뜨림.
      (그래서 CJK/KO는 원문 substring, 로마자만 이 폴딩+단어경계로 비교한다.)
    """
    nfkd = unicodedata.normalize("NFKD", s)
    return "".join(c for c in nfkd if not unicodedata.combining(c)).casefold()


def resolve_xinjiang_region(value: Optional[str]) -> Optional[Dict[str, Any]]:
    """
    입력(중/영/한 표기) → 해당 신장 지구 엔트리. 없으면 None.
    매칭 단일 출처 — check_xinjiang_by_name(배치 판정)도 이 함수를 그대로 쓴다.

    언어 간 표기 연결·정규화에 쓴다. 예: '喀什'·'Kashi'·'카슈가르'·'KASHGAR'
    → 모두 kashgar 엔트리({en:'Kashgar', ...})로 해석돼 표준 표기를 얻는다.
    - 한자·한글 = 원문 substring(CJK는 공백 없이 붙고 다른 단어에 안 박힘).
    - 로마자 = 발음기호 폴딩 + 단어경계(\b). 'Hami'는 잡고 'Hamilton'은 안 잡는다.
    구체 지구가 광역 별칭보다 우선(리스트 순서: 14개 먼저, 광역 끝).
    ※ 정규화가 흡수하는 건 발음기호/대소문자까지. 완전 다른 표기(Wulumuqi 완전핀인,
      Kashkar 오타)는 못 잡음 — 별칭 추가 또는 LLM fallback 영역(상황정리 참조).
    """
    if not value:
        return None
    folded = _fold_latin(value)   # 로마자 비교용(발음기호·대소문자 제거)
    for p in XINJIANG_PREFECTURES:
        if any(t in value for t in (p["zh"] + p["ko"])):          # CJK/KO: 원문 substring
            return p
        if any(re.search(rf"\b{re.escape(_fold_latin(t))}\b", folded) for t in p["en_aliases"]):
            return p
    return None


#   supply_chain_map.map_id(엣지 PK) → edge_id, supply_ratio.map_id → edge_id 로 전 쿼리 정합.
#   프론트 응답 키는 보호 위해 최종 출력에서 'map_id' 별칭/CTE 컬럼명 유지(edge_id AS map_id).
#   최종 작업 시 이 클래스의 map_id↔edge_id 관련 변경을 원복 대상으로 식별.
class SupplyChainRepository:
    def __init__(self, session: AsyncSession):
        self.session = session

    @trace_tool("supply_chain_tree_query")
    async def get_n_tier_supply_chain(
        self,
        product_id: str,
    ) -> List[Dict[str, Any]]:
        """
        특정 product_id에 연결된 원청(Pack)~말단 광산까지 전체 트리를 재귀 탐색.
        스펙 5-1 SUPPLY_CHAIN_TREE_QUERY 기준: bom_versions JOIN으로 product_id 진입,
        트리 루트 = 원청(tier0/hop0, parent_supplier_id IS NULL → child=원청 Pack)부터 하향 탐색.

        [F1 표시 기준 — depth 단일화]
          - depth = CTE 재귀 깊이(0=원청). 프론트 트리 렌더링·레이어 표시 기준축.
          - hop_level = supply_chain_map 엣지 보조 메타(경로 순번). 재귀 JOIN 조건·겸업 탐색용.
            겸업(한양셀 Module→Cell)처럼 depth ≠ hop_level 이 될 수 있다 → 표시는 depth만 사용.
          - 순환 판정: path 키 = (child_supplier_id, part_id) 복합키(겸업 오판 방지).
        공장 좌표는 GeoJSON으로 반환 (스펙 완료 기준).
        """
        query = text("""
            WITH RECURSIVE sc_tree AS (
                -- 앵커: 트리 루트 = 원청 (parent_supplier_id IS NULL, child=원청 Pack, hop_level=0)
                SELECT
                    scm.edge_id AS map_id, scm.bom_version_id, scm.parent_supplier_id, scm.child_supplier_id,
                    scm.part_id, s.company_name, s.provider_type, scm.hop_level,
                    sf.country,
                    ST_AsGeoJSON(sf.location) AS location_geojson,
                    0 AS depth,
                    ARRAY[scm.child_supplier_id::text || ':' || scm.part_id::text] AS path,
                    FALSE AS is_cycle,
                    TRUE AS is_root_anchor
                FROM supply_chain_map scm
                JOIN bom_versions bv ON bv.bom_version_id = scm.bom_version_id
                JOIN suppliers s ON s.supplier_id = scm.child_supplier_id
                LEFT JOIN supplier_factories sf
                    ON sf.supplier_id = s.supplier_id AND sf.is_active = TRUE
                WHERE bv.product_id = :product_id
                  AND scm.parent_supplier_id IS NULL

                UNION ALL

                SELECT
                    scm.edge_id AS map_id, scm.bom_version_id, scm.parent_supplier_id, scm.child_supplier_id,
                    scm.part_id, s.company_name, s.provider_type, scm.hop_level,
                    sf.country,
                    ST_AsGeoJSON(sf.location) AS location_geojson,
                    sct.depth + 1,
                    sct.path || (scm.child_supplier_id::text || ':' || scm.part_id::text),
                    (scm.child_supplier_id::text || ':' || scm.part_id::text) = ANY(sct.path),
                    FALSE AS is_root_anchor
                FROM supply_chain_map scm
                JOIN sc_tree sct ON scm.parent_supplier_id = sct.child_supplier_id
                                AND scm.bom_version_id = sct.bom_version_id
                                AND scm.hop_level = sct.hop_level + 1
                JOIN suppliers s ON s.supplier_id = scm.child_supplier_id
                LEFT JOIN supplier_factories sf
                    ON sf.supplier_id = s.supplier_id AND sf.is_active = TRUE
                WHERE NOT sct.is_cycle
            )
            SELECT
                map_id, parent_supplier_id, child_supplier_id, part_id,
                company_name, provider_type,
                depth,           -- [F1 주축] 프론트 트리 표시 기준
                hop_level,       -- [F1 보조] 엣지 메타 — 겸업 탐색·JOIN 조건용
                is_root_anchor,  -- [F2] parent_supplier_id IS NULL 파생 — 원청/tier0 동적 판정
                country, location_geojson, is_cycle
            FROM sc_tree
            ORDER BY depth, hop_level;
        """)
        result = await self.session.execute(query, {"product_id": product_id})
        return [dict(row._mapping) for row in result]

    @trace_tool("supply_chain_by_bom_depth")
    async def get_by_bom_depth(self, bom_depth: int) -> List[Dict[str, Any]]:
        """
        부품 tier 기준 필터 (bom_depth = parts.tier_level, 0-base).
        '같은 부품 계층(Pack/Module/Cell/활물질/전구체/제련/광산)' 노드만 횡으로 조회.
        hop_level(경로 순번)과는 독립축이므로 ADR에 따라 엔드포인트를 분리한다.
        """
        query = text("""
            SELECT
                scm.edge_id AS map_id, scm.bom_version_id, scm.parent_supplier_id, scm.child_supplier_id,
                scm.part_id, s.company_name, s.provider_type,
                scm.hop_level, p.tier_level AS bom_depth, scm.link_status
            FROM supply_chain_map scm
            JOIN suppliers s ON s.supplier_id = scm.child_supplier_id
            JOIN parts p ON p.part_id = scm.part_id
            WHERE p.tier_level = :bom_depth
            ORDER BY scm.hop_level, s.company_name;
        """)
        result = await self.session.execute(query, {"bom_depth": bom_depth})
        return [dict(row._mapping) for row in result]

    @trace_tool("supply_chain_by_hop")
    async def get_by_hop(self, hop_level: int) -> List[Dict[str, Any]]:
        """
        공급망 차수 기준 필터 (hop_level = 원청 0 기준 경로 순번).
        '같은 공급망 차수' 노드만 횡으로 조회. bom_depth(부품 tier)와는 독립축.
        """
        query = text("""
            SELECT
                scm.edge_id AS map_id, scm.bom_version_id, scm.parent_supplier_id, scm.child_supplier_id,
                scm.part_id, s.company_name, s.provider_type,
                scm.hop_level, p.tier_level AS bom_depth, scm.link_status
            FROM supply_chain_map scm
            JOIN suppliers s ON s.supplier_id = scm.child_supplier_id
            LEFT JOIN parts p ON p.part_id = scm.part_id
            WHERE scm.hop_level = :hop_level
            ORDER BY s.company_name;
        """)
        result = await self.session.execute(query, {"hop_level": hop_level})
        return [dict(row._mapping) for row in result]

    @trace_tool("supply_chain_create")
    async def _ensure_map_header(self, bom_version_id: str) -> str:
        """이 bom_version의 공급망 맵 헤더(supply_chain_maps) 보장 — 없으면 생성하고 map_id 반환."""
        q = text("""
            INSERT INTO supply_chain_maps (bom_version_id, product_id, status)
            SELECT :bv, bv.product_id, 'building' FROM bom_versions bv WHERE bv.bom_version_id = :bv
            ON CONFLICT (bom_version_id) DO UPDATE SET bom_version_id = EXCLUDED.bom_version_id
            RETURNING map_id;
        """)
        r = await self.session.execute(q, {"bv": bom_version_id})
        return str(r.scalar_one())

    async def create_supply_relation(
        self,
        bom_version_id: str,
        parent_supplier_id: str | None,
        child_supplier_id: str,
        part_id: str,
        discovered_via: str | None = None,
    ) -> Dict[str, Any]:
        """supply_chain_map에 parent-child 관계 INSERT 후 생성 row 반환.

        discovered_via: 이 엣지가 '누구의 초대/대리신고로 발견됐는지'(상위 협력사 FK).
        ERP 원천 신고면 None. 상위 협력사가 하위를 풀에 편입시킨 경우 그 상위 supplier_id.
        """
        map_header_id = await self._ensure_map_header(bom_version_id)
        query = text("""
            INSERT INTO supply_chain_map
                (map_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id, hop_level,
                 discovered_via)
            VALUES
                (:map_header_id, :bom_version_id, :parent_supplier_id, :child_supplier_id, :part_id,
                 -- 차수: 루트(부모 없음)=0, 자식=부모 엣지 hop_level+1.
                 -- 설정 안 하면 NULL → n-tier 재귀 CTE(scm.hop_level=parent+1)에서 누락된다.
                 CASE
                     WHEN CAST(:parent_supplier_id AS uuid) IS NULL THEN 0
                     ELSE COALESCE((SELECT scm2.hop_level + 1
                                    FROM supply_chain_map scm2
                                    WHERE scm2.child_supplier_id = :parent_supplier_id
                                      AND scm2.bom_version_id = :bom_version_id
                                    ORDER BY scm2.hop_level
                                    LIMIT 1), 1)
                 END,
                 :discovered_via)
            RETURNING edge_id AS map_id, parent_supplier_id, child_supplier_id, part_id;
        """)
        result = await self.session.execute(query, {
            "map_header_id": map_header_id,
            "bom_version_id": bom_version_id,
            "parent_supplier_id": parent_supplier_id,
            "child_supplier_id": child_supplier_id,
            "part_id": part_id,
            "discovered_via": discovered_via,
        })
        await self.session.flush()
        return dict(result.first()._mapping)

    @trace_tool("supply_chain_get_or_create_child_part")
    async def get_or_create_child_part(
        self,
        bom_version_id: str,
        parent_supplier_id: str,
        child_supplier_id: str,
    ) -> str:
        """캐스케이드 초대로 생성됐지만 맵에 미연결인 협력사를 연결할 때, 그 협력사가
        공급하는 부품(parts) row가 없으면 부모 부품의 하위 tier로 하나 만들어 재사용한다.
        """
        parent_part_q = text("""
            SELECT p.part_id, p.tier_level
            FROM supply_chain_map scm
            JOIN parts p ON p.part_id = scm.part_id
            WHERE scm.bom_version_id = :bom_version_id
              AND scm.child_supplier_id = :parent_supplier_id
            ORDER BY scm.created_at DESC
            LIMIT 1
        """)
        parent_row = (await self.session.execute(parent_part_q, {
            "bom_version_id": bom_version_id,
            "parent_supplier_id": parent_supplier_id,
        })).mappings().first()

        parent_part_id = parent_row["part_id"] if parent_row else None
        parent_tier = parent_row["tier_level"] if parent_row and parent_row["tier_level"] is not None else -1

        child_name_q = text("SELECT company_name FROM suppliers WHERE supplier_id = :sid")
        child_name_row = (await self.session.execute(child_name_q, {"sid": child_supplier_id})).mappings().first()
        child_company_name = (child_name_row or {}).get("company_name") or "미상 협력사"
        part_name = f"{child_company_name} 공급 부품"

        existing_q = text("""
            SELECT part_id FROM parts
            WHERE part_name = :part_name
              AND parent_part_id IS NOT DISTINCT FROM :parent_part_id
            LIMIT 1
        """)
        existing = (await self.session.execute(existing_q, {
            "part_name": part_name,
            "parent_part_id": parent_part_id,
        })).mappings().first()
        if existing:
            return str(existing["part_id"])

        part_code = f"AUTO-{uuid.uuid4().hex[:12].upper()}"
        insert_q = text("""
            INSERT INTO parts (part_code, part_name, tier_level, parent_part_id, source_system)
            VALUES (:part_code, :part_name, :tier_level, :parent_part_id, 'MANUAL_CONNECT')
            RETURNING part_id
        """)
        result = await self.session.execute(insert_q, {
            "part_code": part_code,
            "part_name": part_name,
            "tier_level": parent_tier + 1,
            "parent_part_id": parent_part_id,
        })
        await self.session.flush()
        return str(result.scalar_one())

    @trace_tool("supply_chain_lock_and_check_edge")
    async def lock_and_check_edge_exists(
        self,
        bom_version_id: str,
        parent_supplier_id: str,
        child_supplier_id: str,
    ) -> bool:
        """(bom_version, parent, child) 키로 트랜잭션 어드바이저리 락을 잡고 엣지 존재 여부를
        반환한다. 커밋/롤백 시 자동 해제(xact) — SupplierInvited는 uvicorn 멀티 워커 각각의
        LISTEN 커넥션이 동시에 수신해 동일 엣지를 중복 INSERT할 수 있어(경합), 두 번째
        트랜잭션이 첫 번째 커밋을 기다렸다가 '이미 있음'을 보고 스킵하게 한다.
        """
        lock_q = text("SELECT pg_advisory_xact_lock(hashtextextended(:key, 0))")
        key = f"{bom_version_id}:{parent_supplier_id}:{child_supplier_id}"
        await self.session.execute(lock_q, {"key": key})

        check_q = text("""
            SELECT 1 FROM supply_chain_map
            WHERE bom_version_id = :bom_version_id
              AND parent_supplier_id = :parent_supplier_id
              AND child_supplier_id = :child_supplier_id
            LIMIT 1
        """)
        result = await self.session.execute(check_q, {
            "bom_version_id": bom_version_id,
            "parent_supplier_id": parent_supplier_id,
            "child_supplier_id": child_supplier_id,
        })
        return result.first() is not None

    @trace_tool("supply_chain_get_unconnected_parent_edges")
    async def get_unconnected_parent_bom_versions(
        self,
        parent_supplier_id: str,
        child_supplier_id: str,
    ) -> List[str]:
        """초대(SupplierInvited) 자동 편입용: parent_supplier_id가 child로 연결된 모든
        bom_version_id 중, child_supplier_id가 아직 그 bom_version에 엣지가 없는 것만 반환.
        """
        q = text("""
            SELECT DISTINCT parent_edge.bom_version_id
            FROM supply_chain_map parent_edge
            WHERE parent_edge.child_supplier_id = :parent_id
              AND NOT EXISTS (
                  SELECT 1 FROM supply_chain_map child_edge
                  WHERE child_edge.bom_version_id = parent_edge.bom_version_id
                    AND child_edge.child_supplier_id = :child_id
              )
        """)
        result = await self.session.execute(q, {"parent_id": parent_supplier_id, "child_id": child_supplier_id})
        return [str(row[0]) for row in result]

    @trace_tool("supply_chain_declare_source")
    async def declare_new_source(
        self,
        bom_version_id: str,
        parent_supplier_id: str,
        child_supplier_id: str,
        part_id: str,
    ) -> Dict[str, Any]:
        """협력사 자진신고: 공급원 변경 시 새로운 노드를 SUPPLIER_DECLARED 상태로 생성"""
        map_header_id = await self._ensure_map_header(bom_version_id)
        query = text("""
            INSERT INTO supply_chain_map
                (map_id, bom_version_id, parent_supplier_id, child_supplier_id, part_id,
                 hop_level, link_status, source_system, verification_status, discovered_via)
            VALUES
                (:map_header_id, :bom_version_id, :parent_supplier_id, :child_supplier_id, :part_id,
                 COALESCE((SELECT hop_level + 1 FROM supply_chain_map
                           WHERE child_supplier_id = :parent_supplier_id
                             AND bom_version_id = :bom_version_id
                           LIMIT 1), 1),
                 'supplychain_declared', 'SUPPLIER_DECLARED', 'unverified',
                 -- 자진신고 = 상위 협력사(parent)가 하위를 풀에 편입 → 발견 경로는 parent 본인.
                 :parent_supplier_id)
            RETURNING edge_id AS map_id, parent_supplier_id, child_supplier_id, link_status, verification_status;
        """)
        result = await self.session.execute(query, {
            "map_header_id": map_header_id,
            "bom_version_id": bom_version_id,
            "parent_supplier_id": parent_supplier_id,
            "child_supplier_id": child_supplier_id,
            "part_id": part_id,
        })
        await self.session.flush()
        return dict(result.first()._mapping)

    async def record_discovered_via(
        self,
        invitee_supplier_id: str,
        inviter_supplier_id: str,
    ) -> int:
        """초대(SupplierInvited) 수신 시 발견 경로 백필.

        아직 discovered_via 가 비어있는(=원천 신고가 채우지 않은) 해당 협력사 엣지에만
        초대한 상위 협력사를 기록한다. 이미 값이 있으면 건드리지 않아 멱등하다.
        엣지가 아직 없으면 0행(초대만 되고 아직 관계 미등록) — 관계 등록 경로가 직접 채운다.
        반환: 갱신된 엣지 수.
        """
        q = text("""
            UPDATE supply_chain_map
               SET discovered_via = :inviter
             WHERE child_supplier_id = :invitee
               AND discovered_via IS NULL
            RETURNING edge_id
        """)
        r = await self.session.execute(q, {"inviter": inviter_supplier_id, "invitee": invitee_supplier_id})
        return len(r.fetchall())

    #   supplier 외(supplychain) 도메인. 최종 작업 시 이 메서드 전체 주석/삭제.
    async def set_supplier_verification(
        self,
        bom_version_id: str,
        child_supplier_id: str,
        verified: bool,
    ) -> int:
        """이 BOM 버전에서 해당 협력사로 연결된 맵 엣지들의 verification_status를 일괄 갱신."""
        query = text("""
            UPDATE supply_chain_map
               SET verification_status = :status
             WHERE bom_version_id = :bom_version_id
               AND child_supplier_id = :child_supplier_id
            RETURNING edge_id AS map_id;
        """)
        result = await self.session.execute(query, {
            "bom_version_id": bom_version_id,
            "child_supplier_id": child_supplier_id,
            "status": "verified" if verified else "unverified",
        })
        rows = result.fetchall()
        await self.session.flush()
        return len(rows)

    @trace_tool("get_supplier_master_and_gps_dto")
    async def get_supplier_master_and_gps_dto(self, supplier_id: str) -> dict:
        """HITL 컨텍스트용 협력사 마스터 및 공장 GPS 정보 조회"""
        master_query = text("""
            SELECT supplier_id, company_name, company_name_en, provider_type,
                   status, risk_level, completeness_score,
                   (SELECT sf.country FROM supplier_factories sf
                    WHERE sf.supplier_id = suppliers.supplier_id AND sf.is_active = TRUE
                    ORDER BY (sf.factory_role = 'headquarters') DESC, sf.factory_id
                    LIMIT 1) AS country,
                   NULL::INT AS tier
            FROM suppliers
            WHERE supplier_id = :supplier_id
        """)
        master_res = await self.session.execute(master_query, {"supplier_id": supplier_id})
        master_row = master_res.mappings().first()

        if not master_row:
            return {"supplier_master": {}, "factory_gps": []}

        master_dict = dict(master_row)
        if master_dict.get("supplier_id"):
            master_dict["supplier_id"] = str(master_dict["supplier_id"])

        factory_query = text("""
            SELECT factory_id, factory_name, address, country, region, factory_role,
                   ST_Y(location) AS lat, ST_X(location) AS lng,
                   COALESCE(ST_Within(location, ST_GeomFromText(:xinjiang_wkt, 4326)), FALSE) AS in_xinjiang
            FROM supplier_factories
            WHERE supplier_id = :supplier_id AND is_active = TRUE
        """)
        factory_res = await self.session.execute(factory_query, {
            "supplier_id": supplier_id,
            "xinjiang_wkt": XINJIANG_REGION_WKT,
        })
        factory_rows = factory_res.mappings().all()

        gps_list = []
        for row in factory_rows:
            f_dict = dict(row)
            if f_dict.get("factory_id"):
                f_dict["factory_id"] = str(f_dict["factory_id"])
            gps_list.append(f_dict)

        return {"supplier_master": master_dict, "factory_gps": gps_list}

    @trace_tool("check_company_boundary")
    async def is_cross_company_boundary(self, supplier_a_id: str, supplier_b_id: str) -> bool:
        """회사 경계 확인: corporate_reg_no가 다르거나, 둘 다 없는데 ID가 다르면 다른 법인으로 취급"""
        query = text("""
            SELECT COALESCE(s1.corporate_reg_no, s1.supplier_id::text) != COALESCE(s2.corporate_reg_no, s2.supplier_id::text) AS is_cross
            FROM suppliers s1, suppliers s2
            WHERE s1.supplier_id = :sup_a AND s2.supplier_id = :sup_b;
        """)
        result = await self.session.execute(query, {"sup_a": supplier_a_id, "sup_b": supplier_b_id})
        return bool(result.scalar())

    @trace_tool("cycle_precheck")
    async def would_create_cycle(
        self,
        parent_supplier_id: str,
        child_supplier_id: str,
    ) -> bool:
        """
        child가 parent의 상위(조상)이면 순환이 생긴다.
        child를 루트로 하향 탐색했을 때 parent에 도달하면 True.
        """
        query = text("""
            WITH RECURSIVE descendants AS (
                SELECT child_supplier_id
                FROM supply_chain_map
                WHERE parent_supplier_id = :child_id

                UNION ALL

                SELECT scm.child_supplier_id
                FROM supply_chain_map scm
                JOIN descendants d ON scm.parent_supplier_id = d.child_supplier_id
            )
            SELECT EXISTS (
                SELECT 1 FROM descendants WHERE child_supplier_id = :parent_id
            ) AS has_cycle;
        """)
        result = await self.session.execute(query, {
            "child_id": child_supplier_id,
            "parent_id": parent_supplier_id,
        })
        return bool(result.scalar())

    async def is_ancestor(self, ancestor_id: str, descendant_id: str) -> bool:
        """ancestor_id가 descendant_id의 상위(어느 차수든)인지 — supplier 도메인이 '연결된
        상위 협력사의 대행 입력' 권한(제련소가 하위 광산 공장정보 입력)을 판정할 때 재사용한다.
        would_create_cycle과 같은 하향 탐색 패턴(사이클 없는 DAG 가정)."""
        query = text("""
            WITH RECURSIVE descendants AS (
                SELECT child_supplier_id
                FROM supply_chain_map
                WHERE parent_supplier_id = :ancestor_id

                UNION ALL

                SELECT scm.child_supplier_id
                FROM supply_chain_map scm
                JOIN descendants d ON scm.parent_supplier_id = d.child_supplier_id
            )
            SELECT EXISTS (
                SELECT 1 FROM descendants WHERE child_supplier_id = :descendant_id
            ) AS is_descendant;
        """)
        result = await self.session.execute(query, {
            "ancestor_id": ancestor_id,
            "descendant_id": descendant_id,
        })
        return bool(result.scalar())

    @trace_tool("supply_ratio_sum")
    async def get_ratio_sum_for_map(self, map_id: str) -> float:
        """해당 map_id에 등록된 supply_ratio.ratio_percentage 합. 100 초과 검증용."""
        query = text("""
            SELECT COALESCE(SUM(ratio_percentage), 0) AS total
            FROM supply_ratio
            WHERE edge_id = :map_id;
        """)
        result = await self.session.execute(query, {"map_id": map_id})
        return float(result.scalar() or 0)

    @trace_tool("alternatives_query")
    async def get_alternatives(
        self,
        product_id: str,
        part_id: str,
    ) -> List[Dict[str, Any]]:
        """동일 part_id를 공급하는 다른 협력사 목록 (대체 공급망)."""
        query = text("""
            SELECT DISTINCT
                s.supplier_id, s.company_name, s.provider_type, scm.hop_level,
                sr.ratio_percentage
            FROM supply_chain_map scm
            JOIN bom_versions bv ON bv.bom_version_id = scm.bom_version_id
            JOIN suppliers s ON s.supplier_id = scm.child_supplier_id
            LEFT JOIN supply_ratio sr ON sr.edge_id = scm.edge_id
            WHERE bv.product_id = :product_id
              AND scm.part_id = :part_id
            ORDER BY sr.ratio_percentage DESC NULLS LAST;
        """)
        result = await self.session.execute(query, {
            "product_id": product_id,
            "part_id": part_id,
        })
        return [dict(row._mapping) for row in result]

    @trace_tool("supply_chain_gaps_query")
    async def get_supplier_field_data(
        self, product_id: str, bom_version_id: str | None = None
    ) -> List[Dict[str, Any]]:
        """
        C2 gap 계산용: 제품 공급망 내 모든 (협력사, 등장 차수) 조합과 각 규제 필수 필드의 보유 여부를 조회.

        bom_version_id 지정 시 그 맵(엣지) 안으로만 트리를 한정한다(미지정이면 이 제품의
        전체 bom_version 통틀어 조회 — 기존 동작 유지).

        [주의] 같은 협력사가 이 범위 안에서 서로 다른 hop_level에 여러 번 등장할 수 있다
          (예: 겸업/이중소싱으로 1차이자 2차). 예전엔 회사당 최소 depth 하나로만 합쳐서
          반환했으나, 그러면 그 협력사가 유일하게 채우던 더 깊은 차수가 완성도 집계에서
          통째로 사라진다('1,2차가 같은 회사면 2차가 빠짐' 버그). 완성도는 회사 단위가 아니라
          '그 차수의 관계'가 채워졌는지를 보는 것이므로, 등장하는 (협력사, depth) 조합마다
          행을 하나씩 반환한다 — 프론트 depthStats가 차수별로 정확히 집계하도록.

        반환 컬럼:
          supplier_id, provider_type, depth (등장한 hop_level — 같은 supplier_id가 여러 행일 수 있음)
          has_carbon_intensity          : manufacturer_details.carbon_intensity 존재 여부
          has_factory_carbon_decl       : factory_carbon_declarations 행 존재 여부
          has_mine_coordinates          : miner_details.mine_coordinates 존재 여부
        """
        bom_filter = "AND scm.bom_version_id = :bom_version_id" if bom_version_id else ""
        params: Dict[str, Any] = {"product_id": product_id}
        if bom_version_id:
            params["bom_version_id"] = bom_version_id

        query = text(f"""
            WITH RECURSIVE sc_tree AS (
                SELECT
                    scm.child_supplier_id, s.provider_type,
                    -- [차수 SSOT] 표시 차수 = 엣지 hop_level(원청 0 기준 경로순번). 트리 재귀깊이
                    --   대신 hop_level을 쓰는 이유: 겸업(한양셀 Module hop1 → Cell hop2)의 self-edge가
                    --   아래 사이클 가드로 스킵돼, 재귀깊이로는 하위 노드가 1씩 당겨진다(예: 동성머티리얼
                    --   실제 hop3인데 재귀깊이 2 → '2차' 오표시). hop_level은 seed 차수 SSOT라 정합.
                    scm.hop_level AS depth,
                    -- 사이클 가드용 방문 경로. child_supplier_id는 suppliers INNER JOIN이라 NULL 없음.
                    ARRAY[scm.child_supplier_id] AS path,
                    scm.bom_version_id
                FROM supply_chain_map scm
                JOIN bom_versions bv ON bv.bom_version_id = scm.bom_version_id
                JOIN suppliers s ON s.supplier_id = scm.child_supplier_id
                WHERE bv.product_id = :product_id
                  AND scm.parent_supplier_id IS NULL
                  {bom_filter}

                UNION ALL

                SELECT
                    scm.child_supplier_id, s.provider_type,
                    scm.hop_level,
                    sct.path || scm.child_supplier_id,
                    scm.bom_version_id
                FROM supply_chain_map scm
                JOIN sc_tree sct ON scm.parent_supplier_id = sct.child_supplier_id
                    -- [버그 수정] bom_version_id 제한이 없으면 하위 재귀가 원청(KIRA) 공유 노드를 거쳐
                    -- 다른 제품(bom_version)의 협력사까지 전부 끌고 온다 — 반드시 같은 맵 안에서만 내려간다.
                    AND scm.bom_version_id = sct.bom_version_id
                JOIN suppliers s ON s.supplier_id = scm.child_supplier_id
                -- 사이클/재방문 차단: 이미 경로에 있는 협력사는 재귀하지 않는다(무한/지수 폭주 방지).
                WHERE scm.child_supplier_id <> ALL(sct.path)
            ),
            unique_suppliers AS (
                -- [FIX] 예전엔 회사당 MIN(depth) 하나로 합쳐서, 같은 회사가 여러 차수에 걸치면
                --   더 깊은 차수가 통째로 사라졌다. 이제 (협력사, depth) 조합별로 한 행씩 유지한다
                --   (같은 depth로 여러 경로에서 도달해도 DISTINCT로 중복 한 번만).
                SELECT DISTINCT child_supplier_id AS supplier_id, provider_type, depth
                FROM sc_tree
            ),
            root_suppliers AS (
                SELECT DISTINCT child_supplier_id
                FROM sc_tree
                WHERE depth = 0
            )
            SELECT
                us.supplier_id,
                s.company_name,
                us.provider_type,
                us.depth,
                (rs.child_supplier_id IS NOT NULL) AS is_root_anchor,
                -- Manufacturer: carbon_intensity
                (smd.carbon_intensity IS NOT NULL)                           AS has_carbon_intensity,
                -- Manufacturer: factory_carbon_declarations (공장 단위 1차 선언)
                EXISTS (
                    SELECT 1 FROM factory_carbon_declarations fcd
                    JOIN supplier_factories sf ON sf.factory_id = fcd.factory_id
                    WHERE sf.supplier_id = us.supplier_id AND fcd.is_active = TRUE
                )                                                            AS has_factory_carbon_decl,
                -- Miner: mine_coordinates (PostGIS POINT)
                (smind.mine_coordinates IS NOT NULL)                         AS has_mine_coordinates,
                -- Miner/Trader(UFLPA): origin_country — 소재 국가 미기재 = 원산지 미확인
                (s.country IS NOT NULL)                                      AS has_origin_country,
                -- 전 유형 공통: 제3자 정보제공 동의서 실제 '동의(agreed)' 여부(요청만 한 상태는 미완료로 집계)
                EXISTS (
                    SELECT 1 FROM data_provision_consents dpc
                    WHERE dpc.supplier_id = us.supplier_id AND dpc.status = 'agreed'
                )                                                            AS has_consent_agreed
            FROM unique_suppliers us
            LEFT JOIN suppliers s                        ON s.supplier_id = us.supplier_id
            LEFT JOIN root_suppliers rs                  ON rs.child_supplier_id = us.supplier_id
            LEFT JOIN supplier_manufacturer_details smd ON smd.supplier_id = us.supplier_id
            LEFT JOIN supplier_miner_details smind       ON smind.supplier_id = us.supplier_id
            ORDER BY us.depth, us.provider_type;
        """)
        result = await self.session.execute(query, params)
        return [dict(row._mapping) for row in result]

    @trace_tool("xinjiang_proximity_check")
    async def check_geo_audit_risk_zone(
        self,
        radius_meters: int = 50000,  # 스펙 5-2: 50km 이내
    ) -> List[Dict[str, Any]]:
        """
        협력사 공장/광산 좌표가 신장 위구르 자치구 경계(Polygon) 반경 내(기본 50km)인지 검증.
        ST_DWithin (geography 캐스팅으로 미터 단위) 사용.
        """
        query = text("""
            SELECT
                s.supplier_id, s.company_name,
                sf.factory_id, sf.factory_name, sf.country,
                ST_AsGeoJSON(sf.location) AS coordinates,
                ST_DWithin(
                    sf.location::geography,
                    ST_GeomFromText(:xinjiang_wkt, 4326)::geography,
                    :radius
                ) AS is_in_risk_zone,
                ST_Distance(
                    sf.location::geography,
                    ST_GeomFromText(:xinjiang_wkt, 4326)::geography
                ) / 1000.0 AS distance_km
            FROM supplier_factories sf
            JOIN suppliers s ON sf.supplier_id = s.supplier_id
            WHERE sf.location IS NOT NULL;
        """)
        result = await self.session.execute(query, {
            "xinjiang_wkt": XINJIANG_REGION_WKT,
            "radius": radius_meters,
        })
        return [dict(row._mapping) for row in result]

    @trace_tool("xinjiang_name_match")
    async def check_xinjiang_by_name(self) -> List[Dict[str, Any]]:
        """
        신장(UFLPA) 이름매칭 판정 — region/address에 신장·하위 지구명이 있으면
        좌표 유무와 무관하게 대상으로 반환한다(좌표 폴리곤 판정의 false negative 보완).
        location은 NULL일 수 있으므로 ST_AsGeoJSON은 NULL을 그대로 반환(호출부에서 []처리).

        매칭은 resolve_xinjiang_region() 한 곳으로 통합(발음기호 정규화 포함).
        DB에서 SQL로 거르지 않고 활성 공장을 읽어 파이썬에서 판정한다 —
          이유: 발음기호 폴딩(Ürümqi→urumqi)을 SQL로 하면 unaccent 확장 의존이 생겨
          (스키마/인프라 변경). 매칭 로직을 이름 사전 한 곳에 두는 이점도 있다.
          ※ 활성 공장 전건 스캔이지만 배치당 1회 + 데모/CSDDD 규모라 부담 없음.
        """
        rows = (await self.session.execute(text("""
            SELECT
                sf.factory_id,
                s.supplier_id,
                s.company_name,
                sf.region,
                sf.address,
                ST_AsGeoJSON(sf.location) AS coordinates
            FROM supplier_factories sf
            JOIN suppliers s ON sf.supplier_id = s.supplier_id
            WHERE sf.is_active = TRUE
        """))).mappings().all()

        out: List[Dict[str, Any]] = []
        for r in rows:
            if resolve_xinjiang_region(r["region"]) or resolve_xinjiang_region(r["address"]):
                out.append({
                    "factory_id": r["factory_id"],
                    "supplier_id": r["supplier_id"],
                    "company_name": r["company_name"],
                    "coordinates": r["coordinates"],
                })
        return out

    # [BYPASS:A2] 시연용 4개국 바운딩박스 — 미정의 국가는 ELSE TRUE 통과. 운영 전환 시 국가 폴리곤 테이블 필요
    @trace_tool("coordinate_authenticity")
    async def check_coordinate_authenticity(self, db: AsyncSession) -> List[Dict]:
        """
        공장 좌표(location)가 신고된 국가(country)의 폴리곤 경계 안에 위치하는지 대조.
        실제 운영 환경에서는 국가별 다각형(MultiPolygon) 테이블과 JOIN하지만,
        현재 시연을 위해 CTE로 주요 국가의 바운딩 박스(ST_MakeEnvelope)를 임시 구성하여 검증합니다.
        """
        query = text("""
            WITH mock_country_boundaries AS (
                -- 시연용 주요 국가 바운딩 박스 (BBOX - MinX, MinY, MaxX, MaxY)
                -- 중국(CN), 베트남(VN), 한국(KR), 미국(US)
                SELECT 'CN' AS country_code, ST_MakeEnvelope(73.0, 18.0, 135.0, 53.0, 4326) AS geom UNION ALL
                SELECT 'VN' AS country_code, ST_MakeEnvelope(102.0, 8.0, 109.0, 23.0, 4326) AS geom UNION ALL
                SELECT 'KR' AS country_code, ST_MakeEnvelope(124.0, 33.0, 132.0, 39.0, 4326) AS geom UNION ALL
                SELECT 'US' AS country_code, ST_MakeEnvelope(-125.0, 24.0, -66.0, 49.0, 4326) AS geom
            )
            SELECT
                sf.factory_id,
                s.supplier_id,
                s.company_name,
                ST_AsGeoJSON(sf.location) AS coordinates,
                sf.country,
                CASE
                    -- 경계 데이터가 정의된 국가라면 내부에 있는지 ST_Within으로 판정
                    WHEN mb.geom IS NOT NULL THEN ST_Within(sf.location, mb.geom)
                    -- 경계 데이터가 없는 국가는 시나리오 진행을 위해 임시로 True 처리
                    ELSE TRUE
                END AS country_match
            FROM supplier_factories sf
            JOIN suppliers s ON sf.supplier_id = s.supplier_id
            LEFT JOIN mock_country_boundaries mb ON sf.country = mb.country_code
            WHERE sf.is_active = TRUE 
              AND sf.location IS NOT NULL;
        """)
        # session은 의존성 주입된 self.session 사용. 인자 db는 상위 서비스 호출 호환을 위해 유지합니다.
        result = await self.session.execute(query)
        return [dict(row._mapping) for row in result]

    # -------------------------------------------------------------------------
    # 10.2a: 제품 공급망 맵 조회
    # -------------------------------------------------------------------------

    @trace_tool("supply_chain_map_by_product")
    async def get_supply_chain_map(
        self,
        product_id: str,
        tenant_id: str,
        bom_version_id: str | None = None,
        period_from: str | None = None,
        period_to: str | None = None,
        factory_id: str | None = None,
        po_number: str | None = None,
    ) -> Dict[str, Any]:
        """
        제품 공급망 맵 조회 (10.2a).
        products.tenant_id → bom_versions → supply_chain_map 경로로 tenant 격리.
        반환: supply_chain_map / supply_chain_ratios / suppliers / supplier_factories
        """
        filters = [
            "bv.product_id = :product_id",
            "pr.tenant_id = :tenant_id",
        ]
        params: Dict[str, Any] = {"product_id": product_id, "tenant_id": tenant_id}

        if bom_version_id:
            filters.append("bv.bom_version_id = :bom_version_id")
            params["bom_version_id"] = bom_version_id
        if po_number:
            filters.append("scm.po_number = :po_number")
            params["po_number"] = po_number
        if period_from:
            filters.append("scm.supply_period_from >= :period_from")
            params["period_from"] = period_from
        if period_to:
            filters.append("scm.supply_period_to <= :period_to")
            params["period_to"] = period_to
        if factory_id:
            filters.append("EXISTS (SELECT 1 FROM supply_ratio sr2 WHERE sr2.edge_id = scm.edge_id AND sr2.factory_id = :factory_id)")
            params["factory_id"] = factory_id

        where = " AND ".join(filters)

        # 맵 노드 — 대표 factory_id는 첫 번째 supply_ratio에서 가져옴
        map_query = text(f"""
            SELECT DISTINCT
                scm.edge_id AS map_id,
                scm.part_id,
                scm.child_supplier_id  AS supplier_id,
                scm.parent_supplier_id,  -- [FIX] 프론트 트리가 part_id만으로 자식을 묶어 다중공장 교차조인되던 버그 수정용 — 진짜 부모 협력사 ID
                (
                    SELECT sr.factory_id FROM supply_ratio sr
                    WHERE sr.edge_id = scm.edge_id
                    ORDER BY sr.ratio_percentage DESC NULLS LAST
                    LIMIT 1
                )                      AS factory_id,
                p.tier_level,
                scm.hop_level,
                p.part_name,
                p.part_code,
                scm.link_status,
                scm.verification_status,
                scm.supply_period_from,
                scm.supply_period_to,
                scm.created_at,
                -- 제품별 핵심광물: 엣지 override 우선, 없으면 child 협력사 회사값으로 폴백
                COALESCE(scm.core_minerals, cs.core_minerals) AS core_minerals
            FROM supply_chain_map scm
            JOIN bom_versions bv ON bv.bom_version_id = scm.bom_version_id
            JOIN products pr     ON pr.product_id = bv.product_id
            LEFT JOIN parts p     ON p.part_id = scm.part_id
            LEFT JOIN suppliers cs ON cs.supplier_id = scm.child_supplier_id
            WHERE {where}
            ORDER BY p.tier_level NULLS LAST, scm.edge_id
        """)
        map_rows = await self.session.execute(map_query, params)
        supply_chain_map = [dict(r._mapping) for r in map_rows]

        # 누적 기여도 트리 (루트→공장 경로 ratio 곱). 구조 필터(product/tenant/bom_version)만 적용 —
        # period/po/factory 같은 행 단위 필터는 누적곱 경로를 끊으므로 여기선 제외(맵 배열엔 적용됨).
        contributions = await self.get_supply_chain_contributions(
            product_id=product_id,
            tenant_id=tenant_id,
            bom_version_id=bom_version_id,
        )

        # 비율 테이블 — 기존 계약({part_id, supplier_id, ratio_percent}) 유지 + 누적곱/매핑키 덧붙임.
        # ratio_percent 가 실제로 있는(supply_ratio 존재) 엣지만 포함(기존 INNER JOIN 의미 보존).
        supply_chain_ratios = [
            {
                "part_id":                 c["part_id"],
                "supplier_id":             c["supplier_id"],
                "ratio_percent":           c["ratio_percent"],
                "map_id":                  c["map_id"],
                "factory_id":              c["factory_id"],
                "cumulative_contribution": c["cumulative_contribution"],
            }
            for c in contributions
            if c["ratio_percent"] is not None
        ]

        # 계층별 합 100% 검증 (엣지별 공장합 / 공급사별 묶음합)
        validation = await self.get_supply_chain_validation(
            product_id=product_id,
            tenant_id=tenant_id,
            bom_version_id=bom_version_id,
        )

        # 공급사 브리프 — 맵에 등장하는 고유 supplier_id
        supplier_ids = list({str(r["supplier_id"]) for r in supply_chain_map if r["supplier_id"]})
        suppliers: List[Dict[str, Any]] = []
        if supplier_ids:
            # 내부용 tenant_id는 응답에서 제외 — 프론트 불필요 필드.
            # (suppliers는 이미 tenant 격리된 supply_chain_map에 등장하는 노드로 한정됨)
            sup_query = text("""
                SELECT
                    s.supplier_id, s.company_name, s.provider_type, s.status, s.risk_level,
                    s.completeness_score
                FROM suppliers s
                WHERE s.supplier_id = ANY(:ids)
            """)
            sup_rows = await self.session.execute(sup_query, {"ids": supplier_ids})
            suppliers = [dict(r._mapping) for r in sup_rows]

        # 공장 — 맵에 등장하는 협력사의 공장을 supplier_id 기준으로 전부 반환한다.
        #   (기존: supply_ratio에 연결된 factory_id만 → ratio-공장 연결이 없으면 공장/국가/원산지가
        #    프론트에서 통째로 비었음. 협력사가 입력한 공장 정보는 ratio 유무와 무관하게 내려줘야 한다.)
        supplier_factories: List[Dict[str, Any]] = []
        if supplier_ids:
            fac_query = text("""
                SELECT
                    sf.factory_id, sf.supplier_id, sf.factory_name, sf.address,
                    sf.country, sf.region, sf.factory_role,
                    ST_Y(sf.location) AS latitude,
                    ST_X(sf.location) AS longitude,
                    sf.is_active
                FROM supplier_factories sf
                WHERE sf.supplier_id = ANY(:ids)
            """)
            fac_rows = await self.session.execute(fac_query, {"ids": supplier_ids})
            supplier_factories = [dict(r._mapping) for r in fac_rows]

        return {
            "supply_chain_map": supply_chain_map,
            "supply_chain_ratios": supply_chain_ratios,
            "supply_chain_contributions": contributions,
            "validation": validation,
            "suppliers": suppliers,
            "supplier_factories": supplier_factories,
        }

    @trace_tool("supply_chain_map_confirm")
    async def confirm_map(
        self,
        map_id: str,
        tenant_id: str,
    ) -> Dict[str, Any] | None:
        """
        10.2b: supply_chain_map.link_status → supplychain_confirmed.
        products.tenant_id 경로로 tenant 격리 — 타 테넌트면 None 반환(→404).
        """
        query = text("""
            UPDATE supply_chain_map scm
            SET link_status = 'supplychain_confirmed'
            FROM bom_versions bv
            JOIN products pr ON pr.product_id = bv.product_id
            WHERE scm.bom_version_id = bv.bom_version_id
              AND scm.edge_id = :map_id
              AND pr.tenant_id = :tenant_id
            RETURNING scm.edge_id AS map_id, scm.link_status AS status
        """)
        result = await self.session.execute(query, {"map_id": map_id, "tenant_id": tenant_id})
        await self.session.flush()
        row = result.first()
        if row is None:
            return None
        return {"map_id": str(row[0]), "status": row[1]}

    @trace_tool("supply_chain_pool_confirm")
    async def confirm_pool(
        self,
        map_id: str,
        tenant_id: str,
        supplier_ids: Optional[List[str]] = None,
    ) -> Dict[str, Any]:
        """Tier-1 풀 확정: 이 맵(map_id)의 hop_level=1 엣지 link_status → confirmed.

        풀 = 맵 그 자체(별도 저장소 없음). '확정'은 그 맵에 속한 Tier-1 엣지의 상태전이다.
        supplier_ids 가 오면 그 협력사들만, 없으면 맵의 모든 Tier-1 엣지를 확정한다.
        엣지↔맵은 실제 1:1 키인 bom_version_id 로 묶고, products.tenant_id 로 격리한다.
        반환: {map_id, confirmed_count, confirmed_suppliers[]}.
        """
        params: Dict[str, Any] = {"map_id": map_id, "tenant_id": tenant_id}
        filter_sql = ""
        if supplier_ids:
            placeholders = ", ".join(f":sid{i}" for i in range(len(supplier_ids)))
            filter_sql = f" AND scm.child_supplier_id IN ({placeholders})"
            for i, sid in enumerate(supplier_ids):
                params[f"sid{i}"] = sid

        query = text(f"""
            UPDATE supply_chain_map scm
               SET link_status = 'supplychain_confirmed'
            FROM supply_chain_maps m
            JOIN products pr ON pr.product_id = m.product_id
            WHERE scm.bom_version_id = m.bom_version_id
              AND m.map_id = :map_id
              AND pr.tenant_id = :tenant_id
              AND scm.hop_level = 1
              {filter_sql}
            RETURNING scm.edge_id AS edge_id, scm.child_supplier_id AS supplier_id
        """)
        result = await self.session.execute(query, params)
        rows = result.mappings().all()
        await self.session.flush()
        return {
            "map_id": map_id,
            "confirmed_count": len(rows),
            "confirmed_suppliers": [str(r["supplier_id"]) for r in rows if r["supplier_id"]],
        }

    # -------------------------------------------------------------------------
    # 10.2a 누적 기여도(곱셈 전파) + 계층별 합 100% 검증
    #   ratio_percentage 는 "직속 부모 대비 상대값" (PM 확정) → 경로상 비율의 곱이 말단 기여도.
    #   예) c=20×30%=6%, d=20×70%=14%, e=80×50%=40%, f=80×50%=40% (합 100%)
    # -------------------------------------------------------------------------

    @trace_tool("supply_chain_contributions")
    async def get_supply_chain_contributions(
        self,
        product_id: str,
        tenant_id: str,
        bom_version_id: str | None = None,
    ) -> List[Dict[str, Any]]:
        """
        재귀 CTE로 원청(parent NULL, hop0)부터 말단 공장까지 전개하며
        경로상 ratio_percentage(상대값)를 곱해 `cumulative_contribution`(말단 기여도 %)을 산출.

        - [버그 수정] 엣지의 공장 분할(supply_ratio N행)을 재귀 항 안에서 직접 LEFT JOIN 하면,
          조상 엣지가 공장 K개로 갈라진 순간 그 아래 모든 자손이 K배씩 곱으로 부풀려진다
          (예: 부모 2공장×자식 2공장 = 4행, 손자는 더 곱해짐). 공장 분할은 각 엣지의 '자기 내부'
          비율일 뿐 조상과 무관하므로, 재귀 전파는 엣지 단위 합계(edge_ratio, 보통 100)로만 하고,
          공장별 세부 breakdown은 최종 SELECT에서 한 번만 곱한다.
        - supply_ratio 가 없는 엣지는 100% 패스스루(×1.0)로 취급해 누적곱 경로가 0/NULL로 끊기지 않게 한다.
        - 순환 판정: path 키 = (child_supplier_id, part_id) 복합키(겸업 self-edge 오판 방지, 기존 트리 CTE와 동일).
        """
        bom_filter = "AND bv.bom_version_id = :bom_version_id" if bom_version_id else ""
        params: Dict[str, Any] = {"product_id": product_id, "tenant_id": tenant_id}
        if bom_version_id:
            params["bom_version_id"] = bom_version_id

        query = text(f"""
            WITH RECURSIVE edge_ratio AS (
                -- 엣지별 자기 공장 분할 합(비재귀, 보통 100) — 재귀 전파는 이 값 하나만 사용해
                -- 조상의 공장 분할이 자손 쪽으로 곱셈 중복(fan-out)되지 않게 한다.
                SELECT edge_id, SUM(ratio_percentage) AS total_ratio
                FROM supply_ratio
                GROUP BY edge_id
            ),
            sc_cum AS (
                -- 앵커: 원청 루트 엣지 (parent_supplier_id IS NULL, hop0)
                SELECT
                    scm.edge_id AS map_id, scm.bom_version_id, scm.parent_supplier_id,
                    scm.child_supplier_id, scm.part_id, scm.hop_level, scm.link_status,
                    COALESCE(er.total_ratio / 100.0, 1.0) AS cum_ratio,
                    ARRAY[scm.child_supplier_id::text || ':' || scm.part_id::text] AS path,
                    FALSE AS is_cycle
                FROM supply_chain_map scm
                JOIN bom_versions bv ON bv.bom_version_id = scm.bom_version_id
                JOIN products pr     ON pr.product_id = bv.product_id
                LEFT JOIN edge_ratio er ON er.edge_id = scm.edge_id
                WHERE bv.product_id = :product_id
                  AND pr.tenant_id = :tenant_id
                  AND scm.parent_supplier_id IS NULL
                  {bom_filter}

                UNION ALL

                -- 재귀: 부모 child = 자식 parent, 같은 bom_version, hop_level +1 연속.
                -- 공장 단위가 아니라 엣지 단위(edge_ratio)로만 곱해 fan-out을 막는다.
                SELECT
                    scm.edge_id AS map_id, scm.bom_version_id, scm.parent_supplier_id,
                    scm.child_supplier_id, scm.part_id, scm.hop_level, scm.link_status,
                    c.cum_ratio * COALESCE(er.total_ratio / 100.0, 1.0) AS cum_ratio,
                    c.path || (scm.child_supplier_id::text || ':' || scm.part_id::text),
                    (scm.child_supplier_id::text || ':' || scm.part_id::text) = ANY(c.path)
                FROM supply_chain_map scm
                JOIN sc_cum c ON scm.parent_supplier_id = c.child_supplier_id
                             AND scm.bom_version_id = c.bom_version_id
                             AND scm.hop_level = c.hop_level + 1
                LEFT JOIN edge_ratio er ON er.edge_id = scm.edge_id
                WHERE NOT c.is_cycle
            )
            SELECT
                sc.map_id,
                sc.part_id,
                sc.child_supplier_id   AS supplier_id,
                sc.parent_supplier_id,
                sr.factory_id,
                sc.hop_level,
                sc.link_status,
                sr.ratio_percentage    AS ratio_percent,
                -- 공장별 세부치: 이 엣지에 도달한 누적비(sc.cum_ratio, 이미 이 엣지 자체 총합까지 반영)를
                -- 엣지 내 공장 비중(factory 비율 ÷ 엣지 총합)으로 나눠 공장 단위로만 한 번 배분.
                ROUND(
                    (sc.cum_ratio * COALESCE(sr.ratio_percentage, 100.0)
                        / COALESCE(er.total_ratio, 100.0) * 100.0)::numeric,
                    4
                ) AS cumulative_contribution
            FROM sc_cum sc
            LEFT JOIN edge_ratio er   ON er.edge_id = sc.map_id
            LEFT JOIN supply_ratio sr ON sr.edge_id = sc.map_id
            WHERE NOT sc.is_cycle
            ORDER BY sc.hop_level, sc.map_id;
        """)
        result = await self.session.execute(query, params)
        return [dict(row._mapping) for row in result]

    @trace_tool("supply_chain_validation")
    async def get_supply_chain_validation(
        self,
        product_id: str,
        tenant_id: str,
        bom_version_id: str | None = None,
    ) -> Dict[str, Any]:
        """
        계층별 비율 합 100% 검증 (차단용 아님 — 프론트 경고 표시용).
          - edges : 엣지(map_id)별 공장 분할 ratio 합 (공장 합 100% 대상)
          - tiers : 같은 (parent_supplier_id, part_id) 묶음의 자식 엣지 비율 합 (공급사 분할 100% 대상)
        합이 100 ±0.01 을 벗어나면 ok=false.
        """
        bom_filter = "AND bv.bom_version_id = :bom_version_id" if bom_version_id else ""
        params: Dict[str, Any] = {"product_id": product_id, "tenant_id": tenant_id}
        if bom_version_id:
            params["bom_version_id"] = bom_version_id

        edge_query = text(f"""
            SELECT
                scm.edge_id AS map_id,
                SUM(sr.ratio_percentage) AS total
            FROM supply_chain_map scm
            JOIN bom_versions bv ON bv.bom_version_id = scm.bom_version_id
            JOIN products pr     ON pr.product_id = bv.product_id
            JOIN supply_ratio sr ON sr.edge_id = scm.edge_id
            WHERE bv.product_id = :product_id
              AND pr.tenant_id = :tenant_id
              {bom_filter}
            GROUP BY scm.edge_id
        """)
        edge_rows = await self.session.execute(edge_query, params)
        edges = [
            {
                "map_id": str(r._mapping["map_id"]),
                "sum": float(r._mapping["total"] or 0),
                "ok": abs(float(r._mapping["total"] or 0) - 100.0) <= 0.01,
            }
            for r in edge_rows
        ]

        tier_query = text(f"""
            SELECT
                scm.parent_supplier_id,
                scm.part_id,
                SUM(sr.ratio_percentage) AS total
            FROM supply_chain_map scm
            JOIN bom_versions bv ON bv.bom_version_id = scm.bom_version_id
            JOIN products pr     ON pr.product_id = bv.product_id
            JOIN supply_ratio sr ON sr.edge_id = scm.edge_id
            WHERE bv.product_id = :product_id
              AND pr.tenant_id = :tenant_id
              AND scm.parent_supplier_id IS NOT NULL
              {bom_filter}
            GROUP BY scm.parent_supplier_id, scm.part_id
        """)
        tier_rows = await self.session.execute(tier_query, params)
        tiers = [
            {
                "parent_supplier_id": str(r._mapping["parent_supplier_id"]),
                "part_id": str(r._mapping["part_id"]),
                "sum": float(r._mapping["total"] or 0),
                "ok": abs(float(r._mapping["total"] or 0) - 100.0) <= 0.01,
            }
            for r in tier_rows
        ]

        all_valid = all(e["ok"] for e in edges) and all(t["ok"] for t in tiers)
        return {"edges": edges, "tiers": tiers, "all_valid": all_valid}

    # [BYPASS:A3] 시연용 가상 산림훼손지(보르네오 박스 1개) — 운영 전환 시 GFW 등 실데이터 필요
    @trace_tool("check_eudr_deforestation")
    async def check_eudr_deforestation(self, db: AsyncSession) -> List[Dict[str, Any]]:
        """
        EUDR(산림 훼손) 위험지역 검사를 수행합니다.
        시연을 위해 특정 좌표계(ST_MakeEnvelope)를 가상의 위험 폴리곤으로 간주하고,
        공장 좌표가 그 내부에(ST_Within) 있는지 검사합니다.
        """
        query = text("""
            WITH eudr_risk_zone AS (
                -- 시연용 가상 산림 훼손지: 인도네시아 보르네오 섬 인근 임의 좌표 박스
                -- Longitude(X): 110.0 ~ 118.0 / Latitude(Y): -4.0 ~ 4.0
                SELECT ST_SetSRID(ST_MakeEnvelope(110.0, -4.0, 118.0, 4.0), 4326) AS geom
            )
            SELECT
                sf.factory_id,
                s.supplier_id,
                s.company_name,
                ST_AsGeoJSON(sf.location) AS coordinates,
                ST_Within(sf.location, r.geom) AS is_deforested
            FROM supplier_factories sf
            JOIN suppliers s ON sf.supplier_id = s.supplier_id
            CROSS JOIN eudr_risk_zone r
            WHERE sf.is_active = TRUE
              AND sf.location IS NOT NULL;
        """)

        result = await self.session.execute(query)
        return [dict(row._mapping) for row in result]

    async def list_map_headers(self, tenant_id: str) -> List[Dict[str, Any]]:
        """내 테넌트의 공급망 맵 헤더 목록 + 엣지 수. (맵 그 자체를 map_id로 관리)

        목록 화면이 제품 × 생산기간(BOM 버전) × 고객사 단위로 한 번에 렌더링할 수 있도록
        고객사명(customers)과 BOM 버전의 생산기간(bom_versions)을 함께 조인해 반환한다.
        (프론트가 제품×버전을 순회하며 맵을 재조회하지 않도록 목록 쿼리에서 일괄 제공.)
        """
        query = text("""
            SELECT h.map_id, h.bom_version_id, h.product_id, p.product_name, p.product_code,
                   p.customer_id, c.customer_name,
                   bv.version_number, bv.production_from, bv.production_to,
                   h.status, h.completed_at, COUNT(e.edge_id) AS edge_count
            FROM supply_chain_maps h
            JOIN products p ON p.product_id = h.product_id
            LEFT JOIN customers c ON c.customer_id = p.customer_id
            LEFT JOIN bom_versions bv ON bv.bom_version_id = h.bom_version_id
            LEFT JOIN supply_chain_map e ON e.map_id = h.map_id
            WHERE p.tenant_id = :tenant_id
            GROUP BY h.map_id, h.bom_version_id, h.product_id, p.product_name, p.product_code,
                     p.customer_id, c.customer_name,
                     bv.version_number, bv.production_from, bv.production_to,
                     h.status, h.completed_at
            ORDER BY p.product_name;
        """)
        result = await self.session.execute(query, {"tenant_id": tenant_id})
        return [dict(r._mapping) for r in result]

    async def get_map_header(self, map_id: str, tenant_id: str) -> Optional[Dict[str, Any]]:
        """맵 헤더 단건(map_id). 내 테넌트 소유만(아니면 None). 목록과 동일 필드셋(+completed_by)."""
        query = text("""
            SELECT h.map_id, h.bom_version_id, h.product_id, p.product_name, p.product_code,
                   p.customer_id, c.customer_name,
                   bv.version_number, bv.production_from, bv.production_to,
                   h.status, h.completed_by, h.completed_at,
                   COUNT(e.edge_id) AS edge_count
            FROM supply_chain_maps h
            JOIN products p ON p.product_id = h.product_id
            LEFT JOIN customers c ON c.customer_id = p.customer_id
            LEFT JOIN bom_versions bv ON bv.bom_version_id = h.bom_version_id
            LEFT JOIN supply_chain_map e ON e.map_id = h.map_id
            WHERE h.map_id = :map_id AND p.tenant_id = :tenant_id
            GROUP BY h.map_id, h.bom_version_id, h.product_id, p.product_name, p.product_code,
                     p.customer_id, c.customer_name,
                     bv.version_number, bv.production_from, bv.production_to,
                     h.status, h.completed_by, h.completed_at;
        """)
        row = (await self.session.execute(query, {"map_id": map_id, "tenant_id": tenant_id})).first()
        return dict(row._mapping) if row else None

    async def set_map_status(self, map_id: str, status: str, user_id: str, tenant_id: str) -> Optional[Dict[str, Any]]:
        """맵 완료/전송 상태 변경. 내 테넌트 소유만. flush만(커밋은 service)."""
        is_completed = status == "completed"
        query = text("""
            UPDATE supply_chain_maps h
               SET status = :status,
                   completed_by = CASE WHEN :is_completed THEN CAST(:user_id AS uuid) ELSE h.completed_by END,
                   completed_at = CASE WHEN :is_completed THEN now() ELSE h.completed_at END
            FROM products p
             WHERE h.product_id = p.product_id
               AND h.map_id = :map_id AND p.tenant_id = :tenant_id
            RETURNING h.map_id, h.status, h.completed_at;
        """)
        row = (await self.session.execute(query, {
            "map_id": map_id, "status": status, "is_completed": is_completed,
            "user_id": user_id, "tenant_id": tenant_id,
        })).first()
        await self.session.flush()
        return dict(row._mapping) if row else None

    # ── 고객사 전송용 다국어 리스크 요약 (이 맵=product+bom_version 단위) ──────
    # (구 report 도메인 risk-summary/outbound 이관 — 그 맵 하나의 협력사로 스코프)

    async def aggregate_risk_summary_for_map(self, supplier_ids: List[str]) -> Dict[str, int]:
        """
        이 공급망 맵(product+bom_version)에 속한 협력사(supplier_ids)로 한정한
        리스크 관리 요약용 raw 집계. 비율 계산/문장화는 service에서 수행.
        supplier_ids가 비어 있으면 전부 0으로 반환(집계할 협력사 없음).
        """
        if not supplier_ids:
            return {
                "supplier_total": 0, "high_risk_count": 0,
                "audited_suppliers": 0, "audit_pass": 0, "audit_decided": 0,
                "capa_total": 0, "capa_closed": 0,
                "compliance_total": 0, "compliance_passed": 0,
                "chain_total": 0, "chain_verified": 0,
            }

        sup = (await self.session.execute(text(
            """
            SELECT
                COUNT(*)                                                         AS supplier_total,
                COUNT(*) FILTER (WHERE rp.risk_level IN ('high', 'critical'))     AS high_risk_count
            FROM suppliers s
            LEFT JOIN supplier_risk_profiles rp ON rp.supplier_id = s.supplier_id
            WHERE s.supplier_id = ANY(:sids)
            """
        ), {"sids": supplier_ids})).mappings().one()

        aud = (await self.session.execute(text(
            """
            SELECT
                COUNT(DISTINCT a.supplier_id)                                    AS audited_suppliers,
                COUNT(*) FILTER (WHERE a.result IN ('pass', 'conditional_pass'))  AS audit_pass,
                COUNT(*) FILTER (WHERE a.result IN ('pass', 'conditional_pass', 'fail')) AS audit_decided
            FROM supplier_audit_records a
            WHERE a.supplier_id = ANY(:sids)
            """
        ), {"sids": supplier_ids})).mappings().one()

        capa = (await self.session.execute(text(
            """
            SELECT
                COUNT(*)                                                         AS capa_total,
                COUNT(*) FILTER (
                    WHERE lower(item->>'status')
                          IN ('closed', 'completed', 'resolved', 'verified', 'done')
                )                                                                AS capa_closed
            FROM supplier_audit_records a
            CROSS JOIN LATERAL jsonb_array_elements(
                CASE WHEN jsonb_typeof(a.corrective_actions) = 'array'
                     THEN a.corrective_actions ELSE '[]'::jsonb END
            ) AS item
            WHERE a.supplier_id = ANY(:sids)
            """
        ), {"sids": supplier_ids})).mappings().one()

        comp = (await self.session.execute(text(
            """
            SELECT
                COUNT(*)                                                         AS compliance_total,
                COUNT(*) FILTER (WHERE cr.verdict = 'compliance_passed')          AS compliance_passed
            FROM compliance_results cr
            WHERE cr.supplier_id = ANY(:sids)
            """
        ), {"sids": supplier_ids})).mappings().one()

        chain = (await self.session.execute(text(
            """
            SELECT
                COUNT(*)                                                         AS chain_total,
                COUNT(*) FILTER (WHERE scm.verification_status = 'verified')      AS chain_verified
            FROM supply_chain_map scm
            WHERE scm.child_supplier_id = ANY(:sids)
            """
        ), {"sids": supplier_ids})).mappings().one()

        return {
            "supplier_total":    int(sup["supplier_total"] or 0),
            "high_risk_count":   int(sup["high_risk_count"] or 0),
            "audited_suppliers": int(aud["audited_suppliers"] or 0),
            "audit_pass":        int(aud["audit_pass"] or 0),
            "audit_decided":     int(aud["audit_decided"] or 0),
            "capa_total":        int(capa["capa_total"] or 0),
            "capa_closed":       int(capa["capa_closed"] or 0),
            "compliance_total":  int(comp["compliance_total"] or 0),
            "compliance_passed": int(comp["compliance_passed"] or 0),
            "chain_total":       int(chain["chain_total"] or 0),
            "chain_verified":    int(chain["chain_verified"] or 0),
        }

    async def get_outbound_customer(self, customer_id: str, tenant_id: str) -> Optional[Dict[str, Any]]:
        """전송 대상 고객사 단건(국가 포함). 테넌트가 해당 고객사 제품을 보유할 때만 노출.
        타 테넌트/미보유면 None(→404, 존재 은닉)."""
        row = (await self.session.execute(text(
            """
            SELECT c.customer_id, c.customer_name, c.country
            FROM customers c
            WHERE c.customer_id = CAST(:cid AS uuid)
              AND EXISTS (
                  SELECT 1 FROM products p
                  WHERE p.customer_id = c.customer_id AND p.tenant_id = CAST(:tid AS uuid)
              )
            """
        ), {"cid": customer_id, "tid": tenant_id})).mappings().one_or_none()
        return dict(row) if row else None
