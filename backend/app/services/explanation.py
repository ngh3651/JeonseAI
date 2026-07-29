"""설명 생성 — LLM은 '통역사'다 (decisions.md 2026-07-07 가드레일 구조).

2026-07-28: 실제 HTTP 호출을 `services.llm` provider 뒤로 옮겼다(**동작 변경 없는 리팩터**).
어느 모델이 문장을 만들지는 `.env`의 `LLM_EXPLAIN_PROVIDER`가 정하고(기본 `upstage`),
**가드레일(금지어·길이·`extra="forbid"`·폴백)은 이 파일에 그대로 남는다.**
가드레일을 provider 안에 두면 provider를 바꿀 때 가드레일도 같이 바뀌기 때문이다.

규칙 엔진의 판정(RuleVerdict)을 부동산 초보자용 쉬운 문장으로 옮길 뿐,
판정을 바꿀 통로가 구조적으로 존재하지 않는다:
- 입력은 RuleVerdict(판정 JSON)만 — 원본 이미지·추출 JSON 전달 금지.
- 출력 모델 `ExplanationPayload`는 extra="forbid"이며 등급·점수·금액 필드가 없다.
  LLM이 여분 키(grade 등)를 실어 보내면 검증 실패 → 폴백.
- 호출 실패·타임아웃(재시도 1회)·검증 실패·금지어 → fallback_texts로 **해당 부분만**
  치환하고 리포트는 항상 완성된다(분석 실패로 격상 금지).
- 2026-07-28 확장: **우리 코드의 버그(TypeError 등)도 같은 취급**을 받는다.
  실패 원인이 네트워크든 시그니처 오타든 사용자에게는 똑같이 "안 나온 화면"이다.
  단 코드 버그는 재시도하지 않고 `_log.error`에 traceback을 남긴다 — 폴백이 조용하면
  같은 버그를 또 못 찾는다.
- nextAction("지금 해야 할 일")은 결정적 템플릿 유지 — 행동 지시 문장이라 LLM 드리프트를
  원천 차단. 향후 LLM 생성으로 전환하려면 payload에 필드를 추가하고 검증을 붙인다.
"""

from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import dataclass
from pathlib import Path

import requests
from dotenv import load_dotenv
from pydantic import BaseModel, ConfigDict, ValidationError

from ..schemas.internal import RuleVerdict
from . import fallback_texts, llm
from .llm import LlmError
from .llm.prompts import EXPLAIN_SYSTEM_PROMPT

_log = logging.getLogger("jeonseai")
_BACKEND_ROOT = Path(__file__).resolve().parents[2]

# [decisions.md 2026-07-07 Solar Pro 연동 스펙 — 공식 쿡북(UpstageAI/cookbook) 원문 근거]
SOLAR_BASE_URL = "https://api.upstage.ai/v1/solar"  # OpenAI 호환 base_url
SOLAR_MODEL = "solar-pro2"  # 모델 교체(solar-pro3 등)는 이 상수만 변경
REASONING_EFFORT = "low"  # 문장 생성은 복잡 추론 불요 — 빠르고 저비용
REQUEST_TIMEOUT_SECONDS = 60  # 인프라 수치(판정 아님)
MAX_ATTEMPTS = 2  # 최초 1회 + 재시도 1회

# 단정 금지어 — 보수적 편향(불변 원칙 3). 검출 시 해당 필드만 폴백으로 치환.
# 2026-07-07 검증 하네스 보강: 실출력에서 "안전 범위입니다"·"문제가 없습니다"·
# "위험 요소가 없습니다"가 기존 목록을 통과한 것이 확인되어(페르소나 2인·rule-auditor 지적)
# 부분 문자열 매칭 계열로 확장. 해요체 변형도 포함.
_BANNED_PHRASES = (
    "안전합니다",
    "안전해요",
    "안전한 집",
    "안전 범위",
    "안심하셔도",
    "안심해도",
    "안심하세요",
    "문제없",       # 문제없습니다/문제없어요
    "문제 없",      # 문제 없습니다/문제 없어요
    "문제가 없",    # 문제가 없습니다/문제가 없어요
    "위험 요소가 없",
    "위험요소가 없",
    "이상이 없",
    "걱정하지 않으셔도",
    "걱정 안 하셔도",
    "걱정 마세요",
    "걱정하지 마세요",
    "확실히 안전",
    "절대 안전",
    "100% 안전",
)

