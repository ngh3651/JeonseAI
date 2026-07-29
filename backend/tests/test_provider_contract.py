"""provider 계약 — **등록된 모든 provider를 진짜로 태운다.** HTTP만 목으로 막는다.

왜 이 파일이 생겼나 (2026-07-28):
가드레일 테스트는 `explanation._call_solar`를 목으로 바꿔치기한다. 그것이 옳다 —
그 함수는 "가드레일이 검증할 원본 문자열을 만들어 오는 자리"이고, 가드레일이 무엇을
막는지 보려면 그 자리를 우리가 쥐고 있어야 한다. 그런데 그 목이 **그 아래 계층 전체**를
같이 덮어 버렸다. `provider.chat` → `_payload` → `requests.post`가 한 번도 실행되지
않았고, 그래서 `_payload`의 인자 개수가 어긋난 채로 298건이 전부 초록이었다.
실기기 첫 실행에서 500이 났다.

이 파일의 규칙은 하나다: **목은 HTTP 경계(`requests.post`)에만 놓는다.**
그 위 계층(`chat` · `chat_json` · `_payload` · 응답 파싱 · provider별 튜닝)은
전부 진짜 코드를 태운다. 크레딧은 1원도 쓰지 않는다.

`PROVIDER_CLASSES`를 순회하므로 **새 provider를 등록하면 자동으로 이 계약에 포함된다** —
그것이 이 파일의 핵심이다(A.X처럼 키가 없어도 검사된다. 키 유무는 `available`의 문제이지
페이로드가 올바른지와는 별개다).
"""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from app.services import llm
from app.services.llm import base as llm_base
from app.services.llm.providers import PROVIDER_CLASSES

ALL_PROVIDERS = sorted(PROVIDER_CLASSES.items())
PROVIDER_IDS = [name for name, _ in ALL_PROVIDERS]


@pytest.fixture
def keyed_provider(monkeypatch):
    """provider를 만들되 `.env`와 무관하게 **항상 키가 있는 상태**로 만든다.

    키 유무로 검사가 건너뛰어지면 안 된다 — 오늘 깨진 것은 키가 있던 upstage였고,
    키가 없는 A.X도 키가 도착하는 순간 같은 경로를 탄다.
    """

    def _make(cls):
        provider = cls()
        monkeypatch.setattr(provider, "_key", "test-key", raising=False)
        assert provider.available, f"{cls.name}: 키를 넣었는데도 available=False"
        return provider

    return _make


@pytest.fixture
def captured_post(monkeypatch):
    """`requests.post`만 가로챈다. 보낸 본문을 그대로 돌려받아 검사한다."""
    sent: list[dict] = []

    def fake_post(url, headers=None, json=None, timeout=None, **kwargs):  # noqa: A002
        sent.append({"url": url, "headers": headers or {}, "body": json, "timeout": timeout})
        return SimpleNamespace(
            status_code=200,
            text="",
            json=lambda: {
                "choices": [{"message": {"content": '{"확인": "본문"}'}}],
                "usage": {"prompt_tokens": 11, "completion_tokens": 22},
            },
        )

    monkeypatch.setattr(llm_base.requests, "post", fake_post)
    return sent


# ══════════════════════════════════════════════════════════════════════════════
# 핵심 — 부모가 부르는 그대로 `_payload`가 실행되는가
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.parametrize(("name", "cls"), ALL_PROVIDERS, ids=PROVIDER_IDS)
def test_chat이_모든_provider에서_끝까지_돈다(name, cls, keyed_provider, captured_post):
    """**이 테스트가 있었으면 오늘 아침 500이 안 났다.**

    `chat()`은 내부에서 `self._payload(messages, max_tokens, json_mode, temperature)`를
    위치인자 4개로 부른다. 자식이 3개만 받으면 여기서 바로 TypeError가 난다.
    """
    provider = keyed_provider(cls)
    resp = provider.chat("시스템 문장", "사용자 문장", max_tokens=100)
    assert resp.text == '{"확인": "본문"}'
    assert len(captured_post) == 1, f"{name}: HTTP 호출이 정확히 1회여야 한다"


