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
from dataclasses import dataclass, field
from pathlib import Path

import requests
from dotenv import load_dotenv
from pydantic import BaseModel, ConfigDict, ValidationError

from ..schemas.internal import RuleVerdict
from . import debt_order, fact_ledger, fallback_texts, llm, questions, text_guard
from .llm import LlmError
from .llm.prompts import EXPLAIN_SYSTEM_PROMPT

_log = logging.getLogger("jeonseai")
_BACKEND_ROOT = Path(__file__).resolve().parents[2]

# [decisions.md 2026-07-07 Solar Pro 연동 스펙 — 공식 쿡북(UpstageAI/cookbook) 원문 근거]
SOLAR_BASE_URL = "https://api.upstage.ai/v1/solar"  # OpenAI 호환 base_url
SOLAR_MODEL = "solar-pro2"  # 첫 모델의 기본 이름. 실제 호출은 llm/solar_models.py가 고른다(끝난 모델이면 solar-pro4로 — 2026-10-31)
REQUEST_TIMEOUT_SECONDS = 60  # 인프라 수치(판정 아님)
MAX_ATTEMPTS = 2  # 최초 1회 + 재시도 1회

# 2026-08-05: 여기 있던 `REASONING_EFFORT = "low"`를 지웠다. **이 파일에서 쓰이지 않는
# 죽은 상수**였다(감사 §C 부수 확인) — 실제 적용은 `llm/providers.py:39`가 하고,
# 이 이름을 import하던 곳은 `precedent/explainer.py`뿐이라 그쪽은 자기 상수를 갖는다.
# 죽은 상수를 남겨 두면 "여기를 고치면 바뀐다"고 오해하게 된다.

# 설명 생성에 주는 출력 예산 (2026-08-05 상향 — 감사 §C에서 '관성'으로 분류된 값).
# 문단을 나눠 쓰게 하면(프롬프트 재설계) 예전 1,500으로는 근거 5장이 잘린다.
MAX_OUTPUT_TOKENS = 3000

# 단정 금지어·등급 단어·**숫자 화이트리스트**는 2026-08-05에 `text_guard`로 옮기고
# 방식을 바꿨다. 이유는 그 모듈 docstring에 있다 — 요지는 "부분 문자열 목록은 세 번째로
# 샜다"(감사 2026-08-05 §B-5-3: `"안전한 범위"`가 `"안전 범위"` 목록을 통과).
#
# ⚠ 가드레일의 **정책**(무엇을 언제 검사하나)은 여전히 이 파일에 있다. provider를 바꿔도
#   가드레일이 따라 바뀌면 안 되기 때문이다(이 파일 모듈 docstring 참고). `text_guard`는
#   정책이 부르는 **기계**일 뿐이고, provider 계층에서는 보이지 않는다.

# 필드 길이 상한(표시 안정용 인프라 수치) — 초과 시 해당 필드 폴백
# headline은 프롬프트 지시(40자 이내)+여유 5자 — 홈에서 3초 안에 한 줄로 읽히게(서연 리뷰)
#
# 2026-08-05: `easy_explanation` 240 → 600. 근거는 두 가지다.
#   ⑴ 240의 출처를 못 찾았다(감사 "확인 불가 목록" ①). headline 45와 달리 근거 기록이 없다.
#   ⑵ 프롬프트를 "기준선 → 이 집 수치 → 무슨 뜻 → 확인할 행동" 4단 문단으로 바꿨다.
#      실측 폴백 문구(`fallback_texts.easy_explanation`)가 이미 200자를 넘는 경우가 있어
#      240은 LLM 문장을 폴백보다 짧게 강제하는 셈이었다.
# 표시 안정성은 앱이 `Text`로 자동 줄바꿈하므로(app_card.dart:154-159) 길이 자체가
# 화면을 깨뜨리지는 않는다.
_MAX_LEN = {"headline": 45, "easy_explanation": 600}

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
    # ── 아래 셋은 **로그·보고용**이다 (2026-08-14 D9). 리포트 내용에 영향이 없다.
    #    "어느 모델이 몇 초 만에 이 문장을 썼는가"를 [분석 완료] 요약에 찍기 위한 것 —
    #    제안서에 터미널을 그대로 캡처해 넣으므로 화면 밖에서도 모델명이 남아야 한다.
    provider: str = "-"  # llm provider 이름 (upstage)
    model: str = "-"  # 실제 호출한 모델명 (.env로 덮였으면 덮인 값)
    elapsed: float = 0.0  # 설명 생성에 쓴 초. 부르지 않았으면 0
    # ── 근거 카드별 설명 출처 (2026-08-14 D26) ────────────────────────────
    # `{근거 id: 실제 모델명 | FALLBACK_SOURCE_LABEL}`.
    #
    # 왜 카드마다 따로 두는가: 이 파일의 폴백은 **필드 단위**다. 한 응답 안에서
    # 어떤 카드는 LLM 문장이 통과하고 어떤 카드는 검증에 걸려 준비된 문구로 남는다
    # (`source="AI 생성(일부 폴백)"`가 바로 그 상태다). 전체 라벨 하나로는 그 차이를
    # 화면에서 말할 수 없어, 준비된 문구를 쓴 카드에까지 모델명이 붙게 된다.
    evidence_sources: dict[str, str] = field(default_factory=dict)


