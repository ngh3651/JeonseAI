"""용어 챗봇 답변 — **규칙이 먼저 막고, 그 뒤에만 LLM이 붙는다** (S-12, 2026-08-14).

무엇이 바뀌었나:
예전 챗봇은 `terms.lookup`의 **부분 문자열 검사** 하나였다. 사전에 있는 표기가 질문에
들어 있으면 그 설명을 내보내고, 없으면 404 → 앱이 거절 문구를 띄웠다. 그래서
"집주인이 빚이 많으면 세입자는 어떻게 되나요?" 같은 **자연어 질문이 전부 거절됐다.**

통과 순서 (이 순서가 설계의 전부다):

    사용자 입력
      → L1 판정 요구 차단 (규칙, **LLM 이전**)
      → L2 사전 직격      (검수된 문장 그대로)
      → L3 도메인 게이트   (규칙)
      → L4 Solar 설명 생성 (여기서 처음 AI가 붙는다) + 검증
      → L5 용어 툴팁 부착  (세 경로가 **합류한 뒤 한 곳에서**)

⚠ **왜 L1이 맨 앞인가.** "근저당 잡힌 이 집, 계약해도 돼요?"는 사전(근저당)에도 걸리고
  도메인 키워드도 있다. 판정 요구 게이트가 뒤에 있으면 이 질문이 새 나간다.
  거절을 LLM에게 맡기지 않는 이유도 같다 — 프롬프트는 언젠가 뚫리지만 정규식은 안 뚫린다.

⚠ **이 모듈은 판정을 만들지 않는다.** 출력 스키마에 등급·점수·금액 필드가 없고
  (`ChatAnswer`, `extra="forbid"`), 답변에 아라비아 숫자가 하나라도 있으면 폐기된다
  (`text_guard.check_chat`). 챗봇과 리포트의 숫자가 갈라지는 일이 구조적으로 없다.

LLM이 죽어도 화면은 예전과 똑같이 동작한다 — 키 없음·타임아웃·JSON 깨짐·검증 실패는
전부 '준비된 문구'(거절 응답)로 떨어진다. `.env`의 `CHATBOT_LLM=off`면 L4를 통째로
건너뛰어 **오늘 이전 상태**가 된다(촬영 안전장치).
"""

from __future__ import annotations

import logging
import os
import re
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from . import terms, text_guard
from . import llm
from .llm.prompts import CHAT_SYSTEM_PROMPT

_log = logging.getLogger("jeonseai")
_BACKEND_ROOT = Path(__file__).resolve().parents[2]

# ── 문구 상수 ────────────────────────────────────────────────────────────────
#
# ⚠ 거절 문구는 **서버가 준다.** 예전에는 앱이 하드코딩했는데(404를 받으면 앱이 직접
#   문장을 띄웠다), 그러면 문구를 고칠 때 앱을 다시 배포해야 하고 서버 로그만 봐서는
#   사용자가 무엇을 봤는지 알 수 없다. "화면 문구는 서버가 결정한다"는 원칙과도 어긋난다.
OUT_OF_SCOPE_ANSWER = (
    "저는 부동산 용어를 쉽게 설명해 드리는 도우미예요. "
    "이 집이 안전한지는 안전도 리포트가 분석해 드려요."
)

#: 답변 출처 라벨 — 화면 말풍선 아래 회색 한 줄로 그대로 나간다(2026-08-14 D26과 같은 원칙).
DICTIONARY_SOURCE = "검수된 용어 사전"
FALLBACK_SOURCE = "준비된 문구"

#: 생성 상한 (인프라 수치 — 판정 임계값 아님)
MAX_OUTPUT_TOKENS = 400


# ══════════════════════════════════════════════════════════════════════════════
# L1. 판정 요구 차단 — LLM 이전, 최우선
# ══════════════════════════════════════════════════════════════════════════════
#
# 비교는 **공백을 지운 문자열**에 대고 한다("계약 해도 돼요" 같은 띄어쓰기 변형을
# 따로 적지 않기 위해서).