@pytest.mark.parametrize(("name", "cls"), ALL_PROVIDERS, ids=PROVIDER_IDS)
def test_chat_json도_끝까지_돈다(name, cls, keyed_provider, captured_post):
    provider = keyed_provider(cls)
    payload, resp = provider.chat_json("시스템", "사용자", max_tokens=100)
    assert payload == {"확인": "본문"}
    assert resp.prompt_tokens == 11 and resp.completion_tokens == 22


@pytest.mark.parametrize(("name", "cls"), ALL_PROVIDERS, ids=PROVIDER_IDS)
def test_보낸_본문이_OpenAI_호환_형태다(name, cls, keyed_provider, captured_post):
    """세 provider 모두 OpenAI 호환 `/chat/completions`라는 전제를 못 박는다."""
    provider = keyed_provider(cls)
    provider.chat("시스템", "사용자", max_tokens=100)
    sent = captured_post[0]

    assert sent["url"].endswith("/chat/completions"), f"{name}: 엔드포인트 규약 위반"
    assert sent["headers"].get("Authorization") == "Bearer test-key"
    body = sent["body"]
    assert body["model"] == provider.model, f"{name}: 모델명이 본문에 없다"
    assert [m["role"] for m in body["messages"]] == ["system", "user"]
    assert body["response_format"] == {"type": "json_object"}, f"{name}: json_mode 미반영"


@pytest.mark.parametrize(("name", "cls"), ALL_PROVIDERS, ids=PROVIDER_IDS)
def test_temperature가_전선까지_간다(name, cls, keyed_provider, captured_post):
    """오늘 어긋난 인자가 바로 이것이다 — **어긋나 있어도 값 자체는 안 보였다.**

    `_payload`가 `temperature`를 안 받으면 부르는 순간 TypeError라 티가 나지만,
    받기만 하고 본문에 안 실으면 **조용히 기본값으로 돈다.** 설명 생성 0.3은
    decisions.md 2026-07-07에 기록된 값이라, 조용히 달라지면 기록과 동작이 갈라진다.
    """
    provider = keyed_provider(cls)
    provider.chat("시스템", "사용자", max_tokens=100, temperature=llm.EXPLAIN_TEMPERATURE)
    assert captured_post[0]["body"]["temperature"] == llm.EXPLAIN_TEMPERATURE

    captured_post.clear()
    provider.chat("시스템", "사용자", max_tokens=100, temperature=llm.STRUCTURE_TEMPERATURE)
    assert captured_post[0]["body"]["temperature"] == llm.STRUCTURE_TEMPERATURE


@pytest.mark.parametrize(("name", "cls"), ALL_PROVIDERS, ids=PROVIDER_IDS)
def test_추론모델_보정이_max_tokens에_더해진다(name, cls, keyed_provider, captured_post):
    """`extra_max_tokens`는 '사고에 예산을 쓰는 모델' 보정이다(EXAONE 실측 근거).

    이 값이 본문에서 빠지면 응답 `content`가 빈 문자열로 돌아온다 — 조용한 실패다.
    """
    provider = keyed_provider(cls)
    provider.chat("시스템", "사용자", max_tokens=100)
    assert captured_post[0]["body"]["max_tokens"] == 100 + cls.extra_max_tokens


def test_provider별_고유_튜닝이_실제로_실린다(keyed_provider, captured_post):
    """provider마다 다른 것은 엔드포인트·모델·키뿐이 아니다 — 본문 튜닝도 다르다.

    이 튜닝은 전부 2026-07-28 실측에 근거한다(providers.py 주석 참고). `_payload`
    오버라이드가 통째로 사라져도 위의 공통 검사는 전부 통과하므로, 여기서 따로 못 박는다.
    """
    upstage = keyed_provider(PROVIDER_CLASSES["upstage"])
    upstage.chat("시스템", "사용자", max_tokens=100)
    assert captured_post[-1]["body"]["reasoning_effort"] == "low"

    exaone = keyed_provider(PROVIDER_CLASSES["exaone"])
    exaone.chat("시스템", "사용자", max_tokens=100)
    assert captured_post[-1]["body"]["chat_template_kwargs"] == {"enable_thinking": False}


