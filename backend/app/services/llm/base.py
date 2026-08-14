"""국내 LLM provider 공통 인터페이스 — **판정에 닿지 않는 두 가지 일**만 시킨다.

왜 provider 추상화를 두나 (2026-07-28):
지금까지 LLM은 Solar Pro 하나였고 `explanation.py`가 직접 HTTP를 불렀다. 여기에
두 번째 경로(OCR 텍스트 → 구조화)를 붙이면서, 그리고 대회 규정상 쓸 수 있는 국내 모델이
셋(Upstage Solar · LG EXAONE · SKT A.X)이라, **같은 입력으로 셋을 나란히 재려면**
호출부를 인터페이스 뒤로 밀어야 한다. 재는 것이 목적이지 갈아끼우는 것이 목적이 아니다.

⚠ **이 계층은 판정을 만들지 않는다.** 두 작업 모두 등급·점수와 통로가 없다:
  - `structure()`: OCR 텍스트 → 등기 필드. 출력 스키마에 등급·점수 필드가 **없고**
    `extra="forbid"`라 모델이 실어 보내면 검증에서 떨어진다.
    이 결과는 ⑴ 교차검증 신호 ⑵ 좌표 매칭 보조 ⑶ 설명 문장에만 쓴다.
    **판정은 IE 결과 기준을 유지한다** — 이 경로가 더 많이 찾아도 등급은 안 바뀐다.
  - `explain()`: 규칙 엔진 판정 JSON → 쉬운 문장. 기존 가드레일 그대로.

세 provider 모두 OpenAI 호환 `/chat/completions`라 공통 부모에서 HTTP를 처리하고,
각 구현체는 **엔드포인트·모델명·키 이름**만 다르게 둔다.
"""

from __future__ import annotations

import json
import logging
import os
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import requests
from dotenv import load_dotenv

_log = logging.getLogger("jeonseai")
_BACKEND_ROOT = Path(__file__).resolve().parents[3]

# 인프라 수치 (판정 임계값 아님)
REQUEST_TIMEOUT_SECONDS = 120  # 추론 모델은 사고에 시간을 쓴다 (실측 EXAONE 20~60초)
MAX_ATTEMPTS = 3  # 최초 1회 + 재시도 2회 (serverless 429 대비)
RATE_LIMIT_BACKOFF_SECONDS = 8

# 생성 파라미터 (인프라 수치 — 판정 임계값 아님).
#
# ⚠ 두 작업의 값이 **다르고, 달라야 한다.**
#   - 설명 생성 0.3 : decisions.md [2026-07-07]에 "생성 파라미터 기록"으로 남은 값이다.
#     provider 뒤로 옮기면서 조용히 0.1로 바뀌면 그건 리팩터가 아니라 사양 변경이고,
#     기록된 값과 실제 동작이 갈라진다(2026-07-28 rule-auditor 지적).
#   - 구조화 0.1   : 표를 옮겨 적는 일이라 창작이 아니다. 흔들림을 줄인다.
#
# [2026-08-05] 설명 생성 0.3 → 0.6.
#   왜 올리나: 감사에서 근거 카드 문장이 "어느 집에나 해당하는 일반론처럼 읽힌다"는
#   문제가 제기됐고, 0.3은 문장 골격을 매번 같게 만든다. 재료를 넓힌 것(§Step 1·2)과
#   짝을 이뤄야 매물마다 다른 문장이 나온다.
#   왜 올려도 되나: 이번에 `text_guard`의 **숫자 화이트리스트**가 붙었다. 온도를 올리면
#   표현은 흔들리지만 **재료에 없는 수치는 기계적으로 걸러진다** — 예전에는 이 안전망이
#   없어서 온도가 사실상 유일한 억제 장치였다.
#   왜 1.0이 아닌가: 해요체·용어 괄호 같은 형식 지시는 여전히 검증되지 않는다(감사 §C).
#   형식 준수율이 떨어지면 화면 톤이 무너지므로 중간값에서 멈춘다.
EXPLAIN_TEMPERATURE = 0.6
STRUCTURE_TEMPERATURE = 0.1

# [2026-08-14] 용어 챗봇(작업 ③) 0.3 — **설명 생성 0.6보다 낮다.**
#   왜 낮추나: 설명 생성에는 판정 JSON이라는 **재료**가 있어서, 온도를 올려도 문장이
#   재료 위에서만 흔들린다(없는 수치는 `text_guard` 숫자 화이트리스트가 잡아낸다).
#   챗봇에는 그 재료가 없다 — 사용자 문장 하나뿐이라 화이트리스트를 만들 수 없고,
#   창작 여지가 그대로 **날조 여지**가 된다. 그래서 흔들림을 먼저 줄인다.
#   왜 0.1이 아닌가: 구조화(0.1)는 표를 옮겨 적는 일이라 표현이 같아도 되지만,
#   챗봇은 사람이 읽는 말이라 매번 똑같은 문장 골격이면 기계처럼 읽힌다.
CHAT_TEMPERATURE = 0.3


