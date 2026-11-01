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

from .. import fact_ledger, text_guard  # 2026-08-05: 금지어 목록 → 패턴(E-2와 **같은** 검증 공유)
from ..explanation import _load_api_key  # E-2와 동일 정책 공유 (키 로드)
from ..llm import solar_models

#: 판례 설명도 문장 생성이라 복잡 추론이 필요 없다 — 추론 설정은 모델마다 `solar_models.reasoning_fields`가
#: 맞춘다(solar-pro2·pro3 = low, pro4 = 끔). 2026-10-31부터 이 파일에 따로 두지 않는다.
from .models import PrecedentExplanation, RetrievedPrecedent

_log = logging.getLogger("jeonseai")

_REQUEST_TIMEOUT = 60
_MAX_ATTEMPTS = 2
_MAX_LEN = {"easy_summary": 220, "common_point": 240, "advice": 260}  # 표시 안정용 인프라 수치
MAX_PICK = 4  # AI가 고를 최대 판례 수 (화면 카드 수)
_BOLD = re.compile(r"\*\*(.+?)\*\*")
_HOLDING_EXCERPT_CHARS = 600  # 프롬프트에 싣는 요지 발췌 길이


class _ExplanationList(BaseModel):
    model_config = ConfigDict(extra="forbid")
    cases: list[PrecedentExplanation] = Field(default_factory=list)