#: LLM 문장을 못 써서 **미리 준비해 둔 문구**가 나간 카드의 출처 라벨 (2026-08-14 D26).
#:
#: 앱이 이 문자열을 칩에 그대로 그린다(`설명 · 준비된 문구`). 여기를 바꾸면 화면 문구가
#: 바뀐다. "AI 생성"이라고 쓰지 않는 이유는 2026-07-09 결정 그대로다 — 폴백 문장에
#: 모델명을 붙이면 그건 거짓말이다.
FALLBACK_SOURCE_LABEL = "준비된 문구"


def _all_fallback_sources(base: dict) -> dict[str, str]:
    """호출조차 못 했거나 응답 전체가 버려졌을 때 — 모든 카드가 준비된 문구다."""
    return {eid: FALLBACK_SOURCE_LABEL for eid in base.get("evidences", {})}


def _load_api_key() -> str:
    load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")  # 이미 설정된 환경변수는 덮지 않음
    return os.environ.get("UPSTAGE_API_KEY", "").strip()


#: 시세 출처 코드 → LLM이 문장에서 부를 이름 (2026-08-05).
#: 예전 프롬프트는 무조건 "입력하신 시세"라고 부르게 했는데, 2026-08-03 자동조회가
#: 붙은 뒤로 그 지시가 **거짓**이 됐다(감사 §A-4-⑶).
_PRICE_SOURCE_LABELS = {
    "manual": "직접 입력하신 시세",
    "actual_trade": "국토교통부 실거래가",
    "official_price": "공시가격을 기준으로 계산한 값",
    "tax_base": "국세청 기준시가",
}


def senior_lines(verdict: RuleVerdict) -> list[str]:
    """먼저 갚을 빚 한 건씩 — '1순위 근저당 3억 6,000만원 · 2022.4.15 · 주식회사가상은행' (받는 순서대로, 2026-11-01)."""
    from .formatting import format_won
    from .mark_plans import dot

    senior = next((e for e in verdict.evidences if e.id == "senior_debt"), None)
    if senior is None:
        return []
    f = senior.facts
    items = [("근저당", m.get("order"), m.get("max_claim_amount"), m.get("receipt_date"), m.get("mortgagee"), m.get("rank_number"))
             for m in (f.get("mortgages") or [])]
    items += [("전세권", j.get("order"), j.get("amount"), j.get("receipt_date"), j.get("holder"), j.get("rank_number"))
              for j in (f.get("jeonse_rights") or [])]
    if items and all(i[1] for i in items):
        items.sort(key=lambda i: i[1])
    out = []
    for kind, order, amount, date, holder, _rank in items:
        bits = [debt_order.label(kind, order) + (f" {format_won(amount)}" if amount else " 금액 못 읽음")]
        bits += [b for b in (dot(date), holder) if b]
        out.append(" · ".join(bits))
    return out