class LlmError(Exception):
    """LLM 호출·검증 실패. **분석을 실패시키지 않는다** — 호출부가 폴백한다."""


@dataclass
class LlmResponse:
    """1회 호출 결과. 비교 하네스가 시간·토큰을 재려고 원본 그대로 들고 다닌다."""

    text: str
    elapsed: float
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    model: str = ""

    @property
    def total_tokens(self) -> int | None:
        if self.prompt_tokens is None and self.completion_tokens is None:
            return None
        return (self.prompt_tokens or 0) + (self.completion_tokens or 0)


class LlmProvider(ABC):
    """국내 LLM 하나. 키가 없으면 `available=False`로 **조용히 빠진다.**

    조용히 빠지는 것이 중요하다 — 키가 아직 없는 provider(SKT A.X) 때문에 분석이
    실패하면 안 되고, 키가 도착했을 때는 `.env`에 값만 넣으면 비교 대상에 자동으로
    합류해야 한다(코드 수정 없이).
    """

    #: 사람이 읽는 이름 (보고서·로그에 그대로 쓴다)
    name: str = "unknown"
    #: 기본 모델명. 환경변수로 덮을 수 있다.
    default_model: str = ""
    #: API 키를 담은 환경변수 이름
    key_env: str = ""
    #: 모델명을 덮을 환경변수 이름
    model_env: str = ""
    #: OpenAI 호환 base_url (뒤에 `/chat/completions`를 붙인다)
    base_url: str = ""
    #: **추론(reasoning) 모델 보정.** 사고 과정이 `max_tokens` 예산을 함께 쓰는 모델은
    #: 요청 토큰이 부족하면 `content`가 **빈 문자열로** 돌아온다(실측: EXAONE에
    #: max_tokens=200을 주니 사고 2,721자만 나오고 답이 비었다). 그만큼 더 얹는다.
    extra_max_tokens: int = 0

    def __init__(self) -> None:
        load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")  # 이미 설정된 환경변수는 덮지 않음
        self._key = os.environ.get(self.key_env, "").strip()
        self.model = os.environ.get(self.model_env, "").strip() or self.default_model

    @property
    def available(self) -> bool:
        """키가 있으면 True. 없으면 이 provider는 비교·호출 대상에서 빠진다."""
        return bool(self._key)

    # ── 두 가지 작업 ───────────────────────────────────────────────────────
    @abstractmethod
    def structure(self, layout_text: str, *, timeout: float | None = None):  # noqa: ANN201
        """작업 ① OCR 레이아웃 텍스트 → `RegistryExtract` (등급·점수 필드 없음)."""

    @abstractmethod
    def explain(self, verdict_json: dict, facts: dict) -> dict:
        """작업 ② 규칙 엔진 판정 JSON → 설명 슬롯 dict (검증 전 원본)."""

    # ── 저수준 호출 ────────────────────────────────────────────────────────
    def _payload(
        self, messages: list[dict], max_tokens: int, json_mode: bool, temperature: float
    ) -> dict:
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens + self.extra_max_tokens,
        }
        if json_mode:
            payload["response_format"] = {"type": "json_object"}
        return payload

    def chat(
        self,
        system: str,
        user: str,
        *,
        max_tokens: int = 3000,
        json_mode: bool = True,
        timeout: float | None = None,
        temperature: float = STRUCTURE_TEMPERATURE,
    ) -> LlmResponse:
        """1회 호출. 실패하면 `LlmError`. **429(요청 제한)만** 짧게 물러섰다 다시 시도한다.

        429를 재시도하는 이유: serverless 티어는 동시 요청을 조인다. 비교 하네스가
        provider별 3회씩 연달아 부르면 정상 동작 중에도 429가 난다 — 그것을 '모델 실패'로
        기록하면 비교표가 거짓말을 한다.
        """
        if not self.available:
            raise LlmError(f"{self.name}: API 키 없음 ({self.key_env})")
        messages = [{"role": "system", "content": system}, {"role": "user", "content": user}]

        last_error = "알 수 없음"
        for attempt in range(1, MAX_ATTEMPTS + 1):
            t0 = time.perf_counter()
            try:
                resp = requests.post(
                    f"{self.base_url}/chat/completions",
                    headers={
                        "Authorization": f"Bearer {self._key}",
                        "Content-Type": "application/json",
                    },
                    json=self._payload(messages, max_tokens, json_mode, temperature),
                    timeout=timeout or REQUEST_TIMEOUT_SECONDS,
                )
            except requests.exceptions.RequestException as e:
                raise LlmError(f"{self.name}: 연결 실패 {type(e).__name__}") from e
            elapsed = time.perf_counter() - t0

            if resp.status_code == 429 and attempt < MAX_ATTEMPTS:
                _log.info(f"[LLM:{self.name}] 429 요청 제한 → {RATE_LIMIT_BACKOFF_SECONDS}초 후 재시도")
                time.sleep(RATE_LIMIT_BACKOFF_SECONDS)
                last_error = "HTTP 429"
                continue
            if resp.status_code != 200:
                raise LlmError(f"{self.name}: HTTP {resp.status_code} — {resp.text[:200]}")

            try:
                body = resp.json()
                message = body["choices"][0]["message"]
            except (KeyError, IndexError, TypeError, ValueError) as e:
                raise LlmError(f"{self.name}: 응답 형식을 해석하지 못함") from e

            text = (message.get("content") or "").strip()
            usage = body.get("usage") or {}
            if not text:
                # 추론 모델이 사고에만 예산을 다 쓴 경우 — 원인을 정확히 남긴다.
                thought = len(message.get("reasoning_content") or message.get("reasoning") or "")
                raise LlmError(
                    f"{self.name}: 응답 본문이 비었음"
                    f" (사고 {thought}자 / 생성 토큰 {usage.get('completion_tokens')}"
                    f" — max_tokens {max_tokens + self.extra_max_tokens} 부족 의심)"
                )
            return LlmResponse(
                text=text,
                elapsed=elapsed,
                prompt_tokens=usage.get("prompt_tokens"),
                completion_tokens=usage.get("completion_tokens"),
                model=self.model,
            )
        raise LlmError(f"{self.name}: {MAX_ATTEMPTS}회 시도 실패 ({last_error})")

    def chat_json(
        self, system: str, user: str, *, max_tokens: int = 3000, timeout: float | None = None,
        temperature: float = STRUCTURE_TEMPERATURE,
    ) -> tuple[dict, LlmResponse]:
        """JSON 응답을 dict로. 코드펜스(```json)로 감싸 오는 모델도 받아낸다."""
        resp = self.chat(
            system, user, max_tokens=max_tokens, timeout=timeout, temperature=temperature
        )
        try:
            return _loads_lenient(resp.text), resp
        except ValueError as e:
            raise LlmError(f"{self.name}: JSON 파싱 실패 — {str(e)[:120]}") from e


