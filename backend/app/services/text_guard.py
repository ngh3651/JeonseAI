"""설명 문장 검증 — **날조를 구조로 막는 그물** (2026-08-05 신설).

왜 새로 만들었나:
지금까지 그물은 "금지어 20개 부분 문자열 + 길이"뿐이었다. 그런데 감사(2026-08-05)에서
`"안전한 범위에 속해요"`가 그대로 통과했다 — 목록에는 `"안전 범위"`가 있었지만 실제
문자열은 `"안전한 범위"`라 부분 문자열이 빗나갔다. **2026-07-07에도 같은 이유로 목록을
늘렸으니 이번이 세 번째다.** 단어를 더 붙이는 방식은 다음에 또 샌다.

그래서 방식을 바꾼다:
  ⑴ **숫자 화이트리스트** — 문장에 나온 수치가 입력 재료에 없으면 그 필드를 버린다.
     이것이 핵심이다. 재료를 늘려 LLM에 자율성을 주더라도 **없는 숫자는 말할 수 없다**는
     성질이 기계적으로 보장돼야 자율성 확대가 안전해진다.
  ⑵ **패턴 매칭** — 활용형을 정규식으로 흡수한다(`안전.{0,3}범위`가 '안전한 범위'를 잡는다).
  ⑶ **등급 단어 차단** — 등급은 화면 뱃지가 이미 말한다. 문장이 또 말하면 어긋날 수 있다.

⚠ 이 모듈은 **판정을 하지 않는다.** 문자열을 보고 "이 필드를 쓸 수 있나"만 답한다.
  어떤 검증을 언제 돌릴지(정책)는 `explanation.py`가 정한다.
"""

from __future__ import annotations

import re
from typing import Any, Iterable

# ── ⑵ 금지 표현: 목록 → 패턴 ────────────────────────────────────────────────
#
# 기존 20개 문자열을 **뜻이 같은 것끼리 묶어** 패턴으로 다시 썼다. 비교는 공백을 모두
# 지운 문자열에 대고 한다 — `"문제 가 없"` 같은 띄어쓰기 변형을 따로 적지 않아도 된다.
# `.{0,N}`이 활용형('안전한'·'안전하다고')을 흡수한다.
_BANNED_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    # "안전" 계열 — 단정. `안전선`·`안전장치`처럼 정상 단어는 뒤에 명사가 붙으므로
    # 뜻이 '괜찮다'로 굳는 조합만 잡는다.
    # ⚠ 뒤에 부정이 오면 잡지 않는다. `"완전히 안전하다고 볼 수 없어요"`는 **보수적인**
    #   문장인데 실측(2026-08-05)에서 단정으로 오인돼 폴백됐다.
    ("안전-단정", re.compile(r"안전.{0,3}(합니다|해요|하다|한집|범위|권|하니|하며|하고)(?!.{0,8}(없|않|아니|어렵|어려|힘들|못))")),
    ("안전-강조", re.compile(r"(확실히|절대|100%|완전히)안전(?!.{0,8}(없|않|아니|어렵|어려|힘들|못))")),
    # "안심" 계열
    ("안심-단정", re.compile(r"안심.{0,4}(하셔도|해도|하세요|할수있)")),
    # "문제/위험요소/이상 없다" 계열
    ("없음-단정", re.compile(r"(문제|위험요소|위험한요소|이상|하자|결격)[가는이]?.{0,2}없")),
    # "걱정 마세요" 계열
    ("걱정-단정", re.compile(r"걱정.{0,5}(마세요|마시|않으셔도|안하셔도|하지마)")),
    # "보장" 계열 — 우리는 무엇도 보장하지 않는다
    ("보장-단정", re.compile(r"(보장합니다|보장해요|보장됩니다|보장돼요)")),
)