def _facts_for_prompt(eid: str, facts: dict) -> dict:
    """AI에게 보일 수치사실 — 빚 한 건 한 건의 등기부 칸 번호를 **'N순위'로 읽지 않게** 바꿔 싣는다 (2026-11-01).

    판정 facts는 그대로 두고(그림·숫자 줄이 쓴다) 사본만 바꾼다: `rank_number`('3') → `등기부_칸`('을구 3번'),
    `order`(1) → `받는_순서`('1순위'). 말소된 1번 때문에 살아 있는 첫 빚이 '3순위'로 불리던 것을 막는다.
    """
    if eid != "senior_debt" or not isinstance(facts, dict):
        return facts
    out = dict(facts)
    for key in ("mortgages", "jeonse_rights"):
        rows = []
        for m in facts.get(key) or []:
            r = {k: v for k, v in m.items() if k not in ("rank_number", "order")}
            if m.get("order"):
                r["받는_순서"] = f"{m['order']}순위"
            ref = debt_order.registry_ref("을구", m.get("rank_number"))
            if ref:
                r["등기부_칸"] = ref
            rows.append(r)
        if key in facts:
            out[key] = rows
    return out


def _verdict_for_prompt(verdict: RuleVerdict, ledger: "fact_ledger.Ledger | None" = None) -> dict:
    """LLM에 넘길 판정 요약 — RuleVerdict에서 파생한 값만 (추출 원본·이미지 없음).

    2026-08-05: 설명 재료를 넓혔다. 늘어난 것은 **규칙 엔진이 이미 계산했거나 이미 손에
    쥐고 있던 값**뿐이고, 새 판정은 하나도 없다. 날조 방지는 `text_guard`의 숫자
    화이트리스트가 맡는다 — 재료가 늘면 허용 숫자도 함께 늘어 오탐이 줄고, 재료에 없는
    수는 여전히 통과하지 못한다.
    """
    out: dict = {
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
                "수치사실": _facts_for_prompt(e.id, e.facts),
            }
            for e in verdict.evidences
        ],
    }
    # 이 집 숫자표(2026-11-01) — 같은 숫자를 **같은 이름**으로 부르게 하는 정본. 숫자 뜻 검사(fact_ledger)도 이 장부로 본다.
    if ledger is not None:
        out["이_집_숫자표"] = fact_ledger.sheet(ledger, senior_lines(verdict))

    prov = verdict.price_provenance
    if prov is not None and prov.source:
        out["시세출처"] = {
            "부를_이름": _PRICE_SOURCE_LABELS.get(prov.source, "확인된 시세"),
            "출처코드": prov.source,
            "출처명": prov.source_name,
            "기준일": prov.as_of,
            "표본수": prov.sample_count,
            "산정근거": prov.detail,
            "실거래가_공시기준_괴리율_pct": prov.gap_pct,
            "채택안된_후보": prov.alternatives,
        }
    elif verdict.market_price is None:
        out["시세출처"] = {"부를_이름": "시세를 알 수 없음", "출처코드": None}
    else:
        # price_provenance 없이 market_price만 있는 경로(구 호출부·테스트) — 단정하지 않는다.
        out["시세출처"] = {"부를_이름": "확인된 시세", "출처코드": None}

    if verdict.ownership_history:
        out["소유권이전이력"] = verdict.ownership_history

    # ── 등기부 자체의 사실 (2026-08-05 2차) ─────────────────────────────────
    # 열람일시: 못 읽었으면 **못 읽었다고** 알린다. 비워 두면 LLM이 분석일을 끌어다
    # "오늘 서류"처럼 말할 수 있다 — 그게 이 값을 넘기는 이유와 정반대다.
    out["등기부_열람일시"] = verdict.registry_viewed_at or "읽지 못함(분석일로 대체하지 말 것)"
    if verdict.checked_notes:
        out["찾아본_것"] = verdict.checked_notes

    # 이 근거에 **실제로 배정된** 중개사 질문. LLM이 "물어보세요"로 끝낼 때 이 표현과
    # 어긋나지 않게 하려는 것이다. ⚠ 질문은 큐레이션 데이터라 **바꿔 쓰면 안 된다.**
    try:
        by_evidence = questions.questions_for_verdict(verdict)
    except Exception:  # noqa: BLE001 — 재료 하나가 설명 전체를 죽이지 못한다
        by_evidence = {}
    if by_evidence:
        out["배정된_중개사_질문"] = by_evidence

    # ── 깊은 설명 재료 (2026-11-01) — 규칙이 이미 낸 값만. 판정은 이 값들을 보지 않는다. ──────────────
    if verdict.loss_summary:
        out["경매로_가면"] = verdict.loss_summary  # 리포트 2장·손실 시뮬레이터와 같은 계산
    if verdict.house_signals:
        out["이_집_신호"] = verdict.house_signals  # 등기부 사실을 이어 붙인 문장(평가 아님)
    if verdict.card_todo:
        out["카드에_이미_있는_할일"] = verdict.card_todo  # 화면에 따로 나가는 할 일 — 설명에서 되풀이 금지
    return out


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
        system, user, max_tokens=MAX_OUTPUT_TOKENS, temperature=llm.EXPLAIN_TEMPERATURE
    ).text


