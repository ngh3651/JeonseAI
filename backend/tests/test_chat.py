"""용어 챗봇 가드레일 (S-12, 2026-08-14) — **규칙이 LLM보다 먼저**임을 못 박는다.

이 파일이 지키는 것은 순서다. 판정 요구("이 집 계약해도 돼요?")를 LLM에게 거절시키면
프롬프트가 흔들릴 때마다 새 나가고, 그 사실은 **촬영 중에야** 드러난다. 그래서
차단은 정규식이 하고, 테스트는 **LLM이 불렸는지 자체를** 검사한다(답이 무엇인지가 아니라).

⚠ 실호출 금지. provider는 전부 가짜다 — 크레딧을 쓰지 않는다.
"""

from __future__ import annotations

import json

import pytest

from app.services import chat, terms, text_guard


class _FakeResponse:
    def __init__(self) -> None:
        self.elapsed = 0.2
        self.total_tokens = 100


class _FakeProvider:
    """가짜 provider — **호출 횟수를 센다.** 이 파일의 핵심 계측기다."""

    name = "fake"
    model = "fake-model-1"

    def __init__(self, payload: dict | Exception | None = None, *, available: bool = True):
        self.payload = payload if payload is not None else {"answer": "", "out_of_scope": True}
        self.available = available
        self.calls = 0

    def chat_json(self, system, user, **kwargs):  # noqa: ANN001, ANN003
        self.calls += 1
        if isinstance(self.payload, Exception):
            raise self.payload
        return self.payload, _FakeResponse()


@pytest.fixture
def fake_llm(monkeypatch):
    """provider를 가짜로 갈아 끼우고, 그 가짜를 돌려준다."""

    def _install(payload=None, *, available: bool = True) -> _FakeProvider:
        provider = _FakeProvider(payload, available=available)
        monkeypatch.setattr(chat.llm, "chat_provider", lambda: provider)
        monkeypatch.setenv("CHATBOT_LLM", "on")
        return provider

    return _install


def _answer_payload(text: str) -> dict:
    return {"answer": text, "out_of_scope": False, "terms_used": []}


# ══════════════════════════════════════════════════════════════════════════════
# L1. 판정 요구 차단 — **LLM 호출 0회**여야 한다
# ══════════════════════════════════════════════════════════════════════════════

JUDGMENT_QUESTIONS = [
    "이 집 계약해도 돼요?",
    "여기 들어가도 괜찮을까요?",
    "근저당 잡힌 집인데 안전한가요?",
]
PRICE_QUESTIONS = [
    "보증금 얼마면 적당해요?",
    "집주인한테 얼마가 적정한지 물어볼까요?",
    "전세금 좀 깎아도 될까요?",
]
TARGET_QUESTIONS = [
    "이 집 등기부 어떻게 봐요?",
    "우리 집 전세 괜찮은 편인가요?",
    "이 매물 등기부에 근저당이 있어요",
]
LEGAL_QUESTIONS = [
    "집주인 상대로 소송하면 이길까요?",
    "변호사를 선임해야 하나요?",
    "내용증명을 보내면 되나요?",
]


@pytest.mark.parametrize(
    "question",
    JUDGMENT_QUESTIONS + PRICE_QUESTIONS + TARGET_QUESTIONS + LEGAL_QUESTIONS,
)
def test_L1_판정요구는_LLM에_닿기_전에_막힌다(question, fake_llm):
    provider = fake_llm(_answer_payload("이 답이 나가면 안 된다"))

    reply = chat.answer(question)

    assert provider.calls == 0, f"판정 요구가 LLM까지 갔다: {question!r}"
    assert reply.out_of_scope is True
    assert reply.answer == chat.OUT_OF_SCOPE_ANSWER
    assert reply.source == chat.FALLBACK_SOURCE
    assert reply.layer.startswith("L1-")


def test_L1은_사전에_있는_말이_섞여_있어도_막는다(fake_llm):
    """'근저당 잡힌 이 집, 계약해도 돼요?' — 사전에도 걸리고 도메인도 통과하는 질문이다.

    L1이 뒤에 있으면 이게 그대로 새 나간다. 순서가 설계의 전부인 이유.
    """
    provider = fake_llm()

    reply = chat.answer("근저당 잡힌 이 집, 계약해도 돼요?")

    assert provider.calls == 0
    assert reply.out_of_scope is True
    assert reply.layer.startswith("L1-")


