"""챗봇 — **AI가 모든 말을 직접 읽고 답한다. 판정만은 규칙이 막는다** (2026-10-24).

무엇이 바뀌었나 (2026-08-14 '용어 챗봇' → 2026-10-24 '챗봇'):
예전에는 질문이 AI에 닿기 전에 규칙 3단(판정 요구 차단 → 사전 직격 → 부동산 낱말 검사)을 지났다.
그래서 "안녕"·"바보야"·"더 쉽게"가 낱말 검사에서 전부 '준비된 문구'로 막혔고, 사전에 있는 말
("등기부")은 AI를 거치지 않아 "쉽게"를 붙여도 같은 답이 나왔다. 질문 하나 = 답 하나라 앞 대화도
몰랐다. 규혁(2026-10-24): "AI가 아닌 것 같다 — 부스에서 심사위원이 장난을 많이 칠 텐데."

지금 흐름:

    앱이 보낸 최근 대화(최대 8개)
      → 정리: 주민번호·전화번호 꼴 가리기, 길이 자르기
      → 규칙: 마지막 질문이 **판정 요구**인가(정규식) → 맞으면 '조심 모드' 지시를 붙인다
      → Solar: 검수된 용어 풀이 + 판정 기준(thresholds.py 상수)을 참고 자료로 받고 자기 말로 답한다
      → 검사(`text_guard.check_chat_reply`): 금지 표현 · 등급 단어 · 판정 문장 · 근거 없는 숫자 · 인터넷 주소
      → 걸리면 이유를 알려 주고 **한 번 고쳐 쓰게** 한다 → 그래도 걸리면 짧은 기본 문장

⚠ **이 모듈은 판정을 만들지 않는다.** 출력 스키마에 등급·점수·금액 칸이 없고(`ChatAnswer`,
  `extra="forbid"`), 집·계약을 판단하는 문장은 검사에서 떨어진다. 숫자는 사용자가 말한 것과
  판정 기준 상수만 쓸 수 있어, 챗봇과 리포트의 숫자가 갈라지지 않는다.

⚠ 개인정보: 질문 글은 **로그에 남기지 않는다**(길이·분류만). 서버는 대화를 저장하지 않는다 —
  앞 대화는 앱이 매번 보낸다.

LLM이 죽어도(키 없음·타임아웃·`CHATBOT_LLM=off`) 화면은 산다 — 질문에 검수된 용어가 있으면 그 풀이를,
없으면 짧은 안내 문장을 낸다.

2026-10-30 맞춤형 (규혁: "맨날 다 모른다고 한다 — 앱과 내 정보를 모두 아는 나만의 챗봇이 됐으면"):
- 참고 자료를 넓혔다: **이 앱 안내**(`data/chat_facts.json`의 `app`) · **계약 여정**(`data/journey_stages.json`) ·
  **경매 매각가율**(`data/auction_sale_rates.json`).
- **이 사용자 정보**: 서버에 있는 내 집들(가린 사본 — 주소·보증금·등급·열람일·손실 계산)과 폰이 보낸 계약 일정
  (`journeys` — 날짜·여정 진행)을 함께 준다. 일정은 **저장하지 않는다**(대화와 같다 — 이번 답에만 쓴다).
- 막는 것은 **결정 대신 내리기**와 **새 판정 만들기** 둘뿐(CLAUDE.md §2-1). 퍼센트는 AI에게 준 자료에 있는 것만 통과한다.
"""

from __future__ import annotations

import json
import logging
import os
import re
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable, Literal, Optional

from dotenv import load_dotenv
from pydantic import BaseModel, ConfigDict, ValidationError

from . import llm, terms, text_guard, thresholds
from .llm.prompts import (
    CHAT_CAREFUL_ADDENDUM,
    CHAT_ME_ADDENDUM,
    CHAT_REPAIR_MESSAGE,
    CHAT_REPORT_ADDENDUM,
    CHAT_SYSTEM_PROMPT,
)

_log = logging.getLogger("jeonseai")
_BACKEND_ROOT = Path(__file__).resolve().parents[2]

# ── 상수 (인프라 수치 — 판정 임계값 아님) ─────────────────────────────────────

#: 앞 대화를 몇 개까지 보나(질문·답 합쳐서) — 4번 주고받은 만큼
MAX_TURNS = 8
#: 마지막 질문 길이 상한(라우터가 넘으면 400) · 앞 대화 한 개당 자르는 길이
MAX_USER_CHARS = 500
MAX_HISTORY_CHARS = 800
#: 생성 상한 — 목록 답(500자 안)이 JSON 안에서 잘리지 않게 (2026-10-30: 700 → 1000)
MAX_OUTPUT_TOKENS = 1000
#: 대화 온도 — 설명 생성(0.3)보다 조금 높게: 같은 말만 되풀이하지 않고 자연스럽게(2026-10-24 '자율성').
#: 날조는 온도가 아니라 참고 자료 + 출력 검사로 막는다.
CHAT_TEMPERATURE = 0.5

#: 모드
MODE_NORMAL = "normal"
MODE_CAREFUL = "careful"  # 규칙이 판정 요구를 알아챘다
MODE_FALLBACK = "fallback"  # AI 답을 못 냈다 — 아래 기본 문장

# ── 기본 문장 (AI가 답을 못 냈을 때만) ─────────────────────────────────────────

CAREFUL_FALLBACK = (
    "그건 제가 대신 정해 드릴 수 없어요.\n"
    "등기부등본을 찍어 분석하면 규칙으로 판정한 **안전도 리포트**와 근거를 볼 수 있어요.\n"
    "리포트에 나온 낱말이 어려우면 저한테 편하게 물어보세요."
)
RETRY_FALLBACK = "앗, 답을 잘 정리하지 못했어요.\n조금 다르게 한 번 더 물어봐 주시겠어요?"
OFFLINE_FALLBACK = "지금은 AI 연결이 잠깐 불안정해요.\n잠시 뒤에 다시 물어봐 주세요."


# ══════════════════════════════════════════════════════════════════════════════
# 규칙: 판정 요구 알아채기 — 막지 않고 '조심 모드'로 돌린다
# ══════════════════════════════════════════════════════════════════════════════
#
# 비교는 **공백을 지운 문자열**에 대고 한다("계약 해도 돼요" 같은 띄어쓰기 변형).
# ⚠ 2026-10-24: 예전의 '지시 대상'("이 집", "우리 집"만 있어도 거절) 규칙은 뺐다 — "우리 집에
#   가압류가 3억 걸렸다는데 중개사에게 어떻게 물어봐요?" 같은 정당한 질문이 막혔다.
#   이제 판정 요구여도 막지 않고 AI가 '판단 없이' 답하게 하므로, 넓게 잡아도 손해가 작다.