# 필드 길이 상한(표시 안정용 인프라 수치) — 초과 시 해당 필드 폴백
# headline은 프롬프트 지시(40자 이내)+여유 5자 — 홈에서 3초 안에 한 줄로 읽히게(서연 리뷰)
_MAX_LEN = {"headline": 45, "easy_explanation": 240}

#: **재시도할 가치가 있는** 실패 — 호출·응답·검증 계층. 다시 부르면 될 수도 있다.
#: 이 목록 밖의 예외도 폴백은 되지만(아래 `generate` 참고) 재시도는 하지 않는다.
_EXPECTED_FAILURES = (
    requests.exceptions.RequestException,
    LlmError,
    ValueError,  # json.loads 실패 포함
    ValidationError,
)


class EvidenceExplanation(BaseModel):
    """근거 카드 1건의 설명 슬롯 — 판정 필드 없음."""

    model_config = ConfigDict(extra="forbid")
    id: str
    easy_explanation: str


class ExplanationPayload(BaseModel):
    """LLM이 채울 수 있는 필드의 전부. grade·금액·점수 필드는 존재하지 않는다.

    topRiskSummary는 2026-07-07 검증 하네스에서 결정적 템플릿으로 전환
    (페르소나 2인 지적: 홈 카드 비교 줄에서 LLM 문구가 오해 유발) — 여기 없음.
    """

    model_config = ConfigDict(extra="forbid")
    headline: str
    evidences: list[EvidenceExplanation]


@dataclass
class ExplanationResult:
    texts: dict  # fallback_texts.build()와 동일 형태 — report_builder가 그대로 소비
    source: str  # "AI 생성" | "폴백" | "AI 생성(일부 폴백)"


def _load_api_key() -> str:
    load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")  # 이미 설정된 환경변수는 덮지 않음
    return os.environ.get("UPSTAGE_API_KEY", "").strip()


def _verdict_for_prompt(verdict: RuleVerdict) -> dict:
    """LLM에 넘길 판정 요약 — RuleVerdict에서 파생한 값만 (추출 원본·이미지 없음)."""
    return {
        "종합등급": verdict.grade.value,
        "보증금_원": verdict.deposit,
        "시세_원": verdict.market_price,
        "선순위채권합계_원": verdict.senior_debt_amount,
        "문서_플래그": verdict.doc_flags,
        "근거": [
            {
                "id": e.id,
                "등급": e.grade.value,
                "상태": e.status_label,
                "판정상세": e.detail_text,
                "수치사실": e.facts,
            }
            for e in verdict.evidences
        ],
    }


# 2026-07-07 페르소나 리뷰(지수·서연) 반영해 강화: 해요체 강제·단정 금지·용어 순서·
# headline 형식·입력 시세 주의·기관 명칭·출처 없는 기준 숫자 금지.
#
# 2026-07-28: 원문을 `llm/prompts.py`로 옮기고 여기서는 **가져다 쓰기만** 한다.
# 두 벌로 두면 provider를 바꿀 때 한쪽만 고쳐져 "모델을 바꿨더니 말투가 달라졌다"가 된다.
# 이름(`_SYSTEM_PROMPT`)은 그대로 둔다 — 비교 하네스가 이 이름으로 import한다.
_SYSTEM_PROMPT = EXPLAIN_SYSTEM_PROMPT


