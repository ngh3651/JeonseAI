"""챗봇 (2026-10-24 대화형) — **AI가 답하되, 판정은 규칙이 막는다**를 못 박는다.

지키는 것:
- 인사·잡담·장난·"더 쉽게"도 **AI가 답한다**(예전엔 낱말 검사에서 '준비된 문구'로 막혔다).
- 판정 요구는 규칙이 먼저 알아채 **조심 모드 지시**를 붙인다 — 막지는 않는다.
- 나가는 답은 검사를 통과해야 한다: 판정 문장·근거 없는 숫자·주소·금지 표현이면 한 번 고쳐 쓰게 하고,
  그래도 안 되면 기본 문장.
- 앞 대화가 AI에 그대로 간다(최근 8개). 주민번호·전화번호 꼴은 가린다. 로그에 질문 글이 없다.

⚠ 실호출 금지. provider는 전부 가짜다 — 크레딧을 쓰지 않는다.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.services import chat, terms, text_guard, thresholds
from app.services.llm import LlmError


class _FakeResponse:
    def __init__(self, text: str = "{}") -> None:
        self.elapsed = 0.2
        self.total_tokens = 100
        self.model = "fake-model-1"
        self.text = text


class _FakeProvider:
    """가짜 provider — 받은 지시·대화를 기록하고, 정해 둔 답을 차례로 돌려준다."""

    name = "fake"
    model = "fake-model-1"

    def __init__(self, payloads, *, available: bool = True):
        self.payloads = list(payloads)
        self.available = available
        self.calls: list[dict] = []

    def chat_json(self, system, user, **kwargs):  # noqa: ANN001, ANN003
        self.calls.append({"system": system, "user": user, "history": kwargs.get("history") or []})
        p = self.payloads[min(len(self.calls) - 1, len(self.payloads) - 1)]
        if isinstance(p, Exception):
            raise p
        return p, _FakeResponse(str(p))


@pytest.fixture
def fake_llm(monkeypatch):
    def _install(*payloads, available: bool = True) -> _FakeProvider:
        provider = _FakeProvider(payloads or [{"answer": "안녕하세요!"}], available=available)
        monkeypatch.setattr(chat.llm, "chat_provider", lambda: provider)
        monkeypatch.setenv("CHATBOT_LLM", "on")
        return provider

    return _install


def _a(text: str, kind: str = "real_estate") -> dict:
    return {"answer": text, "kind": kind}


def _u(text: str) -> dict:
    return {"role": "user", "content": text}


def _b(text: str) -> dict:
    return {"role": "assistant", "content": text}


# ══════════════════════════════════════════════════════════════════════════════
# AI가 답한다 — 잡담·장난·짧은 말·사전 낱말도
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.parametrize("q", ["안녕", "ㄹ", "바보야", "집 너무 비싸 ㅜ", "더 쉬운말로 어려워", "등기부", "뭐해"])
def test_모든_말을_AI가_읽고_답한다(fake_llm, q):
    p = fake_llm(_a("안녕하세요!\n전세 이야기라면 편하게 물어보세요.", "small_talk"))
    r = chat.answer(q)
    assert len(p.calls) == 1
    assert r.mode == chat.MODE_NORMAL and r.model == "fake-model-1"
    assert "준비된 문구" not in r.answer and "용어를 쉽게 설명해 드리는 도우미" not in r.answer


def test_사전_낱말도_사전_문장을_그대로_내지_않고_AI가_푼다(fake_llm):
    p = fake_llm(_a("등기부등본은 **집의 이력서**예요."))
    r = chat.answer("등기부")
    assert r.answer == "등기부등본은 **집의 이력서**예요."
    # 검수된 풀이는 AI의 '참고 자료'로 들어간다
    desc = terms.lookup("등기부등본").description
    assert desc in p.calls[0]["system"]


def test_검수_대기_용어는_참고_자료에_넣지_않는다():
    unverified = [t for t in terms.load_all() if not t.verified]
    block = chat.glossary_block()
    for t in unverified:
        assert t.description not in block


def test_판정_기준은_코드_상수에서_읽는다():
    block = chat.criteria_block()
    assert f"{thresholds.JEONSE_RATIO_DANGER_PCT}%" in block
    assert f"{thresholds.SENIOR_DEBT_RATIO_DANGER_PCT}%" in block
    assert f"{round(thresholds.PUBLIC_PRICE_TO_HOUSE_PRICE_RATIO * 100)}%" in block


# ══════════════════════════════════════════════════════════════════════════════
# 앞 대화 — "더 쉽게"가 무엇을 쉽게인지 안다
# ══════════════════════════════════════════════════════════════════════════════


def test_앞_대화가_AI에_간다(fake_llm):
    p = fake_llm(_a("가압류는 **돈 받을 사람이 집을 잠깐 묶어 둔 것**이에요."))
    chat.reply([_u("가압류 알려줘"), _b("가압류는 채권자가 재산을 묶어 두는 절차예요."), _u("더 쉽게")])
    call = p.calls[0]
    assert call["user"] == "더 쉽게"
    assert call["history"] == [
        {"role": "user", "content": "가압류 알려줘"},
        {"role": "assistant", "content": "가압류는 채권자가 재산을 묶어 두는 절차예요."},
    ]


def test_앞_대화는_최근_8개까지_답으로_시작하지_않게(fake_llm):
    p = fake_llm(_a("네!"))
    msgs = []
    for i in range(10):
        msgs += [_u(f"질문{i}"), _b(f"답{i}")]
    msgs.append(_u("마지막"))
    chat.reply(msgs)
    hist = p.calls[0]["history"]
    assert len(hist) <= chat.MAX_TURNS - 1
    assert hist[0]["role"] == "user"


def test_주민번호_전화번호_꼴은_AI에_보내기_전에_가린다(fake_llm):
    p = fake_llm(_a("네, 알겠어요."))
    chat.reply([_u("집주인 900101-1234567 연락처 010-1234-5678 이에요")])
    sent = p.calls[0]["user"]
    assert "1234567" not in sent and "5678" not in sent
    assert "[주민번호 가림]" in sent and "[전화번호 가림]" in sent


# ══════════════════════════════════════════════════════════════════════════════
# 규칙: 판정 요구 → 조심 모드 (막지 않는다)
# ══════════════════════════════════════════════════════════════════════════════

VERDICT_QUESTIONS = [
    "이 집 계약해도 돼요?",
    "여기 들어가도 괜찮을까요?",
    "근저당 잡힌 집인데 안전한가요?",
    "보증금 얼마면 적당해요?",
    "전세금 좀 깎아도 될까요?",
    "집주인 상대로 소송하면 이길까요?",
    "이거 사기야?",
    "이 집 위험해?",
    "이 집 괜찮아?",
    "이 매물 어때요?",
]


@pytest.mark.parametrize("q", VERDICT_QUESTIONS)
def test_판정_요구는_규칙이_알아채고_조심_지시를_붙인다(fake_llm, q):
    p = fake_llm(_a("그건 제가 대신 정해 드릴 수 없어요.\n등기부의 빚을 먼저 확인해 보세요.", "verdict"))
    r = chat.answer(q)
    assert chat.verdict_request_hit(q) is not None
    assert len(p.calls) == 1  # 막지 않고 AI가 답한다
    assert "이번 질문은 판단을 요구하는 질문" in p.calls[0]["system"]
    assert r.mode == chat.MODE_CAREFUL


@pytest.mark.parametrize(
    "q",
    [
        "지금 우리집에 가압류가 3억이 걸려 있다는데 부동산에 가서 어떻게 물어보는게 좋을까",
        "이 집 등기부 어떻게 봐요?",
        "전세금이 집값보다 높으면?",
        "확정일자가 뭐예요",
        "안녕",
        "오늘 기분 어때요",
    ],
)
def test_우리_집만_들어간_정당한_질문은_보통_모드(fake_llm, q):
    p = fake_llm(_a("좋은 질문이에요."))
    r = chat.answer(q)
    assert chat.verdict_request_hit(q) is None
    assert "이번 질문은 판단을 요구하는 질문" not in p.calls[0]["system"]
    assert r.mode == chat.MODE_NORMAL


def test_사용자가_말한_숫자는_답에_써도_된다(fake_llm):
    fake_llm(_a("**3억** 가압류라면 중개사에게 언제 풀리는지 꼭 물어보세요."))
    r = chat.answer("우리집에 가압류가 3억 걸렸대요 어떻게 물어봐요")
    assert r.mode == chat.MODE_NORMAL and "3억" in r.answer


def test_판정_기준_숫자는_써도_된다(fake_llm):
    text = f"이 앱은 전세가율이 {thresholds.JEONSE_RATIO_DANGER_PCT}%를 넘으면 위험 신호로 봐요."
    fake_llm(_a(text))
    assert chat.answer("전세가율 기준이 뭐야").answer == text


# ══════════════════════════════════════════════════════════════════════════════
# 검사 → 한 번 고쳐 쓰기 → 기본 문장
# ══════════════════════════════════════════════════════════════════════════════


def test_판정_문장은_고쳐_쓰게_하고_고친_답을_낸다(fake_llm):
    p = fake_llm(_a("네, 이 집 계약해도 돼요."), _a("그건 제가 정해 드릴 수 없어요.\n등기부를 확인해 보세요."))
    r = chat.answer("이 집 계약해도 돼요?")
    assert len(p.calls) == 2
    assert "보여 줄 수 없어요" in p.calls[1]["user"]  # 이유를 알려 준다
    assert p.calls[1]["history"][-1]["role"] == "assistant"  # 방금 답을 대화에 넣는다
    assert r.answer.startswith("그건 제가 정해 드릴 수 없어요") and r.layer == "AI-고쳐씀"


def test_두_번_다_걸리면_조심_모드_기본_문장(fake_llm):
    p = fake_llm(_a("계약하셔도 될 것 같아요."))
    r = chat.answer("이 집 계약해도 돼요?")
    assert len(p.calls) == 2
    assert r.answer == chat.CAREFUL_FALLBACK and r.mode == chat.MODE_FALLBACK


def test_지어낸_숫자는_고쳐_쓰게_한다(fake_llm):
    p = fake_llm(_a("보통 전세가율 70%면 괜찮다고 해요."), _a("보통 계약 기간은 법으로 정해져 있어요."))
    r = chat.answer("전세 계약 기간이 얼마나 돼?")
    assert len(p.calls) == 2 and "'70%'" in p.calls[1]["user"]
    assert r.answer == "보통 계약 기간은 법으로 정해져 있어요."


def test_뜻을_묻는_질문이_두_번_걸리면_용어_풀이로_떨어진다(fake_llm):
    fake_llm(_a("www.example.com 을 보세요"))
    r = chat.answer("등기부등본이 뭐야?")
    assert r.mode == chat.MODE_FALLBACK
    assert r.answer == terms.lookup("등기부등본").description


def test_뜻이_아닌_질문엔_사전_풀이를_내지_않는다(fake_llm):
    """'어디서 떼요?'에 뜻 풀이가 나가면 동문서답이다 (2026-10-24 실기기)."""
    fake_llm(_a("www.example.com 을 보세요"))
    r = chat.answer("등기부등본 어디서 발급받아?")
    assert r.answer == chat.RETRY_FALLBACK


def test_공공기관_주소와_실생활_숫자는_쓸_수_있다(fake_llm):
    text = "대법원 인터넷등기소(iros.go.kr)에서 떼요.\n인터넷 열람은 700원, 발급은 1,000원이에요."
    fake_llm(_a(text))
    r = chat.answer("등기부등본 어디서 발급받아?")
    assert r.mode == chat.MODE_NORMAL and r.answer == text


def test_실생활_정보는_참고_자료로_들어간다(fake_llm):
    p = fake_llm(_a("네!"))
    chat.answer("확정일자 어디서 받아?")
    assert "인터넷등기소" in p.calls[0]["system"] and "출처:" in p.calls[0]["system"]


def test_헬스체크에_챗봇_통계(client, fake_llm):
    fake_llm(_a("www.example.com"), _a("안녕하세요!"))
    client.post("/api/chat", json={"messages": [_u("안녕")]}, headers={"X-Device-Id": "dev-test-9"})
    body = client.get("/").json()
    assert body["chat"]["repaired"] >= 1 and "주소" in body["chat"]["recentRejects"]


def test_스키마에_없는_칸은_고쳐_쓰게_한다(fake_llm):
    p = fake_llm({"answer": "괜찮아요", "grade": "GOOD"}, _a("확인할 것을 알려 드릴게요."))
    r = chat.answer("근저당이 뭐야")
    assert len(p.calls) == 2 and r.answer == "확인할 것을 알려 드릴게요."


def test_굵게_표시가_짝이_안_맞으면_뺀다(fake_llm):
    fake_llm(_a("근저당은 **빚 표시예요."))
    assert chat.answer("근저당").answer == "근저당은 빚 표시예요."


def test_마크다운_나열은_점으로(fake_llm):
    fake_llm(_a("확인할 것:\n- 갑구\n- 을구"))
    assert chat.answer("등기부 뭐 봐").answer == "확인할 것:\n· 갑구\n· 을구"


# ══════════════════════════════════════════════════════════════════════════════
# AI가 없을 때 — 화면은 산다
# ══════════════════════════════════════════════════════════════════════════════


def test_키가_없으면_용어_풀이_아니면_안내(fake_llm):
    fake_llm(available=False)
    assert chat.answer("근저당권이 뭐야").answer == terms.lookup("근저당권").description
    assert chat.answer("안녕").answer == chat.OFFLINE_FALLBACK


def test_호출_실패도_같은_자리로(fake_llm):
    fake_llm(LlmError("연결 실패"))
    r = chat.answer("안녕")
    assert r.answer == chat.OFFLINE_FALLBACK and r.mode == chat.MODE_FALLBACK


def test_비상_스위치_끄면_AI_안_부른다(fake_llm, monkeypatch):
    p = fake_llm(_a("안녕"))
    monkeypatch.setenv("CHATBOT_LLM", "off")
    r = chat.answer("이 집 계약해도 돼요?")
    assert p.calls == [] and r.answer == chat.CAREFUL_FALLBACK


# ══════════════════════════════════════════════════════════════════════════════
# 검사 그물 (text_guard.check_chat_reply)
# ══════════════════════════════════════════════════════════════════════════════

ALLOWED = text_guard.chat_allowed_numbers(["보증금 2억"], chat.criteria_numbers())


@pytest.mark.parametrize(
    "text",
    [
        "이 집 계약해도 돼요.",
        "계약하셔도 될 것 같아요.",
        "이 집은 계약하지 마세요.",
        "이 집은 사기 같아요.",
        "그 매물은 위험해요.",
        "적당한 가격이에요.",
        "안전합니다.",
        "걱정 마세요.",
        "양호한 편이에요.",
        "전세가율 70%면 괜찮아요.",
        "www.example.com 에서 떼요",
        "전세가율이 80%라 주의 기준에 해당해요.",
        "보증금이 집값의 80%를 넘었어요.",
        "이 집은 안전한 편이에요.",
        "걱정할 필요 없어요.",
    ],
)
def test_막히는_답(text):
    assert text_guard.check_chat_reply(text, allowed=ALLOWED) is not None


@pytest.mark.parametrize(
    "text",
    [
        "계약해도 되는지는 제가 정해 드릴 수 없어요.",
        "보증금 **2억**이라면 등기부의 빚을 먼저 보세요.",
        "1순위 근저당이 먼저 받아 가요.",
        "확인할 것은 세 가지예요.",
        "전세가율이 90%를 넘으면 위험 신호로 봐요.",
        "괜찮아요, 천천히 물어보세요.",
        "빚이 집값을 넘어서면 보증금을 못 돌려받을 수 있어요.",
        "보통 2년 계약이 많아요.",
        "인터넷등기소(iros.go.kr)에서 700원이면 열람할 수 있어요.",
        "이사한 날부터 14일 안에 전입신고를 해요.",
        "안녕하세요! 전세 이야기라면 편하게 물어보세요.",
    ],
)
def test_통과하는_답(text):
    assert text_guard.check_chat_reply(text, allowed=ALLOWED) is None


def test_조심_모드에서는_권유_안심도_막는다():
    assert text_guard.check_chat_reply("괜찮아요.", allowed=ALLOWED, careful=True) is not None
    assert text_guard.check_chat_reply("추천해요.", allowed=ALLOWED, careful=True) is not None


# ══════════════════════════════════════════════════════════════════════════════
# 엔드포인트
# ══════════════════════════════════════════════════════════════════════════════


@pytest.fixture
def client():
    from app.dependencies import reset_rate_limit
    from app.main import app

    reset_rate_limit()
    return TestClient(app)


def test_POST_chat_모양(client, fake_llm):
    fake_llm(_a("안녕하세요!\n**전세** 이야기라면 물어보세요.", "small_talk"))
    r = client.post("/api/chat", json={"messages": [_u("안녕")]}, headers={"X-Device-Id": "dev-test-1"})
    assert r.status_code == 200
    body = r.json()
    assert set(body) == {"answer", "mode", "model"}
    assert body["mode"] == "normal" and "**전세**" in body["answer"]


@pytest.mark.parametrize(
    "messages",
    [[_b("답만")], [_u("   ")], [_u("가" * (chat.MAX_USER_CHARS + 1))]],
)
def test_POST_chat_잘못된_요청은_400(client, fake_llm, messages):
    fake_llm()
    assert client.post("/api/chat", json={"messages": messages}).status_code == 400


def test_POST_chat_횟수_상한(client, fake_llm, monkeypatch):
    fake_llm()
    monkeypatch.setenv("RATE_LIMIT_CHAT_PER_HOUR", "2")
    h = {"X-Device-Id": "dev-test-2"}
    codes = [client.post("/api/chat", json={"messages": [_u("안녕")]}, headers=h).status_code for _ in range(3)]
    assert codes == [200, 200, 429]


def test_옛_주소는_새_엔진에_굵게_빼고(client, fake_llm):
    fake_llm(_a("근저당권은 **빚 표시**예요."))
    r = client.get("/api/glossary/lookup", params={"q": "근저당권"})
    body = r.json()
    assert r.status_code == 200
    assert body["answer"] == body["description"] == "근저당권은 빚 표시예요."
    assert body["outOfScope"] is False and body["source"] == "fake-model-1"
    assert client.get("/api/glossary/lookup", params={"q": " "}).status_code == 404


def test_로그에_질문_글이_없다(fake_llm, caplog):
    fake_llm(_a("네!"))
    with caplog.at_level("INFO", logger="jeonseai"):
        chat.answer("홍길동 집주인 이 집 계약해도 돼요")
        chat.answer("오늘 점심 메뉴 추천해줘 김영희")
    joined = "\n".join(r.getMessage() for r in caplog.records)
    assert "[챗봇" in joined
    for word in ("홍길동", "김영희", "점심"):
        assert word not in joined


# ══════════════════════════════════════════════════════════════════════════════
# 실측(2026-10-24 tools/try_chat.py) 뒤 다듬기
# ══════════════════════════════════════════════════════════════════════════════


def test_이모지는_지우고_한_줄_한_문장_빈_줄_없음():
    out = chat.tidy("안녕하세요! 😊 첫 전세라면 편하게 물어보세요. 등기부를 먼저 봐요.\n\n· 갑구 확인\n\n끝이에요.")
    assert out == "안녕하세요!\n첫 전세라면 편하게 물어보세요.\n등기부를 먼저 봐요.\n· 갑구 확인\n끝이에요."


def test_주의_기준을_위험이라고_하면_고쳐_쓰게_한다(fake_llm):
    caution = thresholds.JEONSE_RATIO_CAUTION_PCT
    danger = thresholds.JEONSE_RATIO_DANGER_PCT
    p = fake_llm(
        _a(f"보증금이 집값의 {caution}%를 넘으면 위험할 수 있어요."),
        _a(f"{caution}%를 넘으면 주의, {danger}%를 넘으면 위험 신호로 봐요."),
    )
    r = chat.answer("집 너무 비싸 ㅜ")
    assert len(p.calls) == 2 and "'주의' 기준" in p.calls[1]["user"]
    assert r.layer == "AI-고쳐씀"


# ══════════════════════════════════════════════════════════════════════════════
# 리포트를 아는 챗봇 (2026-10-26) — "왜 위험해?"엔 리포트 근거로, "계약해도 돼?"엔 판단 없이
# ══════════════════════════════════════════════════════════════════════════════


def _danger_report():
    from tests.test_clean_report import build_clean_report

    r = build_clean_report().model_copy(deep=True)
    r.grade = "위험"
    r.headline = "보증금을 돌려받지 못할 수 있어요"
    r.seniorDebtAmount = 360_000_000
    r.evidences[3].grade = "위험"
    r.evidences[3].detailText = "지금 살아 있는 빚 3억 6,000만원 · 2건 — 집값의 72%예요"
    return r


def test_리포트를_주면_AI가_리포트_내용을_받는다(fake_llm):
    p = fake_llm(_a("리포트에서는 먼저 받아 가는 빚이 3억 6,000만원이라 **위험**으로 나왔어요."))
    r = chat.reply([_u("왜 위험이야?")], report=_danger_report())
    system = p.calls[0]["system"]
    assert "이 사용자의 안전도 리포트" in system
    assert "종합 판정(규칙 엔진 결과): 위험" in system
    assert "3억 6,000만원" in system
    assert r.mode == chat.MODE_NORMAL, "리포트가 낸 등급을 전하는 건 검사를 통과한다"


def test_리포트_없이는_지금과_같다(fake_llm):
    p = fake_llm(_a("안녕하세요!", "small_talk"))
    chat.reply([_u("안녕")])
    assert "이 사용자의 안전도 리포트" not in p.calls[0]["system"]


def test_리포트에_나온_퍼센트는_쓸_수_있고_없는_퍼센트는_막힌다(fake_llm):
    fake_llm(_a("리포트에서는 빚이 집값의 72%예요."))
    assert chat.reply([_u("빚이 얼마나 돼?")], report=_danger_report()).mode == chat.MODE_NORMAL
    p = fake_llm(_a("빚이 집값의 77%예요."), _a("빚이 집값의 77%예요."))
    r = chat.reply([_u("빚이 얼마나 돼?")], report=_danger_report())
    assert r.mode == chat.MODE_FALLBACK and len(p.calls) == 2


def test_리포트에_없는_등급은_말할_수_없다(fake_llm):
    """리포트는 '위험'인데 '양호'라고 하면 걸린다 — 판정을 바꾸지 못한다."""
    p = fake_llm(_a("리포트에서는 양호로 나왔어요."), _a("리포트에서는 양호로 나왔어요."))
    report = _danger_report()
    for e in report.evidences:
        e.grade = "위험"
    r = chat.reply([_u("결과가 어때?")], report=report)
    assert r.mode == chat.MODE_FALLBACK and len(p.calls) == 2


def test_리포트가_있어도_계약해도_되냐엔_판단하지_않는다(fake_llm):
    p = fake_llm(_a("리포트가 위험이니 계약하셔도 돼요."), _a("리포트가 위험이니 계약하셔도 돼요."))
    r = chat.reply([_u("이 집 계약해도 돼?")], report=_danger_report())
    assert "조심" in p.calls[0]["system"] or "판단을 요구" in p.calls[0]["system"]
    assert r.mode == chat.MODE_FALLBACK, "계약 허락은 리포트가 있어도 막힌다"


def test_POST_chat_reportId로_내_리포트를_찾는다(client, fake_llm):
    p = fake_llm(_a("리포트에서는 보증금이 시세의 48%예요."))
    from app.services import store
    from tests.test_clean_report import build_clean_report

    h = {"X-Device-Id": "dev-test-3"}
    mine = build_clean_report()
    store.add(mine, device_id=h["X-Device-Id"])
    r = client.post("/api/chat", json={"messages": [_u("전세가율 얼마야?")], "reportId": mine.id}, headers=h)
    assert r.status_code == 200
    assert "이 사용자의 안전도 리포트" in p.calls[0]["system"]
    assert r.json()["mode"] == "normal"


def test_POST_chat_없는_reportId면_리포트_없이_답한다(client, fake_llm):
    p = fake_llm(_a("안녕하세요!", "small_talk"))
    r = client.post("/api/chat", json={"messages": [_u("안녕")], "reportId": "nope"}, headers={"X-Device-Id": "dev-test-4"})
    assert r.status_code == 200
    assert "이 사용자의 안전도 리포트" not in p.calls[0]["system"]


# ══════════════════════════════════════════════════════════════════════════════
# 맞춤형 (2026-10-30) — 앱 안내 · 계약 여정 · 매각가율 · 내 집 · 계약 일정을 알고 답한다
# 규혁: "내 계약 여정 못 읽어?"에 "개인 정보를 읽을 수 없어요"가 나왔다 → 내 정보로 바로 답해야 한다.
# ══════════════════════════════════════════════════════════════════════════════

from datetime import date, timedelta  # noqa: E402


def _house(report_id: str, *, alias: str, address: str, deposit: int, analyzed: str, pid: str | None = None):
    from tests.test_clean_report import build_clean_report

    r = build_clean_report().model_copy(deep=True)
    r.id = report_id
    r.alias = alias
    r.address = address
    r.propertyAddress = address
    r.propertyId = pid
    r.deposit = deposit
    r.analyzedAt = analyzed
    r.registryViewedAt = "2026.08.14"
    return r


def _two_houses():
    """최신순(서버 이력과 같은 순서): 두 번째로 등록한 집이 가장 최근에 분석한 집이다."""
    newer = _house("rep-b", alias="망원동 빌라", address="서울특별시 마포구 망원동 1-2 제302호",
                   deposit=150_000_000, analyzed="2026-10-28T03:00:00+00:00", pid="11111111111111")
    older = _house("rep-a", alias="성산동 아파트", address="인천광역시 남동구 구월동 3-4 제501호",
                   deposit=100_000_000, analyzed="2026-10-01T03:00:00+00:00", pid="22222222222222")
    return [newer, older]


def test_참고_자료에_앱_안내_계약_여정_매각가율이_들어간다(fake_llm):
    p = fake_llm(_a("네!"))
    chat.answer("이 앱으로 막을 수 있는 사기는 뭐야?")
    system = p.calls[0]["system"]
    assert "이 앱 안내" in system and "등기부로는 못 보는 위험" in system and "막을 수 있는 위험" in system
    assert "이체 직전 등기부 대조" in system, "여정 화면과 같은 파일의 할 일이 들어간다"
    assert "매각가율" in system and "대법원" in system


def test_내_집과_보증금을_알고_답한다(fake_llm):
    p = fake_llm(_a("2개, 1억 5,000만원, 1억원"))
    r = chat.reply([_u("내 집 몇 개고 보증금 얼마야? 숫자로만")], houses=_two_houses(), journeys=[])
    system = p.calls[0]["system"]
    assert "이 사용자 정보" in system and "내 집 2곳" in system
    assert "1억 5,000만원" in system and "망원동" in system, "주소·보증금이 들어간다(규혁 결정)"
    assert r.mode == chat.MODE_NORMAL and r.answer == "2개, 1억 5,000만원, 1억원"


def test_등록_순서는_처음_분석한_순서다(fake_llm):
    p = fake_llm(_a("네!"))
    chat.reply([_u("두 번째로 등록한 집은?")], houses=_two_houses(), journeys=[])
    system = p.calls[0]["system"]
    assert "[1번째로 등록한 집] '성산동 아파트'" in system
    assert "[2번째로 등록한 집] '망원동 빌라' (가장 최근에 분석한 집" in system


def test_같은_집은_한_곳으로_센다(fake_llm):
    p = fake_llm(_a("네!"))
    houses = _two_houses()
    again = houses[0].model_copy(update={"id": "rep-b-old", "analyzedAt": "2026-10-20T03:00:00+00:00"})
    chat.reply([_u("내 집 몇 개야")], houses=[houses[0], again, houses[1]], journeys=[])
    system = p.calls[0]["system"]
    assert "내 집 2곳" in system and "이 집 분석 2번" in system


def test_일정이_있으면_다음_단계와_할_일과_날짜를_안다(fake_llm):
    p = fake_llm(_a("내일이 잔금 날이에요."))
    today = chat.today_kst()
    journeys = [{
        "reportId": "rep-b",
        "dates": {"downPayment": (today - timedelta(days=17)).isoformat(), "contract": today.isoformat(),
                  "balance": (today + timedelta(days=1)).isoformat()},
        "doneThrough": 2,
        "selected": True,
    }]
    chat.reply([_u("나 다음에 해야 하는 주요 행동은 뭐야?")], houses=_two_houses(), journeys=journeys)
    system = p.calls[0]["system"]
    assert "계약서" in system and "오늘" in system and "내일, D-1" in system
    assert "다음은 4단계 '잔금 보내는 날'" in system
    assert "다음 단계 할 일: 이체 직전 등기부 대조" in system
    assert "다음에 등기부를 다시 떼서 대조할 때: 4단계" in system
    assert "77일 전에 뗀 서류" in system or "일 전에 뗀 서류" in system


def test_옛_앱은_일정이_안_왔다고_적는다(fake_llm):
    p = fake_llm(_a("네!"))
    chat.reply([_u("내 일정 알아?")], houses=_two_houses(), journeys=None)
    system = p.calls[0]["system"]
    assert "이번 질문에는 함께 오지 않았어요" in system
    assert "개인정보라서 볼 수 없어요'라고 말하지 마세요" in system


def test_일정이_없으면_넣는_곳을_알려_준다(fake_llm):
    p = fake_llm(_a("네!"))
    chat.reply([_u("내 일정 알아?")], houses=_two_houses(), journeys=[])
    assert "아직 넣지 않았어요 (계약 여정에서 날짜를 넣을 수 있어요)" in p.calls[0]["system"]


def test_집이_없으면_분석하라고_적는다(fake_llm):
    p = fake_llm(_a("네!"))
    chat.reply([_u("내 집 몇 개야")], houses=[], journeys=[])
    assert "내 집: 아직 없어요" in p.calls[0]["system"]


def test_잘못된_일정_칸은_그_칸만_버린다():
    parsed = chat.parse_journeys([
        {"reportId": "a", "dates": {"balance": "2026-10-31", "nope": "2026-10-01", "contract": "어제"}, "doneThrough": 3},
        {"reportId": "", "dates": {}},
        "이상한 값",
    ])
    assert parsed == [chat.JourneyIn("a", {"balance": date(2026, 10, 31)}, 3, False)]
    assert chat.parse_journeys(None) is None and chat.parse_journeys([]) == []


def test_매각가율은_매각가율을_말할_때만_쓸_수_있다(fake_llm):
    fake_llm(_a("서울 아파트 경매 매각가율은 96.3%예요."))
    assert chat.answer("서울 아파트 매각가율 얼마야?").mode == chat.MODE_NORMAL
    p = fake_llm(_a("이 집 전세가율은 96.3%예요."), _a("이 집 전세가율은 96.3%예요."))
    r = chat.answer("전세가율 알려 줘")
    assert r.mode == chat.MODE_FALLBACK and len(p.calls) == 2, "매각가율 표에 기대 다른 퍼센트를 지어내면 걸린다"


def test_실생활_정보의_퍼센트는_쓸_수_있다(fake_llm):
    fake_llm(_a("계약갱신요구권을 쓰면 보증금은 5% 이내로만 올릴 수 있어요."))
    assert chat.answer("갱신할 때 보증금 얼마나 올릴 수 있어?").mode == chat.MODE_NORMAL


def test_내_집_목록만_있으면_기준에_대_보는_말은_막힌다(fake_llm):
    """자세한 리포트 없이 집 목록만 있을 때 "90%를 넘어요"는 리포트 인용이 아니라 새 판정이다."""
    p = fake_llm(_a("말씀하신 금액이면 90%를 넘어요."), _a("말씀하신 금액이면 90%를 넘어요."))
    r = chat.reply([_u("보증금 2억 집값 2억 1천이면?")], houses=_two_houses(), journeys=[])
    assert r.mode == chat.MODE_FALLBACK and len(p.calls) == 2


def test_내_집이_낸_등급은_전할_수_있다(fake_llm):
    fake_llm(_a("리포트에서는 '망원동 빌라'가 양호로 나왔어요."))
    r = chat.reply([_u("내 집 결과 어떻게 나왔어?")], houses=_two_houses(), journeys=[])
    assert r.mode == chat.MODE_NORMAL


def test_계약_허락은_내_정보가_있어도_막힌다(fake_llm):
    p = fake_llm(_a("네, 계약하셔도 돼요."), _a("네, 계약하셔도 돼요."))
    r = chat.reply([_u("이 집 계약해도 돼?")], houses=_two_houses(), journeys=[])
    assert r.mode == chat.MODE_FALLBACK and len(p.calls) == 2


@pytest.mark.parametrize("q", ["카르마에 대해 어떻게 생각해?", "끝말잇기 단어 골라줘", "번역 좀 봐줘"])
def test_결정과_상관없는_말은_조심_모드가_아니다(q):
    assert chat.verdict_request_hit(q) is None


@pytest.mark.parametrize("q", ["이 집 어떻게 생각해?", "두 집 중에 골라줘 이 매물이랑", "이 집 좀 봐줘"])
def test_집을_가리키면_조심_모드다(q):
    assert chat.verdict_request_hit(q) is not None


def test_POST_chat_내_집과_일정을_알고_답한다(client, fake_llm):
    from app.services import store

    p = fake_llm(_a("내일이 잔금 날이에요."))
    h = {"X-Device-Id": "dev-test-5"}
    for r in reversed(_two_houses()):  # 오래된 것부터 넣는다(서버 이력은 최신순으로 나온다)
        store.add(r, device_id=h["X-Device-Id"])
    tomorrow = (chat.today_kst() + timedelta(days=1)).isoformat()
    body = {
        "messages": [_u("다음에 뭐 해야 해?")],
        "journeys": [{"reportId": "rep-b", "dates": {"balance": tomorrow}, "doneThrough": 2, "selected": True}],
    }
    r = client.post("/api/chat", json=body, headers=h)
    assert r.status_code == 200 and set(r.json()) == {"answer", "mode", "model"}
    system = p.calls[0]["system"]
    assert "내 집 2곳" in system and "잔금" in system and "내일, D-1" in system
    assert "이 사용자의 안전도 리포트" in system, "보던 리포트가 없으면 가장 최근 집의 리포트를 자세히 안다"


def test_POST_chat_옛_앱_요청도_그대로_된다(client, fake_llm):
    p = fake_llm(_a("안녕하세요!", "small_talk"))
    r = client.post("/api/chat", json={"messages": [_u("안녕")]}, headers={"X-Device-Id": "dev-test-6"})
    assert r.status_code == 200
    assert "내 집: 아직 없어요" in p.calls[0]["system"] and "이번 질문에는 함께 오지 않았어요" not in p.calls[0]["system"]


def test_POST_chat_남의_리포트_id로는_일정이_붙지_않는다(client, fake_llm):
    from app.services import store

    p = fake_llm(_a("네!"))
    store.add(_two_houses()[0], device_id="dev-test-7-other")
    body = {"messages": [_u("내 일정?")], "journeys": [{"reportId": "rep-b", "dates": {"balance": "2026-10-31"}}]}
    r = client.post("/api/chat", json=body, headers={"X-Device-Id": "dev-test-7"})
    assert r.status_code == 200
    system = p.calls[0]["system"]
    assert "망원동" not in system and "내 집: 아직 없어요" in system


def test_POST_chat_잘못된_일정_모양은_422(client, fake_llm):
    fake_llm()
    bad = {"messages": [_u("안녕")], "journeys": [{"dates": {}}]}
    assert client.post("/api/chat", json=bad, headers={"X-Device-Id": "dev-test-8"}).status_code == 422


def test_내_정보도_가린_사본만_AI에_간다(client, fake_llm):
    """서버의 가린 사본(홍○○)으로 만든다 — 설명용 LLM 입력에 실명이 없다(CLAUDE.md §2-5)."""
    from app.services import store

    p = fake_llm(_a("네!"))
    r = _two_houses()[0]
    r.personNames = ["홍길동"]
    r.headline = "홍길동 소유 집이에요"
    store.add(r, device_id="dev-test-9")
    client.post("/api/chat", json={"messages": [_u("내 집 알려 줘")], "journeys": []}, headers={"X-Device-Id": "dev-test-9"})
    system = p.calls[0]["system"]
    assert "홍길동" not in system and "홍○○" in system


def test_로그에_주소와_일정이_없다(fake_llm, caplog):
    import logging

    fake_llm(_a("네!"))
    caplog.set_level(logging.INFO, logger="jeonseai")
    chat.reply(
        [_u("다음 할 일?")],
        houses=_two_houses(),
        journeys=[{"reportId": "rep-b", "dates": {"balance": "2026-10-31"}, "doneThrough": 2}],
    )
    logged = "\n".join(rec.getMessage() for rec in caplog.records)
    assert "망원동" not in logged and "2026-10-31" not in logged and "1억" not in logged
    assert "집 2곳" in logged


def test_열람일을_잘못_읽어_미래면_며칠_전인지_말하지_않는다(fake_llm):
    p = fake_llm(_a("네!"))
    houses = _two_houses()
    future = chat.today_kst() + timedelta(days=5)
    houses[0].registryViewedAt = future.strftime("%Y.%m.%d")
    houses[1].registryViewedAt = chat.today_kst().strftime("%Y.%m.%d")
    chat.reply([_u("등기부 언제 뗐어?")], houses=houses, journeys=[])
    system = p.calls[0]["system"]
    assert "-5일" not in system and f"등기부 열람일 {future.strftime('%Y.%m.%d')} ·" in system
    assert "(오늘 뗀 서류)" in system