_SYSTEM_PROMPT = """당신은 전세 위험 분석 앱의 '판례 통역사'입니다. 검색으로 실제 찾아온 판례 후보를 읽고, **지금 이 집과 가장 닮은 판례를 골라**, 부동산 지식이 없는 사회초년생에게 "이 판례가 이 집과 어디가 닮았는지"와 "그래서 이 집에서 무엇을 해야 하는지"를 쉬운 한국어로 알려 주는 것이 역할입니다.

입력:
- '이_매물': 규칙 엔진이 이미 내린 판정(종합 등급, 보증금·시세·먼저 갚을 빚, 위험 항목별 내용, 살아 있는 등기 항목의 종류·접수일·금액·권리자 종류). 판정은 바꿀 수 없습니다.
- '판례_후보': 검색된 실제 판례(요지, 사람이 쓴 요약·결과·조언이 있을 수 있음). 최대 10건.
- '기준_견본': 법률 담당 팀원이 원문과 대조해 검수한 판례 카드. **말투·쉬운 정도·길이는 이 견본을 따르세요.**

0단계 — 고르기:
- '판례_후보' 중에서 **이 집과 상황이 가장 닮은 판례를 최대 4건** 고르세요. 닮은 순서대로 쓰세요.
- 닮음 = 같은 종류의 위험(예: 가압류)이 같은 순서·같은 조건으로 걸려 있는가. 단어만 같고 상황이 다르면 고르지 마세요.
- 닮은 판례가 없으면 빈 목록 {"cases": []} 을 돌려주세요. 억지로 고르지 마세요.

반드시 지킬 것:
1. 입력에 없는 판례·사건번호·법 조문을 언급하지 마세요. 판례 이야기는 그 판례의 요지 안에서만 하세요.
2. 위험 판정(등급·점수)을 바꾸거나 새로 만들지 마세요. "이 집은 위험해요/안전해요" 같은 판정 문장 금지.
3. 모든 문장은 "~해요/~하세요"로 끝내세요. "~합니다/~입니다" 금지.
4. 단정 표현 금지: "안전합니다", "문제없습니다", "걱정 마세요" 계열 전부 금지.
5. **숫자(금액·비율·건수·날짜)는 입력에 있는 것만** 쓰세요. 금액은 '이_매물'의 '금액_표기'를 그대로 옮기세요. 입력에 없는 숫자를 하나라도 쓰면 그 칸은 버려집니다.
6. 전문용어는 쉬운 말을 먼저 쓰고 필요하면 괄호로 용어를 병기하세요.
7. **이 집 숫자는 '이_매물.이_집_숫자표'의 이름 그대로의 자리에** 쓰세요(보증금은 보증금, 시세는 시세). 빚이 2건 이상이면
   '선순위'·'먼저 갚을 빚'은 **합계**로 말하고, 한 건만 말할 때는 "1순위 근저당 ○○원"처럼 **받는 순서**를 붙이세요.
   'N순위'는 '받는_순서'만 쓰세요. 경매로 팔리면 먼저 받는 쪽은 **돈을 빌려준 곳**이에요(빚을 진 집주인이 아니에요).
   이 규칙을 어기면 그 칸은 버려져요.

줄바꿈 (화면 폭에 맞춘 규칙 — 꼭 지키세요):
- 줄바꿈은 \n 으로 표시합니다. 한 줄 글자 수는 띄어쓰기 포함으로 셉니다.
- easy_summary: 한 줄 15자 안쪽. common_point·advice: 한 줄 12자 안쪽(말풍선이 좁아요).
- 줄은 **말 덩어리가 끝나는 곳에서만** 바꾸세요(~은/는, ~에, ~하면, ~고, 쉼표·마침표 뒤). 꾸미는 말과 받는 말을 떼지 마세요.
  좋은 예: "나는 어제 사과나무를 심었고\n오늘 포도나무를 심었다"
  나쁜 예: "나는 어제 사과나무를\n심었고 오늘 포도나무를 심었다"

굵게:
- 칸마다 가장 중요한 말 **1곳(많아야 2곳)**만 **굵게** 처럼 별표 두 개로 감싸세요. 문장 전체가 아니라 핵심 3~8글자.
- 용어(가압류·전입신고 같은 낱말)만 따로 굵게 하지 마세요.

칸별로:
- easy_summary (2문장, 60~90자): [판례 속에서 무슨 일이 있었나] + [법원이 어떻게 판단했나]. 판례 이야기만 하고 이 집 이야기는 하지 마세요.
  사람이 쓴 '요약'이 있으면 그 뜻을 바꾸지 마세요.
- common_point (2~3문장, 80~130자) — 이 칸이 가장 중요합니다:
  ① "판례 속 집은 ~였어요" (판결을 가른 핵심 조건 하나)
  ② "이 집도 ~예요" — **'이_매물'의 숫자나 사실을 반드시 하나 이상** (금액·건수·접수일·순서). 없으면 이 칸은 버려집니다.
  ③ (선택) "그래서 ~하면 판례처럼 ~될 수 있어요" 또는 "다만 ~는 달라요"(다른 점이 중요하면 솔직하게).
  "확인이 필요해요"처럼 어느 집에나 맞는 말로 끝내지 마세요.
  예: "판례 속 임차인은\n가압류가 걸린 뒤에\n이사 들어왔어요.\n이 집에도 **4억원** 가압류가\n이미 걸려 있어요.\n지금 계약하면\n판례와 같은 순서가 돼요."
- advice (행동 2~3개, 70~120자): 한 행동에 한 문장, **[언제] [누구에게/어디서] [무엇을] 하세요**. 언제 = 계약 전 / 잔금 전 / 입주 다음 날.
  바로 할 수 있는 행동만 쓰고 "주의하세요"는 쓰지 마세요. common_point를 되풀이하지 마세요. 이 집 상황에 맞추세요.
  사람이 쓴 '조언'이 있으면 그 내용을 빠뜨리지 말고 이 집에 맞게 고쳐 쓰세요.
  예: "계약 전에 집주인에게\n가압류를 언제 풀지\n물어보세요.\n잔금 전까지 말소하겠다는\n약속을 **특약**에 넣으세요."
- outcome_kind: **임차인(세입자)이 결국 어떻게 됐는지**를 셋 중 하나로 고르세요. 문장을 쓰지 말고 값만.
   "lost"(보증금을 돌려받지 못했어요) / "partial"(일부만 돌려받았어요) / "won_after_suit"(소송 끝에 인정받았어요 — 이겼더라도 이 값)
   판단하기 어려우면 키를 빼세요. ※ 임차인이 이긴 판례도 "소송까지 갔다"가 핵심 — 안심 신호가 아닙니다.
- emphasis: "result" 키에만, 입력의 '결과' 문장에서 **그대로 잘라낸** 가장 중요한 구절 1개(30자 이내). '결과'가 없으면 키를 빼세요.
  '결과'는 사람이 확정한 문장이라 고쳐 쓰지 마세요.

다음 JSON 형식으로만 응답하세요 (다른 텍스트 금지):
{"cases": [{"case_id": "고른 후보의 case_id 그대로", "easy_summary": "...", "common_point": "...", "advice": "...", "outcome_kind": "lost", "emphasis": {"result": ["..."]}}]}
고른 판례만, 닮은 순서대로 쓰세요."""