_VERDICT_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        "판단요구",
        re.compile(
            r"계약해도|들어가도|살아도|해도되|계약할까|계약하면|해도괜찮|괜찮나|괜찮을까|괜찮은가"
            r"|안전한가|안전할까|안전한지|위험한가|위험할까|위험한지"
            # '어때요'·'괜찮아?'·'봐줘'·'어떻게 생각해'·'골라 줘'는 **집·계약을 가리킬 때만** —
            # "오늘 기분 어때요"·"카르마 어떻게 생각해"·"끝말잇기 단어 골라 줘"가 조심 모드로 가지 않게(2026-10-24 심사 리뷰 · 2026-10-30 자율성)
            r"|(집|매물|계약|여기|이거|이곳|조건|보증금|가격|전세|월세)\S{0,8}"
            r"(어때|어떤가|괜찮아|괜찮은편|안전한편|봐줘|봐주세요|어떻게보|어떻게생각|골라)"
            r"|낫나요|나을까|추천해|추천좀|믿어도|믿을만|사기인가|사기일까|사기맞|사기야|사기예요\?"
            r"|판단해|판단좀|평가해|몇점|점수매|등급매|등급알려|위험도알려"
            r"|(위험|안전)(해|해요|하나요|한가요|한거야|한거죠)\?|들어가야|계약해야|해야할까|말아야"
        ),
    ),
    (
        "금액조언",
        re.compile(
            r"얼마면|얼마가적당|얼마가적정|얼마정도가|적정가|적당한가격|깎아|깎을|협상|비싼가|비싼편|싸게|싼편"
        ),
    ),
    ("법률자문", re.compile(r"소송|고소|승소|변호사|소장|내용증명|고발|법적으로어떻게")),
)


def _squeeze(text: str) -> str:
    return re.sub(r"\s+", "", text or "")


def verdict_request_hit(query: str) -> str | None:
    """판정·조언 요구면 그 종류, 아니면 None. **AI를 부르기 전에** 규칙이 먼저 본다."""
    squeezed = _squeeze(query)
    for name, pattern in _VERDICT_PATTERNS:
        if pattern.search(squeezed):
            return name
    return None


# ══════════════════════════════════════════════════════════════════════════════
# 정리: 개인정보 꼴 가리기 · 대화 다듬기
# ══════════════════════════════════════════════════════════════════════════════

_RRN_RE = re.compile(r"\d{6}\s*-\s*[1-8]\d{6}")
_PHONE_RE = re.compile(r"0\d{1,2}\s*-?\s*\d{3,4}\s*-?\s*\d{4}")


def mask_personal(text: str) -> str:
    """주민번호·전화번호 꼴을 AI에 보내기 전에 가린다 (이름은 글만 보고 가릴 수 없어 그대로)."""
    text = _RRN_RE.sub("[주민번호 가림]", text or "")
    return _PHONE_RE.sub("[전화번호 가림]", text)


@dataclass(frozen=True)
class Turn:
    role: Literal["user", "assistant"]
    content: str


def _clean_turns(messages: Iterable[dict | Turn]) -> list[Turn]:
    """앱이 보낸 대화 → 최근 `MAX_TURNS`개, 역할 확인, 길이 자르기, 개인정보 꼴 가리기.

    앞 대화의 '답'은 앱이 보낸 것이라 지어낼 수 있다 — 그래도 괜찮다: 그 글로 무엇을 꾀어도
    **나가는 답은 검사를 통과해야** 한다.
    """
    out: list[Turn] = []
    for m in messages:
        role = m.role if isinstance(m, Turn) else (m.get("role") if isinstance(m, dict) else None)
        content = m.content if isinstance(m, Turn) else (m.get("content") if isinstance(m, dict) else None)
        if role not in ("user", "assistant") or not isinstance(content, str):
            continue
        content = content.strip()
        if not content:
            continue
        limit = MAX_USER_CHARS if role == "user" else MAX_HISTORY_CHARS
        out.append(Turn(role, mask_personal(content[:limit])))
    out = out[-MAX_TURNS:]
    while out and out[0].role != "user":  # 앞이 답으로 시작하면 버린다
        out.pop(0)
    return out


# ══════════════════════════════════════════════════════════════════════════════
# 참고 자료 — 검수된 용어 풀이 · 판정 기준
# ══════════════════════════════════════════════════════════════════════════════


def glossary_block() -> str:
    """검수된 용어(`verified=true`)만 — 검수 대기 문장을 근거로 주지 않는다."""
    lines = []
    for t in terms.load():
        alias = f" (= {', '.join(t.aliases)})" if t.aliases else ""
        lines.append(f"· {t.term}{alias}: {t.description}")
    return "\n".join(lines) or "· (없음)"


def criteria_numbers() -> list[float]:
    """판정 기준 숫자 — 챗봇 답에 써도 되는 수(사용자 숫자와 함께). **thresholds.py 상수 그대로.**"""
    ratio = thresholds.PUBLIC_PRICE_TO_HOUSE_PRICE_RATIO
    return [
        thresholds.JEONSE_RATIO_CAUTION_PCT,
        thresholds.JEONSE_RATIO_DANGER_PCT,
        thresholds.SENIOR_DEBT_RATIO_DANGER_PCT,
        thresholds.COMBINED_RATIO_DANGER_PCT,
        round(ratio * 100),
        ratio,
    ]


