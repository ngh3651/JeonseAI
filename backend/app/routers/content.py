"""큐레이션 콘텐츠 라우터 (계약 §3.7~§3.9).

- GET /api/journey-stages          계약 여정 단계 (비회원 허용)
- GET /api/glossary                용어 목록/추천 칩 (비회원 허용)
- GET /api/glossary/lookup?q=      용어 조회 (비회원 허용, 못 찾으면 404=범위 밖)

더미 응답은 app/dummy_data.py(앱 더미 그대로 이식)에서 온다. 실데이터는 Phase E.
"""

from __future__ import annotations

from fastapi import APIRouter, HTTPException

from .. import dummy_data
from ..schemas.contract import GlossaryAnswer, GlossaryTerm, JourneyStage
from ..services import chat, journey

router = APIRouter(prefix="/api", tags=["content"])


@router.get("/journey-stages", response_model=list[JourneyStage])
async def journey_stages() -> list[JourneyStage]:
    """계약 여정 단계(정적, 모든 사용자 동일).

    날짜·진행 상태는 응답에 없다 — **일정은 기기에만 저장**하고(S-11), 어디까지 왔는지는
    앱이 그 날짜로 계산한다. 서버는 "무엇을 언제 해야 하는가"라는 단계 정의만 준다.
    """
    return journey.load_stages()


@router.get("/glossary", response_model=list[GlossaryTerm])
async def glossary() -> list[GlossaryTerm]:
    """용어 챗봇 추천 칩 목록."""
    return dummy_data.glossary_terms()


@router.get("/glossary/lookup", response_model=GlossaryAnswer)
def glossary_lookup(q: str) -> GlossaryAnswer:
    """질문 하나 → 답 하나 (계약 §3.9 · 2026-08-14 S-12).

    **항상 200이다.** 예전에는 사전에 없으면 404였고 앱이 거절 문구를 하드코딩했다.
    이제 거절도 서버가 문장으로 준다(`outOfScope=true`) — 그래야 문구를 서버가 정하고,
    LLM 답과 거절을 한 경로에서 다룰 수 있다.

    답이 어디서 오는지는 `source`에 그대로 적힌다:
      · `"검수된 용어 사전"` — data/terms.json 문장 그대로 (LLM 호출 0회)
      · 실제 모델 문자열      — Solar가 쓴 문장 (검증 통과분만)
      · `"준비된 문구"`       — 판정 요구 차단·범위 밖·LLM 실패

    ⚠ 동기(def) 핸들러다 — LLM 호출이 수 초 걸릴 수 있어 스레드풀에서 돌게 한다.
    ⚠ 404 분기는 **일부러 남겨 둔다**(아래 방어선). 질문이 비어 있는 것은 클라이언트
      오류이고, 옛 앱이 404를 '범위 밖'으로 다루던 동작과도 어긋나지 않는다.
    """
    if not (q or "").strip():
        raise HTTPException(status_code=404, detail="질문이 비어 있어요")
    reply = chat.answer(q)
    return GlossaryAnswer(
        answer=reply.answer,
        outOfScope=reply.out_of_scope,
        source=reply.source,
        termGlossary=reply.term_glossary,
        term=reply.term,
        description=reply.answer,  # 옛 앱 호환 거울 필드
    )