_VERDICT_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        "판단요구",
        re.compile(
            r"계약해도|들어가도|살아도|해도되|계약할까|계약하면|해도괜찮|괜찮나|괜찮을까|괜찮은가"
            r"|안전한가|안전할까|안전한지|위험한가|위험할까|위험한지|어때요|어떤가요|어떻게보|어떻게생각"
            r"|낫나요|나을까|추천해|추천좀|골라|골라줘|믿어도|믿을만|사기인가|사기일까|사기맞"
            r"|판단해|판단좀|평가해|봐주세요|봐줘|몇점|점수매|등급매|등급알려|위험도알려"
        ),
    ),
    (
        "금액조언",
        re.compile(
            r"얼마면|얼마가적당|얼마가적정|얼마정도가|적정가|적당한가격|깎아|깎을|협상|비싼가|비싼편|싸게"
        ),
    ),
    ("법률자문", re.compile(r"소송|고소|승소|변호사|소장|내용증명|고발|법적으로어떻게")),
)

#: 지시 대상("이 집", "우리 집")은 **원문에서 낱말 첫머리로만** 잡는다.
#:
#: ⚠ 공백을 지운 문자열에서 `이집`을 찾으면 **"전세금이 집값보다 높으면?"** 같은 정상
#:   질문이 걸린다(`전세금**이 집**값`). 조사 `이`가 앞말에 붙은 경우를 배제해야 한다.
_TARGET_RE = re.compile(
    r"(?:^|[^가-힣A-Za-z0-9])(이\s*집|이\s*매물|이\s*계약|이\s*등기부|우리\s*집|우리\s*계약"
    r"|저희\s*집|여기는|여기가|제\s*집|내\s*집)"
)


def _squeeze(text: str) -> str:
    return re.sub(r"\s+", "", text or "")


def verdict_request_hit(query: str) -> str | None:
    """판정·조언 요구면 그 종류, 아니면 None. **LLM을 부르기 전에** 이걸 먼저 본다."""
    squeezed = _squeeze(query)
    for name, pattern in _VERDICT_PATTERNS:
        if pattern.search(squeezed):
            return name
    if _TARGET_RE.search(query or ""):
        return "지시대상"
    return None


# ══════════════════════════════════════════════════════════════════════════════
# L3. 도메인 게이트
# ══════════════════════════════════════════════════════════════════════════════
#
# 키워드 집합은 `terms.json`에서 **생성한다** — 하드코딩 목록을 새로 만들면 용어가
# 늘어날 때 둘이 갈라진다.
#
# ⚠ 여기서는 `load_all()`(검수 대기 포함)을 쓴다. 검수 게이트는 **설명 문장**을 막는
#   장치이지 "이 질문이 부동산 얘기인가"를 막는 장치가 아니다. 검수 대기 용어(예: 대항력)를
#   키워드에서 빼면 그 단어를 물어본 사람이 "부동산 얘기가 아니에요"라는 답을 듣게 된다.
#   설명은 여전히 검수된 문장이나 LLM 생성문으로만 나간다.

#: terms.json에 없지만 사람들이 실제로 쓰는 말 (수동 목록)
_EXTRA_DOMAIN_WORDS = (
    "전세 월세 보증금 임대 임차 임대인 임차인 집주인 세입자 계약 계약서 특약 잔금 계약금 "
    "중개사 공인중개사 부동산 매물 이사 전입 이사비 관리비 갱신 재계약 묵시적 만기 퇴거 "
    "반환 돌려받 등기 등기부 서류 발급 경매 낙찰 배당 담보 빚 채권 채무"
).split()


def domain_keywords() -> set[str]:
    """도메인 판별 키워드 — terms.json의 모든 표기 + 수동 목록."""
    words = {_squeeze(w) for w in _EXTRA_DOMAIN_WORDS if w.strip()}
    for term in terms.load_all():
        for surface in term.surfaces:
            if surface.strip():
                words.add(_squeeze(surface))
    return {w for w in words if w}