# ── ⑶ 등급 단어 ────────────────────────────────────────────────────────────
#
# 등급은 화면에 뱃지로 크게 나온다(계약 §2.1 grade). 문장이 또 말하면 뱃지와 어긋날 수
# 있고, 실제로 감사에서 headline에 "양호"가 들어간 채 통과했다.
#
# ⚠ `"위험"`은 **일괄 금지하지 않는다.** 우리 폴백 문구부터가 `"큰 위험 신호는 보이지
#   않았어요"`(fallback_texts.HEADLINES[GOOD])를 쓴다 — 일상어로 정상 사용된다.
#   그래서 **등급 라벨로 쓰인 꼴만** 잡는다.
_GRADE_LABEL_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("등급단어-양호", re.compile(r"양호")),
    ("등급단어-확인필요", re.compile(r"확인필요")),
    ("등급단어-위험라벨", re.compile(r"(종합)?등급[은는이가]?.{0,3}위험|위험.{0,2}(등급|판정)")),
)


def _squeeze(text: str) -> str:
    """공백을 전부 지운다 — 띄어쓰기 변형을 패턴에 적지 않기 위해서."""
    return re.sub(r"\s+", "", text or "")


def banned_hit(text: str) -> str | None:
    """금지 표현에 걸리면 그 이름, 아니면 None."""
    squeezed = _squeeze(text)
    for name, pattern in _BANNED_PATTERNS:
        if pattern.search(squeezed):
            return name
    return None


def grade_word_hit(text: str) -> str | None:
    """등급 단어가 라벨 의미로 쓰였으면 그 이름, 아니면 None."""
    squeezed = _squeeze(text)
    for name, pattern in _GRADE_LABEL_PATTERNS:
        if pattern.search(squeezed):
            return name
    return None


# ══════════════════════════════════════════════════════════════════════════════
# ⑴ 숫자 화이트리스트
# ══════════════════════════════════════════════════════════════════════════════

#: 한글 수사 — "두 건"을 2로 읽는다. 열까지만 둔다(그 이상은 문장에서 숫자로 쓴다).
_KO_NUMERALS = {
    "한": 1, "두": 2, "세": 3, "네": 4, "다섯": 5,
    "여섯": 6, "일곱": 7, "여덟": 8, "아홉": 9, "열": 10,
}
#: 한글 수사 뒤에 올 때만 수로 인정하는 단위 — "한 번 더"의 '한'을 1로 세지 않기 위함이 아니라,
#: 오히려 **세는 말일 때만** 인정해 오탐을 줄인다.
_KO_COUNTERS = ("건", "곳", "가지", "명", "채", "군데")

_KO_NUM_RE = re.compile(
    r"(" + "|".join(_KO_NUMERALS) + r")\s*(" + "|".join(_KO_COUNTERS) + r")"
)

#: 금액 덩어리 — `1억 8,000만원`·`2억원`·`1.8억`·`8,000만원`·`1억 2천만원`을
#: **하나의 수**로 읽는다. 이걸 안 하면 `1억 8,000만원`이 1과 8000으로 쪼개져
#: 180000000과 대조되지 않는다.
#:
#: ⚠ `천만`을 `천`·`만`보다 **먼저** 봐야 한다. 순서를 바꾸면 `2천만`이 2천(2,000)으로
#:   읽혀 실측에서 `1억 2천`이 100000002로 계산됐다(2026-08-05 오탐).
_MONEY_UNITS = r"억|천만|백만|만|천"
_MONEY_RE = re.compile(rf"(?:\d[\d,]*(?:\.\d+)?\s*(?:{_MONEY_UNITS})\s*)+(?:\d[\d,]*)?\s*원?")
_MONEY_PART_RE = re.compile(rf"(\d[\d,]*(?:\.\d+)?)\s*({_MONEY_UNITS})?")
_UNIT = {
    "억": 100_000_000,
    "천만": 10_000_000,
    "백만": 1_000_000,
    "만": 10_000,
    "천": 1_000,
    None: 1,
}

#: 남은 평범한 숫자 — 퍼센트·건수·연도·날짜 조각
_PLAIN_RE = re.compile(r"\d[\d,]*(?:\.\d+)?")


def _to_float(raw: str) -> float:
    return float(raw.replace(",", ""))


