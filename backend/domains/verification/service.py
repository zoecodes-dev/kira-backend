import uuid

from backend.infrastructure.trace import trace_tool
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import text

@trace_tool("get_compliance_history_dto")
async def get_compliance_history_dto(db: AsyncSession, batch_id: uuid.UUID) -> list[dict]:
    """[조회 전용 DTO 헬퍼] HITL 등 타 도메인에서 컴플라이언스 이력을 조회할 때 사용합니다."""
    stmt = text("""
        SELECT verdict, reasoning_text, supplier_id, regulation_id
        FROM compliance_results
        WHERE batch_id = :batch_id
    """)
    result = await db.execute(stmt, {"batch_id": str(batch_id)})
    return [dict(r._mapping) for r in result.fetchall()]