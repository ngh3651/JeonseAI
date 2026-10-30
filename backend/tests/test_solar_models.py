"""Solar 모델 바꾸기 (2026-10-31) — 끝난 모델이면 다음 모델로, 키·한도 문제면 그대로."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from app.services.llm import solar_models
from app.services.llm import base as llm_base
from app.services.llm.providers import UpstageSolarProvider


@pytest.fixture(autouse=True)
def _reset(monkeypatch):
    monkeypatch.delenv("UPSTAGE_MODEL", raising=False)
    monkeypatch.delenv("UPSTAGE_FALLBACK_MODELS", raising=False)
    solar_models.reset_for_tests()
    yield
    solar_models.reset_for_tests()


def _resp(status: int, text: str = "", content: str = '{"ok": 1}'):
    return SimpleNamespace(
        status_code=status,
        text=text,
        json=lambda: {"choices": [{"message": {"content": content}}], "usage": {}},
    )


def _fake(statuses: dict[str, tuple[int, str]]):
    sent: list[dict] = []

    def post(url, headers=None, json=None, timeout=None, **kw):  # noqa: A002
        sent.append(json)
        status, text = statuses.get(json["model"], (200, ""))
        return _resp(status, text)

    return post, sent


def test_기본은_지금까지와_같은_모델_추론_low():
    post, sent = _fake({})
    resp, used = solar_models.post_chat({"messages": []}, api_key="k", timeout=5, post=post)
    assert resp.status_code == 200 and used == "solar-pro2"
    assert sent[0]["model"] == "solar-pro2" and sent[0]["reasoning_effort"] == "low"


def test_끝난_모델이면_pro4로_바꿔_다시_부르고_계속_쓴다():
    post, sent = _fake({"solar-pro2": (404, '{"error": {"message": "The model solar-pro2 does not exist"}}')})
    resp, used = solar_models.post_chat({"messages": []}, api_key="k", timeout=5, post=post)
    assert resp.status_code == 200 and used == "solar-pro4"
    assert [s["model"] for s in sent] == ["solar-pro2", "solar-pro4"]
    # pro4는 추론 설정을 빼서 끈 채로 부른다
    assert "reasoning_effort" not in sent[1]
    # 다음 요청부터는 처음부터 pro4 — 끝난 모델에 헛걸음하지 않는다
    sent.clear()
    solar_models.post_chat({"messages": []}, api_key="k", timeout=5, post=post)
    assert [s["model"] for s in sent] == ["solar-pro4"]
    assert solar_models.current() == "solar-pro4"


def test_400이라도_모델_이야기면_바꾼다():
    post, sent = _fake({"solar-pro2": (400, "solar-pro2 has reached end of service; please upgrade to solar-pro4")})
    _, used = solar_models.post_chat({"messages": []}, api_key="k", timeout=5, post=post)
    assert used == "solar-pro4"


@pytest.mark.parametrize("status", [401, 429, 500, 503])
def test_키_한도_서버_오류는_모델을_바꾸지_않는다(status):
    post, sent = _fake({"solar-pro2": (status, "model busy")})
    resp, used = solar_models.post_chat({"messages": []}, api_key="k", timeout=5, post=post)
    assert resp.status_code == status and used == "solar-pro2"
    assert len(sent) == 1 and solar_models.current() == "solar-pro2"


def test_400인데_모델과_무관한_말이면_그대로():
    post, sent = _fake({"solar-pro2": (400, "max_tokens is too large")})
    resp, used = solar_models.post_chat({"messages": []}, api_key="k", timeout=5, post=post)
    assert resp.status_code == 400 and used == "solar-pro2" and len(sent) == 1


def test_모두_끝났으면_마지막_응답을_그대로_돌려준다():
    post, sent = _fake({
        "solar-pro2": (404, "model not found"),
        "solar-pro4": (404, "model not found"),
    })
    resp, used = solar_models.post_chat({"messages": []}, api_key="k", timeout=5, post=post)
    assert resp.status_code == 404 and used == "solar-pro4"
    assert [s["model"] for s in sent] == ["solar-pro2", "solar-pro4"]


def test_환경변수로_순서를_정한다(monkeypatch):
    monkeypatch.setenv("UPSTAGE_MODEL", "solar-pro4")
    monkeypatch.setenv("UPSTAGE_FALLBACK_MODELS", "solar-mini4, solar-pro4")
    assert solar_models.chain() == ["solar-pro4", "solar-mini4"]


def test_provider도_바꾼_모델로_답하고_그_이름을_남긴다(monkeypatch):
    monkeypatch.setenv("UPSTAGE_API_KEY", "test-key")
    post, sent = _fake({"solar-pro2": (410, "gone")})
    monkeypatch.setattr(llm_base.requests, "post", post)
    provider = UpstageSolarProvider()
    resp = provider.chat("sys", "user", json_mode=True)
    assert resp.model == "solar-pro4" and provider.model == "solar-pro4"
    assert [s["model"] for s in sent] == ["solar-pro2", "solar-pro4"]
    # 새로 만든 provider도 바뀐 모델에서 시작한다
    assert UpstageSolarProvider().model == "solar-pro4"