def _field_reason(
    kind: str,
    text: str,
    allowed: set[float],
    grade: str | None = None,
    ledger: "fact_ledger.Ledger | None" = None,
) -> str | None:
    """이 필드를 쓸 수 있나 — 쓸 수 있으면 None, 아니면 **사유 문자열**.

    2026-08-05: 불리언(`_field_ok`) → 사유 문자열로 바꿨다. 폴백이 조용하면 무엇이
    걸렸는지 다음에도 모르기 때문이다(감사 §B-5의 세 건이 전부 '통과한 위반'이었다).
    2026-11-01: 숫자가 재료에 **있는지**에 더해 **제자리에 쓰였는지**(fact_ledger)도 본다.
    """
    reason = text_guard.check(text, max_len=_MAX_LEN[kind], allowed=allowed, grade=grade)
    if reason is None and kind == "easy_explanation":
        reason = _lead_format_reason(text)
    if reason is None:
        try:
            meaning = fact_ledger.check(text, ledger)
        except Exception:  # noqa: BLE001 — 검사기 버그가 설명 전체를 폴백시키지 않게(로그만)
            _log.error("[설명] ⚠ 숫자 뜻 검사 실패 — 이 칸은 예전 검사만", exc_info=True)
            meaning = None
        if meaning:
            reason = f"숫자 뜻: {meaning}"
    return reason


def _lead_format_reason(text: str) -> str | None:
    """'이 집 핵심' 문단 모양 검사 (2026-11-01) — 깨진 굵은 표시만 막는다.

    앱은 문단 맨 앞 `**머리말**`을 굵은 한 줄로 따로 세운다(`splitLeadParagraph`). `**`가 짝이 안 맞으면
    화면에 별표가 그대로 보이므로 그 카드만 준비된 문구로 돌린다. 머리말이 없는 문단은 그냥 문단으로 그려지니
    **막지 않는다**(괜히 폴백을 늘리지 않게).
    """
    for para in text.split("\n"):
        n = para.count("**")
        if n == 0:
            continue
        if n != 2 or not para.lstrip().startswith("**"):
            return "굵은 표시(**)는 문단 맨 앞 머리말에만"
    return None




class _RepairPayload(BaseModel):
    """고쳐 쓰기 응답 — 걸린 칸만. 판정 필드는 여기에도 없다."""

    model_config = ConfigDict(extra="forbid")
    headline: str | None = None
    evidences: list[EvidenceExplanation] = []


#: 고쳐 쓰기 지시 — 시스템 지시(EXPLAIN_SYSTEM_PROMPT)는 그대로 두고 사용자 칸에 붙인다
_REPAIR_NOTE = (
    "\n\n## 고쳐 쓰기\n아래 칸은 화면에 내보내기 전 검사에 걸렸어요. '걸린_이유'를 그대로 고쳐서 **그 칸만** 다시 써 주세요."
    " 숫자는 위 판정 JSON(특히 `이_집_숫자표`)에 있는 것만, 제자리에 쓰세요. 다른 칸은 쓰지 마세요.\n"
    '출력: {"headline": "(headline이 걸렸을 때만)", "evidences": [{"id": "걸린 근거 id", "easy_explanation": "..."}]}\n'
)