def _call_solar(messages: list[dict], api_key: str) -> str:
    """Solar Pro 호출 — 테스트에서 이 함수를 목으로 대체한다."""
    # 모델·추론 설정은 solar_models가 고른다 — 끝난 모델이면 다음 모델로 바꿔 다시 부른다(2026-10-31)
    resp, _model = solar_models.post_chat(
        {
            "messages": messages,
            "temperature": 0.3,
            "max_tokens": 3000,  # 4건 × (요약·공통점·조언) — 2026-10-23 조언까지 쓰면서 늘림
            "response_format": {"type": "json_object"},
        },
        api_key=api_key,
        timeout=_REQUEST_TIMEOUT,
    )
    resp.raise_for_status()
    return resp.json()["choices"][0]["message"]["content"]


_EXEMPLARS: list[dict] | None = None


def exemplars() -> list[dict]:
    """기준 견본 — 법률 담당 팀원이 원문과 대조해 검수한 판례 카드(seed_cases.json, `curated_by`에 '검수'·verified).

    Solar는 말투·쉬운 정도·길이를 이 견본에 맞춘다. 검수 판례가 늘면(남은 7건) 견본도 저절로 늘어난다.
    """
    global _EXEMPLARS
    if _EXEMPLARS is None:
        from .ingest import load_seed_cases

        out = []
        for c in load_seed_cases():
            by = str(c.get("curated_by") or "")
            if not c.get("verified") or "대기" in by or "검수" not in by:
                continue
            out.append(
                {
                    "사건번호": c.get("case_no"),
                    "요약": c.get("summary_easy"),
                    "결과": c.get("outcome"),
                    "조언": c.get("advice"),
                }
            )
        _EXEMPLARS = out[:4]
    return _EXEMPLARS


def split_bold(text: str) -> tuple[str, list[str]]:
    """`**굵게**` 표시를 떼어 낸 글과 굵게 구절 목록. 표시가 3곳 이상이면 굵게는 버린다(글은 살린다)."""
    found = _BOLD.findall(text or "")
    plain = _BOLD.sub(lambda m: m.group(1), text or "").replace("**", "")
    if len(found) > 2:
        found = []
    return plain, [f.strip() for f in found if f.strip()]


def _mentions_property(text: str, property_text: str) -> bool:
    """공통점이 **이 집의 숫자**를 하나라도 짚었나 — '이_매물'의 금액(값으로 비교) 또는 건수.

    2026-10-24 심사 리뷰: 예전엔 숫자를 **글자 조각**으로 견줘 "4"가 날짜 어디에든 걸려 통과했다.
    이제 `text_guard`와 같은 방식으로 **값**을 읽어 금액(만 원 이상)이나 'N건'이 이 집 재료와 같아야 한다.
    """
    prop = text_guard.collect_allowed(property_text) - {0.0}
    for chunk, value in text_guard.extract_numbers(text):
        if re.search(r"\d", chunk) and value >= 10_000 and text_guard._supported(value, prop):
            return True
    for m in re.finditer(r"(\d+)\s*건", text):
        if float(m.group(1)) in prop:
            return True
    return False


#: 한 줄 안의 문장 경계 — '…요. 다음' / '…다. 다음' (챗봇과 같은 규칙)
_SENTENCE_SPLIT_RE = re.compile(r"(?<=[요다죠까네][.!?])\s+(?=\S)")


def tidy_lines(text: str) -> str:
    """줄바꿈 정리 — 줄마다 앞뒤 공백을 지우고 빈 줄은 없앤다. 한 줄에 문장이 여럿 붙어 오면 **문장마다 줄을 나눈다**
    (2026-10-24 실기기: "…들어왔어요. 이"가 한 줄에 붙었다)."""
    out: list[str] = []
    for ln in (text or "").replace("\r", "").split("\n"):
        ln = ln.strip()
        if ln:
            out.extend(part.strip() for part in _SENTENCE_SPLIT_RE.split(ln) if part.strip())
    return "\n".join(out)


def _digits_only(s: str) -> str:
    return re.sub(r"[,\s]", "", s)