def _loads_lenient(text: str) -> dict:
    """모델이 ```json 펜스나 앞뒤 산문을 붙여 보내도 JSON 객체를 꺼낸다.

    관대하게 파싱하는 것이 가드레일을 무르게 하지는 않는다 — **꺼낸 뒤에 pydantic이
    `extra="forbid"`로 검증**하므로, 여기서 통과해도 스키마에 없는 키가 있으면 떨어진다.
    """
    s = (text or "").strip()
    if s.startswith("```"):
        s = s.split("```")[1] if "```" in s[3:] else s[3:]
        if s.lstrip().lower().startswith("json"):
            s = s.lstrip()[4:]
    s = s.strip()
    if not s.startswith("{"):
        start, end = s.find("{"), s.rfind("}")
        if start == -1 or end <= start:
            raise ValueError("JSON 객체를 찾지 못함")
        s = s[start : end + 1]
    parsed = json.loads(s)
    if not isinstance(parsed, dict):
        raise ValueError("최상위가 객체가 아님")
    return parsed


class OpenAiCompatibleProvider(LlmProvider):
    """세 provider의 공통 몸통 — 엔드포인트·모델·키만 다르다."""

    def structure(self, layout_text: str, *, timeout: float | None = None):  # noqa: ANN201
        from .structuring import structure_registry  # 순환 import 방지로 지연 로딩

        return structure_registry(self, layout_text, timeout=timeout)

    def explain(self, verdict_json: dict, facts: dict) -> dict:
        """판정 JSON → 설명 슬롯 dict (검증 전 원본).

        ⚠ 검증(금지어·길이·`extra="forbid"`)은 **`explanation.py`가 한다.**
          가드레일을 provider 안에 두면 provider를 바꿀 때 가드레일도 같이 바뀐다.
        """
        from .prompts import EXPLAIN_SYSTEM_PROMPT

        user = "판정 JSON:\n" + json.dumps(
            {**verdict_json, **({"수치사실": facts} if facts else {})}, ensure_ascii=False
        )
        payload, resp = self.chat_json(
            EXPLAIN_SYSTEM_PROMPT, user, max_tokens=1500, temperature=EXPLAIN_TEMPERATURE
        )
        _log.info(
            f"[LLM:{self.name}] 설명 생성 {resp.elapsed:.1f}초"
            f" / 토큰 {resp.total_tokens if resp.total_tokens is not None else '미제공'}"
        )
        return payload