def extract_numbers(text: str) -> list[tuple[str, float]]:
    """문장에서 수를 뽑는다 → `[(원문 조각, 값)]`.

    순서가 중요하다: **금액 덩어리를 먼저** 소비해야 `1억 8,000만원`이 1·8000으로
    쪼개지지 않는다.
    """
    if not text:
        return []
    found: list[tuple[str, float]] = []
    consumed = [False] * len(text)

    for m in _MONEY_RE.finditer(text):
        chunk = m.group(0)
        total = 0.0
        for part in _MONEY_PART_RE.finditer(chunk):
            num = part.group(1)
            if not num:
                continue
            total += _to_float(num) * _UNIT[part.group(2)]
        if total:
            found.append((chunk.strip(), total))
            for i in range(m.start(), m.end()):
                consumed[i] = True

    for m in _PLAIN_RE.finditer(text):
        if any(consumed[i] for i in range(m.start(), m.end())):
            continue
        found.append((m.group(0), _to_float(m.group(0))))

    for m in _KO_NUM_RE.finditer(text):
        found.append((m.group(0), float(_KO_NUMERALS[m.group(1)])))

    return found


def collect_allowed(material: Any) -> set[float]:
    """입력 재료(판정 JSON)에 등장하는 모든 수 → 허용 집합.

    숫자 필드뿐 아니라 **문자열 안의 수까지** 훑는다. `detail_text`는 우리가 만든
    문장이라 거기 적힌 `80%`·`1억 8,000만원`은 이미 사실이다 — 이것을 허용에 넣지
    않으면 LLM이 우리 문장을 그대로 옮겨 써도 폴백된다(오탐).
    """
    allowed: set[float] = {0.0}  # 0은 늘 허용 — "0원"·"0건"은 없음을 말하는 안전한 표현
    _walk(material, allowed)
    return allowed


def _walk(node: Any, out: set[float]) -> None:
    if isinstance(node, bool) or node is None:
        return
    if isinstance(node, (int, float)):
        out.add(float(node))
        return
    if isinstance(node, str):
        for _, value in extract_numbers(node):
            out.add(value)
        return
    if isinstance(node, dict):
        for v in node.values():
            _walk(v, out)
        return
    if isinstance(node, (list, tuple, set)):
        for v in node:
            _walk(v, out)


#: 반올림 표기 허용 오차. `1억 8,000만원`을 `1.8억`으로 줄여 쓰는 것을 통과시키되,
#: 지어낸 다른 수가 우연히 걸리지 않을 만큼 좁게 둔다.
_REL_TOLERANCE = 0.01


def _supported(value: float, allowed: Iterable[float]) -> bool:
    for a in allowed:
        if value == a:
            return True
        if a and abs(value - a) / abs(a) <= _REL_TOLERANCE:
            return True
    return False


def unsupported_numbers(text: str, allowed: set[float]) -> list[str]:
    """재료에 없는 수의 원문 조각 목록. 비어 있으면 통과."""
    bad: list[str] = []
    for chunk, value in extract_numbers(text):
        if not _supported(value, allowed):
            bad.append(chunk)
    return bad


# ══════════════════════════════════════════════════════════════════════════════
# 종합 판정
# ══════════════════════════════════════════════════════════════════════════════


# ══════════════════════════════════════════════════════════════════════════════
# 챗봇 답 검사 (2026-10-24 대화형 챗봇)
# ══════════════════════════════════════════════════════════════════════════════
#
# 예전(2026-08-14)에는 챗봇에 재료가 없다며 **숫자 전면 금지**였다. 이제는 재료가 생겼다 —
# ⑴ 사용자가 직접 말한 숫자(그 사람의 사실이다) ⑵ 판정 기준(thresholds.py 상수).
# 그래서 리포트와 같은 **화이트리스트** 방식으로 바꿨다: 그 밖의 숫자를 AI가 지어내면 걸린다.

#: 챗봇 답 길이 상한 — 넘으면 자르지 않고 고쳐 쓰게 한다(잘린 문장은 뜻이 바뀐다).
CHAT_MAX_LEN = 450