def _numbers_grounded(text: str, source: str) -> bool:
    """글 속 숫자가 전부 입력(source)에 있는가 — 지어낸 금액·비율 차단.

    2026-10-24: 글자 조각 비교 → **값 비교**(`text_guard`와 같은 그물). `4억원`과 `400,000,000`이 같은 수로 읽히고,
    날짜 속 "4"에 우연히 걸려 통과하지 않는다. 한글 수사("두 건")는 보지 않는다.
    """
    allowed = text_guard.collect_allowed(source)
    bad = [c for c in text_guard.unsupported_numbers(text, allowed) if re.search(r"\d", c)]
    return not bad


def _why_not_ok(kind: str, text: str, source: str = "") -> str:
    """`_field_ok`가 왜 떨어뜨렸나 — 이름만(글은 남기지 않는다)."""
    if not text or not text.strip():
        return "빈칸"
    if len(text) > _MAX_LEN[kind]:
        return "길이"
    if text_guard.banned_hit(text) is not None:
        return "금지표현"
    if text_guard.grade_word_hit(text) is not None:
        return "등급단어"
    if not _numbers_grounded(text, source):
        return "숫자"
    return "?"


def _field_ok(kind: str, text: str, source: str = "") -> bool:
    if not text or not text.strip():
        return False
    if len(text) > _MAX_LEN[kind]:
        return False
    if text_guard.banned_hit(text) is not None:
        return False
    if text_guard.grade_word_hit(text) is not None:  # 등급 이름은 리포트 뱃지가 말한다(2026-10-24)
        return False
    if text_guard.legal_fact_hit(text) is not None:  # 누가 먼저 받나 같은 법의 사실(2026-11-01)
        return False
    return _numbers_grounded(text, source)


#: 칸 이름(AI에게 돌려줄 말)
_FIELD_NAME = {"easy_summary": "easy_summary(판례 요약)", "common_point": "common_point(우리 매물과 공통점)",
               "advice": "advice(이런 피해를 피하려면)"}


def _reason_text(kind: str, text: str, source: str, ledger: "fact_ledger.Ledger | None") -> str | None:
    """이 칸이 왜 못 나가나 — **AI에게 돌려줄 쉬운 말**. 통과면 None (2026-11-01 고쳐 쓰기용)."""
    if not _field_ok(kind, text, source):
        why = _why_not_ok(kind, text, source)
        legal = text_guard.legal_fact_hit(text or "")
        if legal:
            return legal[1]
        return {
            "빈칸": "칸이 비었어요",
            "길이": f"{_MAX_LEN[kind]}자를 넘었어요. 더 짧게 써 주세요",
            "금지표현": "'안전해요·문제없어요·걱정 마세요' 같은 단정은 쓸 수 없어요",
            "등급단어": "'양호·확인 필요·위험' 같은 등급 이름은 쓸 수 없어요",
            "숫자": "입력에 없는 숫자를 썼어요. 입력의 '금액_표기'·숫자만 쓰세요",
        }.get(why, "검사에 걸렸어요")
    if kind in ("common_point", "advice"):
        meaning = fact_ledger.check(text, ledger, skip_precedent=True)
        if meaning:
            return meaning
    return None


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


# ── 마지막 호출 결과 (헬스체크 `GET /`의 `precedentExplain`) — 2026-10-24 실기기에서 판례 카드가 전부 폴백(원문 요지 +
#    "결과는 원문을 확인해 주세요")으로 나왔는데 로그 없이는 왜인지 몰랐다. 사건번호·글은 남기지 않고 개수·이유 이름만.
_last: dict = {}


def last_status() -> dict:
    return dict(_last)


def _remember(result: str, *, reason: str = "", kept: int = 0, drops: list[str] | None = None, elapsed: float = 0.0) -> None:
    from datetime import datetime, timedelta, timezone

    _last.clear()
    _last.update(
        {
            "at": datetime.now(timezone(timedelta(hours=9))).strftime("%m-%d %H:%M"),
            "result": result,
            "reason": reason,
            "kept": kept,
            "drops": drops or [],
            "seconds": round(elapsed, 1),
        }
    )