def _repair(material: dict, payload: "ExplanationPayload", retry: dict[str, str], api_key: str, name: str) -> dict:
    """걸린 칸만 한 번 다시 쓰게 한다 → {칸 id 또는 'headline': 새 글}. 실패하면 빈 dict(예외를 내지 않는다)."""
    first = {e.id: e.easy_explanation for e in payload.evidences}
    asks = [
        {"칸": k, "처음_쓴_글": (payload.headline if k == "headline" else first.get(k)) or "", "걸린_이유": v}
        for k, v in retry.items()
    ]
    messages = [
        {"role": "system", "content": _SYSTEM_PROMPT},
        {
            "role": "user",
            "content": "판정 JSON:\n" + json.dumps(material, ensure_ascii=False)
            + _REPAIR_NOTE + "고칠 칸:\n" + json.dumps(asks, ensure_ascii=False),
        },
    ]
    t0 = time.perf_counter()
    try:
        fixed = _RepairPayload.model_validate(json.loads(_call_solar(messages, api_key)))
    except Exception as e:  # noqa: BLE001 — 고쳐 쓰기는 덤이다. 실패하면 준비된 문구로 간다
        _log.info(f"[설명:{name}] 고쳐 쓰기 실패 → 걸린 칸은 준비된 문구 ({type(e).__name__}, {time.perf_counter() - t0:.1f}초)")
        return {}
    out = {e.id: e.easy_explanation for e in fixed.evidences if e.id in retry}
    if fixed.headline and "headline" in retry:
        out["headline"] = fixed.headline
    _log.info(f"[설명:{name}] 고쳐 쓰기 {len(retry)}칸 요청 → {len(out)}칸 받음 ({time.perf_counter() - t0:.1f}초)")
    return out


def generate(
    verdict: RuleVerdict, *, report_id: str = "-", ledger: "fact_ledger.Ledger | None" = None
) -> ExplanationResult:
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
        return _generate_with_llm(verdict, base, report_id=report_id, ledger=ledger)
    except Exception as e:  # noqa: BLE001 — 구조적 방어선 (위 docstring 참고)
        _log.error(
            f"[설명] ⚠ 설명 생성 경로에서 예기치 못한 예외 — 폴백 문구로 리포트 완성"
            f" ({type(e).__name__}: {str(e)[:120]})",
            exc_info=True,
        )
        return ExplanationResult(
            texts=base, source="폴백", evidence_sources=_all_fallback_sources(base)
        )