#: 집·계약에 대한 **판정 문장** — 어느 쪽(해도 된다/하지 마라)이든 챗봇이 말하면 안 된다.
#: 공백을 지운 문자열에 댄다. `계약해도 되는지는 제가 정할 수 없어요`처럼 **묻거나 부정하는 꼴**은 통과.
_CHAT_VERDICT_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("계약-허락", re.compile(r"계약(을)?(해도|하셔도|하시면)(돼|됩|되겠|될것같|괜찮|좋)(?!는지|을지|는가|나요|ㄹ지)")),
    ("계약-말림", re.compile(r"계약(은|을)?(하지마|하지않는게좋|안하는게좋|피하는게좋|피하세요|미루세요|포기하)")),
    ("가격-단정", re.compile(r"(적정|적당|합리적인|싼|비싼)(한)?(가격|편|금액)(이에요|이예요|입니다|이네요)")),
    # 기준에 **대어 본** 말 — "80%라 주의 기준에 해당해요"는 숫자로 내린 판정이다(2026-10-24 심사 리뷰).
    # "90%를 넘으면 위험 신호로 봐요"(조건)는 통과한다.
    ("기준-적용", re.compile(r"(주의|위험|확인)(신호|구간|기준|수준|범위)?(에|에요|이에요)?(해당|들어가|들어와|속해|속합|속하)")),
    ("기준-넘음", re.compile(r"(넘어서|넘었|넘어요|넘습니다|넘네요|넘는군요)(?!면)")),
    ("단정-완곡", re.compile(r"(안전한편|괜찮은편이|걱정할필요(가|는)?없|걱정하지않으셔도|문제될게없)")),
)

#: '이 집'·'그 매물'을 주어로 한 판정 — **원문**에 댄다(공백을 지우면 "빚**이 집**값"이 '이집'으로 읽힌다).
_CHAT_VERDICT_RAW_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("사기-단정", re.compile(r"(?<![가-힣])(이|그)\s*(집|매물|건)(은|는)?\s*.{0,6}사기\s*(예요|에요|입니다|가\s*맞|인\s*것\s*같|같아요|일\s*가능성이\s*높)")),
    ("집-단정", re.compile(r"(?<![가-힣])(이|그)\s*(집|매물)(은|는|이|가)?\s*.{0,8}(위험해요|위험합니다|위험한\s*집|괜찮아요|괜찮습니다|괜찮은\s*집|좋은\s*집|나쁜\s*집)")),
)

#: 조심 모드(규칙이 판정 요구를 알아챈 질문)에서만 더 막는 말 — 권유·안심 표현.
_CHAT_CAREFUL_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("조심-권유", re.compile(r"(추천해요|추천드려요|추천합니다|권해드려요|계약하세요|계약하셔도|들어가셔도)")),
    ("조심-안심", re.compile(r"(괜찮(아요|습니다|을거예요|을것같아요))(?!.{0,8}(없|않|아니|어렵|못|모르))")),
)

#: 인터넷 주소 — **공공기관(go.kr·or.kr)만** 허용한다(2026-10-24: 막으면 "어디서 떼요?"에 답을 못 했다).
#: 그 밖의 주소는 지어냈거나 광고일 수 있다.
_URL_RE = re.compile(r"(?:https?://)?(?:www\.)?((?:[a-z0-9-]+\.)+[a-z]{2,})(?:/\S*)?", re.I)
_PUBLIC_DOMAIN_RE = re.compile(r"\.(go|or)\.kr$", re.I)
#: 퍼센트 숫자 — 판정 기준과 부딪힐 수 있는 수는 이것뿐이라 이것만 묶는다(2026-10-24 '자율성')
_PERCENT_RE = re.compile(r"(\d+(?:\.\d+)?)\s*(%|퍼센트|프로)")


def chat_allowed_numbers(user_texts: Iterable[str], extra: Iterable[float] = ()) -> set[float]:
    """챗봇 답에 써도 되는 수 — 사용자가 말한 수 + 판정 기준(호출부가 넘긴다) + 0."""
    allowed: set[float] = {0.0}
    for t in user_texts:
        for _, value in extract_numbers(t or ""):
            allowed.add(value)
    allowed.update(float(x) for x in extra)
    return allowed


#: 리포트의 등급 글자 → 그 등급 단어 패턴 이름 (리포트를 아는 챗봇이 **리포트가 낸 등급만** 그대로 전할 수 있게)
GRADE_LABEL_OF = {"양호": "등급단어-양호", "확인 필요": "등급단어-확인필요", "위험": "등급단어-위험라벨"}

#: 리포트가 이미 낸 결과를 전할 때는 "기준을 넘었어요"가 판정이 아니라 **리포트 내용의 인용**이다
_REPORT_QUOTABLE = {"기준-적용", "기준-넘음"}