def in_domain(query: str) -> bool:
    """부동산 얘기인가 — 키워드가 하나라도 있으면 통과."""
    squeezed = _squeeze(query)
    if not squeezed:
        return False
    return any(word in squeezed for word in domain_keywords())


# ══════════════════════════════════════════════════════════════════════════════
# L4. LLM 출력 스키마
# ══════════════════════════════════════════════════════════════════════════════


class ChatAnswer(BaseModel):
    """챗봇 답변 슬롯. **등급·점수·확률·금액 필드가 존재하지 않는다** — 리포트와 같은 경계.

    `extra="forbid"`라 모델이 `grade` 같은 키를 실어 보내면 검증에서 떨어져 폴백된다.
    """

    model_config = ConfigDict(extra="forbid")

    answer: str = ""
    out_of_scope: bool = False
    terms_used: list[str] = Field(default_factory=list)


# ══════════════════════════════════════════════════════════════════════════════
# 결과
# ══════════════════════════════════════════════════════════════════════════════


@dataclass
class ChatReply:
    """화면에 그대로 그릴 한 덩어리 (계약 §3.9)."""

    answer: str
    out_of_scope: bool
    source: str
    term_glossary: dict[str, str] = field(default_factory=dict)
    term: str | None = None
    #: 이번 답변에 LLM을 실제로 불렀는가 (로그·하네스용 — 응답에는 나가지 않는다)
    llm_called: bool = False
    #: 어느 층에서 결론이 났는지 (로그·하네스용)
    layer: str = ""


_OFF_VALUES = {"off", "none", "disabled", "no", "false", "0"}


def llm_enabled() -> bool:
    """`.env`의 `CHATBOT_LLM` — `off`면 L4를 통째로 건너뛴다(촬영 안전장치)."""
    load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")
    raw = (os.environ.get("CHATBOT_LLM", "") or "on").strip().lower()
    return raw not in _OFF_VALUES


def _finish(
    answer: str,
    *,
    out_of_scope: bool,
    source: str,
    term: str | None = None,
    llm_called: bool = False,
    layer: str,
) -> ChatReply:
    """**모든 경로가 여기서 합류한다** — 용어 툴팁(L5)은 여기 한 곳에서만 붙인다.

    분기마다 붙이면 언젠가 한 분기에서 빠지고, 그 분기만 밑줄 없는 화면이 된다.
    """
    return ChatReply(
        answer=answer,
        out_of_scope=out_of_scope,
        source=source,
        term_glossary=terms.attach(answer),
        term=term,
        llm_called=llm_called,
        layer=layer,
    )


def _refuse(*, source: str, layer: str, llm_called: bool = False) -> ChatReply:
    """범위 밖 응답 — 문구는 서버가 준다. 앱은 여기에 유도 버튼만 붙인다."""
    return _finish(
        OUT_OF_SCOPE_ANSWER,
        out_of_scope=True,
        source=source,
        llm_called=llm_called,
        layer=layer,
    )


# ══════════════════════════════════════════════════════════════════════════════
# 본체
# ══════════════════════════════════════════════════════════════════════════════


