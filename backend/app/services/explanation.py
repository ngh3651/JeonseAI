"""Solar Pro 설명 생성 — LLM은 '통역사'다 (decisions.md 2026-07-07 가드레일 구조).

규칙 엔진의 판정(RuleVerdict)을 부동산 초보자용 쉬운 문장으로 옮길 뿐,
판정을 바꿀 통로가 구조적으로 존재하지 않는다:
- 입력은 RuleVerdict(판정 JSON)만 — 원본 이미지·추출 JSON 전달 금지.
- 출력 모델 `ExplanationPayload`는 extra="forbid"이며 등급·점수·금액 필드가 없다.
  LLM이 여분 키(grade 등)를 실어 보내면 검증 실패 → 폴백.
- 호출 실패·타임아웃(재시도 1회)·검증 실패·금지어 → fallback_texts로 **해당 부분만**
  치환하고 리포트는 항상 완성된다(분석 실패로 격상 금지).
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
from . import fallback_texts

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
_SYSTEM_PROMPT = """당신은 전세 위험 분석 앱의 '통역사'입니다. 규칙 엔진이 내린 판정 결과(JSON)를 부동산 지식이 없는 사회초년생이 이해할 수 있는 쉬운 한국어로 풀어쓰는 것이 유일한 역할입니다.

반드시 지킬 것:
1. 판정(등급·수치)을 바꾸거나 새로 만들지 마세요. 주어진 판정을 설명만 합니다.
2. 모든 문장은 반드시 "~해요/~하세요"로 끝내세요. "~합니다", "~입니다"로 끝나는 문장 금지. (예: "문의해야 합니다"(X) → "물어봐 주세요"(O))
3. 단정 표현 금지: "안전합니다", "안전 범위", "문제가 없습니다", "위험 요소가 없습니다", "걱정 마세요" 전부 금지. 등급이 '양호'인 항목도 "~는 보이지 않았어요"라고 쓰고, 사용자가 직접 확인할 행동 한 가지로 문장을 끝내세요. (예: "계약 직전 최신 등기부로 다시 확인하세요")
4. 전문용어(선순위 채권, 근저당, 채권최고액, 권리 관계, 신탁등기, 압류 등)는 쉬운 말을 먼저 쓰고 괄호 안에 용어를 넣으세요. 예: "나보다 먼저 돈을 받아갈 빚(선순위 채권)".
5. headline은 단어 나열이 아니라 완성된 한 문장으로 쓰세요. "종합등급", "양호", "위험", "확인 필요" 같은 등급 단어를 headline에 넣지 마세요 — 등급은 화면에 따로 크게 표시돼요.
6. 시세는 사용자가 직접 입력한 값이에요. 반드시 "입력하신 시세"라고 부르고, 시세가 정확한지 직접 확인이 필요하다는 안내를 지우지 마세요.
7. 기관은 정식 명칭으로 쓰고 HUG는 처음 나올 때 풀어주세요: "HUG(주택도시보증공사) 안심전세포털", "HUG 등 보증기관".
8. 판정 JSON에 없는 기준 숫자를 새로 언급하지 마세요.
9. 각 설명은 1~2문장, 판정에 담긴 실제 수치(금액·비율·건수)를 자연스럽게 녹여 쓰세요.

다음 JSON 형식으로만 응답하세요 (다른 텍스트 금지):
{"headline": "리포트 맨 위 결론 한 문장(40자 이내)", "evidences": [{"id": "근거 id 그대로", "easy_explanation": "그 근거 카드의 쉬운 설명(2문장 이내)"}]}
evidences에는 입력의 근거 id를 전부 포함하세요."""


def _call_solar(messages: list[dict], api_key: str) -> str:
    """Solar Pro 호출 — 테스트에서 이 함수를 목으로 대체한다."""
    resp = requests.post(
        f"{SOLAR_BASE_URL}/chat/completions",
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        json={
            "model": SOLAR_MODEL,
            "messages": messages,
            "temperature": 0.3,
            "max_tokens": 1500,
            "reasoning_effort": REASONING_EFFORT,
            "response_format": {"type": "json_object"},  # JSON 모드 — 검증은 서버(pydantic)가 담당
        },
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    resp.raise_for_status()
    return resp.json()["choices"][0]["message"]["content"]


def _field_ok(kind: str, text: str) -> bool:
    """금지어·길이 검사 — 실패한 필드만 폴백으로 치환된다."""
    if not text or not text.strip():
        return False
    if len(text) > _MAX_LEN[kind]:
        return False
    return not any(p in text for p in _BANNED_PHRASES)


def generate(verdict: RuleVerdict) -> ExplanationResult:
    """판정 → 설명 텍스트. 어떤 실패에도 완성된 texts를 돌려준다(리포트 항상 완성)."""
    base = fallback_texts.build(verdict)  # 결정적 기본값 — 실패 시 이대로 나간다

    api_key = _load_api_key()
    if not api_key:
        _log.info("[Solar] 호출 생략 → 폴백 문구 사용 (원인: API 키 없음)")
        return ExplanationResult(texts=base, source="폴백")

    messages = [
        {"role": "system", "content": _SYSTEM_PROMPT},
        {
            "role": "user",
            "content": "판정 JSON:\n" + json.dumps(_verdict_for_prompt(verdict), ensure_ascii=False),
        },
    ]

    _log.info(f"[Solar] 설명 생성 호출 — 입력: 판정 {len(verdict.evidences)}건 (⚠ 크레딧 소모)")
    t0 = time.perf_counter()
    payload: ExplanationPayload | None = None
    last_error = "알 수 없음"
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            content = _call_solar(messages, api_key)
            payload = ExplanationPayload.model_validate(json.loads(content))
            break
        except (requests.exceptions.RequestException, ValueError, ValidationError) as e:
            last_error = f"{type(e).__name__}: {str(e)[:120]}"
            if attempt < MAX_ATTEMPTS:
                _log.info(f"[Solar] {attempt}차 시도 실패 → 재시도 (원인: {last_error})")

    if payload is None:
        _log.info(
            f"[Solar] 검증 실패/타임아웃 → 폴백 문구 사용 (원인: {last_error}, {time.perf_counter() - t0:.1f}초)"
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
