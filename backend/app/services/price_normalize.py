"""주소·지번·동호·날짜 정규화 — **DB를 만드는 쪽과 조회하는 쪽이 같은 규칙을 쓰게** 하는 모듈.

여기 있는 함수가 하나라도 두 곳에서 다르게 구현되면, 빌드된 DB와 조회 키가 어긋나
"데이터는 있는데 못 찾는" 조용한 실패가 생긴다. 그래서 순수 함수만 모아 한 곳에 둔다.

⚠ 모르면 `None`/빈 문자열을 돌려준다. 그럴듯한 값을 지어내지 않는다.
"""

from __future__ import annotations

import re

# ── 지번 ─────────────────────────────────────────────────────────────────────

_JIBUN_TEXT = re.compile(r"(\d+)(?:\s*-\s*(\d+))?")


def normalize_jibun(bon: object, bu: object = None) -> str:
    """본번·부번 → 비교용 지번 문자열. 부번 0/빈값은 없는 것과 같게 본다.

    `market_price.normalize_jibun`과 **같은 결과**를 내야 한다(실거래가 매칭과 공시가격
    매칭이 같은 키를 쓴다). 그쪽은 '1234-5' 형태의 한 문자열을 받고, 이쪽은 컬럼이
    둘로 나뉜 CSV도 받는다는 점만 다르다.
    """
    bon_s = str(bon or "").strip()
    bu_s = str(bu or "").strip()
    if not bon_s:
        return ""
    m = re.fullmatch(r"0*(\d+)", bon_s)
    if not m:
        # '1234-5' 처럼 한 칸에 다 들어 있는 경우
        return normalize_jibun_text(bon_s)
    bon_n = int(m.group(1))
    bu_n = 0
    if bu_s:
        mb = re.fullmatch(r"0*(\d+)", bu_s)
        if mb:
            bu_n = int(mb.group(1))
    return f"{bon_n}-{bu_n}" if bu_n else str(bon_n)


def normalize_jibun_text(raw: str) -> str:
    """'1234-5' · '1234' · '산 12-3' → 비교용 지번. 숫자를 못 찾으면 빈 문자열."""
    m = _JIBUN_TEXT.search(raw or "")
    if not m:
        return ""
    bon = int(m.group(1))
    bu = int(m.group(2)) if m.group(2) else 0
    return f"{bon}-{bu}" if bu else str(bon)


# ── 동·호 ────────────────────────────────────────────────────────────────────

_DONG_RE = re.compile(r"제?\s*([0-9]{1,4}|[A-Za-z]|[가-힣]{1,3})\s*동(?![가-힣])")
_HO_RE = re.compile(r"제?\s*([0-9]{1,5}(?:-[0-9]{1,3})?)\s*호(?![가-힣])")
_FLOOR_RE = re.compile(r"제?\s*(지하\s*)?([0-9]{1,3})\s*층(?![가-힣])")


def normalize_unit(raw: object) -> str:
    """'제101동' · '101동' · '0101' · '101' → '101'. 알파벳/한글 동은 그대로 대문자로.

    앞자리 0은 떼어 낸다 — CSV는 '0101', 등기부는 '제101동'으로 오는 일이 흔하다.
    """
    s = str(raw or "").strip()
    if not s:
        return ""
    s = s.lstrip("제").strip()
    s = re.sub(r"[동호층]\s*$", "", s).strip()
    if re.fullmatch(r"0*\d+", s):
        return str(int(s))
    return s.upper()


def extract_dong(address: str) -> str:
    """주소 문자열에서 **건물 동**을 뽑는다. 없으면 빈 문자열.

    ⚠ 읍면동('신정동')과 구분해야 한다. 그래서 `동` 뒤에 한글이 이어지지 않고,
      앞이 숫자·영문·짧은 한글인 경우만 인정한다. '신정동'은 앞이 '신정'(2글자
      한글)이라 걸릴 수 있으므로, **'제'가 붙었거나 숫자/영문인 것만** 채택한다.
    """
    text = address or ""
    best = ""
    for m in _DONG_RE.finditer(text):
        token = m.group(1)
        prefixed = text[m.start() : m.end()].lstrip().startswith("제")
        if token.isdigit() or (len(token) == 1 and token.isascii()) or prefixed:
            best = normalize_unit(token)
    return best


def extract_ho(address: str) -> str:
    """주소 문자열에서 **호수**를 뽑는다(가장 뒤에 나온 것). 없으면 빈 문자열."""
    matches = _HO_RE.findall(address or "")
    return normalize_unit(matches[-1]) if matches else ""


