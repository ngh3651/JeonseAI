"""판례 설명 생성 — Solar Pro는 '검색된 판례의 통역사'다 (E-2 가드레일 구조의 연장).

환각 차단 구조 (LLM이 판례를 지어낼 통로 자체가 없다):
- 입력은 **검색으로 실제 가져온 판례 목록**(case_id·요지·결과)과 판정 요약뿐.
- 출력 모델은 extra="forbid" — 사건번호·등급·점수·결과 문장 필드가 존재하지 않는다.
  사건번호·출처는 서버가 검색된 문서(PrecedentDoc)에서 복사한다.
- 2026-10-23 규혁 결정: **이 매물 맞춤** 공통점·조언·요약은 Solar가 쓴다(판례는 "우리 집과 얼마나 닮았나"가
  궁금해서 보는 것). 대신 숫자는 입력에 있는 것만(`_numbers_grounded`), 금지어·길이 검사, 실패하면 큐레이션 문구.
- LLM 응답의 case_id가 검색 결과에 없으면 그 항목은 폐기(지어낸 판례 인용 차단).
- 호출 실패·검증 실패·금지어 → 결정적 폴백 문구(큐레이션 요약)로 해당 항목만 치환.
  판례 섹션은 항상 완성되거나, 정직하게 비어 있다.

금지어·모델 상수는 E-2 설명 생성기(explanation.py)의 것을 재사용한다 — 정책 단일화.
"""

from __future__ import annotations

import json
import logging
import re
import time

import requests
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .. import text_guard  # 2026-08-05: 금지어 목록 → 패턴(E-2와 **같은** 검증 공유)
from ..explanation import (  # E-2와 동일 정책 공유 (모델·키 로드)
    _load_api_key,
    SOLAR_BASE_URL,
    SOLAR_MODEL,
)

#: 판례 설명도 문장 생성이라 복잡 추론이 필요 없다. 예전에는 `explanation`의 상수를
#: 빌려 썼는데, 그 상수는 정작 그쪽에서 쓰이지 않는 죽은 값이었다(감사 2026-08-05).
#: 실제로 쓰는 이 파일이 자기 값을 갖는다.
REASONING_EFFORT = "low"
from .models import PrecedentExplanation, RetrievedPrecedent

_log = logging.getLogger("jeonseai")

_REQUEST_TIMEOUT = 60
_MAX_ATTEMPTS = 2
_MAX_LEN = {"easy_summary": 220, "common_point": 220, "advice": 260}  # 표시 안정용 인프라 수치
_HOLDING_EXCERPT_CHARS = 600  # 프롬프트에 싣는 요지 발췌 길이


class _ExplanationList(BaseModel):
    model_config = ConfigDict(extra="forbid")
    cases: list[PrecedentExplanation] = Field(default_factory=list)


