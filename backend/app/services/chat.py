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
"""

from __future__ import annotations

import logging
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Literal, Optional

from dotenv import load_dotenv
from pydantic import BaseModel, ConfigDict, ValidationError

from . import llm, terms, text_guard, thresholds
from .llm.prompts import CHAT_CAREFUL_ADDENDUM, CHAT_REPAIR_MESSAGE, CHAT_SYSTEM_PROMPT

_log = logging.getLogger("jeonseai")
_BACKEND_ROOT = Path(__file__).resolve().parents[2]

# ── 상수 (인프라 수치 — 판정 임계값 아님) ─────────────────────────────────────

#: 앞 대화를 몇 개까지 보나(질문·답 합쳐서) — 4번 주고받은 만큼
MAX_TURNS = 8
#: 마지막 질문 길이 상한(라우터가 넘으면 400) · 앞 대화 한 개당 자르는 길이
MAX_USER_CHARS = 500
MAX_HISTORY_CHARS = 800
#: 생성 상한
MAX_OUTPUT_TOKENS = 600

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
            r"|안전한가|안전할까|안전한지|위험한가|위험할까|위험한지|어떻게보|어떻게생각"
            # '어때요'·'괜찮아?'는 **집·계약을 가리킬 때만** — "오늘 기분 어때요"가 조심 모드로 가지 않게(2026-10-24 심사 리뷰)
            r"|(집|매물|계약|여기|이거|이곳|조건|보증금|가격|전세|월세)\S{0,8}(어때|어떤가|괜찮아|괜찮은편|안전한편)"
            r"|낫나요|나을까|추천해|추천좀|골라|골라줘|믿어도|믿을만|사기인가|사기일까|사기맞|사기야|사기예요\?"
            r"|판단해|판단좀|평가해|봐주세요|봐줘|몇점|점수매|등급매|등급알려|위험도알려"
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
            f"{t.JEONSE_RATIO_DANGER_PCT}%를 넘으면 '위험 신호'로 봐요 (HUG 전세보증금반환보증 담보인정비율 기준). "
            f"⚠ {t.JEONSE_RATIO_CAUTION_PCT}%는 '주의'예요 — '위험'이라고 하지 마세요.",
            f"· 선순위 채권(나보다 먼저 받아 가는 빚) ÷ 집값: {t.SENIOR_DEBT_RATIO_DANGER_PCT}%를 넘으면 위험 신호 "
            "(HUG 전세보증 가입 요건).",
            f"· 보증금 + 선순위 채권이 집값의 {t.COMBINED_RATIO_DANGER_PCT}%를 넘으면 위험 신호 (HUG 가입 요건).",
            f"· 집값 시세를 모를 때: 공동주택 공시가격의 {round(t.PUBLIC_PRICE_TO_HOUSE_PRICE_RATIO * 100)}%를 "
            "집값으로 봐요 (HUG 방식).",
            "· 말소된(지워진) 빚은 위험으로 보지 않아요. 정보가 모자라면 '안전'이 아니라 '확인 필요'로 봐요.",
        ]
    )


def system_prompt(careful: bool) -> str:
    base = CHAT_SYSTEM_PROMPT.format(glossary=glossary_block(), criteria=criteria_block())
    return base + (CHAT_CAREFUL_ADDENDUM if careful else "")


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


def _dictionary_fallback(question: str, careful: bool) -> ChatReply | None:
    if careful:
        return None
    found = terms.lookup(question)
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


def reply(messages: Iterable[dict | Turn]) -> ChatReply:
    """최근 대화 → 화면에 그릴 답. **어떤 실패에도 예외를 던지지 않는다.**"""
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
        return _generate(turns, careful)
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


def _generate(turns: list[Turn], careful: bool) -> ChatReply:
    question = turns[-1].content
    provider = llm.chat_provider()
    if not provider.available:
        _log.info(f"[챗봇:{provider.name}] API 키 없음 — 기본 문장")
        return _fallback(question, careful, layer="키없음", text=OFFLINE_FALLBACK)

    system = system_prompt(careful)
    history = [{"role": t.role, "content": t.content} for t in turns[:-1]]
    allowed = text_guard.chat_allowed_numbers(
        [t.content for t in turns if t.role == "user"], criteria_numbers()
    )
    user_msg = question
    calls = 0
    last_reason = ""
    for attempt in (1, 2):  # 처음 + 한 번 고쳐 쓰기
        try:
            payload, resp = provider.chat_json(
                system,
                user_msg,
                max_tokens=MAX_OUTPUT_TOKENS,
                temperature=llm.CHAT_TEMPERATURE,
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
            verdict = text_guard.check_chat_reply(text or "", allowed=allowed, careful=careful)
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