# ══════════════════════════════════════════════════════════════════════════════
# 두 가지 작업(structure · explain)도 실제 코드로 태운다
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.parametrize(("name", "cls"), ALL_PROVIDERS, ids=PROVIDER_IDS)
def test_explain이_끝까지_돈다(name, cls, keyed_provider, monkeypatch):
    """설명 생성 경로 — 오늘 500이 난 바로 그 경로를 provider 전수로 태운다."""
    body = {
        "headline": "빚이 많아 확인이 필요해요",
        "evidences": [{"id": "senior_debt", "easy_explanation": "확인이 필요해요."}],
    }

    def fake_post(url, headers=None, json=None, timeout=None, **kwargs):  # noqa: A002
        import json as _json

        return SimpleNamespace(
            status_code=200,
            text="",
            json=lambda: {"choices": [{"message": {"content": _json.dumps(body)}}], "usage": {}},
        )

    monkeypatch.setattr(llm_base.requests, "post", fake_post)
    provider = keyed_provider(cls)
    out = provider.explain({"종합등급": "위험"}, {"보증금": 100})
    assert out == body


@pytest.mark.parametrize(("name", "cls"), ALL_PROVIDERS, ids=PROVIDER_IDS)
def test_structure가_끝까지_돈다(name, cls, keyed_provider, monkeypatch):
    """구조화 경로 — 실기기 로그의 `[LLM:upstage] 구조화 실패`가 이 자리였다.

    ⚠ 스키마에 등급·점수 필드가 없다는 것(`extra="forbid"`)은 이 테스트의 관심사가
      아니다 — `tests/test_cross_check.py`가 그 경계를 지킨다. 여기서는 **부를 수
      있는가**만 본다.
    """
    empty_registry = {
        "address": "서울특별시 서초구 서초동 123-4",
        "current_owners": [],
        "mortgages": [],
    }

    def fake_post(url, headers=None, json=None, timeout=None, **kwargs):  # noqa: A002
        import json as _json

        return SimpleNamespace(
            status_code=200,
            text="",
            json=lambda: {
                "choices": [{"message": {"content": _json.dumps(empty_registry)}}],
                "usage": {},
            },
        )

    monkeypatch.setattr(llm_base.requests, "post", fake_post)
    provider = keyed_provider(cls)
    extract = provider.structure("【을구】\n1 근저당권설정 채권최고액 금36,000,000원", timeout=5)
    assert extract is not None
    assert extract.address == "서울특별시 서초구 서초동 123-4"


# ══════════════════════════════════════════════════════════════════════════════
# 레지스트리 자체 — 새 provider가 조용히 빠지지 않게
# ══════════════════════════════════════════════════════════════════════════════


def test_등록된_provider가_전부_필수_속성을_갖는다():
    for name, cls in ALL_PROVIDERS:
        assert cls.name == name, f"PROVIDER_CLASSES 키('{name}')와 name('{cls.name}')이 다르다"
        assert cls.default_model, f"{name}: default_model 없음"
        assert cls.key_env and cls.model_env, f"{name}: 환경변수 이름 없음"
        assert cls.base_url.startswith("https://"), f"{name}: base_url이 https가 아니다"


def test_all_providers가_레지스트리_전체를_돌려준다():
    """비교 하네스가 '건너뜀'까지 보고하려면 키 없는 provider도 목록에 있어야 한다."""
    assert {p.name for p in llm.all_providers()} == set(PROVIDER_IDS)


def test_키가_없으면_부르지_않고_LlmError를_낸다(monkeypatch, captured_post):
    """키 없는 provider가 **네트워크를 건드리기 전에** 멈추는지 — A.X의 현재 상태다."""
    provider = PROVIDER_CLASSES["ax"]()
    monkeypatch.setattr(provider, "_key", "", raising=False)
    assert provider.available is False
    with pytest.raises(llm.LlmError):
        provider.chat("시스템", "사용자")
    assert captured_post == [], "키가 없는데 HTTP를 호출했다"