_SYSTEM_PROMPT = """당신은 전세 위험 분석 앱의 '판례 통역사'입니다. 검색으로 실제 찾아온 판례를 읽고, 부동산 지식이 없는 사회초년생에게 **"이 판례가 지금 우리 집과 얼마나, 어디가 닮았는지"와 "그래서 이 집에서 무엇을 해야 하는지"**를 쉬운 한국어로 알려 주는 것이 역할입니다.

입력:
- '이 매물': 규칙 엔진이 이미 내린 판정(종합 등급, 위험 항목별 내용, 보증금·시세·먼저 갚을 빚 금액). 판정은 바꿀 수 없습니다.
- '판례_목록': 검색된 실제 판례(요지, 사람이 쓴 요약·결과·조언이 있을 수 있음).

반드시 지킬 것:
1. 입력에 없는 판례·사건번호·법 조문을 언급하지 마세요. 판례 이야기는 그 판례의 요지 안에서만 하세요.
2. 위험 판정(등급·점수)을 바꾸거나 새로 만들지 마세요. "이 집은 위험해요/안전해요" 같은 판정 문장 금지.
3. 모든 문장은 "~해요/~하세요"로 끝내세요. "~합니다/~입니다" 금지.
4. 단정 표현 금지: "안전합니다", "문제없습니다", "걱정 마세요" 계열 전부 금지.
5. **숫자(금액·비율·건수·날짜)는 입력에 있는 것만** 쓰세요. 입력에 없는 숫자를 하나라도 쓰면 그 문장은 버려집니다.
6. 전문용어는 쉬운 말을 먼저 쓰고 괄호로 용어를 병기하세요. 예: "먼저 갚아야 하는 빚(선순위 채권)".
7. **읽기 편하게**: 한 문장은 40자 안팎으로 짧게. 문장이 둘 이상이면 문장 사이에 줄바꿈(\\n)을 넣으세요. 한 칸에 최대 3문장.

칸별로:
- easy_summary: 그 판례에서 무슨 일이 있었고 법원이 어떻게 판단했는지 1~2문장. 사람이 쓴 '요약'이 있으면 그 뜻을 바꾸지 말고 더 쉽게 다듬으세요.
- common_point: **이 매물과 이 판례가 어디가 닮았는지** 1~2문장. '이 매물'의 실제 내용(어떤 위험이 몇 건, 금액 등)을 짚어서 구체적으로 쓰세요.
  예: "이 집에도 가압류가 1건 있어요.\\n판례 속 집처럼 경매로 넘어가면 보증금을 지키기 어려울 수 있어요."
  닮지 않은 점이 중요하면 한 문장 덧붙여도 돼요 (예: "다만 판례는 다가구주택이었어요").
- advice: **이 매물에서 계약 전에 할 일** 2~3개를 짧은 문장으로, 줄바꿈으로 나눠 쓰세요. 판례의 교훈을 이 집 상황에 맞춰 바꿔 쓰세요.
  사람이 쓴 '조언'이 있으면 그 내용을 빠뜨리지 말고 이 집에 맞게 고쳐 쓰세요.
  예: "계약 전에 집주인에게 가압류를 언제 풀지 물어보세요.\\n잔금 전에 등기부를 다시 떼서 가압류가 사라졌는지 확인하세요."
- outcome_kind: **임차인(세입자)이 결국 어떻게 됐는지**를 셋 중 하나로 고르세요. 문장을 쓰지 말고 값만 고르세요.
   - "lost"           : 보증금을 돌려받지 못했어요
   - "partial"        : 일부만 돌려받았어요
   - "won_after_suit" : 소송 끝에 인정받았어요 (이겼더라도 이 값입니다)
   판결문에서 판단하기 어려우면 이 키를 아예 빼세요. 추측해서 넣지 마세요.
   ※ 임차인이 이긴 판례도 "소송까지 갔다"는 사실이 핵심입니다 — 안심 신호가 아닙니다.
- emphasis: **화면에서 굵게 보여줄 구절**을 고르는 칸입니다. 새 문장을 쓰는 칸이 아닙니다.
   - "common_point"·"advice" 키에는 당신이 쓴 그 문장에서 **그대로 잘라낸** 구절을 넣으세요.
   - "result" 키에는 입력의 '결과' 문장에서 **그대로 잘라낸** 구절을 넣으세요. 입력에 '결과'가 없으면 키를 빼세요.
     ※ '결과'는 사람이 확정한 문장이라 고쳐 쓰지 마세요.
   - 한 글자라도 다르면 그 필드는 버려집니다. 요약하거나 다듬지 말고 **복사해서** 넣으세요.
   - 필드당 최대 2개, 하나당 30자 이내, 합쳐서 그 문장의 30%를 넘지 마세요.
   - 고를 것: 보증금을 잃었다는 사실, 금액·비율·기간, 그 사건의 결정적 조건, 꼭 해야 할 행동.

다음 JSON 형식으로만 응답하세요 (다른 텍스트 금지):
{"cases": [{"case_id": "입력의 case_id 그대로", "easy_summary": "...", "common_point": "...", "advice": "...", "outcome_kind": "lost", "emphasis": {"common_point": ["..."], "advice": ["..."], "result": ["..."]}}]}
입력된 판례 전부에 대해 하나씩 작성하세요."""


def _call_solar(messages: list[dict], api_key: str) -> str:
    """Solar Pro 호출 — 테스트에서 이 함수를 목으로 대체한다."""
    resp = requests.post(
        f"{SOLAR_BASE_URL}/chat/completions",
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        json={
            "model": SOLAR_MODEL,
            "messages": messages,
            "temperature": 0.3,
            "max_tokens": 3000,  # 4건 × (요약·공통점·조언) — 2026-10-23 조언까지 쓰면서 늘림
            "reasoning_effort": REASONING_EFFORT,
            "response_format": {"type": "json_object"},
        },
        timeout=_REQUEST_TIMEOUT,
    )
    resp.raise_for_status()
    return resp.json()["choices"][0]["message"]["content"]


def tidy_lines(text: str) -> str:
    """줄바꿈 정리 — 줄마다 앞뒤 공백을 지우고 빈 줄은 하나도 남기지 않는다(카드 안에서 문장마다 한 줄)."""
    lines = [ln.strip() for ln in (text or "").replace("\r", "").split("\n")]
    return "\n".join(ln for ln in lines if ln)


def _digits_only(s: str) -> str:
    return re.sub(r"[,\s]", "", s)


def _numbers_grounded(text: str, source: str) -> bool:
    """글 속 숫자(1,000 · 3.5 · 2024 …)가 전부 입력(source)에 있는가 — 지어낸 금액·비율 차단."""
    src = _digits_only(source)
    for raw in re.findall(r"\d[\d,\.]*", text):
        n = raw.replace(",", "").rstrip(".")
        if n and n not in src:
            return False
    return True


def _field_ok(kind: str, text: str, source: str = "") -> bool:
    if not text or not text.strip():
        return False
    if len(text) > _MAX_LEN[kind]:
        return False
    if text_guard.banned_hit(text) is not None:
        return False
    return _numbers_grounded(text, source)