def _vet(
    exp: PrecedentExplanation, source_text: str, property_text: str, ledger: "fact_ledger.Ledger | None"
) -> tuple[PrecedentExplanation | None, dict[str, str], list[str]]:
    """설명 하나 다듬고 검사 → (쓸 설명 | None, 걸린 칸 {칸: AI에게 돌려줄 이유}, 로그용 이름들).

    요약·공통점이 걸리면 카드를 못 쓴다(None). 조언만 걸리면 조언 칸만 버린다(큐레이션 조언으로).
    """
    # 줄바꿈 정리 + `**굵게**` 표시를 떼어 강조 목록(emphasis)으로 옮긴다 — 옛 앱도 굵게를 그린다
    summary, b_sum = split_bold(tidy_lines(exp.easy_summary))
    common, b_com = split_bold(tidy_lines(exp.common_point))
    advice, b_adv = split_bold(tidy_lines(exp.advice)) if exp.advice else (None, [])
    emphasis = {k: v for k, v in (exp.emphasis or {}).items() if k == "result"}
    if b_sum:
        emphasis["easy_summary"] = b_sum
    if b_com:
        emphasis["common_point"] = b_com
    if b_adv:
        emphasis["advice"] = b_adv
    clean = exp.model_copy(update={"easy_summary": summary, "common_point": common, "advice": advice, "emphasis": emphasis})
    failed: dict[str, str] = {}
    notes: list[str] = []
    r = _reason_text("easy_summary", clean.easy_summary, source_text, ledger)
    if r:
        failed["easy_summary"] = r
        notes.append("요약검사:" + _why_not_ok("easy_summary", clean.easy_summary, source_text))
    r = _reason_text("common_point", clean.common_point, source_text, ledger)
    if r:
        failed["common_point"] = r
        notes.append("공통점검사:" + (_why_not_ok("common_point", clean.common_point, source_text)
                                     if not _field_ok("common_point", clean.common_point, source_text) else "숫자뜻"))
    elif not _mentions_property(clean.common_point, property_text):
        # 공통점이 이 집의 숫자를 하나도 짚지 않으면(어느 집에나 맞는 말) 버린다 → 폴백
        failed["common_point"] = "이 집의 숫자(금액·건수·접수일)를 하나 이상 넣어 '이 집도 ~예요'를 써 주세요"
        notes.append("이집숫자없음")
    if failed:
        return None, failed, notes
    if clean.advice:
        r = _reason_text("advice", clean.advice, source_text, ledger)
        if r:
            # 조언만 검사에 걸리면 **조언 칸만** 버린다(요약·공통점은 살린다) → 호출부가 큐레이션 조언으로
            _log.info(f"[Solar/판례] 조언 검사 실패 → 큐레이션 조언으로 ({exp.case_id})")
            clean = clean.model_copy(update={"advice": None})
            notes.append("조언만버림")
    return clean, {}, notes


_REPAIR_NOTE = (
    "\n\n## 고쳐 쓰기\n아래 판례 카드는 화면에 내보내기 전 검사에 걸렸어요. '걸린_칸'의 이유대로 고쳐서 **그 판례만** 다시 써 주세요."
    " 판례는 바꾸지 말고(case_id 그대로), 이 집 숫자는 '이_매물.이_집_숫자표'에 있는 것만 제자리에 쓰세요.\n"
    "출력은 처음과 같은 JSON 모양: {\"cases\": [{\"case_id\": ..., \"easy_summary\": ..., \"common_point\": ..., \"advice\": ...}]}\n"
)


def _repair_cases(
    payload: dict, to_fix: list[tuple[str, dict[str, str], PrecedentExplanation]], api_key: str
) -> dict[str, PrecedentExplanation]:
    """걸린 판례 카드만 한 번 다시 쓰게 한다 → {case_id: 새 설명}. 실패하면 빈 dict."""
    asks = [
        {
            "case_id": cid,
            "처음_쓴_글": {"easy_summary": first.easy_summary, "common_point": first.common_point, "advice": first.advice},
            "걸린_칸": {_FIELD_NAME.get(k, k): v for k, v in failed.items()},
        }
        for cid, failed, first in to_fix
    ]
    ids = {cid for cid, _, _ in to_fix}
    small = dict(payload)
    small["판례_후보"] = [c for c in payload.get("판례_후보", []) if c.get("case_id") in ids]
    messages = [
        {"role": "system", "content": _SYSTEM_PROMPT},
        {"role": "user", "content": json.dumps(small, ensure_ascii=False) + _REPAIR_NOTE + "고칠 카드:\n"
         + json.dumps(asks, ensure_ascii=False)},
    ]
    t0 = time.perf_counter()
    try:
        parsed = _ExplanationList.model_validate(json.loads(_call_solar(messages, api_key)))
    except Exception as e:  # noqa: BLE001 — 고쳐 쓰기는 덤이다
        _log.info(f"[Solar/판례] 고쳐 쓰기 실패 ({type(e).__name__}, {time.perf_counter() - t0:.1f}초)")
        return {}
    out = {c.case_id: c for c in parsed.cases if c.case_id in ids}
    _log.info(f"[Solar/판례] 고쳐 쓰기 {len(ids)}건 요청 → {len(out)}건 받음 ({time.perf_counter() - t0:.1f}초)")
    return out