def criteria_block() -> str:
    """판정 기준 설명 — 숫자는 **코드 상수에서 읽는다**(리포트와 챗봇이 다른 숫자를 말하지 않게)."""
    t = thresholds
    return "\n".join(
        [
            f"· 전세가율(보증금 ÷ 집값): {t.JEONSE_RATIO_CAUTION_PCT}%를 넘으면 '주의', "
            f"{t.JEONSE_RATIO_DANGER_PCT}%를 넘으면 '위험 신호'로 봐요 ({t.JEONSE_RATIO_CAUTION_PCT}%는 한국부동산원 임대차 시장 사이렌의 주의 구간, "
            f"{t.JEONSE_RATIO_DANGER_PCT}%는 HUG 전세보증금반환보증 담보인정비율). "
            f"⚠ {t.JEONSE_RATIO_CAUTION_PCT}%는 '주의'예요 — '위험'이라고 하지 마세요.",
            f"· 선순위 채권(나보다 먼저 받아 가는 빚) ÷ 집값: {t.SENIOR_DEBT_RATIO_DANGER_PCT}%를 넘으면 위험 신호 "
            "(HUG 전세보증 가입 요건).",
            f"· 보증금 + 선순위 채권이 집값의 {t.COMBINED_RATIO_DANGER_PCT}%를 넘으면 위험 신호 (HUG 가입 요건).",
            f"· 집값 시세를 모를 때: 공동주택 공시가격의 {round(t.PUBLIC_PRICE_TO_HOUSE_PRICE_RATIO * 100)}%를 "
            "집값으로 봐요 (HUG 방식).",
            "· 말소된(지워진) 빚은 위험으로 보지 않아요. 정보가 모자라면 '안전'이 아니라 '확인 필요'로 봐요.",
        ]
    )


_FACTS_PATH = _BACKEND_ROOT / "data" / "chat_facts.json"