def _generate_with_llm(
    verdict: RuleVerdict, base: dict, *, report_id: str = "-", ledger: "fact_ledger.Ledger | None" = None
) -> ExplanationResult:
    """실제 생성·검증·병합. 예외를 밖으로 낼 수 있다 — `generate`가 받아낸다."""
    provider = llm.explain_provider()
    api_key = _load_api_key()  # 목 호출 호환용 인자 (실제 키는 provider가 직접 읽는다)
    if not provider.available:
        _log.info(f"[설명:{provider.name}] 호출 생략 → 폴백 문구 사용 (원인: API 키 없음)")
        return ExplanationResult(
            texts=base,
            source="폴백",
            provider=provider.name,
            model=provider.model,
            evidence_sources=_all_fallback_sources(base),
        )

    # 이 dict가 **재료의 정본**이다 — LLM에 보내는 것과 숫자 화이트리스트의 기준이
    # 같은 객체여야 한다(둘이 어긋나면 정상 문장이 폴백된다).
    material = _verdict_for_prompt(verdict, ledger)
    messages = [
        {"role": "system", "content": _SYSTEM_PROMPT},
        {
            "role": "user",
            "content": "판정 JSON:\n" + json.dumps(material, ensure_ascii=False),
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
        failed_elapsed = time.perf_counter() - t0
        _log.info(
            f"[설명:{provider.name}] 검증 실패/타임아웃 → 폴백 문구 사용"
            f" (원인: {last_error}, {failed_elapsed:.1f}초)"
        )
        return ExplanationResult(
            texts=base,
            source="폴백",
            provider=provider.name,
            model=provider.model,
            elapsed=failed_elapsed,
            evidence_sources=_all_fallback_sources(base),
        )

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
    #: 폴백 사유를 필드별로 모은다 — 조용한 폴백은 같은 문제를 반복시킨다(2026-08-05).
    reasons: list[str] = []
    #: 숫자 화이트리스트의 기준이 되는 **재료**. LLM에 실제로 보낸 것과 같은 dict를 쓴다 —
    #: 보낸 것과 검사 기준이 어긋나면 정상 문장이 폴백된다.
    allowed = text_guard.collect_allowed(material)

    # 맨 윗줄은 종합 등급, 카드는 그 카드 등급과 **같은 방향**이어야 한다(2026-10-29 — 위험인데 안심시키기 금지)
    head_reason = _field_reason("headline", payload.headline, allowed, verdict.grade.value, ledger)
    by_id = {e.id: e.easy_explanation for e in payload.evidences}
    grade_of = {e.id: e.grade.value for e in verdict.evidences}
    card_reason: dict[str, str | None] = {}
    for eid in texts["evidences"]:
        candidate = by_id.get(eid)
        card_reason[eid] = (
            "응답 누락" if candidate is None
            else _field_reason("easy_explanation", candidate, allowed, grade_of.get(eid), ledger)
        )

    # ── 고쳐 쓰기 한 번 (2026-11-01) ───────────────────────────────────────
    # 검사에 걸린 칸을 바로 준비된 문구로 내리지 않고, **왜 걸렸는지**를 알려 그 칸만 한 번 다시 쓰게 한다.
    # AI 문장을 틀에 가두지 않으면서(고정 문구로 바꾸지 않는다) 틀린 숫자·뜻은 화면에 닿지 못하게 하는 자리.
    # 다시 쓴 글도 **같은 검사**를 다시 통과해야 쓴다. 그래도 걸리면 준비된 문구.
    retry = {k: v for k, v in card_reason.items() if v}
    if head_reason:
        retry["headline"] = head_reason
    if retry:
        fixed = _repair(material, payload, retry, api_key, provider.name)
        if head_reason and fixed.get("headline"):
            again = _field_reason("headline", fixed["headline"], allowed, verdict.grade.value, ledger)
            if again is None:
                payload = payload.model_copy(update={"headline": fixed["headline"]})
                head_reason = None
        for eid in list(card_reason):
            text_fixed = fixed.get(eid)
            if card_reason[eid] and text_fixed:
                again = _field_reason("easy_explanation", text_fixed, allowed, grade_of.get(eid), ledger)
                if again is None:
                    by_id[eid] = text_fixed
                    card_reason[eid] = None
                else:
                    card_reason[eid] = f"{card_reason[eid]} → 고쳐 쓴 글도 {again}"

    if head_reason is None:
        texts["headline"] = payload.headline.strip()
        applied += 1
    else:
        dropped += 1
        reasons.append(f"headline={head_reason}")

    # [D26 · 2026-08-14] 카드마다 "이 문장을 누가 썼는가"를 여기서 기록한다.
    # 이 루프가 **필드 단위 폴백이 실제로 갈리는 유일한 지점**이라, 다른 곳에서 추측하지
    # 않고 갈리는 자리에서 바로 남긴다.
    evidence_sources: dict[str, str] = {}
    for eid in texts["evidences"]:
        reason = card_reason.get(eid)
        if reason is None:
            texts["evidences"][eid]["easy_explanation"] = by_id[eid].strip()
            applied += 1
            evidence_sources[eid] = provider.model
        else:
            dropped += 1  # 해당 카드만 폴백 유지
            reasons.append(f"{eid}={reason}")
            evidence_sources[eid] = FALLBACK_SOURCE_LABEL

    elapsed = time.perf_counter() - t0
    if dropped == 0:
        source = "AI 생성"
        _log.info(f"[Solar] 응답 OK ({elapsed:.1f}초) — 설명 {applied}건 생성")
    elif applied == 0:
        source = "폴백"
        _log.info(
            f"[Solar] 응답 수신했으나 사용 가능 문구 0건 → 전체 폴백 ({elapsed:.1f}초)"
            f" — 사유: {' | '.join(reasons)}"
        )
    else:
        source = "AI 생성(일부 폴백)"
        _log.info(
            f"[Solar] 응답 OK ({elapsed:.1f}초) — 설명 {applied}건 생성 · {dropped}건 폴백"
            f" — 사유: {' | '.join(reasons)}"
        )
    return ExplanationResult(
        texts=texts,
        source=source,
        provider=provider.name,
        model=provider.model,
        elapsed=elapsed,
        evidence_sources=evidence_sources,
    )
