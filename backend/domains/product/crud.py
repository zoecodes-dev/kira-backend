# =============================================================================
# backend/domains/product/crud.py
#
# KIRA Compliance Intelligence Platform — Product Domain DB Query Layer
#
# 역할: 실제 PostgreSQL DB를 조회하여 5계층 BOM 트리를 반환.
#
# 구현 방식:
#   1. WITH RECURSIVE CTE — parts.parent_part_id 기반 전 계층 플랫 조회
#   2. Python 내 트리 조립 — 플랫 rows → children 중첩 구조 변환
#
# 도메인 격리 원칙 (PROJECT_CORE.md 5-1):
#   - 타 도메인 import 없음.
#   - infrastructure.database는 인프라 레이어이므로 허용.
# =============================================================================

from __future__ import annotations

from typing import Any, Dict, Optional
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession


# ---------------------------------------------------------------------------
# get_bom_tree
# ---------------------------------------------------------------------------

async def get_bom_tree(
    db: AsyncSession,
    product_id: UUID,
) -> Optional[Dict[str, Any]]:
    """
    product_id에 해당하는 제품의 active BOM 버전 기준
    5계층 BOM 트리를 반환한다.

    [쿼리 전략]
    1단계 — products + bom_versions 조회
        product_id로 제품 정보와 active BOM 버전을 가져온다.
        active 버전이 없으면 None 반환.

    2단계 — WITH RECURSIVE CTE
        bom_version_id 기준으로 bom_items에 속한 루트 부품(parent_part_id IS NULL)
        을 앵커로 잡고, parent_part_id 관계를 따라 전 계층을 플랫하게 조회한다.

    3단계 — Python 트리 조립
        플랫한 rows를 part_id / parent_part_id 관계 기반으로
        children 배열 중첩 구조로 조립한다.

    [반환값]
    active BOM 버전이 존재하면 5계층 중첩 딕셔너리 반환.
    제품 또는 active BOM이 없으면 None 반환.
    """

    # ------------------------------------------------------------------
    # 1단계: 제품 정보 + active BOM 버전 조회
    # ------------------------------------------------------------------
    product_query = text("""
        SELECT
            p.product_id,
            p.product_code,
            p.product_name,
            bv.bom_version_id,
            bv.version_number,
            bv.status
        FROM products p
        JOIN bom_versions bv
            ON bv.product_id = p.product_id
        WHERE p.product_id  = :product_id
          AND bv.status     = 'active'
        LIMIT 1
    """)

    product_result = await db.execute(
        product_query,
        {"product_id": str(product_id)},
    )
    product_row = product_result.mappings().first()

    if not product_row:
        return None

    bom_version_id = product_row["bom_version_id"]

    # ------------------------------------------------------------------
    # 2단계: WITH RECURSIVE CTE — 전 계층 플랫 조회
    #
    # 앵커: bom_version에 속한 부품 중 parent_part_id IS NULL (루트)
    # 재귀: 방금 찾은 부품의 part_id = 다음 부품의 parent_part_id
    #
    # bom_items 컬럼(required_quantity, origin_country 등)은
    # parts와 JOIN하여 각 노드에 병합.
    # ------------------------------------------------------------------
    recursive_query = text("""
        WITH RECURSIVE bom_tree AS (

            -- 앵커: 루트 부품 (parent_part_id IS NULL)
            SELECT
                p.part_id,
                p.part_code,
                p.part_name,
                p.tier_level,
                p.parent_part_id,
                p.hs_code,
                p.material_type,
                p.unit_price,
                bi.required_quantity,
                bi.required_quantity_unit,
                bi.origin_country,
                bi.direct_material_cost
            FROM parts p
            JOIN bom_items bi
                ON bi.part_id          = p.part_id
               AND bi.bom_version_id   = :bom_version_id
            WHERE p.parent_part_id IS NULL

            UNION ALL

            -- 재귀: 직전 계층 부품의 자식 탐색
            SELECT
                p.part_id,
                p.part_code,
                p.part_name,
                p.tier_level,
                p.parent_part_id,
                p.hs_code,
                p.material_type,
                p.unit_price,
                bi.required_quantity,
                bi.required_quantity_unit,
                bi.origin_country,
                bi.direct_material_cost
            FROM parts p
            JOIN bom_items bi
                ON bi.part_id          = p.part_id
               AND bi.bom_version_id   = :bom_version_id
            JOIN bom_tree bt
                ON p.parent_part_id    = bt.part_id

        )
        SELECT * FROM bom_tree
        ORDER BY tier_level, part_code
    """)

    tree_result = await db.execute(
        recursive_query,
        {"bom_version_id": str(bom_version_id)},
    )
    rows = tree_result.mappings().all()

    if not rows:
        return None

    # ------------------------------------------------------------------
    # 3단계: 플랫 rows → children 중첩 트리 조립
    #
    # 전략:
    #   - 모든 row를 part_id 키의 노드 딕셔너리로 변환 (node_map)
    #   - parent_part_id가 있으면 부모 노드의 children에 append
    #   - parent_part_id가 None이면 루트 노드
    # ------------------------------------------------------------------
    node_map: Dict[str, Dict[str, Any]] = {}

    for row in rows:
        node = {
            "part_id":                str(row["part_id"]),
            "part_code":              row["part_code"],
            "part_name":              row["part_name"],
            "tier_level":             row["tier_level"],
            "parent_part_id":         str(row["parent_part_id"]) if row["parent_part_id"] else None,
            "hs_code":                row["hs_code"],
            "material_type":          row["material_type"],
            "unit_price":             float(row["unit_price"]) if row["unit_price"] is not None else None,
            "required_quantity":      float(row["required_quantity"]) if row["required_quantity"] is not None else None,
            "required_quantity_unit": row["required_quantity_unit"],
            "origin_country":         row["origin_country"],
            "direct_material_cost":   float(row["direct_material_cost"]) if row["direct_material_cost"] is not None else None,
            "children":               [],
        }
        node_map[str(row["part_id"])] = node

    # 부모-자식 연결
    root_node: Optional[Dict[str, Any]] = None

    for node in node_map.values():
        parent_id = node["parent_part_id"]
        if parent_id and parent_id in node_map:
            node_map[parent_id]["children"].append(node)
        else:
            root_node = node

    if not root_node:
        return None

    # ------------------------------------------------------------------
    # 최종 응답 조립
    # ------------------------------------------------------------------
    return {
        "product_id":   str(product_row["product_id"]),
        "product_code": product_row["product_code"],
        "product_name": product_row["product_name"],
        "bom_version":  product_row["version_number"],
        "bom_status":   product_row["status"],
        "tree":         root_node,
    }
