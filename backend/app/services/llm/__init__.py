"""LLM provider 레지스트리 — 어떤 모델로 어떤 일을 할지 `.env`가 정한다.

```
LLM_STRUCTURE_PROVIDER=upstage   # 작업 ① OCR 텍스트 → 등기 필드 구조화
LLM_EXPLAIN_PROVIDER=upstage     # 작업 ② 판정 JSON → 설명 문장
```
둘 다 기본값은 `upstage`다(지금까지의 동작과 동일 — 리팩터가 동작을 바꾸면 안 된다).

⚠ 이 계층은 **판정을 만들지 않는다.** 자세한 근거는 `base.py` 모듈 docstring 참고.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path

from dotenv import load_dotenv

from .base import (
    CHAT_TEMPERATURE,
    EXPLAIN_TEMPERATURE,
    STRUCTURE_TEMPERATURE,
    LlmError,
    LlmProvider,
    LlmResponse,
)
from .prompts import render_layout_text
from .providers import PROVIDER_CLASSES, AxProvider, ExaoneProvider, UpstageSolarProvider

_log = logging.getLogger("jeonseai")
_BACKEND_ROOT = Path(__file__).resolve().parents[3]

DEFAULT_PROVIDER = "upstage"

#: 두 번째 경로(구조화)를 통째로 끄는 값들. 시연 직전에 크레딧·시간을 아끼고 싶을 때
#: `.env`에 `LLM_STRUCTURE_PROVIDER=off` 한 줄이면 된다(코드 수정 없이).
_OFF_VALUES = {"off", "none", "disabled", "no", "false", "0"}

#: 두 번째 경로의 호출 상한(초). IE(실측 17~26초)의 그림자 안에서 끝나야 총시간이
#: 늘지 않는다. 넘으면 조용히 폴백하고 분석은 그대로 완성된다.
STRUCTURE_TIMEOUT_SECONDS = 45.0

__all__ = [
    "CHAT_TEMPERATURE",
    "EXPLAIN_TEMPERATURE",
    "STRUCTURE_TEMPERATURE",
    "AxProvider",
    "ExaoneProvider",
    "LlmError",
    "LlmProvider",
    "LlmResponse",
    "PROVIDER_CLASSES",
    "UpstageSolarProvider",
    "all_providers",
    "available_providers",
    "chat_provider",
    "get_provider",
    "render_layout_text",
    "structure_provider",
    "explain_provider",
]


def get_provider(name: str) -> LlmProvider:
    """이름으로 provider 하나. 모르는 이름이면 기본값으로 떨어진다(분석을 막지 않는다)."""
    cls = PROVIDER_CLASSES.get((name or "").strip().lower())
    if cls is None:
        _log.info(f"[LLM] 알 수 없는 provider '{name}' → 기본값 '{DEFAULT_PROVIDER}' 사용")
        cls = PROVIDER_CLASSES[DEFAULT_PROVIDER]
    return cls()


def _from_env(env_key: str) -> LlmProvider:
    load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")
    return get_provider(os.environ.get(env_key, "") or DEFAULT_PROVIDER)


def structure_provider() -> LlmProvider | None:
    """작업 ①(구조화)을 맡을 provider — `LLM_STRUCTURE_PROVIDER`.

    `off`/`none`/`0` 등을 넣으면 **None**을 돌려준다 = 두 번째 경로를 아예 끈다.
    키가 없어도 None이다 — 호출부는 두 경우를 구분할 필요가 없다(둘 다 '없음'이다).
    """
    load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")
    raw = (os.environ.get("LLM_STRUCTURE_PROVIDER", "") or DEFAULT_PROVIDER).strip().lower()
    if raw in _OFF_VALUES:
        _log.info("[LLM] 두 번째 경로(구조화) 꺼짐 — LLM_STRUCTURE_PROVIDER=off")
        return None
    provider = get_provider(raw)
    if not provider.available:
        _log.info(f"[LLM] 두 번째 경로(구조화) 건너뜀 — {provider.name} API 키 없음")
        return None
    return provider


def explain_provider() -> LlmProvider:
    """작업 ②(설명 문장)를 맡을 provider — `LLM_EXPLAIN_PROVIDER`."""
    return _from_env("LLM_EXPLAIN_PROVIDER")


def chat_provider() -> LlmProvider:
    """작업 ③(용어 챗봇)을 맡을 provider — `LLM_CHAT_PROVIDER`.

    없으면 `LLM_EXPLAIN_PROVIDER`를 **상속**한다. 둘 다 없으면 기본값(upstage).
    상속시키는 이유: 설명 모델을 바꾸는 사람은 대개 챗봇도 같은 모델로 보고 있고,
    두 변수를 따로 관리하게 하면 한쪽만 바뀐 채로 시연에 들어간다.

    ⚠ 이 계층도 **판정을 만들지 않는다.** 챗봇 출력 스키마에는 등급·점수 필드가 없고,
      판정 요구는 LLM에 닿기 전에 `services/chat.py`의 규칙이 막는다.
    """
    load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")
    raw = (
        os.environ.get("LLM_CHAT_PROVIDER", "")
        or os.environ.get("LLM_EXPLAIN_PROVIDER", "")
        or DEFAULT_PROVIDER
    )
    return get_provider(raw)


def all_providers() -> list[LlmProvider]:
    """선언 순서대로 전부 (키 없는 것 포함) — 비교 하네스가 '건너뜀'을 보고하기 위함."""
    return [cls() for cls in PROVIDER_CLASSES.values()]


def available_providers() -> list[LlmProvider]:
    """키가 있어 실제로 부를 수 있는 provider만."""
    return [p for p in all_providers() if p.available]