def answer(query: str) -> ChatReply:
    """사용자 질문 하나 → 화면에 그릴 답. **어떤 실패에도 예외를 던지지 않는다.**"""
    q = (query or "").strip()
    if not q:
        return _refuse(source=FALLBACK_SOURCE, layer="L0-빈질문")

    # ── L1. 판정 요구 차단 (LLM 호출 0회) ──────────────────────────────────
    hit = verdict_request_hit(q)
    if hit:
        _log.info(f"[챗봇] L1 차단({hit}) — LLM 호출 안 함 | 질문 {q[:40]!r}")
        return _refuse(source=FALLBACK_SOURCE, layer=f"L1-{hit}")

    # ── L2. 사전 직격 (검수된 문장 그대로, LLM 호출 0회) ───────────────────
    found = terms.lookup(q)
    if found is not None:
        _log.info(f"[챗봇] L2 사전 직격 '{found.term}' — LLM 호출 안 함")
        return _finish(
            found.description,
            out_of_scope=False,
            source=DICTIONARY_SOURCE,
            term=found.term,
            layer="L2-사전",
        )

    # ── L3. 도메인 게이트 (LLM 호출 0회) ───────────────────────────────────
    if not in_domain(q):
        _log.info(f"[챗봇] L3 범위 밖 — LLM 호출 안 함 | 질문 {q[:40]!r}")
        return _refuse(source=FALLBACK_SOURCE, layer="L3-범위밖")

    # ── L4. Solar 설명 생성 ────────────────────────────────────────────────
    if not llm_enabled():
        _log.info("[챗봇] CHATBOT_LLM=off — 생성 건너뜀(예전 동작과 동일)")
        return _refuse(source=FALLBACK_SOURCE, layer="L4-꺼짐")

    try:
        return _generate(q)
    except Exception as e:  # noqa: BLE001 — 구조적 방어선: 챗봇이 화면을 깨뜨리지 않는다
        _log.error(
            f"[챗봇] ⚠ 생성 경로에서 예기치 못한 예외 — 준비된 문구로 응답"
            f" ({type(e).__name__}: {str(e)[:120]})",
            exc_info=True,
        )
        return _refuse(source=FALLBACK_SOURCE, layer="L4-예외", llm_called=True)


def _generate(q: str) -> ChatReply:
    """실제 호출·검증. 실패하면 거절 응답으로 떨어진다(예외를 밖으로 내지 않는다)."""
    provider = llm.chat_provider()
    if not provider.available:
        _log.info(f"[챗봇:{provider.name}] API 키 없음 — 준비된 문구로 응답")
        return _refuse(source=FALLBACK_SOURCE, layer="L4-키없음")

    try:
        payload, resp = provider.chat_json(
            CHAT_SYSTEM_PROMPT,
            q,
            max_tokens=MAX_OUTPUT_TOKENS,
            temperature=llm.CHAT_TEMPERATURE,
        )
    except llm.LlmError as e:
        _log.info(f"[챗봇:{provider.name}] 호출 실패 → 준비된 문구 ({str(e)[:120]})")
        return _refuse(source=FALLBACK_SOURCE, layer="L4-호출실패", llm_called=True)

    try:
        parsed = ChatAnswer.model_validate(payload)
    except ValidationError as e:
        first = e.errors()[0] if e.errors() else {}
        _log.info(
            f"[챗봇:{provider.name}] 스키마 위반 → 준비된 문구"
            f" ({' → '.join(str(x) for x in first.get('loc', ()))}: {first.get('msg', '?')})"
        )
        return _refuse(source=FALLBACK_SOURCE, layer="L4-스키마", llm_called=True)

    # 모델이 스스로 범위 밖이라고 했다 — answer가 남아 있어도 **버린다**.
    if parsed.out_of_scope:
        if parsed.answer.strip():
            _log.info(f"[챗봇:{provider.name}] out_of_scope=true인데 answer가 있음 → 버림")
        return _refuse(source=FALLBACK_SOURCE, layer="L4-모델거절", llm_called=True)

    reason = text_guard.check_chat(parsed.answer)
    if reason:
        _log.info(f"[챗봇:{provider.name}] 검증 실패({reason}) → 준비된 문구")
        return _refuse(source=FALLBACK_SOURCE, layer="L4-검증실패", llm_called=True)

    _log.info(
        f"[챗봇:{provider.name}] 생성 성공 {resp.elapsed:.1f}초"
        f" / 토큰 {resp.total_tokens if resp.total_tokens is not None else '미제공'}"
        f" / {len(parsed.answer)}자"
    )
    # 출처 라벨은 **실제 모델 문자열**이다 — 'AI 생성' 같은 뭉뚱그린 말을 쓰지 않는다(D26).
    return _finish(
        parsed.answer.strip(),
        out_of_scope=False,
        source=provider.model,
        llm_called=True,
        layer="L4-생성",
    )