def check_chat_reply(
    text: str,
    *,
    allowed: set[float],
    careful: bool = False,
    report_grades: Iterable[str] | None = None,
) -> tuple[str, str] | None:
    """챗봇 답을 내보내도 되나. 통과면 None, 아니면 `(분류, 쉬운 말 사유)`.

    분류는 로그용(사용자 글이 섞이지 않는다), 사유는 AI에게 고쳐 쓰라고 돌려줄 문장이다.
    금지 표현·등급 단어는 리포트와 **같은 패턴**을 쓴다(두 화면이 다른 그물을 쓰면 조용히 갈라진다).
    """
    if not text or not text.strip():
        return ("빈답", "답이 비어 있어요")
    if len(text) > CHAT_MAX_LEN:
        return ("길이", f"{CHAT_MAX_LEN}자를 넘었어요. 더 짧게 줄여 주세요")
    hit = banned_hit(text)
    if hit:
        return (f"금지표현-{hit}", "'안전해요·문제없어요·걱정 마세요·안심하세요' 같은 단정 표현은 쓸 수 없어요")
    squeezed = _squeeze(text)
    # 리포트를 아는 챗봇(2026-10-26): 리포트·근거 카드가 **실제로 낸** 등급 단어만 허용한다 — 다른 등급을 말하면 걸린다
    report_mode = report_grades is not None
    quotable = {GRADE_LABEL_OF[g] for g in (report_grades or ()) if g in GRADE_LABEL_OF}
    for name, pattern in _GRADE_LABEL_PATTERNS:
        if pattern.search(squeezed) and name not in quotable:
            return (
                name,
                "리포트에 없는 등급 이름은 쓸 수 없어요. 리포트가 낸 결과만 '리포트에서는 ~로 나왔어요'처럼 전해 주세요"
                if report_mode
                else "'양호·확인 필요·위험 등급' 같은 등급 이름은 쓸 수 없어요",
            )
    verdict_msg = (
        "집이나 계약, 가격이 괜찮은지 판단하는 말은 할 수 없어요. 리포트 결과는 '리포트에서는 ~로 나왔어요'처럼 "
        "리포트가 판단한 것으로만 전하고, 계약 여부는 정하지 말아 주세요"
        if report_mode
        else "집이나 계약, 가격이 괜찮은지 판단하는 말은 할 수 없어요. 판단 없이 확인할 방법만 알려 주세요"
    )
    for name, pattern in _CHAT_VERDICT_PATTERNS + (_CHAT_CAREFUL_PATTERNS if careful else ()):
        if report_mode and name in _REPORT_QUOTABLE:
            continue
        if pattern.search(squeezed):
            return (name, verdict_msg)
    for name, pattern in _CHAT_VERDICT_RAW_PATTERNS:
        if pattern.search(text):
            return (name, verdict_msg)
    for m in _URL_RE.finditer(text):
        host = m.group(1).lower()
        if "." in host and not _PUBLIC_DOMAIN_RE.search(host):
            return ("주소", "공공기관(go.kr·or.kr)이 아닌 인터넷 주소는 쓸 수 없어요. 기관 이름만 말로 써 주세요")
    for m in _PERCENT_RE.finditer(text):
        if not _supported(float(m.group(1)), allowed):
            return ("숫자", f"'{m.group(0)}'는 근거가 없어 쓸 수 없어요. 판정 기준표의 퍼센트만 쓰거나 말로 풀어 주세요")
    return None


def check(text: str, *, max_len: int, allowed: set[float]) -> str | None:
    """이 문자열을 화면에 써도 되나. **통과면 None, 아니면 사유 문자열.**

    사유를 문자열로 돌려주는 이유: 폴백이 조용하면 무엇이 걸렸는지 다음에도 모른다
    (2026-07-28 교훈). 호출부가 이 값을 그대로 로그에 남긴다.
    """
    if not text or not text.strip():
        return "빈 문자열"
    if len(text) > max_len:
        return f"길이 초과({len(text)}자 > {max_len}자)"
    hit = banned_hit(text)
    if hit:
        return f"금지 표현({hit})"
    hit = grade_word_hit(text)
    if hit:
        return f"등급 단어({hit})"
    bad = unsupported_numbers(text, allowed)
    if bad:
        return f"재료에 없는 수치({', '.join(bad[:3])})"
    return None