def test_조사_이가_붙은_정상_질문은_지시대상으로_오인하지_않는다(fake_llm):
    """'전세금이 집값보다 높으면?' 에는 '이 집'이 없다 — 공백만 지우면 걸린다."""
    provider = fake_llm(_answer_payload("보증금이 집값보다 높으면 돌려받기 어려울 수 있어요."))

    reply = chat.answer("전세금이 집값보다 높으면 어떻게 되나요?")

    assert reply.out_of_scope is False, "정상 질문이 L1에 걸렸다"
    assert provider.calls == 1


# ══════════════════════════════════════════════════════════════════════════════
# L2. 사전 직격 — 검수된 문장 그대로, LLM 호출 0회
# ══════════════════════════════════════════════════════════════════════════════


def test_L2_사전에_있으면_검수된_문장을_그대로_쓴다(fake_llm):
    provider = fake_llm(_answer_payload("LLM이 다시 쓴 문장"))

    reply = chat.answer("근저당권")

    assert provider.calls == 0, "검수된 문장을 LLM이 고쳐 쓰면 검수가 무의미해진다"
    assert reply.source == chat.DICTIONARY_SOURCE
    assert reply.term == "근저당권"
    assert reply.answer == next(t for t in terms.load() if t.term == "근저당권").description


# ══════════════════════════════════════════════════════════════════════════════
# L3. 도메인 게이트
# ══════════════════════════════════════════════════════════════════════════════

#: **사전에 없는** 자연어 질문 — 여기서만 LLM이 실제로 답한다(이번 작업의 합격선).
#: 사전에 있는 표기가 섞인 질문은 L2에서 끝나므로 이 목록에 두지 않는다.
IN_DOMAIN = [
    "집주인이 빚이 많으면 세입자는 어떻게 되나요?",
    "보증금을 못 돌려받으면 어떻게 해야 하나요?",
    "계약 전에 뭘 확인해야 하나요?",
    "집주인이 바뀌면 저는 어떻게 되나요?",
    "월세랑 전세는 뭐가 다른가요?",
]
OUT_OF_DOMAIN = [
    "오늘 날씨 어떤지 알려줘",
    "파이썬으로 크롤러 만드는 법 알려줘",
    "점심 메뉴 추천",
    "주식 지금 사도 될까",
    "여자친구 선물 뭐가 좋을까",
]


@pytest.mark.parametrize("question", IN_DOMAIN)
def test_L3_부동산_질문은_통과한다(question, fake_llm):
    provider = fake_llm(_answer_payload("보증금을 지키는 방법을 알려드릴게요."))

    reply = chat.answer(question)

    assert provider.calls == 1, f"도메인 질문이 LLM까지 못 갔다: {question!r}"
    assert reply.out_of_scope is False


@pytest.mark.parametrize("question", OUT_OF_DOMAIN)
def test_L3_범위_밖은_LLM을_부르지_않는다(question, fake_llm):
    provider = fake_llm(_answer_payload("무슨 답이든"))

    reply = chat.answer(question)

    assert provider.calls == 0, f"범위 밖 질문에 크레딧을 썼다: {question!r}"
    assert reply.out_of_scope is True
    assert reply.layer == "L3-범위밖"


def test_도메인_키워드는_terms_json에서_생성된다():
    """하드코딩 목록을 새로 만들면 용어가 늘어날 때 둘이 갈라진다."""
    keywords = chat.domain_keywords()

    assert "근저당권" in keywords
    assert "전세가율" in keywords
    # 검수 대기 용어도 **키워드로는** 쓴다 — 설명이 아니라 '부동산 얘기인가' 판별이라서.
    assert "대항력" in keywords
    assert "전세" in keywords  # 수동 목록


# ══════════════════════════════════════════════════════════════════════════════
# L4. 검증 — 하나라도 걸리면 답변을 **버리고** 거절로 떨어진다
# ══════════════════════════════════════════════════════════════════════════════


def test_숫자가_들어간_답변은_폐기된다(fake_llm):
    """챗봇에는 재료가 없다 — '전세가율 80%가 기준'을 지어내면 판정 계층과 충돌한다."""
    provider = fake_llm(_answer_payload("보증금이 집값의 80%를 넘으면 주의해야 해요."))

    reply = chat.answer("집주인이 빚이 많으면 세입자는 어떻게 되나요?")

    assert provider.calls == 1
    assert reply.out_of_scope is True
    assert reply.answer == chat.OUT_OF_SCOPE_ANSWER
    assert reply.source == chat.FALLBACK_SOURCE


def test_한글_수사는_허용한다():
    assert text_guard.check_chat("확인해야 할 것이 한두 가지 있어요.") is None
    assert text_guard.check_chat("보증금을 지키는 방법은 두 가지예요.") is None