def _call_solar(messages: list[dict], api_key: str) -> str:
    """LLM 호출 — **테스트가 이 함수를 목으로 대체한다**(가드레일 테스트의 이음매).

    2026-07-28: 실제 호출을 `services.llm` provider 뒤로 옮겼다. 이름과 시그니처는
    일부러 그대로 뒀다 — 이 함수는 "가드레일이 검증할 원본 문자열을 만들어 오는 자리"라는
    역할로 가드레일 테스트 8건에 박혀 있고, 이음매를 옮기면 그 테스트를 다시 써야 한다.
    다시 쓰는 순간 **가드레일이 실제로 무엇을 막고 있었는지가 흐려진다.**

    `api_key`는 provider가 자기 키를 직접 읽으므로 쓰이지 않는다(호환용 인자).
    """
    provider = llm.explain_provider()
    system = next((m["content"] for m in messages if m.get("role") == "system"), "")
    user = next((m["content"] for m in messages if m.get("role") == "user"), "")
    return provider.chat(
        system, user, max_tokens=1500, temperature=llm.EXPLAIN_TEMPERATURE
    ).text


def _field_ok(kind: str, text: str) -> bool:
    """금지어·길이 검사 — 실패한 필드만 폴백으로 치환된다."""
    if not text or not text.strip():
        return False
    if len(text) > _MAX_LEN[kind]:
        return False
    return not any(p in text for p in _BANNED_PHRASES)


def generate(verdict: RuleVerdict) -> ExplanationResult:
    """판정 → 설명 텍스트. **어떤 실패에도** 완성된 texts를 돌려준다(리포트 항상 완성).

    이 함수의 보증은 "예외를 빠뜨리지 않고 잘 잡았다"가 아니라 **구조**다 —
    실제 작업은 전부 `_generate_with_llm`이 하고, 여기서는 그 바깥을 통째로 감싼다.
    안쪽 어디에서 무엇이 터지든(호출·파싱·검증·우리 코드 버그·provider 생성 실패까지)
    사용자는 폴백 문구로 완성된 리포트를 받는다. 2026-07-28 실기기 500의 교훈이다.

    ⚠ 단 하나 예외: `fallback_texts.build`가 터지면 그대로 던진다. 폴백 문구조차
      만들 수 없다면 보여줄 것이 아무것도 없다 — 그건 진짜 실패다.
    """
    base = fallback_texts.build(verdict)  # 결정적 기본값 — 실패 시 이대로 나간다
    try:
        return _generate_with_llm(verdict, base)
    except Exception as e:  # noqa: BLE001 — 구조적 방어선 (위 docstring 참고)
        _log.error(
            f"[설명] ⚠ 설명 생성 경로에서 예기치 못한 예외 — 폴백 문구로 리포트 완성"
            f" ({type(e).__name__}: {str(e)[:120]})",
            exc_info=True,
        )
        return ExplanationResult(texts=base, source="폴백")