def explain_matches(
    matches: list[RetrievedPrecedent], verdict_summary: dict, ledger: "fact_ledger.Ledger | None" = None
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
        _remember("폴백", reason="키 없음")
        return {}, "폴백"

    payload = {
        "이_매물": verdict_summary,
        "기준_견본": exemplars(),
        "판례_후보": [
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
    property_text = json.dumps(verdict_summary, ensure_ascii=False)
    messages = [
        {"role": "system", "content": _SYSTEM_PROMPT},
        {"role": "user", "content": source_text},
    ]

    _log.info(f"[Solar/판례] 고르기+설명 호출 — 후보 {len(matches)}건 (⚠ 크레딧 소모)")
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
        _remember("폴백", reason=last_error.split(":")[0], elapsed=time.perf_counter() - t0)
        return {}, "폴백"

    valid_ids = {m.doc.case_id for m in matches}
    dropped = 0
    drops: list[str] = []
    # 고른 순서대로: (case_id, 다듬은 설명 | None, 걸린 칸 {칸: 이유}, 처음 설명)
    vetted: list[tuple[str, PrecedentExplanation | None, dict[str, str], PrecedentExplanation]] = []
    seen_ids: set[str] = set()
    for exp in parsed.cases:
        if exp.case_id not in valid_ids or exp.case_id in seen_ids:
            dropped += 1  # 검색 결과에 없는 판례 언급 → 폐기 (환각 인용 차단)
            drops.append("없는사건")
            continue
        seen_ids.add(exp.case_id)
        clean, failed, note = _vet(exp, source_text, property_text, ledger)
        drops.extend(note)
        vetted.append((exp.case_id, clean, failed, exp))

    # ── 고쳐 쓰기 한 번 (2026-11-01) — 걸린 판례 카드만, 걸린 이유와 함께 다시 쓰게 한다. 다시 쓴 글도 같은 검사를 지나야 쓴다.
    to_fix = [(cid, failed, first) for cid, clean, failed, first in vetted if clean is None and failed]
    if to_fix:
        fixed = _repair_cases(payload, to_fix, api_key)
        for i, (cid, clean, failed, first) in enumerate(vetted):
            again = fixed.get(cid)
            if clean is not None or again is None:
                continue
            clean2, failed2, note2 = _vet(again, source_text, property_text, ledger)
            if clean2 is not None:
                vetted[i] = (cid, clean2, {}, first)
                drops.append("고쳐씀")
            else:
                drops.extend(f"고쳐도:{n}" for n in note2)

    out: dict[str, PrecedentExplanation] = {}
    for cid, clean, failed, _first in vetted:
        if clean is None:
            dropped += 1
            continue
        if len(out) >= MAX_PICK:
            break
        out[cid] = clean

    elapsed = time.perf_counter() - t0
    if not out:
        _log.info(f"[Solar/판례] 사용 가능 설명 0건 → 전체 폴백 ({elapsed:.1f}초) · 이유 {drops}")
        _remember("폴백", reason="쓸 설명 0건", drops=drops, elapsed=elapsed)
        return {}, "폴백"
    missing = len(matches) - len(out)
    source = "AI 생성" if missing == 0 and dropped == 0 else "AI 생성(일부 폴백)"
    _log.info(f"[Solar/판례] 응답 OK ({elapsed:.1f}초) — 설명 {len(out)}건 · 폐기/누락 {dropped + missing}건")
    _remember("AI", kept=len(out), drops=drops, elapsed=elapsed)
    return out, source
