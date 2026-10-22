"""사진 속 **실명·주민번호 자리**를 찾는다 — 앱의 '사진 속 이름 가리기'가 덮을 상자 (2026-10-22, P0-2b).

왜 따로 있나: PR #4의 가리기 스위치는 **앱이 위치를 아는 칸(집주인 이름 하이라이트)**만 덮었다.
사진에는 채무자·이전 소유자·전세권자·개인 근저당권자·개인 채권자의 이름과 주민번호 앞자리가
그대로 보인다. 그 위치를 아는 것은 OCR을 돌린 서버뿐이라, 서버가 **좌표만** 모아 보낸다.

지키는 것:
1. **글자를 보내지 않는다.** 응답에는 (쪽, x, y, w, h)만 — 이름을 다시 적어 보내면 가리는 뜻이 없다.
   로그에도 개수만 남긴다.
2. **판정과 무관하다.** 등급·근거 카드·하이라이트를 하나도 바꾸지 않는다(표시 전용).
3. **애매하면 덮는다.** 사람 이름인지 헷갈리면 가린다 — 더 가려서 잃는 것은 화면 한 칸이고,
   덜 가려서 잃는 것은 남의 실명이다. 은행·회사·관공서 같은 **기관 이름만** 그대로 둔다
   (`formatting.looks_like_institution` — 설명 재료 마스킹과 같은 규칙 + 관공서 몇 개).
   같은 이유로 낱말은 **통째로** 덮는다(`매매홍길동`이면 `매매`까지) — 하이라이트처럼 딱 맞출 필요가 없다.
4. **말소된 줄도 덮는다.** 말소는 "빚이 없어졌다"는 뜻이지 "이름이 공개됐다"는 뜻이 아니다.
5. **사진 묶음 점검과 무관하게 돈다.** 다른 등기부가 섞여 하이라이트를 통째로 보류할 때도 이름은 가린다.
6. **못 찾아본 쪽은 통째로 덮는다.** OCR이 실패했거나 글자를 하나도 못 읽은 쪽은 이름이 어디 있는지
   모른다 → 그 쪽 전체(`x=0, y=0, w=1, h=1`)를 상자 하나로 보낸다. "가리기 켜면 화면에 실명 0건"의
   마지막 방어선이다.

찾는 길 세 가지 (하나만 맞아도 덮는다):
- ① **등록번호** — `900101-*******`·`110111-0015671` 모양. 번호 자체 + 바로 앞 칸의 이름.
- ② **역할어** — `채무자 홍길동`처럼 번호 없이 이름만 오는 칸(채무자 줄에는 원래 번호가 없다).
- ③ **추출 대조** — IE가 읽은 사람 이름(소유자·채무자·권리자…)이 사진 글자 안에 있으면 그 자리.
  ①②가 놓치는 이상한 배치를 잡는 안전망이다.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field

from ..schemas.contract import PrivacyMask
from ..schemas.internal import RegistryExtract
from .formatting import looks_like_institution
from .ocr import OcrResult
from .ocr_layout import (
    _NAME_GAP_RATIO,
    _PREFIXES,
    Line,
    OcrPage,
    Word,
    detect_columns,
    median_height,
)

_log = logging.getLogger("jeonseai")

Box = tuple[float, float, float, float]

# ── 등록번호 모양 ────────────────────────────────────────────────────────────
# 하이라이트용(`ocr_layout._ID_PATTERN`)보다 **넓게** 잡는다 — 가리기는 놓치는 쪽이 더 나쁘다.
#   · 줄표 변형(－ ‐ –)과 전각 별표(＊)도 받는다
#   · 줄표를 OCR이 빠뜨려도 뒤가 별표면 받는다(`900101*******`, `9001011******`)
# 줄 단위로 **공백 없이 이어 붙인 글자**에서 찾는다 — `900101-` / `*******`처럼 낱말이 쪼개져도 잡힌다.
_ID_ANY = re.compile(r"\d{6}(?:[-－‐–][0-9*＊]{6,8}|\d?[*＊]{6,7})")

# 이름이 **뒤에** 오는 역할어. `소유자 홍길동`, `채무자 홍길동`, `근저당권자 박사채 750101-…`.
# 긴 것부터 본다 — '권리자'가 '가등기권리자'를 잘라 먹지 않게.
_ROLE_ANCHORS = tuple(
    sorted(
        {
            "소유자", "공유자", "권리자", "채무자", "채권자", "근저당권자", "전세권자", "임차권자",
            "가압류권자", "가등기권자", "가등기권리자", "지상권자", "질권자", "수탁자", "위탁자",
            "신탁자", "임차인", "대리인",
        },
        key=len,
        reverse=True,
    )
)

# 역할어 뒤에 와도 **이름이 아닌** 낱말 — 표 머리 `권리자 및 기타사항`이 대표적이다.
_NOT_NAME_WORDS = frozenset({"및", "기타사항", "기타", "외", "등"})

# 관공서 — 압류의 `권리자 국 / 처분청 양천세무서`처럼 **사람이 아닌** 권리자. 공개된 이름이라 두되,
# 목록에 없는 기관은 사람처럼 가려진다(그쪽이 안전하다 — `formatting.INSTITUTION_MARKERS`와 같은 태도).
_PUBLIC_BODY_EXACT = frozenset({"국", "처분청", "대한민국"})
_PUBLIC_BODY_MARKERS = (
    "세무서", "세관", "국세청", "시청", "구청", "군청", "도청", "법원", "검찰", "경찰", "지방자치",
    "특별시", "광역시", "특별자치", "세무서장", "구청장", "국민건강", "근로복지",
)

# IE에서 **사람 이름이 들어오는** 필드 (registry_schema.py). 기관이면 아래에서 걸러진다.
_IE_NAME_FIELDS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("ownership_changes", ("holder",)),
    ("mortgages", ("debtor", "mortgagee")),
    ("jeonse_rights", ("holder",)),
    ("lease_registrations", ("holder",)),
    ("provisional_seizures", ("claimant",)),
    ("provisional_dispositions", ("claimant",)),
    ("seizures", ("claimant",)),
    ("auction_commencements", ("claimant",)),
    ("trust_registrations", ("trustee",)),
)

# 상자 여백 — 원본 상자 크기에 대한 비율. 앱이 높이의 15%를 한 번 더 넓힌다(`redactionRectFor`).
_PAD_RATIO = 0.1

#: 쪽 전체를 덮는 상자 — "이 쪽은 이름 자리를 찾아보지 못했다"는 뜻(앱이 안내 문구를 붙인다).
FULL_PAGE = (0.0, 0.0, 1.0, 1.0)


@dataclass
class PrivacyMaskResult:
    """가림 상자 목록 + 실제로 찾아본 쪽 + (로그용) 길별 개수."""

    masks: list[PrivacyMask] = field(default_factory=list)
    checked_pages: list[int] = field(default_factory=list)
    unchecked_pages: list[int] = field(default_factory=list)
    counts: dict[str, int] = field(default_factory=dict)


# ══════════════════════════════════════════════════════════════════════════════
# 글자 → 위치
# ══════════════════════════════════════════════════════════════════════════════


def _weight(ch: str) -> float:
    """글자 폭 어림 — 한글·한자는 숫자·기호보다 대략 두 배 넓다."""
    return 1.0 if ch.isascii() else 2.0


def _sub_box(word: Word, start: int, end: int) -> Box:
    """`word.text[start:end]`가 차지하는 가로 범위를 **글자 폭 비례로 어림한** 상자.

    OCR은 낱말 단위 상자만 준다. `홍길동900101-*******`처럼 이름과 번호가 한 낱말로 오면 그 안을
    나눠야 한다. 어림이라 양옆으로 **한 칸씩 넉넉히** 잡는다(덜 가리는 쪽이 더 나쁘다).
    """
    text = word.text
    if not text or (start <= 0 and end >= len(text)):
        return word.box
    weights = [_weight(c) for c in text]
    unit = (word.x1 - word.x0) / (sum(weights) or 1.0)
    left = word.x0 + sum(weights[:start]) * unit
    right = word.x0 + sum(weights[:end]) * unit
    return (max(word.x0, left - unit), word.y0, min(word.x1, right + unit), word.y1)


def _concat(line: Line) -> tuple[str, list[tuple[int, int]]]:
    """줄의 글자를 **공백 없이** 이어 붙인 문자열 + 글자마다 (낱말 번호, 낱말 안 위치)."""
    buf: list[str] = []
    where: list[tuple[int, int]] = []
    for wi, w in enumerate(line.words):
        for ci, ch in enumerate(w.text):
            buf.append(ch)
            where.append((wi, ci))
    return "".join(buf), where


def _span_boxes(line: Line, where: list[tuple[int, int]], start: int, end: int) -> list[Box]:
    """이어 붙인 문자열의 [start, end) 구간 → 걸친 낱말마다 그 부분만의 상자."""
    by_word: dict[int, list[int]] = {}
    for wi, ci in where[start:end]:
        by_word.setdefault(wi, []).append(ci)
    return [_sub_box(line.words[wi], min(cs), max(cs) + 1) for wi, cs in by_word.items()]


# ══════════════════════════════════════════════════════════════════════════════
# 이 낱말은 사람 이름인가
# ══════════════════════════════════════════════════════════════════════════════


def _has_digit(text: str) -> bool:
    return any(ch.isdigit() for ch in text)


def _is_hangul(ch: str) -> bool:
    return "가" <= ch <= "힣"


def _hangul_count(text: str) -> int:
    return sum(1 for ch in text if _is_hangul(ch))


def _public_body(text: str) -> bool:
    compact = "".join(text.split())
    return compact in _PUBLIC_BODY_EXACT or any(m in compact for m in _PUBLIC_BODY_MARKERS)


def _not_a_person(text: str) -> bool:
    """기관·관공서 이름인가 — 그럴 때만 **가리지 않는다**."""
    return looks_like_institution(text) or _public_body(text)


def _is_label(text: str) -> bool:
    """역할어·등기원인어·표 머리 낱말 **그 자체**인가 (이름이 아니라 이름 앞의 꼬리표)."""
    return text in _PREFIXES or text in _ROLE_ANCHORS or text in _NOT_NAME_WORDS


def _maybe_name(text: str) -> bool:
    """이름이 들어 있을 수 있는 낱말인가 — 숫자·꼬리표·기관이 아니고 한글이 있다."""
    return (
        bool(text)
        and not _has_digit(text)
        and not _is_label(text)
        and _hangul_count(text) > 0
        and not _not_a_person(text)
    )


# ══════════════════════════════════════════════════════════════════════════════
# 찾는 길 ① 등록번호 + 그 앞 이름
# ══════════════════════════════════════════════════════════════════════════════


def _names_before(line: Line, wi: int, ci: int, med_h: float) -> list[Box]:
    """등록번호가 시작하는 자리(낱말 `wi`의 `ci`번째 글자) **앞**의 이름 상자들.

    `홍길동900101-…`처럼 붙어 오면 그 앞부분을, 떨어져 오면 왼쪽 낱말을 **통째로** 본다.
    같은 칸으로 볼 간격은 하이라이트와 같은 `_NAME_GAP_RATIO × 글자 높이`다.
    """
    word = line.words[wi]
    boxes: list[Box] = []
    inline = word.text[:ci].strip()
    if inline and not _is_label(inline):
        if not _not_a_person(inline):
            boxes.append(_sub_box(word, 0, ci))
        return boxes  # 이름(또는 기관명)이 같은 낱말에 붙어 왔다 — 왼쪽 낱말은 다른 칸이다
    max_gap = _NAME_GAP_RATIO * med_h
    right_edge = word.x0
    found = 0
    for j in range(wi - 1, max(-1, wi - 4), -1):  # 이름은 길어야 두 낱말 + 꼬리표 하나를 건너뛸 여유
        prev = line.words[j]
        if prev.x1 < right_edge - max_gap:
            break  # 너무 멀다 → 다른 칸
        text = prev.text.strip()
        if _is_label(text):
            if found:
                break  # 이름 앞의 꼬리표(`소유자`)까지 왔다 — 이름은 끝났다
            right_edge = prev.x0
            continue
        if not _maybe_name(text):
            break  # 날짜·금액·기관 — 이름 칸이 아니다
        boxes.append(prev.box)
        found += 1
        if _hangul_count(text) >= 3 or found >= 2:
            break  # 이름 하나가 다 찼다(`홍길동`, `남궁 민수`)
        right_edge = prev.x0
    return boxes


def _id_masks(line: Line, med_h: float) -> tuple[list[Box], list[Box]]:
    """(등록번호 상자들, 그 앞 이름 상자들)."""
    text, where = _concat(line)
    ids: list[Box] = []
    names: list[Box] = []
    for m in _ID_ANY.finditer(text):
        ids.extend(_span_boxes(line, where, m.start(), m.end()))
        wi, ci = where[m.start()]
        names.extend(_names_before(line, wi, ci, med_h))
    return ids, names


# ══════════════════════════════════════════════════════════════════════════════
# 찾는 길 ② 역할어 뒤 이름 (번호 없는 칸 — 채무자 등)
# ══════════════════════════════════════════════════════════════════════════════


def _role_masks(line: Line, med_h: float) -> list[Box]:
    out: list[Box] = []
    max_gap = _NAME_GAP_RATIO * med_h
    for i, w in enumerate(line.words):
        text = w.text.strip()
        role = next((r for r in _ROLE_ANCHORS if text.startswith(r)), None)
        if role is None:
            continue
        rest = text[len(role):]
        if rest:
            # 역할어에 이름이 붙어 왔다: `채무자홍길동` → 역할어 뒤를 덮는다
            # (`채무자변경`처럼 붙은 것이 등기원인어면 이름이 아니다)
            if _maybe_name(rest):
                out.append(_sub_box(w, len(role), len(text)))
            continue
        prev = w
        for nxt in line.words[i + 1 : i + 3]:  # 이름은 길어야 두 낱말
            if nxt.x0 - prev.x1 > max_gap:
                break
            if not _maybe_name(nxt.text.strip()):
                break
            out.append(nxt.box)
            if _hangul_count(nxt.text) >= 3:
                break
            prev = nxt
    return out


# ══════════════════════════════════════════════════════════════════════════════
# 찾는 길 ③ IE가 읽은 사람 이름과 대조
# ══════════════════════════════════════════════════════════════════════════════

_OTHERS_TAIL = re.compile(r"\s*외\s*\d+\s*(?:명|인)\s*$")


def name_values(extract: RegistryExtract | None) -> list[str]:
    """IE가 읽은 **이름 칸의 글자 그대로** — 현재 소유자 + `_IE_NAME_FIELDS`. 사람·기관을 가리지 않고 전부."""
    if extract is None:
        return []
    raw: list[object] = [o.name for o in extract.current_owners]
    for key, attrs in _IE_NAME_FIELDS:
        for entry in getattr(extract, key, None) or []:
            raw.extend(getattr(entry, attr, None) for attr in attrs)
    return [v for v in raw if isinstance(v, str) and v.strip()]


def without_others_tail(value: str) -> str:
    """`홍길동 외 1명` → `홍길동`."""
    return _OTHERS_TAIL.sub("", value or "")


def is_person_value(value: str) -> bool:
    """이름 칸 하나가 **사람**으로 보이는가 — 기관·관공서·표 머리 낱말이면 아니다(`외 N명` 꼬리는 떼고 본다)."""
    compact = "".join(without_others_tail(value).split())
    return len(compact) >= 2 and not _is_label(compact) and not _not_a_person(compact)


def person_names(extract: RegistryExtract | None) -> list[str]:
    """IE 결과에서 **사람으로 보이는** 이름 낱말만 (긴 것부터). 기관·관공서·꼬리표는 뺀다.

    ⚠ 위치를 찾는 데만 쓴다 — 응답·로그에 싣지 않는다. 화면용 실명 목록(`Report.personNames`)은 따로
      `name_privacy.person_names`가 **이름 칸 글자 그대로** 만든다(낱말로 쪼개지 않는다 — 2026-10-22).
    ⚠ 접두어를 떼지 않는다 — `이전수` 같은 이름이 '이전'(등기원인어)에 잘려 사라진다.
    ⚠ **주소에 든 낱말은 뺀다.** 압류 채권자가 `서울특별시 양천구`면 `양천구`가 사람 이름처럼 남아,
      모든 쪽 머리의 주소 줄(대조할 곳)이 가려진다. 진짜 이름 칸은 ①②가 따로 덮는다.
    """
    if extract is None:
        return []
    address = "".join((extract.address or "").split())
    names: set[str] = set()
    for value in name_values(extract):
        for token in re.split(r"[\s,·/()]+", _OTHERS_TAIL.sub("", value)):
            token = token.strip()
            if len(token) < 2 or not all(_is_hangul(c) for c in token):
                continue
            if _is_label(token) or _not_a_person(token) or token in address:
                continue
            names.add(token)
    return sorted(names, key=len, reverse=True)


def _known_name_masks(line: Line, names: list[str]) -> list[Box]:
    if not names:
        return []
    text, where = _concat(line)
    out: list[Box] = []
    for name in names:
        start = text.find(name)
        while start != -1:
            out.extend(_span_boxes(line, where, start, start + len(name)))
            start = text.find(name, start + len(name))
    return out


# ══════════════════════════════════════════════════════════════════════════════
# 모으기 · 합치기 · 정규화
# ══════════════════════════════════════════════════════════════════════════════


def _overlaps(a: Box, b: Box) -> bool:
    return a[0] <= b[2] and b[0] <= a[2] and a[1] <= b[3] and b[1] <= a[3]


def _merge(boxes: list[Box]) -> list[Box]:
    """겹치는 상자를 하나로 — 같은 이름을 두 길이 함께 찾아도 상자는 하나다."""
    merged: list[Box] = []
    for box in sorted(boxes):
        cur = box
        changed = True
        while changed:
            changed = False
            for other in list(merged):
                if _overlaps(cur, other):
                    merged.remove(other)
                    cur = (
                        min(cur[0], other[0]),
                        min(cur[1], other[1]),
                        max(cur[2], other[2]),
                        max(cur[3], other[3]),
                    )
                    changed = True
        merged.append(cur)
    return merged


def _normalize(box: Box, page: OcrPage) -> PrivacyMask | None:
    if page.width <= 0 or page.height <= 0:
        return None
    x0, y0, x1, y1 = box
    pad_x = (x1 - x0) * _PAD_RATIO
    pad_y = (y1 - y0) * _PAD_RATIO
    x0, y0 = max(0.0, x0 - pad_x), max(0.0, y0 - pad_y)
    x1, y1 = min(float(page.width), x1 + pad_x), min(float(page.height), y1 + pad_y)
    if x1 <= x0 or y1 <= y0:
        return None
    return PrivacyMask(
        page=page.index,
        x=round(x0 / page.width, 6),
        y=round(y0 / page.height, 6),
        w=round((x1 - x0) / page.width, 6),
        h=round((y1 - y0) / page.height, 6),
    )


def _full_page(index: int) -> PrivacyMask:
    x, y, w, h = FULL_PAGE
    return PrivacyMask(page=index, x=x, y=y, w=w, h=h)


def _page_boxes(page: OcrPage, names: list[str], counts: dict[str, int]) -> list[Box]:
    med_h = median_height(page.words)
    boxes: list[Box] = []
    for line in page.lines:
        if detect_columns(line, page.name, med_h) is not None:
            continue  # 표 머리(`순위번호 … 권리자 및 기타사항`) — 이름이 없다
        ids, id_names = _id_masks(line, med_h)
        roles = _role_masks(line, med_h)
        known = _known_name_masks(line, names)
        counts["id"] += len(ids)
        counts["name_id"] += len(id_names)
        counts["name_role"] += len(roles)
        counts["name_known"] += len(known)
        boxes += ids + id_names + roles + known
    return _merge(boxes)


def build_privacy_masks(
    ocr: OcrResult, extract: RegistryExtract | None = None, *, page_count: int | None = None
) -> PrivacyMaskResult:
    """OCR 결과(+IE 결과) → 가림 상자. **예외를 밖으로 던지지 않는다.**

    `page_count`는 **올라온 사진 장수**다. OCR이 실패한 쪽은 `ocr.pages`에 아예 없으므로, 이 값이 있어야
    그 쪽을 '못 찾아본 쪽'으로 알고 통째로 덮을 수 있다(없으면 OCR이 돌려준 쪽만 다룬다).

    `page`는 **업로드 순서**(0부터)다 — 하이라이트처럼 사진 순서를 다시 세우지 않는다. 가림 상자는
    낱말 하나·줄 하나 안에서 끝나므로 쪽 순서와 무관하다.
    """
    result = PrivacyMaskResult(counts={"id": 0, "name_id": 0, "name_role": 0, "name_known": 0})
    try:
        names = person_names(extract)
    except Exception:  # noqa: BLE001 — 이름 대조가 깨져도 ①②는 돈다
        _log.error("[가리기] ⚠ 추출 이름 목록을 만들지 못함 — 등록번호·역할어로만 찾습니다", exc_info=True)
        names = []

    by_index = {p.index: p for p in ocr.pages}
    # 올라온 장수와 OCR이 돌려준 쪽 중 **큰 쪽**까지 본다 — 어느 쪽도 조용히 빠지지 않게.
    total = max(page_count or 0, (max(by_index) + 1) if by_index else 0)
    for index in range(total):
        page = by_index.get(index)
        masks: list[PrivacyMask] | None = None
        if page is not None and page.words:
            try:
                boxes = _page_boxes(page, names, result.counts)
                normalized = [_normalize(b, page) for b in boxes]
                if all(m is not None for m in normalized):
                    masks = [m for m in normalized if m is not None]
            except Exception:  # noqa: BLE001 — 한 쪽이 깨져도 다른 쪽은 가린다
                _log.error(f"[가리기] ⚠ {index + 1}쪽에서 찾다가 예외 — 그 쪽은 통째로 덮습니다", exc_info=True)
        if masks is None:
            # 글자를 못 읽었거나(OCR 실패·0글자) 원본 크기를 모른다 → 이름 자리를 모른다 → 통째로 덮는다
            result.masks.append(_full_page(index))
            result.unchecked_pages.append(index)
            continue
        result.masks.extend(masks)
        result.checked_pages.append(index)

    c = result.counts
    _log.info(
        f"[가리기] 사진 {total}장 중 {len(result.checked_pages)}장에서 찾아봄"
        f" — 가림 상자 {len(result.masks) - len(result.unchecked_pages)}개"
        f" + 통째로 덮은 쪽 {len(result.unchecked_pages)}장"
        f" (등록번호 {c['id']} · 번호 앞 이름 {c['name_id']} · 역할어 뒤 이름 {c['name_role']}"
        f" · 추출 이름 대조 {c['name_known']}, 겹친 것은 합침)"
    )
    return result