def _generate_with_llm(verdict: RuleVerdict, base: dict) -> ExplanationResult:
    """실제 생성·검증·병합. 예외를 밖으로 낼 수 있다 — `generate`가 받아낸다."""
    provider = llm.explain_provider()
    api_key = _load_api_key()  # 목 호출 호환용 인자 (실제 키는 provider가 직접 읽는다)
    if not provider.available:
        _log.info(f"[설명:{provider.name}] 호출 생략 → 폴백 문구 사용 (원인: API 키 없음)")
        return ExplanationResult(texts=base, source="폴백")

    messages = [
        {"role": "system", "content": _SYSTEM_PROMPT},
        {
            "role": "user",
            "content": "판정 JSON:\n" + json.dumps(_verdict_for_prompt(verdict), ensure_ascii=False),
        },
    ]

    _log.info(
        f"[설명:{provider.name}] 생성 호출 — 입력: 판정 {len(verdict.evidences)}건 (⚠ 크레딧 소모)"
    )
    t0 = time.perf_counter()
    payload: ExplanationPayload | None = None
    last_error = "알 수 없음"
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            content = _call_solar(messages, api_key)
            payload = ExplanationPayload.model_validate(json.loads(content))
            break
        except _EXPECTED_FAILURES as e:
            # 예상된 실패 — 호출·응답·검증. 다시 부르면 될 수도 있다.
            last_error = f"{type(e).__name__}: {str(e)[:120]}"
            if attempt < MAX_ATTEMPTS:
                _log.info(f"[설명:{provider.name}] {attempt}차 시도 실패 → 재시도 (원인: {last_error})")
        except Exception as e:  # noqa: BLE001 — 설명 생성이 분석을 죽이지 못하게 하는 마지막 방어선
            # **우리 코드의 버그다.** 리포트는 이미 완성돼 있으므로 폴백으로 내보내되,
            # 재시도는 하지 않는다(같은 코드가 같은 자리에서 또 터진다 — 크레딧만 태운다).
            #
            # ⚠ 절대 조용히 넘어가지 않는다. 2026-07-28 실기기 첫 실행에서
            #   `TypeError: _payload() takes 4 positional arguments but 5 were given`이
            #   여기까지 왔는데 잡히지 않아 **완성된 리포트를 든 채로 요청이 500으로 죽었다.**
            #   사용자에게는 네트워크 실패든 우리 버그든 똑같이 "안 나온 화면"이다.
            #   그래서 폴백은 넓게 잡고, 대신 **traceback을 로그에 남겨** 다음엔 바로 찾는다.
            last_error = f"{type(e).__name__}: {str(e)[:120]}"
            _log.error(
                f"[설명:{provider.name}] ⚠ 예기치 못한 예외 — 코드 버그 의심,"
                f" 재시도 없이 폴백 ({last_error})",
                exc_info=True,
            )
            break

    if payload is None:
        _log.info(
            f"[설명:{provider.name}] 검증 실패/타임아웃 → 폴백 문구 사용"
            f" (원인: {last_error}, {time.perf_counter() - t0:.1f}초)"
        )
        return ExplanationResult(texts=base, source="폴백")

    # ── 병합: LLM은 설명 슬롯만 채운다. 판정 필드는 여기 없다(report_builder가 verdict에서 복사).
    # next_action·top_risk_summary는 결정적 템플릿 유지 (decisions.md 2026-07-07 + 하네스 조치) ──
    texts = {
        "headline": base["headline"],
        "next_action": base["next_action"],
        "top_risk_summary": base["top_risk_summary"],
        "evidences": {eid: dict(body) for eid, body in base["evidences"].items()},
    }
    applied = 0
    dropped = 0

    if _field_ok("headline", payload.headline):
        texts["headline"] = payload.headline.strip()
        applied += 1
    else:
        dropped += 1

    by_id = {e.id: e.easy_explanation for e in payload.evidences}
    for eid in texts["evidences"]:
        candidate = by_id.get(eid)
        if candidate is not None and _field_ok("easy_explanation", candidate):
            texts["evidences"][eid]["easy_explanation"] = candidate.strip()
            applied += 1
        else:
            dropped += 1  # 누락·금지어·과길이 → 해당 카드만 폴백 유지

    elapsed = time.perf_counter() - t0
    if dropped == 0:
        source = "AI 생성"
        _log.info(f"[Solar] 응답 OK ({elapsed:.1f}초) — 설명 {applied}건 생성")
    elif applied == 0:
        source = "폴백"
        _log.info(f"[Solar] 응답 수신했으나 사용 가능 문구 0건 → 전체 폴백 ({elapsed:.1f}초)")
    else:
        source = "AI 생성(일부 폴백)"
        _log.info(
            f"[Solar] 응답 OK ({elapsed:.1f}초) — 설명 {applied}건 생성 · {dropped}건은 금지어/누락으로 폴백"
        )
    return ExplanationResult(texts=texts, source=source)