def test_길이_상한을_넘으면_자르지_않고_버린다(fake_llm):
    long_answer = "보증금을 지키는 방법을 알려드릴게요. " * 20
    provider = fake_llm(_answer_payload(long_answer))

    reply = chat.answer("보증금은 어떻게 지키나요?")

    assert provider.calls == 1
    assert reply.out_of_scope is True
    assert len(reply.answer) < 200


def test_모델이_범위밖이라고_하면_answer가_있어도_버린다(fake_llm):
    provider = fake_llm(
        {"answer": "그 집은 계약해도 괜찮아 보여요", "out_of_scope": True, "terms_used": []}
    )

    reply = chat.answer("보증금 지키는 방법 알려줘")

    assert provider.calls == 1
    assert reply.answer == chat.OUT_OF_SCOPE_ANSWER


def test_금지_표현이_있으면_폐기된다(fake_llm):
    provider = fake_llm(_answer_payload("이런 경우라면 안전합니다."))

    reply = chat.answer("보증금 지키는 방법 알려줘")

    assert provider.calls == 1
    assert reply.out_of_scope is True
    assert reply.source == chat.FALLBACK_SOURCE


def test_등급_단어가_있으면_폐기된다(fake_llm):
    fake_llm(_answer_payload("이 경우는 보통 확인 필요로 봐요."))

    reply = chat.answer("보증금 지키는 방법 알려줘")

    assert reply.out_of_scope is True


def test_스키마에_없는_필드를_실어_보내면_폐기된다(fake_llm):
    """등급·점수 필드가 오면 `extra='forbid'`가 잡는다 — 리포트와 같은 경계."""
    provider = fake_llm(
        {"answer": "설명이에요.", "out_of_scope": False, "terms_used": [], "grade": "위험"}
    )

    reply = chat.answer("보증금 지키는 방법 알려줘")

    assert provider.calls == 1
    assert reply.out_of_scope is True
    assert reply.layer == "L4-스키마"


def test_호출이_실패해도_화면은_답을_받는다(fake_llm):
    from app.services.llm import LlmError

    provider = fake_llm(LlmError("타임아웃 (테스트에서 일부러 냄)"))

    reply = chat.answer("보증금 지키는 방법 알려줘")

    assert provider.calls == 1
    assert reply.answer == chat.OUT_OF_SCOPE_ANSWER
    assert reply.source == chat.FALLBACK_SOURCE


def test_API_키가_없으면_조용히_준비된_문구로_간다(fake_llm):
    provider = fake_llm(_answer_payload("나오면 안 되는 답"), available=False)

    reply = chat.answer("보증금 지키는 방법 알려줘")

    assert provider.calls == 0
    assert reply.source == chat.FALLBACK_SOURCE


def test_통과한_답변에는_실제_모델명이_라벨로_붙는다(fake_llm):
    fake_llm(_answer_payload("보증금을 지키려면 전입신고를 서둘러 하세요."))

    reply = chat.answer("보증금 지키는 방법 알려줘")

    assert reply.source == "fake-model-1", "'AI 생성'처럼 뭉뚱그리지 않는다(D26)"
    assert reply.out_of_scope is False


# ══════════════════════════════════════════════════════════════════════════════
# L5. 용어 툴팁 — 세 경로가 합류한 뒤 한 곳에서 붙는다
# ══════════════════════════════════════════════════════════════════════════════


def test_LLM_답변에도_용어_툴팁이_붙는다(fake_llm):
    fake_llm(_answer_payload("전입신고를 하면 대항력을 갖출 준비가 돼요."))

    reply = chat.answer("보증금 지키는 방법 알려줘")

    assert "전입신고" in reply.term_glossary


def test_모델이_용어를_띄어_써도_툴팁이_붙는다(fake_llm):
    """실측(2026-08-14): Solar가 `근저당 권`처럼 띄어 쓰면 예전 매칭은 조용히 빠뜨렸다.

    화면에는 어려운 말이 그대로 남고 밑줄만 없어서, 사용자는 뜻을 알 길이 없었다.
    키는 **본문에 나타난 그 형태**여야 앱이 `indexOf`로 찾는다.
    """
    fake_llm(_answer_payload("집에 근저당 권이 잡혀 있으면 순위가 밀릴 수 있어요."))

    reply = chat.answer("보증금 지키는 방법 알려줘")

    assert "근저당 권" in reply.term_glossary
    assert "근저당 권" in reply.answer, "키가 본문에 없으면 앱이 밑줄을 못 붙인다"


