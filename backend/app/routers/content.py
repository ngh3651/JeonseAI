"""큐레이션 콘텐츠 라우터 (계약 §3.7~§3.9).

- GET /api/journey-stages          계약 여정 단계 (비회원 허용)
- GET /api/glossary                용어 목록/추천 칩 (비회원 허용)
- GET /api/glossary/lookup?q=      옛 앱용 질문 하나 → 답 하나 (2026-10-24부터 새 챗봇 엔진에 연결)
- POST /api/chat                   챗봇 — 최근 대화 → 답 (비회원 허용, 2026-10-24)
- GET /api/precedents/status       판례 창고 판례 수 · 마지막 업데이트 날짜 (2026-10-24)

더미 응답은 app/dummy_data.py(앱 더미 그대로 이식)에서 온다. 실데이터는 Phase E.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException, Request

from .. import dummy_data
from ..dependencies import checked_device_id, get_current_user, limit_chat
from ..schemas.contract import (
    ChatRequest,
    ChatResponse,
    GlossaryAnswer,
    GlossaryTerm,
    JourneyStage,
    PrecedentStatus,
)
from ..services import chat, journey, store

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


@router.post("/chat", response_model=ChatResponse)
def chat_reply(
    body: ChatRequest,
    request: Request,
    x_device_id: Optional[str] = Header(default=None, alias="X-Device-Id"),
    authorization: Optional[str] = Header(default=None, alias="Authorization"),
) -> ChatResponse:
    """챗봇 (계약 §3.21 · 2026-10-24). 최근 대화 → 답 하나. **항상 200**(AI가 못 답하면 기본 문장).

    ⚠ 동기(def) 핸들러 — Solar 호출이 수 초 걸려 스레드풀에서 돌게 한다.
    ⚠ 질문 글은 로그에 남기지 않는다(`chat.py`). 대화는 저장하지 않는다 — 앱이 매번 보낸다.
    """
    last = body.messages[-1]
    if last.role != "user" or not last.content.strip():
        raise HTTPException(status_code=400, detail="마지막 메시지가 질문이 아니에요")
    if len(last.content.strip()) > chat.MAX_USER_CHARS:
        raise HTTPException(status_code=400, detail=f"질문은 {chat.MAX_USER_CHARS}자까지 보낼 수 있어요")
    limit_chat(request, checked_device_id(x_device_id) or "no-device")
    owner = _owner(x_device_id, authorization)
    houses = _own_reports(owner)
    report = _own_report(body.reportId, owner) or (houses[0] if houses else None)
    r = chat.reply(
        [m.model_dump() for m in body.messages],
        report=report,
        houses=houses,
        journeys=body.journeys,
    )
    return ChatResponse(answer=r.answer, mode=r.mode, model=r.model)


def _owner(x_device_id: Optional[str], authorization: Optional[str]) -> Optional[str]:
    """이 요청의 주인 — 세션 오류·기기 정보 없음이면 None(내 정보 없이 답한다).

    ⚠ 옛 앱이 함께 쓰는 `legacy-device`는 주인으로 보지 않는다 — 여러 사람의 기록이 한 주인에 섞여 있다.
    """
    from .. import settings

    try:
        owner = get_current_user(x_device_id=x_device_id, authorization=authorization)
    except Exception:  # noqa: BLE001 — 주인을 몰라도 챗봇은 답한다
        return None
    return None if owner == settings.LEGACY_DEVICE_ID else owner


def _own_reports(owner: Optional[str]):
    """이 사용자의 이력(서버의 **가린 사본**, 최신순) — 챗봇의 '내 집'. 주인을 모르면 None."""
    if owner is None:
        return None
    try:
        return store.list_reports(device_id=owner)
    except Exception:  # noqa: BLE001
        return None


def _own_report(report_id: Optional[str], owner: Optional[str]):
    """이 사용자의 리포트(서버의 **가린 사본**) — 없거나 남의 것·세션 오류면 None(리포트 없이 답한다)."""
    if not report_id or owner is None:
        return None
    try:
        return store.get(report_id, device_id=owner)
    except Exception:  # noqa: BLE001 — 리포트를 못 찾아도 챗봇은 답한다
        return None


@router.get("/glossary/lookup", response_model=GlossaryAnswer)
def glossary_lookup(q: str, request: Request) -> GlossaryAnswer:
    """**옛 앱용** 질문 하나 → 답 하나 (계약 §3.9). 2026-10-24부터 새 챗봇 엔진(`chat.reply`)에 연결.

    옛 앱은 굵게 표시(`**`)를 그리지 못해 빼서 보내고, 범위 밖 유도 버튼(`outOfScope`)은 더 쓰지 않는다.
    """
    if not (q or "").strip():
        raise HTTPException(status_code=404, detail="질문이 비어 있어요")
    limit_chat(request, "legacy-lookup")
    reply = chat.answer(q[: chat.MAX_USER_CHARS])
    return GlossaryAnswer(
        answer=reply.plain,
        outOfScope=False,
        source=reply.model,
        description=reply.plain,  # 옛 앱 호환 거울 필드
    )


@router.get("/precedents/status", response_model=PrecedentStatus)
def precedents_status() -> PrecedentStatus:
    """판례 창고 상태 — 판례 화면의 "판례 데이터는 계속 추가되고 있어요 · 2026.10.24 기준".

    `updatedAt` = 자동 업데이트가 마지막으로 **성공한** 날(아직 없으면 창고를 만든 날). 모르면 null —
    앱은 null이면 날짜를 빼고 보여 준다(지어내지 않는다).
    """
    from ..services.precedent import updater

    return PrecedentStatus(**updater.public_status())