def fallback_summary(match: RetrievedPrecedent) -> str:
    """결정적 폴백 — 큐레이션 요약이 있으면 그대로, 없으면 요지 첫 문장."""
    doc = match.doc
    if doc.summary_easy:
        return doc.summary_easy
    first = doc.holding.split(". ")[0].strip()
    return (first[:150] + "…") if len(first) > 150 else first


def fallback_common_point(match: RetrievedPrecedent) -> str:
    """결정적 폴백 — 판정과 겹친 위험 태그 기반 한 문장."""
    if match.matched_tags:
        return f"이 매물의 판정에서도 {' · '.join(match.matched_tags)} 신호가 확인됐어요"
    return "이 매물의 위험 신호와 같은 유형의 사건이에요"


def explain_matches(
    matches: list[RetrievedPrecedent], verdict_summary: dict
) -> tuple[dict[str, PrecedentExplanation], str]:
    """검색 결과 → {case_id: 설명}. 실패 항목은 비워 두고(호출부가 폴백 적용) source를 반환.

    verdict_summary: 판정에서 파생한 요약 dict (수치 사실 — LLM이 공통점·조언에 쓸 재료, 이름·주소 없음).
    반환 source: "AI 생성" | "폴백" | "AI 생성(일부 폴백)"
    """
    if not matches:
        return {}, "폴백"

    api_key = _load_api_key()
    if not api_key:
        _log.info("[Solar/판례] 호출 생략 → 폴백 문구 (원인: API 키 없음)")
        return {}, "폴백"

    payload = {
        "이_매물": verdict_summary,
        "판례_목록": [
            {
                "case_id": m.doc.case_id,
                "사건번호": m.doc.case_no,
                "법원": m.doc.court,
                "요지": m.doc.holding[:_HOLDING_EXCERPT_CHARS],
                "요약": m.doc.summary_easy,
                "결과": m.doc.outcome,
                # 2026-10-23: 사람이 쓴 조언은 **재료**로 준다 — Solar가 이 집에 맞춰 고쳐 쓴다(빠뜨리지 않게).
                "조언": m.doc.advice,
                "겹친_위험_태그": m.matched_tags,
            }
            for m in matches
        ],
    }
    source_text = json.dumps(payload, ensure_ascii=False)
    messages = [
        {"role": "system", "content": _SYSTEM_PROMPT},
        {"role": "user", "content": source_text},
    ]

    _log.info(f"[Solar/판례] 설명 생성 호출 — 판례 {len(matches)}건 (⚠ 크레딧 소모)")
    t0 = time.perf_counter()
    parsed: _ExplanationList | None = None
    last_error = "알 수 없음"
    for attempt in range(1, _MAX_ATTEMPTS + 1):
        try:
            content = _call_solar(messages, api_key)
            parsed = _ExplanationList.model_validate(json.loads(content))
            break
        except (requests.exceptions.RequestException, ValueError, ValidationError) as e:
            last_error = f"{type(e).__name__}: {str(e)[:120]}"
            if attempt < _MAX_ATTEMPTS:
                _log.info(f"[Solar/판례] {attempt}차 시도 실패 → 재시도 (원인: {last_error})")

    if parsed is None:
        _log.info(f"[Solar/판례] 실패 → 전체 폴백 (원인: {last_error}, {time.perf_counter() - t0:.1f}초)")
        return {}, "폴백"

    valid_ids = {m.doc.case_id for m in matches}
    out: dict[str, PrecedentExplanation] = {}
    dropped = 0
    for exp in parsed.cases:
        if exp.case_id not in valid_ids:
            dropped += 1  # 검색 결과에 없는 판례 언급 → 폐기 (환각 인용 차단)
            continue
        exp = exp.model_copy(
            update={
                "easy_summary": tidy_lines(exp.easy_summary),
                "common_point": tidy_lines(exp.common_point),
                "advice": tidy_lines(exp.advice) if exp.advice else None,
            }
        )
        if not _field_ok("easy_summary", exp.easy_summary, source_text) or not _field_ok(
            "common_point", exp.common_point, source_text
        ):
            dropped += 1
            continue
        # 조언만 검사에 걸리면 **조언 칸만** 버린다(요약·공통점은 살린다) → 호출부가 큐레이션 조언으로
        if exp.advice and not _field_ok("advice", exp.advice, source_text):
            _log.info(f"[Solar/판례] 조언 검사 실패 → 큐레이션 조언으로 ({exp.case_id})")
            exp = exp.model_copy(update={"advice": None})
        out[exp.case_id] = exp

    elapsed = time.perf_counter() - t0
    if not out:
        _log.info(f"[Solar/판례] 사용 가능 설명 0건 → 전체 폴백 ({elapsed:.1f}초)")
        return {}, "폴백"
    missing = len(matches) - len(out)
    source = "AI 생성" if missing == 0 and dropped == 0 else "AI 생성(일부 폴백)"
    _log.info(f"[Solar/판례] 응답 OK ({elapsed:.1f}초) — 설명 {len(out)}건 · 폐기/누락 {dropped + missing}건")
    return out, source