def test_줄바꿈을_건너뛰며_용어를_잇지_않는다():
    """문단이 갈린 곳에서 글자를 이어 붙이면 엉뚱한 자리에 밑줄이 붙는다."""
    assert "근저당권" not in terms.attach("근저당\n권리관계를 확인하세요")


def test_사전_답변에도_툴팁이_붙는다(fake_llm):
    """검수된 문장 속 어려운 말에도 밑줄이 붙는다 — 붙이는 곳이 한 군데라서 가능하다."""
    fake_llm()

    reply = chat.answer("을구")

    assert reply.layer == "L2-사전"
    assert "근저당권" in reply.term_glossary, "사전 경로에서 툴팁이 빠졌다"


# ══════════════════════════════════════════════════════════════════════════════
# 스위치 — 최악의 경우에도 '오늘 이전'으로 돌아갈 뿐
# ══════════════════════════════════════════════════════════════════════════════


def test_CHATBOT_LLM_off면_예전과_똑같이_동작한다(fake_llm, monkeypatch):
    """사전 직격은 그대로 되고, 자연어 질문은 거절된다 = 이 작업 이전의 동작."""
    provider = fake_llm(_answer_payload("나오면 안 되는 답"))
    monkeypatch.setenv("CHATBOT_LLM", "off")

    natural = chat.answer("집주인이 빚이 많으면 세입자는 어떻게 되나요?")
    dictionary = chat.answer("확정일자")

    assert provider.calls == 0, "off인데 LLM을 불렀다"
    assert natural.out_of_scope is True
    assert natural.layer == "L4-꺼짐"
    assert dictionary.out_of_scope is False
    assert dictionary.source == chat.DICTIONARY_SOURCE


# ══════════════════════════════════════════════════════════════════════════════
# 엔드포인트 — 404가 아니라 200으로 나간다
# ══════════════════════════════════════════════════════════════════════════════


@pytest.fixture
def client():
    from fastapi.testclient import TestClient

    from app.main import app

    return TestClient(app)


def test_범위_밖_질문도_200으로_나간다(client, monkeypatch):
    monkeypatch.setenv("CHATBOT_LLM", "off")

    resp = client.get("/api/glossary/lookup", params={"q": "오늘 날씨 어때?"})

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["outOfScope"] is True
    assert body["answer"] == chat.OUT_OF_SCOPE_ANSWER
    assert body["source"] == chat.FALLBACK_SOURCE
    assert body["term"] is None


def test_사전_직격은_용어명과_출처를_함께_준다(client):
    resp = client.get("/api/glossary/lookup", params={"q": "근저당권이 뭐예요?"})

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["term"] == "근저당권"
    assert body["source"] == chat.DICTIONARY_SOURCE
    assert body["outOfScope"] is False
    # 옛 앱 호환 거울 필드
    assert body["description"] == body["answer"]


def test_빈_질문은_404_그대로다(client):
    """옛 앱이 404를 '범위 밖'으로 다루던 동작과 어긋나지 않는 유일한 분기."""
    assert client.get("/api/glossary/lookup", params={"q": "  "}).status_code == 404


def test_추천_칩은_검수된_것만_나간다(client):
    resp = client.get("/api/glossary")

    assert resp.status_code == 200
    chips = {c["term"] for c in resp.json()}
    assert "근저당권" in chips
    assert "대항력" not in chips, "검수 대기 용어가 응답에 나갔다(terms-review-queue.md)"


def test_응답_스키마에_등급_점수_필드가_없다():
    """리포트와 같은 경계 — 챗봇 응답에는 판정 필드가 존재하지 않는다."""
    from app.schemas.contract import GlossaryAnswer

    forbidden = {"grade", "score", "gauge", "probability", "risk", "amount"}
    assert forbidden.isdisjoint(GlossaryAnswer.model_fields)
    assert forbidden.isdisjoint(chat.ChatAnswer.model_fields)


def test_챗봇_평가셋이_계약대로_구성돼_있다():
    """비교 하네스가 쓰는 고정 질문 10개 — 구성이 바뀌면 표가 비교 불가능해진다."""
    from pathlib import Path

    path = Path(__file__).resolve().parents[1] / "data" / "chat_eval.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    kinds = [q["kind"] for q in data["questions"]]

    assert len(kinds) == 10
    assert kinds.count("dictionary") == 3
    assert kinds.count("domain") == 4
    assert kinds.count("verdict") == 2
    assert kinds.count("off_topic") == 1