# '호수 표기가 있나'와 '호수가 몇 호인가'는 다른 질문이다.
# 앞의 질문에는 **숫자를 못 읽어도 표기 자체가 있으면 예**라고 답해야 한다 —
# OCR이 한 글자를 놓쳤거나 문서가 마스킹된 경우('제○○○호')에 "호수 표기가 없다"고
# 읽으면 집합건물을 통건물로 오인해 전세가율을 통째로 보류하게 된다.
_HO_PRESENT_RE = re.compile(r"제\s*[0-9○Ｏ\-]{1,6}\s*호(?![가-힣])|[0-9]{1,5}\s*호(?![가-힣])")


def has_unit_designation(address: str) -> bool:
    """'제N호' 같은 **호수 표기**가 있나 — 집합건물(호별 등기) 판별의 1차 신호.

    값(몇 호인지)이 필요하면 `extract_ho`를 쓴다. 이 함수는 존재 여부만 본다.
    """
    return bool(_HO_PRESENT_RE.search(address or ""))


# 등기부 헤더의 서류 종류 표기. `[집합건물]`이면 호별 등기(아파트·빌라·오피스텔),
# `[건물]`·`[토지]`면 통건물 등기(단독·다가구)다. 이게 호수 표기보다 강한 신호다.
_BRACKET_RE = re.compile(r"^\s*\[([^\]]+)\]")
COLLECTIVE_MARKERS = ("집합건물",)
WHOLE_BUILDING_MARKERS = ("건물", "토지")


def registry_kind(address: str) -> str | None:
    """주소 앞 대괄호 표기 → 'collective'(집합건물) | 'whole'(건물·토지) | None(표기 없음)."""
    m = _BRACKET_RE.match(address or "")
    if not m:
        return None
    label = m.group(1).strip()
    if label in COLLECTIVE_MARKERS:
        return "collective"
    if label in WHOLE_BUILDING_MARKERS:
        return "whole"
    return None


def is_whole_building(address: str) -> bool:
    """단독·다가구(통건물 등기)로 **의심**되는가 — 보수적으로 넓게 잡는다.

    판단 순서:
      ① 대괄호 표기가 있으면 그것만 믿는다 ('[집합건물]' → False, '[건물]' → True).
      ② 표기가 없으면 호수 표기 유무로 본다 — 호수가 없으면 통건물로 **의심**한다.

    ⚠ 여기서 True가 나오면 전세가율 판정을 보류한다. 다가구는 등기부가 1개라
      **앞순위 세입자들의 보증금 합계를 알 수 없고**, 그래서 낮은 전세가율이
      안전 신호가 아니다. 애매하면 True 쪽으로 기운다(보수적 편향).
    """
    kind = registry_kind(address)
    if kind == "collective":
        return False
    if kind == "whole":
        return True
    return not has_unit_designation(address)


# ── 날짜 ─────────────────────────────────────────────────────────────────────

_DATE_COMPACT = re.compile(r"^(\d{4})(\d{2})(\d{2})$")
_DATE_MONTH = re.compile(r"^(\d{4})(\d{2})$")
_DATE_DASH = re.compile(r"^(\d{4})[-./](\d{1,2})[-./](\d{1,2})$")


def normalize_as_of(raw: object) -> str:
    """'20250101' · '2025-01-01' · '2025.1.1' · '202501' → 'YYYY-MM-DD'. 못 읽으면 빈 문자열."""
    s = str(raw or "").strip()
    if not s:
        return ""
    m = _DATE_COMPACT.match(s)
    if m:
        return f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
    m = _DATE_DASH.match(s)
    if m:
        return f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"
    m = _DATE_MONTH.match(s)
    if m:
        return f"{m.group(1)}-{m.group(2)}-01"
    return ""


# ── 숫자 ─────────────────────────────────────────────────────────────────────


def parse_float(raw: object) -> float | None:
    """'84.88' · '84.88㎡' · '1,234.5' → float. 못 읽으면 None (0으로 떨어뜨리지 않는다)."""
    s = str(raw or "").strip().replace(",", "")
    s = re.sub(r"[^0-9.\-]", "", s)
    if not s or s in ("-", ".", "-."):
        return None
    try:
        return float(s)
    except ValueError:
        return None


def parse_int(raw: object) -> int | None:
    """'123,456' · '123456원' → int. 못 읽으면 None."""
    v = parse_float(raw)
    if v is None:
        return None
    return int(v)
