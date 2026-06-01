# backend/agents/data_gateway.py
"""
data_gateway 노드 — 협력사가 올린 문서를 정형 데이터로 바꾸는 단계(stage_extraction).

오늘(Day1)은 LLM 호출 없는 골격이다. BatchState를 받아서 current_stage를
"stage_extraction"으로 전이시키고, extraction_result에 더미 dict를 채워 반환한다.
실제 문서 파싱(Sonnet+Vision)은 Day2에 이 안을 채운다.

이 노드가 팀에서 처음 만들어지는 LangGraph 노드 함수라, 다른 팀원(은지·영수·차윤)이
이 모양을 복사한다. 그래서 "자기 칸만 칠한다"는 원칙을 모양으로 보여주는 게 목적이다.
"""
from backend.agents.state import BatchState
from backend.infrastructure.trace import trace_node


@trace_node("data_gateway", "agent")
async def data_gateway_node(state: BatchState) -> BatchState:
    # 골격 단계: 아직 문서를 읽지 않는다. Day2에 parse_document 도구 호출로 채운다.
    # @trace_node는 인자에 db/batch_id가 없으면 기록을 자동으로 건너뛴다(에러 아님).
    # 노드는 state 하나만 받으므로 오늘은 기록이 건너뛰어지고,
    # 실제 audit_trail 기록은 Day2에 노드 안에서 부르는 @trace_tool 도구가 담당한다.

    dummy_extraction = {
        "parsed": False,            # Day2에 실제 파싱 결과로 교체
        "note": "skeleton — no LLM call yet",
    }

    # state.py가 total=False라 부분 갱신이 가능하다. 내 칸만 바꿔서 넘긴다.
    return {
        **state,
        "current_stage": "stage_extraction",
        "extraction_result": dummy_extraction,
    }