def _facts_file() -> dict:
    try:
        raw = json.loads(_FACTS_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return raw if isinstance(raw, dict) else {}


def facts_block() -> str:
    """실생활 정보(발급처·수수료·기한 등, 출처 있음) — `data/chat_facts.json`. 팀원이 파일만 고치면 된다."""
    facts = _facts_file().get("facts", [])
    lines = [f"· [{f.get('topic', '')}] {f.get('fact', '')} (출처: {f.get('source', '')})" for f in facts]
    return "\n".join(lines) or "· (없음)"


# ══════════════════════════════════════════════════════════════════════════════
# 참고 자료 — 이 앱 안내 · 계약 여정 · 경매 매각가율 (2026-10-30 "앱의 모든 정보를 알았으면", 규혁)
# ══════════════════════════════════════════════════════════════════════════════


def app_block() -> str:
    """이 앱 안내(기능·쓰는 법·막을 수 있는 위험·요금제·개인정보) — `data/chat_facts.json`의 `app`.

    앱 화면·코드에서 확인한 사실만 적는다. 기능이 바뀌면 이 파일만 고친다(팀원 편집 가능).
    """
    items = _facts_file().get("app", [])
    lines = [f"· [{a.get('topic', '')}] {a.get('fact', '')}" for a in items if isinstance(a, dict) and a.get("fact")]
    return "\n".join(lines) or "· (없음)"


def _plain(text: str | None) -> str:
    """굵게 표시·겹친 공백을 뺀 한 줄."""
    return re.sub(r"\s+", " ", (text or "").replace("**", "")).strip()


def journey_block() -> str:
    """계약 여정 9단계 — 앱 여정 화면과 **같은 파일**(`data/journey_stages.json`)이라 챗봇이 다른 할 일을 말하지 않는다."""
    from . import journey

    lines: list[str] = []
    for i, s in enumerate(journey.load_stages()):
        name = s.chip or s.title
        head = f"{i + 1}단계 {name}" + (f" — {s.title}" if s.title != name else "")
        sub = _plain(s.subtitle)
        lines.append(head + (f" ({sub})" if sub else ""))
        for it in s.items:
            why, where = _plain(it.why), _plain(it.where)
            lines.append(f"   - {it.text}" + (f": {why}" if why else "") + (f" [{where}]" if where else ""))
    return "\n".join(lines) or "· (없음)"


#: 매각가율 표에서 챗봇에게 보여 줄 용도 — 단독·다가구는 앱처럼 소계 한 값으로 (`loss_estimate`가 통건물에 쓰는 값)
_RATE_USES = ("아파트", "연립다세대", "오피스텔", "단독·다가구")


def rates_block() -> str:
    """시·도 × 용도 매각가율 — 손실 시뮬레이터와 **같은 표**(`loss_estimate.load_table`). 숫자는 이 표에서만 나온다."""
    from . import loss_estimate

    table = loss_estimate.load_table()
    if not table.cells:
        return "· (자료 없음 — 매각가율 숫자를 말하지 마세요)"
    regions: list[str] = []
    for region, _use in table.cells:
        if region not in regions:
            regions.append(region)
    lines = [f"(출처: {table.source or '대법원 법원경매정보 매각통계'} · 기간 {table.period or '모름'} · 괄호 = 매각 건수)"]
    for region in regions:
        parts = []
        for use in _RATE_USES:
            cell = table.cells.get((region, use))
            if cell and cell.rate:
                few = ", 표본 적음" if cell.sold < loss_estimate.MIN_SOLD else ""
                parts.append(f"{use} {round(cell.rate * 100, 1)}%({cell.sold:,}건{few})")
        if parts:
            lines.append(f"· {region}: " + " · ".join(parts))
    return "\n".join(lines)


def system_prompt(
    careful: bool,
    report_text: str | None = None,
    me_text: str | None = None,
    today: date | None = None,
) -> str:
    base = CHAT_SYSTEM_PROMPT.format(
        glossary=glossary_block(),
        criteria=criteria_block(),
        facts=facts_block(),
        app=app_block(),
        journey=journey_block(),
        rates=rates_block(),
    )
    me_part = CHAT_ME_ADDENDUM.format(today=_long_date(today or today_kst()), me=me_text) if me_text else ""
    report_part = CHAT_REPORT_ADDENDUM.format(report=report_text) if report_text else ""
    return base + me_part + report_part + (CHAT_CAREFUL_ADDENDUM if careful else "")


# ══════════════════════════════════════════════════════════════════════════════
# 이 사용자 정보 — 내 집(서버의 가린 사본) + 계약 일정(폰이 보낸 것, 저장 안 함) (2026-10-30)
# ══════════════════════════════════════════════════════════════════════════════
#
# 왜: "내 계약 여정 너는 못 읽어?"에 "개인 정보를 읽을 수 없어요"가 나왔다(실기기 2026-10-30). 리포트는 읽으면서
# 일정은 모르니 "다음에 뭐 해?"에 늘 '계약 전' 일반론만 했다. 규혁: "등기부 분석도 시키는데 잔금이 내일인 걸
# 얘가 알아서 뭘 하겠니" → 일정은 **답을 쓰는 동안만** 보낸다(서버는 저장·로그 안 함, 폰 저장은 그대로).
# 집 목록·숫자는 서버의 **가린 사본**이라 설명용 LLM 입력에 실명이 없다(§2-5). 주소는 넣는다(규혁 결정).

KST = timezone(timedelta(hours=9))
_WEEKDAYS = "월화수목금토일"
#: 폰이 보내는 일정 칸 → 이름 (앱 `JourneyDateKey`와 같은 이름 · 이사 다음 날은 서버가 계산한다)
DATE_KEYS: dict[str, str] = {"downPayment": "가계약금", "contract": "계약서", "balance": "잔금", "moveIn": "이사"}
#: 자세히 적는 집 수 — 넘으면 별칭만 (부스 폰처럼 집이 많을 때 지시문이 끝없이 길어지지 않게)
MAX_HOUSES_DETAILED = 8
#: '다음 단계 할 일'까지 적는 집 수
MAX_HOUSES_WITH_TODO = 3


def today_kst() -> date:
    return datetime.now(KST).date()


def _long_date(d: date) -> str:
    return f"{d.year}년 {d.month}월 {d.day}일 ({_WEEKDAYS[d.weekday()]})"


def _md(d: date) -> str:
    return f"{d.month}/{d.day}({_WEEKDAYS[d.weekday()]})"


def _when(d: date, today: date) -> str:
    n = (d - today).days
    if n == 0:
        return "오늘"
    if n == 1:
        return "내일, D-1"
    if n > 1:
        return f"{n}일 뒤, D-{n}"
    return f"{-n}일 지남"


def _iso_date_kst(iso: str | None) -> date | None:
    """ISO 시각 → 한국 날짜 (못 읽으면 None)."""
    if not iso:
        return None
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt.astimezone(KST).date() if dt.tzinfo else dt.date()


def _registry_date(viewed: str | None) -> date | None:
    """등기부 열람일 'YYYY.MM.DD' → 날짜 (못 읽으면 None)."""
    m = re.match(r"\s*(\d{4})\D+(\d{1,2})\D+(\d{1,2})", viewed or "")
    if not m:
        return None
    try:
        return date(int(m[1]), int(m[2]), int(m[3]))
    except ValueError:
        return None


@dataclass(frozen=True)
class JourneyIn:
    """폰이 보낸 한 집의 계약 일정 — **이번 답에만** 쓴다(서버는 저장하지 않는다)."""

    report_id: str  # 그 집의 최신 리포트 id — 서버의 '내 집' 묶음에서 같은 집을 찾는 열쇠
    dates: dict[str, date] = field(default_factory=dict)  # downPayment|contract|balance|moveIn
    done_through: int = 0  # 끝난 마지막 단계 번호(0 = 분석만) — 앱 여정 계산(JourneyProgress.doneThrough) 그대로
    selected: bool = False  # 계약 여정에서 고른 집


def parse_journeys(raw: Iterable[Any] | None) -> list[JourneyIn] | None:
    """앱이 보낸 `journeys` → 정리된 목록. **None = 옛 앱이라 일정을 모른다** · [] = 넣은 일정이 없다.

    날짜 칸 이름·형식이 틀린 것은 조용히 버린다(그 칸만).
    """
    if raw is None:
        return None
    out: list[JourneyIn] = []
    for item in raw:
        data = item.model_dump() if hasattr(item, "model_dump") else item
        if not isinstance(data, dict):
            continue
        rid = data.get("reportId")
        if not isinstance(rid, str) or not rid.strip():
            continue
        dates: dict[str, date] = {}
        for key, value in (data.get("dates") or {}).items():
            if key in DATE_KEYS and isinstance(value, str):
                try:
                    dates[key] = date.fromisoformat(value.strip()[:10])
                except ValueError:
                    continue
        done = data.get("doneThrough")
        done_i = done if isinstance(done, int) and not isinstance(done, bool) else 0
        out.append(JourneyIn(rid.strip(), dates, done_i, bool(data.get("selected"))))
    return out


@dataclass
class House:
    """같은 집 분석들(최신순) — 앱 '내 집' 카드 하나. 보이는 리포트는 늘 최신 1개."""

    reports: list

    @property
    def latest(self):
        return self.reports[0]

    @property
    def first(self):
        return self.reports[-1]

    @property
    def ids(self) -> set[str]:
        return {r.id for r in self.reports}


def group_houses(reports: Iterable) -> list[House]:
    """이력(최신순) → 집 묶음(최근에 분석한 집부터). 앱 `groupByProperty`·`store.same_property`와 같은 규칙."""
    from . import store

    groups: list[list] = []
    for r in reports:
        home = None
        for g in groups:
            if any(store.same_property(x, r) for x in g) and not any(
                x.propertyId and r.propertyId and x.propertyId != r.propertyId for x in g
            ):
                home = g
                break
        if home is None:
            groups.append([r])
        else:
            home.append(r)
    return [House(g) for g in groups]


def _address(report) -> str:
    raw = _plain((report.propertyAddress or report.address or "").replace("[집합건물]", ""))
    if not raw or raw.replace(" ", "").startswith("주소미확인"):
        return "못 읽음"
    return raw[:120]


def _loss_line(report) -> str:
    """손실 시뮬레이터(리포트 2장)와 같은 규칙 계산 한 줄 — AI가 숫자를 만들지 않게 계산을 그대로 준다."""
    from . import loss_estimate

    try:
        est = loss_estimate.estimate(report)
    except Exception:  # noqa: BLE001 — 계산을 못 해도 나머지 정보로 답한다
        return ""
    if est.status == "debt_exceeds":
        return "· 경매로 넘어가면(손실 시뮬레이터): 먼저 갚을 빚이 집값 이상이라 돌려받을 돈이 0원으로 계산돼요"
    if est.ratePct is None:
        return ""
    where = f"{est.region}{'(지역 표본이 적어 전국 값)' if est.regionFallback else ''} {est.use}"
    if est.status == "ok":
        return (
            f"· 경매로 넘어가면(손실 시뮬레이터): {where} 매각가율 {est.ratePct}% → 예상 낙찰가 {_won(est.expectedSale)}"
            f" · 돌려받을 돈 {_won(est.expectedReturn)} · 못 돌려받는 돈 {_won(est.expectedLoss)}"
        )
    return f"· 이 집 지역·용도의 매각가율: {where} {est.ratePct}% (시세가 없어 손실 계산은 안 됨)"


def _stage_date(stage, j: JourneyIn) -> date | None:
    key = getattr(stage, "dateKey", None)
    if key == "moveInNext":
        move_in = j.dates.get("moveIn")
        return move_in + timedelta(days=1) if move_in else None
    return j.dates.get(key) if key else None


def _journey_lines(j: JourneyIn | None, stages: list, today: date, *, with_todo: bool) -> list[str]:
    if j is None or (not j.dates and j.done_through <= 0):
        return ["· 계약 일정: 아직 넣지 않았어요 (계약 여정에서 날짜를 넣을 수 있어요)"]
    parts = [
        f"{label} {_md(d)} {_when(d, today)}" if (d := j.dates.get(key)) else f"{label} 안 넣음"
        for key, label in DATE_KEYS.items()
    ]
    lines = ["· 계약 일정: " + " · ".join(parts)]
    if not stages:
        return lines
    done = max(0, min(j.done_through, len(stages) - 1))
    nxt = done + 1
    if nxt < len(stages):
        s = stages[nxt]
        d = _stage_date(s, j)
        when = f" ({_md(d)}, {_when(d, today)})" if d else ""
        lines.append(f"· 계약 여정: {done + 1}단계 '{stages[done].title}'까지 끝 → 다음은 {nxt + 1}단계 '{s.title}'{when}")
        if with_todo and s.items:
            todo = " / ".join(it.text + (f"({_plain(it.why)[:70]})" if it.why else "") for it in s.items)
            lines.append(f"· 다음 단계 할 일: {todo}")
    else:
        lines.append(f"· 계약 여정: {len(stages)}단계를 모두 마쳤어요")
    for i in range(nxt, len(stages)):
        if stages[i].compare:
            d = _stage_date(stages[i], j)
            when = f" ({_md(d)}, {_when(d, today)})" if d else ""
            lines.append(f"· 다음에 등기부를 다시 떼서 대조할 때: {i + 1}단계 '{stages[i].title}'{when}")
            break
    return lines


def me_block(
    houses: list[House] | None,
    journeys: list[JourneyIn] | None,
    *,
    focus_id: str | None = None,
    today: date | None = None,
    stages: list | None = None,
) -> tuple[str, set[str]]:
    """이 사용자 정보 글 + 그 글에 나온 등급들(챗봇이 그대로 전할 수 있는 것).

    `houses`: 서버의 내 집 묶음(None = 이번에 확인 못 함) · `journeys`: 폰이 보낸 일정(None = 옛 앱).
    """
    today = today or today_kst()
    if stages is None:
        from . import journey

        stages = journey.load_stages()
    grades: set[str] = set()
    lines: list[str] = []
    if houses is None:
        lines.append("· 내 집: 이번에는 확인하지 못했어요 (홈의 '내 집'에서 볼 수 있어요)")
    elif not houses:
        lines.append("· 내 집: 아직 없어요 (홈에서 등기부를 찍어 분석하면 리포트와 '내 집'이 생겨요)")
    else:
        # 등록 순서 = 처음 분석한 순서 ('두 번째로 등록한 집'을 물을 때)
        order = sorted(range(len(houses)), key=lambda i: houses[i].first.analyzedAt or "")
        number = {i: n + 1 for n, i in enumerate(order)}
        detailed = set(range(min(len(houses), MAX_HOUSES_DETAILED)))  # 최근에 분석한 집부터
        by_id = {}
        for j in journeys or []:
            by_id.setdefault(j.report_id, j)

        def journey_of(h: House) -> JourneyIn | None:
            return next((by_id[i] for i in [r.id for r in h.reports] if i in by_id), None)

        # '다음 단계 할 일'은 여정에서 고른 집 → 보고 있는 리포트의 집 → 최근 집 순으로 몇 곳만
        priority = sorted(
            [i for i in detailed if journey_of(houses[i]) is not None],
            key=lambda i: (
                not journey_of(houses[i]).selected,
                not (focus_id and focus_id in houses[i].ids),
                i,
            ),
        )
        with_todo = set(priority[:MAX_HOUSES_WITH_TODO])

        lines.append(f"내 집 {len(houses)}곳 (같은 집을 여러 번 분석해도 한 곳 · 등록 순서 = 처음 분석한 순서)")
        if journeys is None:
            lines.append("· 계약 일정·여정 진행: 이번 질문에는 함께 오지 않았어요 — 물으면 계약 여정 화면에서 확인해 달라고 하세요")
        others: list[str] = []
        for i in order:
            h = houses[i]
            r = h.latest
            alias = _plain(r.alias)[:40] or "이름 없음"
            grades.add(r.grade)
            if i not in detailed:
                others.append(f"{number[i]}번째 '{alias}'({r.grade})")
                continue
            grades.update(e.grade for e in r.evidences)
            j = journey_of(h)
            flags = []
            if i == 0:
                flags.append("가장 최근에 분석한 집")
            if focus_id and focus_id in h.ids:
                flags.append("지금 보고 있는 리포트 — 아래에 자세히")
            if j is not None and j.selected:
                flags.append("계약 여정에서 고른 집")
            lines.append(f"[{number[i]}번째로 등록한 집] '{alias}'" + (f" ({' · '.join(flags)})" if flags else ""))
            lines.append(f"· 주소: {_address(r)}")
            lines.append(f"· 리포트 결과(규칙 엔진): {r.grade}" + (f" — {_plain(r.headline)}" if r.headline else ""))
            if r.topRiskSummary:
                lines.append(f"· 가장 큰 위험: {_plain(r.topRiskSummary)}")
            if r.evidences:
                lines.append("· 근거 카드: " + " / ".join(f"{_plain(e.termSubtitle or e.title)}: {e.grade}" for e in r.evidences))
            lines.append(
                f"· 보증금 {_won(r.deposit)} · 집값(시세) {_won(r.marketPrice)} · 먼저 받아 갈 빚 합계 {_won(r.seniorDebtAmount)}"
            )
            viewed = _registry_date(r.registryViewedAt)
            analyzed = _iso_date_kst(r.analyzedAt)
            age = (today - viewed).days if viewed else None
            # 날짜를 잘못 읽어 오늘보다 뒤면 며칠 전인지 말하지 않는다(지어내지 않는다)
            age_text = "" if age is None or age < 0 else (" (오늘 뗀 서류)" if age == 0 else f" ({age}일 전에 뗀 서류)")
            reg = f"· 등기부 열람일 {r.registryViewedAt}{age_text}" if r.registryViewedAt else "· 등기부 열람일: 못 읽음"
            if analyzed:
                reg += f" · 마지막 분석 {analyzed.isoformat()}"
            if len(h.reports) > 1:
                reg += f" · 이 집 분석 {len(h.reports)}번"
            lines.append(reg)
            if loss := _loss_line(r):
                lines.append(loss)
            if journeys is not None:
                lines.extend(_journey_lines(j, stages, today, with_todo=i in with_todo))
        if others:
            lines.append("· 그 밖의 집: " + " · ".join(others))
    return "\n".join(lines), grades


# ══════════════════════════════════════════════════════════════════════════════
# 사용자의 리포트 (2026-10-26 — "챗봇이 내 리포트를 알아야 맞춤으로 답한다", 규혁)
# ══════════════════════════════════════════════════════════════════════════════
#
# 재료는 **서버에 남은 가린 사본**(`store.get` — 사람 이름 `홍○○`)이다 → 설명용 LLM 입력에 실명이 없다(CLAUDE.md §2-5).
# 리포트의 등급·근거는 **규칙 엔진이 이미 낸 결과**라, 챗봇은 그것을 전하고 풀어 줄 뿐 바꾸거나 새로 만들지 않는다(§2-1).


def _won(v: int | None) -> str:
    """원 → '1억 2,000만원' 꼴 (없으면 '모름')."""
    if v is None:
        return "모름"
    if v == 0:
        return "0원"
    eok, man = divmod(int(v) // 10_000, 10_000)
    parts = ([f"{eok}억"] if eok else []) + ([f"{man:,}만"] if man else [])
    return (" ".join(parts) or "0") + "원"


def report_block(report) -> tuple[str, list[float]]:
    """리포트 → (AI에게 줄 글, 그 글에 나온 숫자들). 숫자는 답에 써도 되는 수로 더한다."""
    lines = [
        f"· 매물: {report.alias}",
        f"· 종합 판정(규칙 엔진 결과): {report.grade} — {report.headline}",
        f"· 가장 큰 위험: {report.topRiskSummary}" if report.topRiskSummary else "",
        f"· 다음 할 일(리포트 안내): {report.nextAction}" if report.nextAction else "",
        f"· 보증금 {_won(report.deposit)} · 집값(시세) {_won(report.marketPrice)}"
        + (f" (기준일 {report.marketPriceAsOf})" if report.marketPrice and report.marketPriceAsOf else "")
        + f" · 나보다 먼저 받아 가는 빚(선순위 채권) 합계 {_won(report.seniorDebtAmount)}",
        f"· 등기부를 뗀 날(열람일): {report.registryViewedAt}" if report.registryViewedAt else "",
        "· 근거 카드:",
    ]
    for e in report.evidences:
        detail = " ".join(x for x in (e.statusLabel, e.easyExplanation, e.detailText) if x)
        lines.append(f"  - {e.title}: {e.grade} — {detail[:300]}")
    if report.riskFacts:
        lines.append("· 등기부에서 찾은 위험 항목:")
        for f in report.riskFacts[:8]:
            amount = f", 금액 {_won(f.amount)}" if f.amount else ""
            when = f", 접수 {f.receiptDate}" if f.receiptDate else ""
            holder = f", 권리자 {f.holder}" if f.holder else ""
            lines.append(f"  - {f.kind}{when}{amount}{holder}")
    if report.checkedNotes:
        lines.append("· 확인 메모: " + " / ".join(n.replace("**", "") for n in report.checkedNotes[:6]))
    text = "\n".join(x for x in lines if x)
    numbers = [value for _, value in text_guard.extract_numbers(text)]
    return text, numbers


def report_grades(report) -> set[str]:
    """리포트에 실제로 나온 등급 글자들(종합 + 근거 카드) — 챗봇이 그대로 전할 수 있는 것."""
    return {report.grade, *(e.grade for e in report.evidences)}


# ══════════════════════════════════════════════════════════════════════════════
# AI 출력 스키마 · 결과
# ══════════════════════════════════════════════════════════════════════════════


class ChatAnswer(BaseModel):
    """챗봇 답 슬롯. **등급·점수·확률·금액 칸이 존재하지 않는다** — 리포트와 같은 경계.

    `extra="forbid"`라 모델이 `grade` 같은 키를 실어 보내면 검증에서 떨어진다.
    `kind`는 로그용 분류(인사/부동산/상관없음/판단요구) — 화면에도, 판정에도 쓰지 않는다.
    """

    model_config = ConfigDict(extra="forbid")

    answer: str = ""
    kind: Optional[str] = None


@dataclass
class ChatReply:
    """화면에 그대로 그릴 한 덩어리 (계약 §3.21)."""

    answer: str  # `**굵게**` 표시가 들어 있을 수 있다(앱이 굵게 그린다)
    mode: str = MODE_NORMAL
    model: str = ""  # 실제로 답을 쓴 모델 — 기본 문장이면 빈 문자열
    #: 로그·테스트용 — 응답에는 나가지 않는다
    llm_calls: int = 0
    layer: str = ""
    kind: str | None = None

    @property
    def plain(self) -> str:
        """굵게 표시를 뺀 글 — 옛 앱(`GET /api/glossary/lookup`)용."""
        return self.answer.replace("**", "")

    # ── 옛 계약(§3.9) 호환 이름 ──
    @property
    def out_of_scope(self) -> bool:
        return False

    @property
    def source(self) -> str:
        return self.model

    @property
    def llm_called(self) -> bool:
        return self.llm_calls > 0


_OFF_VALUES = {"off", "none", "disabled", "no", "false", "0"}


def llm_enabled() -> bool:
    """`.env`의 `CHATBOT_LLM` — `off`면 AI를 통째로 건너뛴다(비상 스위치: 용어 풀이 + 안내 문장만)."""
    load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")
    raw = (os.environ.get("CHATBOT_LLM", "") or "on").strip().lower()
    return raw not in _OFF_VALUES


# ══════════════════════════════════════════════════════════════════════════════
# 답 다듬기 — 굵게 표시·나열 기호 정리 (검사 전에 한다)
# ══════════════════════════════════════════════════════════════════════════════

MAX_BOLD_SPANS = 3


#: 이모지·그림 문자 — 말투 규칙(이모지 없음)을 코드로 지킨다(실측 2026-10-24: 😊가 나왔다)
_EMOJI_RE = re.compile("[\U0001F000-\U0001FAFF\u2600-\u27BF\uFE0F\u200D]")
#: 한 줄 안의 문장 경계 — '…요. 다음' / '…다. 다음' / '…요? 다음'
_SENTENCE_SPLIT_RE = re.compile(r"(?<=[요다죠까네][.!?])\s+(?=\S)")


def tidy(text: str) -> str:
    """모양만 고친다(뜻은 그대로).

    - 마크다운 나열·제목 → '· ' · 이모지 삭제 · 빈 줄 삭제
    - 나열이 아닌 줄에 문장이 여럿 붙어 있으면 **문장마다 줄을 나눈다**(한 줄 한 문장 — 실측 2026-10-24)
    - 짝이 안 맞거나 너무 많은 굵게는 뺀다
    """
    lines: list[str] = []
    for line in _EMOJI_RE.sub("", (text or "").replace("\r\n", "\n")).split("\n"):
        s = line.strip()
        s = re.sub(r"^#{1,6}\s*", "", s)
        s = re.sub(r"^[-*•]\s+", "· ", s)
        s = re.sub(r"\s{2,}", " ", s)
        if not s:
            continue
        if s.startswith("· "):
            lines.append(s)
        else:
            lines.extend(part.strip() for part in _SENTENCE_SPLIT_RE.split(s) if part.strip())
    out = "\n".join(lines)
    marks = out.count("**")
    if marks % 2 == 1 or marks // 2 > MAX_BOLD_SPANS:
        out = out.replace("**", "")
    return out


def criteria_mixup(text: str) -> str | None:
    """판정 기준 숫자를 **다른 단계 이름**으로 말했나 — '80%를 넘으면 위험'(우리 기준은 80% 주의·90% 위험).

    숫자가 허용 목록에 있어도 짝이 틀리면 리포트와 말이 갈라진다(실측 2026-10-24).
    """
    caution = thresholds.JEONSE_RATIO_CAUTION_PCT
    for m in re.finditer(rf"(?<!\d){caution}\s*%", text):
        window = text[m.end() : m.end() + 20]
        if "위험" in window and "주의" not in window:
            return f"{caution}%는 '주의' 기준이에요. '위험'은 {thresholds.JEONSE_RATIO_DANGER_PCT}%예요"
    return None


# ══════════════════════════════════════════════════════════════════════════════
# 본체
# ══════════════════════════════════════════════════════════════════════════════


#: "뭐야·뜻" 같은 **뜻을 묻는 질문**일 때만 사전 풀이로 떨어진다 — "어디서 떼요?"에 뜻 풀이가 나가면 동문서답이다(2026-10-24 실기기)
_MEANING_RE = re.compile(r"뭐|무엇|뜻|의미|이란|란\?|설명|알려|쉽게|모르")


def _dictionary_fallback(question: str, careful: bool) -> ChatReply | None:
    if careful:
        return None
    q = question.strip()
    found = terms.lookup(q)
    if found is None:
        return None
    is_bare_term = len(_squeeze(q)) <= len(_squeeze(found.term)) + 2
    if not (is_bare_term or _MEANING_RE.search(q)):
        return None
    if found is None:
        return None
    return ChatReply(answer=found.description, mode=MODE_FALLBACK, layer="폴백-용어풀이")


def _fallback(question: str, careful: bool, *, layer: str, text: str, llm_calls: int = 0) -> ChatReply:
    if careful:
        return ChatReply(answer=CAREFUL_FALLBACK, mode=MODE_FALLBACK, layer=layer, llm_calls=llm_calls)
    hit = _dictionary_fallback(question, careful)
    if hit is not None:
        hit.layer = f"{layer}→용어풀이"
        hit.llm_calls = llm_calls
        return hit
    return ChatReply(answer=text, mode=MODE_FALLBACK, layer=layer, llm_calls=llm_calls)


# ── 운영 통계 (헬스체크 `GET /`의 `chat`) — 서버가 켜진 뒤로 몇 번 AI가 바로 답했고, 고쳐 썼고,
#    기본 문장으로 떨어졌는지 + 최근 검사에 걸린 이유(분류 이름만 — 사용자 글은 없다). 2026-10-24
_stats = {"ai": 0, "repaired": 0, "fallback": 0}
_recent_rejects: list[str] = []


def _record(r: ChatReply) -> ChatReply:
    key = "fallback" if r.mode == MODE_FALLBACK else ("repaired" if r.layer == "AI-고쳐씀" else "ai")
    _stats[key] += 1
    return r


def _record_reject(code: str) -> None:
    _recent_rejects.append(code)
    del _recent_rejects[:-20]


def stats() -> dict:
    return {**_stats, "recentRejects": list(_recent_rejects)}


def reply(
    messages: Iterable[dict | Turn],
    report=None,
    *,
    houses: Iterable | None = None,
    journeys: Iterable[Any] | None = None,
) -> ChatReply:
    """최근 대화 → 화면에 그릴 답. **어떤 실패에도 예외를 던지지 않는다.**

    `report`: 사용자가 보던 리포트(서버의 가린 사본, `contract.Report`) — 있으면 그 내용을 알고 답한다(2026-10-26).
    `houses`: 이 사용자의 이력(가린 사본, 최신순 — `store.list_reports`). None = 확인 못 함(2026-10-30).
    `journeys`: 폰이 보낸 계약 일정(`ChatJourney` 목록). None = 옛 앱이라 일정을 모른다(2026-10-30).
    """
    return _record(_reply(messages, report, houses=houses, journeys=journeys))


def _me(report, houses, journeys) -> tuple[str | None, set[str]]:
    """이 사용자 정보 글(없으면 None) + 등급들. 실패하면 정보 없이 답한다."""
    if houses is None and journeys is None:
        return None, set()
    try:
        grouped = group_houses(houses) if houses is not None else None
        parsed = parse_journeys(journeys)
        text, grades = me_block(grouped, parsed, focus_id=report.id if report is not None else None)
        _log.info(
            f"[챗봇] 내 정보를 알고 답함 — 집 {len(grouped) if grouped is not None else '?'}곳"
            f" · 일정 {len(parsed) if parsed is not None else '?'}곳"
        )
        return text, grades
    except Exception as e:  # noqa: BLE001 — 내 정보 글을 못 만들면 그것 없이 답한다
        _log.info(f"[챗봇] 내 정보 글 만들기 실패 — 그것 없이 답함 ({type(e).__name__})")
        return None, set()


def _reply(messages: Iterable[dict | Turn], report=None, *, houses=None, journeys=None) -> ChatReply:
    turns = _clean_turns(messages)
    if not turns or turns[-1].role != "user":
        return ChatReply(answer=RETRY_FALLBACK, mode=MODE_FALLBACK, layer="빈질문")
    question = turns[-1].content

    hit = verdict_request_hit(question)
    careful = hit is not None
    if careful:
        _log.info(f"[챗봇] 규칙: 판정 요구({hit}) → 조심 모드 | 질문 {len(question)}자")

    if not llm_enabled():
        _log.info("[챗봇] CHATBOT_LLM=off — AI 건너뜀(용어 풀이·안내 문장)")
        return _fallback(question, careful, layer="AI꺼짐", text=OFFLINE_FALLBACK)

    try:
        return _generate(turns, careful, report, houses=houses, journeys=journeys)
    except Exception as e:  # noqa: BLE001 — 구조적 방어선: 챗봇이 화면을 깨뜨리지 않는다
        _log.error(f"[챗봇] ⚠ 예기치 못한 예외 — 기본 문장으로 ({type(e).__name__})", exc_info=True)
        return _fallback(question, careful, layer="예외", text=OFFLINE_FALLBACK, llm_calls=1)


def answer(query: str) -> ChatReply:
    """질문 하나 → 답 하나. 옛 주소(`GET /api/glossary/lookup`)·도구용."""
    return reply([{"role": "user", "content": query or ""}])


def _parse(payload: dict) -> tuple[str | None, str | None, str]:
    """AI 응답 → (답, 분류, 실패 사유). 성공이면 사유가 빈 문자열."""
    try:
        parsed = ChatAnswer.model_validate(payload)
    except ValidationError:
        return None, None, "정해진 JSON 모양({\"answer\": ..., \"kind\": ...})이 아니에요"
    return tidy(parsed.answer), parsed.kind, ""


def _generate(turns: list[Turn], careful: bool, report=None, *, houses=None, journeys=None) -> ChatReply:
    question = turns[-1].content
    provider = llm.chat_provider()
    if not provider.available:
        _log.info(f"[챗봇:{provider.name}] API 키 없음 — 기본 문장")
        return _fallback(question, careful, layer="키없음", text=OFFLINE_FALLBACK)

    report_text, report_numbers, report_set = None, [], None
    if report is not None:
        try:
            report_text, report_numbers = report_block(report)
            report_set = report_grades(report)
            _log.info(f"[챗봇] 리포트를 알고 답함 — 등급 {report.grade} · 근거 {len(report.evidences)}개")
        except Exception as e:  # noqa: BLE001 — 리포트 글을 못 만들면 리포트 없이 답한다
            _log.info(f"[챗봇] 리포트 글 만들기 실패 — 리포트 없이 답함 ({type(e).__name__})")
            report_text, report_numbers, report_set = None, [], None
    me_text, me_grades = _me(report if report_text else None, houses, journeys)
    # 전할 수 있는 등급 = 리포트 + 내 집들이 실제로 낸 것. 둘 다 없으면 등급 이름 자체를 못 쓴다(예전과 같다)
    grades = (report_set or set()) | me_grades if (report_set is not None or me_text) else None
    system = system_prompt(careful, report_text, me_text)
    history = [{"role": t.role, "content": t.content} for t in turns[:-1]]
    # 답에 써도 되는 퍼센트 = 사용자가 말한 수 + 판정 기준 + 리포트 + **AI에게 준 자료에 퍼센트로 나온 수**
    # (실생활 정보·앱 안내·여정·내 집). 2026-10-30: 예전엔 '계약갱신 5%'처럼 실생활 정보의 퍼센트도 걸렸다.
    # 경매 매각가율 표는 36~96%를 촘촘히 덮어서 **매각가율을 말하는 문장에서만** 근거로 쓴다(text_guard.RATE_CONTEXT_RE).
    rates_text = rates_block()
    allowed = text_guard.chat_allowed_numbers(
        [t.content for t in turns if t.role == "user"],
        [*criteria_numbers(), *report_numbers, *text_guard.percent_values(system.replace(rates_text, ""))],
    )
    rate_context = [(text_guard.RATE_CONTEXT_RE, text_guard.percent_values(rates_text))]
    user_msg = question
    calls = 0
    last_reason = ""
    for attempt in (1, 2):  # 처음 + 한 번 고쳐 쓰기
        try:
            payload, resp = provider.chat_json(
                system,
                user_msg,
                max_tokens=MAX_OUTPUT_TOKENS,
                temperature=CHAT_TEMPERATURE,
                history=history,
            )
        except llm.LlmError as e:
            calls += 1
            _log.info(f"[챗봇:{provider.name}] 호출 실패 → 기본 문장 ({str(e)[:80]})")
            return _fallback(question, careful, layer="호출실패", text=OFFLINE_FALLBACK, llm_calls=calls)
        calls += 1

        text, kind, why = _parse(payload)
        code = "스키마" if why else ""
        if not why:
            verdict = text_guard.check_chat_reply(
                text or "",
                allowed=allowed,
                careful=careful,
                report_grades=grades,
                quote_report=report_set is not None,
                context_numbers=rate_context,
            )
            if verdict is None:
                mix = criteria_mixup(text or "")
                verdict = ("기준혼동", mix) if mix else None
            if verdict is None:
                _log.info(
                    f"[챗봇:{provider.name}] 답 {'(고쳐 쓴 뒤) ' if attempt == 2 else ''}통과"
                    f" · {'조심' if careful else '보통'} · 분류 {kind or '-'}"
                    f" · {resp.elapsed:.1f}초 · {len(text or '')}자"
                )
                return ChatReply(
                    answer=text or "",
                    mode=MODE_CAREFUL if careful else MODE_NORMAL,
                    model=resp.model or provider.model,
                    llm_calls=calls,
                    layer="AI" if attempt == 1 else "AI-고쳐씀",
                    kind=kind,
                )
            code, why = verdict
        last_reason = code
        _record_reject(code)
        _log.info(f"[챗봇:{provider.name}] 검사 걸림({code}) — {'고쳐 쓰게 함' if attempt == 1 else '기본 문장'}")
        # 고쳐 쓰기: 방금 답을 대화에 넣고, 이유를 알려 준다
        history = history + [
            {"role": "user", "content": user_msg},
            {"role": "assistant", "content": resp.text[:MAX_HISTORY_CHARS]},
        ]
        user_msg = CHAT_REPAIR_MESSAGE.format(reason=why)

    return _fallback(
        question,
        careful,
        layer=f"검사실패-{last_reason}",
        text=RETRY_FALLBACK,
        llm_calls=calls,
    )
