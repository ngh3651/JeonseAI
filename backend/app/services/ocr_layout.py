"""Document OCR 응답의 레이아웃 해석 — 단어 → 줄 → **등기 항목**.

⚠ 이 모듈은 **표시(하이라이트) 전용**이다. 위험 판정(규칙 엔진)에 어떤 영향도 주지 않는다.
  여기서 나오는 말소 판정은 "어디에 칠하지 **않을지**"를 정할 뿐, 등급·점수·근거 카드를
  바꾸지 않는다. 판정은 Information Extract + rule_engine 경로 그대로다.

왜 이런 구조인가 (2026-07-27 실측 근거 — docs/ocr-highlight-findings.md):
- OCR은 **텍스트와 좌표만** 준다. 선·스타일이 없어 **취소선으로 말소를 알 수 없다**.
  말소는 "N번○○등기말소"라는 **별도 행**으로만 드러난다 → 이 텍스트를 파싱하는 것이
  유일한 경로다.
- 등기부는 표다. 한 칸(cell) 안의 글이 여러 줄로 접히고, 그 사이에 옆 칸 글자가 끼어든다.
  줄 단위로 이어붙이면 `1번근저당권설정등` + (날짜) + `기말소` 로 끊긴다.
  → **컬럼 x밴드로 걸러 같은 칸 글자끼리만 이어붙인다.**
- 순위번호는 "줄 맨 앞 숫자"가 아니다. 등기목적 칸에 접힌 분수의 분모("2분의 / 1")도
  줄 맨 앞에 온다. → **헤더의 `순위번호` word x범위를 밴드로 삼아** 그 안의 숫자만 인정한다.

레이아웃 파라미터(`_GAP_RATIO` 등)는 **표 인식용 튜닝값**이지 위험 임계값이 아니다
(risk-scoring 규칙의 "출처 없는 수치 금지" 대상 아님).
"""

from __future__ import annotations

import logging
import re
import statistics
from dataclasses import dataclass, field

_log = logging.getLogger("jeonseai")

# ── 레이아웃 튜닝 파라미터 (위험 임계값 아님) ────────────────────────────────
# 컬럼 경계로 볼 word 간 x간격 = 이 비율 × 글자높이 중앙값.
# 실측(3.png 헤더): 칸 안 간격 7~16px, 칸 사이 간격 44~177px, 글자높이 ~16px.
# 1.8×16 = 28.8 → 두 분포 사이를 넉넉히 가른다. 해상도가 달라져도 글자높이에
# 비례하므로 그대로 통한다(절대 픽셀값 하드코딩 회피).
_GAP_RATIO = 1.8
# 순위번호 밴드 여유 — 헤더 word 폭의 이 비율만큼 좌우로 넓힌다.
_RANK_BAND_MARGIN = 0.15
# 이름 word와 등록번호 word 사이 허용 간격 = 이 비율 × 글자높이 (다른 칸 침범 방지).
# 실측 간격 14~15px, 글자높이 16px → 2.5×16 = 40px 이내면 같은 칸으로 본다.
_NAME_GAP_RATIO = 2.5

# ── 정규식 ───────────────────────────────────────────────────────────────────
# 등록번호: 개인 주민번호는 뒤 7자리가 마스킹(`○○○○○○-○******`),
#          법인등록번호는 뒤 7자리가 숫자(`110111-0015671`) — 이것이 개인/법인 판별 근거.
_ID_PATTERN = re.compile(r"(\d{6})\s*[-－]\s*([0-9*]{6,8})")
_RANK_TEXT = re.compile(r"^(\d{1,3})(?:[-－](\d{1,2}))?$")
_PERSON_NAME = re.compile(r"^[가-힣]{2,4}$")
_MONEY = re.compile(r"\d{1,3}(?:,\d{3})+")
# 말소 근거 행: "1번근저당권설정등기말소" — 등기목적 칸 텍스트에서만 찾는다.
_CANCEL_TARGET = re.compile(r"(\d{1,3})번([가-힣]{1,20}?)말소")
# 대상 순위를 못 읽은 말소 행을 잡는 안전망 — **등기목적으로 읽히는 말소만** 인정한다.
#
# 예전에는 `말소` 한 글자만 봤다. 그러면 페이지 하단 안내 문구
# "실선으로 그어진 부분은 **말소**사항을 표시함"이 말소 근거 행으로 잡히는데,
# 그 문구에는 대상 순위(`N번`)가 없으니 `cancel_bound`가 False로 남고,
# 라운드 4 방어(미결 말소 → 금액 표시 전체 보류)가 발동한다. 이 안내 문구는
# **모든 등기부 맨 아래에 인쇄**되므로 근저당 하이라이트가 영구히 사라진다
# (2026-07-27 실호출에서 실제 발생 — 유효 근저당 3건이 전부 묻혔다).
#
# 보수적 편향은 그대로다: 진짜 `N번…말소` 행이 대상을 못 찾으면 여전히 보류한다.
# 여기서 좁힌 것은 "산문 속의 말소"뿐이다.
_CANCEL_ANY = re.compile(r"등기말소|말소등기|말소$")
# 페이지 머리말(주소 줄) — 항목 본문이 아니므로 항목에 붙이지 않는다.
_PAGE_HEADER = re.compile(r"^\s*\[(집합건물|건물|토지)\]")
# 문서 머리말·꼬리말 — 표지/발급정보 줄. 어떤 등기 항목에도 속하지 않는다.
# 이걸 걸러내지 않으면, 앞 페이지에서 열려 있던 항목이 다음 페이지 표지의
# "등기사항전부증명서(**말소**사항 포함)" 를 삼켜 **엉뚱한 항목이 말소로 보인다**
# (2026-07-27 실측: 매매목록 순위2가 1.png 표지를 먹고 '말소근거행'으로 오탐).
_DOC_PREAMBLE = re.compile(
    r"등기사항전부증명서|고유번호|제출용|열람일시|발급확인번호|인터넷등기소|수수료|관할등기소"
)
# 페이지 **하단**의 안내·범례 — 표 바깥의 인쇄 문구다. 등기 행이 아니다.
#
# 실측(2026-07-27 page_5.jpg L8·L11~L13):
#   `-- 이 하 여 백 --`
#   `* 실선으로 그어진 부분은 말소사항을 표시함. * 기록사항 없는 갑구, 을구는 …`
#   `* 증명서는 컬러 또는 흑백으로 출력 가능함.`
#   `* 본 등기사항증명서는 열람용이므로 …`
# 이 줄들은 마지막 페이지 아래에 있어, 앞 페이지에서 열려 있던 **마지막 등기 항목이
# 통째로 삼킨다**. 그러면 등기목적 칸이 "근저당권설정 + 그어진부분은말소사항을표시함…"이
# 되어 유효한 근저당이 말소 근거 행으로 오탐된다(위 `_CANCEL_ANY` 주석 참고).
# `등기사항증명서`는 `_DOC_PREAMBLE`의 `등기사항전부증명서`와 다른 문자열이라 따로 필요하다.
_DOC_FOOTNOTE = re.compile(
    r"실선으로|말소사항을표시|기록사항없|컬러또는흑백|출력가능|열람용|법적인효력"
    r"|이하여백|등기사항증명서"
)

# 하이라이트·말소 판정의 유효 구역 — 권리관계가 기록되는 곳은 갑구·을구뿐이다.
# 표제부(건물 표시)·매매목록은 권리 항목이 아니라 부가 정보라 대상에서 뺀다.
RIGHTS_SECTIONS = ("갑구", "을구")
# 첫 페이지에 구역 머리(【갑 구】 등)가 없으면 구역을 모른 채 항목이 시작될 수 있다.
UNKNOWN_SECTION = "미상"

# 페이지 꼬리말 표식 — 실측(1.png "1/5", 5.png "5/5"). 페이지 순서·누락 판별에 쓴다.
_PAGE_MARKER = re.compile(r"^(\d{1,3})\s*/\s*(\d{1,3})$")
# 발급확인번호 — 같은 발급본이면 전 페이지 동일(실측: 1.png·5.png 모두 AAPI-GJBJ-1806)
_ISSUE_NO = re.compile(r"([A-Z]{3,5}[-－][A-Z]{3,5}[-－]\d{3,5})")

# 표 헤더의 첫 컬럼 이름 (이 word가 있는 줄을 헤더로 보고 컬럼 밴드를 갱신한다)
_RANK_HEADERS = ("순위번호", "표시번호", "일련번호")

# 구역 — 등기부의 큰 묶음. `【 갑 구 】` 처럼 글자가 흩어져 오므로 공백 제거 후 본다.
_SECTIONS = ("갑구", "을구", "표제부", "매매목록")

# 이름 앞에 붙어 오는 역할어·등기원인어 (OCR이 한 word로 붙여버린 경우 떼어낸다).
# 긴 것부터 지워야 '신탁'이 '신탁자'를 잘라먹지 않는다 → _PREFIXES에서 길이순 정렬.
_ROLE_WORDS = (
    "근저당권자", "전세권자", "임차권자", "가압류권자", "압류권자", "소유자", "공유자",
    "채무자", "채권자", "권리자", "임차인", "신탁자", "수탁자", "위탁자", "지분",
)
_CAUSE_WORDS = (
    "설정계약", "협의분할에의한상속", "협의분할", "재산분할", "공유물분할", "현물출자",
    "대물변제", "확정판결", "임의경매", "강제경매", "매매", "증여", "상속", "해지",
    "경매", "신탁", "교환", "양도", "분할", "변경", "이전",
)
_PREFIXES = tuple(sorted(set(_ROLE_WORDS + _CAUSE_WORDS), key=len, reverse=True))


# ══════════════════════════════════════════════════════════════════════════════
# 자료구조
# ══════════════════════════════════════════════════════════════════════════════


@dataclass
class Word:
    """OCR 단어 하나 — 텍스트 + confidence + 사각 bbox(**전송한 원본 이미지의 픽셀**)."""

    text: str
    confidence: float
    x0: float
    y0: float
    x1: float
    y1: float

    @property
    def cx(self) -> float:
        return (self.x0 + self.x1) / 2

    @property
    def cy(self) -> float:
        return (self.y0 + self.y1) / 2

    @property
    def height(self) -> float:
        return max(1.0, self.y1 - self.y0)

    @property
    def box(self) -> tuple[float, float, float, float]:
        return (self.x0, self.y0, self.x1, self.y1)


@dataclass
class Line:
    """같은 줄로 묶인 단어들 (왼→오 정렬)."""

    index: int
    words: list[Word]

    @property
    def box(self) -> tuple[float, float, float, float]:
        return (
            min(w.x0 for w in self.words),
            min(w.y0 for w in self.words),
            max(w.x1 for w in self.words),
            max(w.y1 for w in self.words),
        )

    @property
    def display(self) -> str:
        return " ".join(w.text for w in self.words)

    def concat(self) -> tuple[str, list[int]]:
        """패턴 매칭용 — **공백 없이** 이어붙인 문자열 + 문자→word 인덱스 맵."""
        buf: list[str] = []
        owner: list[int] = []
        for i, w in enumerate(self.words):
            for ch in w.text:
                buf.append(ch)
                owner.append(i)
        return "".join(buf), owner

    @property
    def squeezed(self) -> str:
        return "".join(w.text for w in self.words)


@dataclass
class OcrPage:
    """이미지 1장의 OCR 결과 (좌표는 이 이미지의 픽셀 기준)."""

    name: str  # 표시용 이름 (파일 stem)
    index: int  # 업로드 순서 (0부터) — 앱이 몇 번째 사진에 그릴지 결정
    words: list[Word]
    lines: list[Line]
    width: int = 0  # 원본 픽셀 크기 (Pillow로 직접 읽은 값 — OCR 응답을 믿지 않는다)
    height: int = 0


@dataclass
class ColumnBands:
    """표 컬럼의 x 밴드 — 헤더 줄에서 뽑는다."""

    kind: str  # "순위번호" | "표시번호" | "일련번호"
    rank: tuple[float, float]
    purpose: tuple[float, float]
    origin: str  # 어느 페이지/줄에서 왔는지 (로그·근거용)


@dataclass
class NameHit:
    """등록번호 앞에서 잡아낸 권리자 이름 1건."""

    name: str
    kind: str  # "개인" | "법인"
    id_prefix: str  # 앞 6자리 (로그는 마스킹해서 쓴다)
    box: tuple[float, float, float, float]
    word_index: int
    page_index: int
    line_index: int
    raw_candidate: str  # 다듬기 전 원본 word (진단용)
    stripped: list[str] = field(default_factory=list)  # 떼어낸 접두어


@dataclass
class MoneyHit:
    """금액 word 1건."""

    text: str
    box: tuple[float, float, float, float]
    page_index: int
    line_index: int


@dataclass
class RegistryItem:
    """등기 표의 '항목' 하나 — 순위번호 줄부터 다음 순위번호 전까지 (페이지 넘어갈 수 있음)."""

    section: str
    rank: str | None
    # 순위번호 word 자체 — 매칭 앵커로 쓴다("순위번호와 금액이 같은 줄에 있는가").
    rank_box: tuple[float, float, float, float] | None = None
    rank_page_index: int = -1
    rank_line_index: int = -1
    lines: list[tuple[int, str, Line]] = field(default_factory=list)  # (page_index, page_name, line)
    purpose_words: list[Word] = field(default_factory=list)
    names: list[NameHit] = field(default_factory=list)
    moneys: list[MoneyHit] = field(default_factory=list)
    canceled: bool = False
    cancel_evidence: str | None = None
    is_cancel_record: bool = False  # 이 항목 자체가 '○번○○등기말소' 행인가
    # 말소 근거 행이 **대상 항목을 실제로 찾았는가**. False면 "무언가 말소됐는데 무엇인지
    # 모른다"는 뜻이라, 금액 하이라이트를 통째로 보류해야 한다(잘못 칠하면 최악의 오류).
    cancel_bound: bool = False

    @property
    def purpose(self) -> str:
        """등기목적 칸 텍스트 — **같은 칸 word만** 읽기순으로 이어붙인 것."""
        return "".join(w.text for w in self.purpose_words)

    @property
    def location(self) -> str:
        """근거 표기용 위치 — 예: `4:L12-13` (여러 페이지면 `3:L30-33,4:L2-4`)."""
        by_page: dict[str, list[int]] = {}
        for _, page_name, line in self.lines:
            by_page.setdefault(page_name, []).append(line.index)
        parts = []
        for page_name, idxs in by_page.items():
            lo, hi = min(idxs), max(idxs)
            parts.append(f"{page_name}:L{lo}" if lo == hi else f"{page_name}:L{lo}-{hi}")
        return ",".join(parts)

    @property
    def page_indexes(self) -> list[int]:
        seen: list[int] = []
        for page_index, _, _ in self.lines:
            if page_index not in seen:
                seen.append(page_index)
        return seen

    def box_on_page(self, page_index: int) -> tuple[float, float, float, float] | None:
        boxes = [line.box for pi, _, line in self.lines if pi == page_index]
        if not boxes:
            return None
        return (
            min(b[0] for b in boxes),
            min(b[1] for b in boxes),
            max(b[2] for b in boxes),
            max(b[3] for b in boxes),
        )


# ══════════════════════════════════════════════════════════════════════════════
# 파싱 / 줄 묶기
# ══════════════════════════════════════════════════════════════════════════════


def parse_words(raw: dict) -> list[Word]:
    """OCR 원본 JSON → Word 목록. `pages[].words[]`, 최상위 `words[]` 둘 다 허용."""
    out: list[Word] = []
    containers = raw.get("pages") or []
    if not containers and raw.get("words"):
        containers = [raw]
    for page in containers:
        for w in page.get("words") or []:
            verts = (w.get("boundingBox") or {}).get("vertices") or []
            xs = [float(v.get("x", 0)) for v in verts]
            ys = [float(v.get("y", 0)) for v in verts]
            if not xs or not ys:
                continue
            out.append(
                Word(
                    text=w.get("text", ""),
                    confidence=float(w.get("confidence", 0.0)),
                    x0=min(xs),
                    y0=min(ys),
                    x1=max(xs),
                    y1=max(ys),
                )
            )
    return out


def group_lines(words: list[Word], tol_ratio: float = 0.6) -> list[Line]:
    """y중심과 글자높이로 같은 줄을 묶는다 (표 형식이라 같은 y의 다른 칸도 한 줄이 된다)."""
    if not words:
        return []
    ordered = sorted(words, key=lambda w: (w.cy, w.x0))
    buckets: list[list[Word]] = [[ordered[0]]]
    for w in ordered[1:]:
        cur = buckets[-1]
        ref_cy = statistics.median([x.cy for x in cur])
        ref_h = statistics.median([x.height for x in cur] + [w.height])
        if abs(w.cy - ref_cy) <= tol_ratio * ref_h:
            cur.append(w)
        else:
            buckets.append([w])
    return [Line(index=i, words=sorted(b, key=lambda w: w.x0)) for i, b in enumerate(buckets)]


def median_height(words: list[Word]) -> float:
    return statistics.median([w.height for w in words]) if words else 16.0


# ══════════════════════════════════════════════════════════════════════════════
# 컬럼 밴드 / 구역
# ══════════════════════════════════════════════════════════════════════════════


def _group_by_gap(words: list[Word], gap: float) -> list[list[Word]]:
    """x간격이 `gap`을 넘으면 다른 컬럼으로 본다."""
    if not words:
        return []
    groups: list[list[Word]] = [[words[0]]]
    for w in words[1:]:
        if w.x0 - groups[-1][-1].x1 > gap:
            groups.append([w])
        else:
            groups[-1].append(w)
    return groups


def detect_columns(line: Line, page_name: str, med_h: float) -> ColumnBands | None:
    """헤더 줄이면 컬럼 밴드를 뽑는다. 헤더가 아니면 None.

    첫 그룹이 `순위번호`/`표시번호`/`일련번호` 여야 헤더로 인정한다.
    등기목적 밴드는 (순위번호 오른쪽 끝, **세 번째** 그룹 왼쪽 끝) — 헤더 글자가
    칸 가운데 정렬돼 있어 헤더 폭을 그대로 쓰면 실제 칸보다 훨씬 좁아지기 때문이다.
    """
    groups = _group_by_gap(line.words, _GAP_RATIO * med_h)
    if not groups:
        return None
    head = "".join(w.text for w in groups[0])
    if head not in _RANK_HEADERS:
        return None
    rank = (groups[0][0].x0, groups[0][-1].x1)
    if len(groups) >= 3:
        purpose = (rank[1], groups[2][0].x0)
    elif len(groups) == 2:
        purpose = (rank[1], groups[1][-1].x1)
    else:
        purpose = (rank[1], rank[1])
    return ColumnBands(kind=head, rank=rank, purpose=purpose, origin=f"{page_name}:L{line.index}")


def detect_section(line: Line) -> str | None:
    """`【 갑 구 】` 같은 구역 머리 줄이면 구역명을 돌려준다."""
    sq = line.squeezed
    if "【" not in sq and "[" not in sq:
        return None
    for name in _SECTIONS:
        if name in sq:
            return name
    return None


def find_rank(line: Line, bands: ColumnBands | None) -> Word | None:
    """순위번호 컬럼 밴드 안에 있는 숫자 word만 순위번호로 인정한다."""
    if bands is None:
        return None
    lo, hi = bands.rank
    margin = _RANK_BAND_MARGIN * max(1.0, hi - lo)
    for w in line.words:
        if lo - margin <= w.cx <= hi + margin and _RANK_TEXT.match(w.text.strip()):
            return w
    return None


def _purpose_words(line: Line, bands: ColumnBands | None) -> list[Word]:
    if bands is None:
        return []
    lo, hi = bands.purpose
    return [w for w in line.words if lo <= w.cx <= hi]


# ══════════════════════════════════════════════════════════════════════════════
# 이름 (권리자) 추출 — word 단위
# ══════════════════════════════════════════════════════════════════════════════


def strip_prefixes(text: str) -> tuple[str, list[str]]:
    """이름 앞에 붙은 역할어·등기원인어를 반복해서 떼어낸다."""
    removed: list[str] = []
    changed = True
    while changed:
        changed = False
        for p in _PREFIXES:
            if text.startswith(p) and len(text) > len(p):
                text = text[len(p) :]
                removed.append(p)
                changed = True
                break
    return text, removed


def _is_valid_name(name: str, kind: str) -> bool:
    if kind == "개인":
        return bool(_PERSON_NAME.match(name))
    return len(name) >= 2 and any("가" <= c <= "힣" for c in name)


def extract_names(line: Line, page_index: int, med_h: float) -> list[NameHit]:
    """등록번호 word를 먼저 찾고 **바로 앞 word**를 이름으로 삼는다.

    문자 단위 정규식(줄 전체를 공백 없이 이어붙여 매칭)은 `매매`+`소유자D`을 한 덩어리로
    삼켜 bbox가 옆 칸까지 번진다(실측 181px). word 단위로 가면 43px로 정확히 좁혀진다.
    """
    hits: list[NameHit] = []
    max_gap = _NAME_GAP_RATIO * med_h
    for i, w in enumerate(line.words):
        m = _ID_PATTERN.search(w.text)
        if not m:
            continue
        kind = "법인" if m.group(2).isdigit() else "개인"

        # ⑴ 같은 word 안에 이름이 붙어 온 경우 ("소유자A○○○○○○-○******")
        inline = w.text[: m.start()].strip()
        candidates: list[tuple[str, int]] = []
        if inline:
            candidates.append((inline, i))
        else:
            # ⑵ 바로 앞 word. 그것이 통째로 역할어/등기원인어면 한 칸 더 앞까지만 본다.
            for back in (1, 2):
                j = i - back
                if j < 0:
                    break
                prev = line.words[j]
                if prev.x1 < w.x0 - max_gap * back:
                    break  # 너무 멀다 → 다른 칸. 억지로 끌어오지 않는다.
                candidates.append((prev.text.strip(), j))

        for raw, j in candidates:
            name, removed = strip_prefixes(raw)
            if not _is_valid_name(name, kind):
                continue
            src = line.words[j]
            hits.append(
                NameHit(
                    name=name,
                    kind=kind,
                    id_prefix=m.group(1),
                    box=src.box,
                    word_index=j,
                    page_index=page_index,
                    line_index=line.index,
                    raw_candidate=raw,
                    stripped=removed,
                )
            )
            break
    return hits


def extract_moneys(line: Line, page_index: int) -> list[MoneyHit]:
    """콤마 금액이 들어 있는 word를 그대로 잡는다 (실측: '금36,000,000원'이 word 1개)."""
    return [
        MoneyHit(text=w.text, box=w.box, page_index=page_index, line_index=line.index)
        for w in line.words
        if _MONEY.search(w.text)
    ]


# ══════════════════════════════════════════════════════════════════════════════
# 항목 그룹화 + 말소 판정
# ══════════════════════════════════════════════════════════════════════════════


def build_items(pages: list[OcrPage], tol_ratio: float = 0.6) -> list[RegistryItem]:
    """페이지들(업로드 순서) → 등기 항목 목록.

    항목은 **페이지를 넘어 이어진다** — 을구 순위1의 금액은 3.png, 근저당권자는 4.png에
    있는 것이 실제 샘플이다. 그래서 페이지 경계에서 항목을 닫지 않는다.
    (전제: 페이지가 촬영 순서대로 들어온다. 순서가 섞이면 항목이 잘못 이어질 수 있어
     라운드 4에서 별도 방어를 둔다.)
    """
    items: list[RegistryItem] = []
    section: str | None = None
    bands: ColumnBands | None = None
    current: RegistryItem | None = None

    for page in pages:
        med_h = median_height(page.words)
        for line in page.lines:
            sec = detect_section(line)
            if sec:
                section, current = sec, None  # 구역이 바뀌면 열려 있던 항목을 닫는다
                continue
            cb = detect_columns(line, page.name, med_h)
            if cb:
                bands = cb
                continue
            squeezed = line.squeezed
            if (
                _PAGE_HEADER.match(line.display)
                or _DOC_PREAMBLE.search(squeezed)
                or _DOC_FOOTNOTE.search(squeezed)
            ):
                continue  # 표지·주소 줄·발급정보·하단 안내 — 항목 본문이 아니다

            rank_word = find_rank(line, bands)
            if rank_word is not None:
                current = RegistryItem(
                    section=section or UNKNOWN_SECTION,
                    rank=rank_word.text.strip().replace("－", "-"),
                    rank_box=rank_word.box,
                    rank_page_index=page.index,
                    rank_line_index=line.index,
                )
                items.append(current)
            if current is None:
                continue

            current.lines.append((page.index, page.name, line))
            current.purpose_words.extend(_purpose_words(line, bands))
            current.names.extend(extract_names(line, page.index, med_h))
            current.moneys.extend(extract_moneys(line, page.index))

    _apply_cancellations(items)
    return items


@dataclass
class DocumentCheck:
    """올린 사진들이 '같은 등기부 전체'인지에 대한 점검 결과.

    이 점검이 필요한 이유는 하나다 — **말소를 놓치지 않기 위해서**다.
    말소는 "N번○○등기말소"라는 별도 행으로만 드러나는데, 그 행이 **올리지 않은 페이지에**
    있으면 말소된 근저당이 유효해 보인다. 그 상태로 형광펜을 칠하면 사용자가
    "이미 없어진 빚"을 현재 위험으로 오해한다 — 이 기능의 최악의 오류다.
    """

    ok_to_highlight_money: bool = True  # 금액 항목(근저당·전세권)을 칠해도 되는가
    ok_to_highlight_any: bool = True  # 아무거나 칠해도 되는가
    notice: str | None = None  # 사용자에게 보여줄 한 줄 (없으면 None)
    reasons: list[str] = field(default_factory=list)  # 로그용 상세


def _page_footer_facts(page: OcrPage) -> tuple[tuple[int, int] | None, str | None, str | None]:
    """(페이지 표식 (n, m), 발급확인번호, 상단 주소 줄) — 없으면 각각 None."""
    marker: tuple[int, int] | None = None
    issue: str | None = None
    address: str | None = None
    for line in page.lines:
        squeezed = line.squeezed
        if address is None and _PAGE_HEADER.match(line.display):
            address = re.sub(r"\s+", "", line.display)
        if issue is None:
            m = _ISSUE_NO.search(squeezed)
            if m:
                issue = m.group(1).replace("－", "-")
        for w in line.words:
            m = _PAGE_MARKER.match(w.text.strip())
            if m:
                n, total = int(m.group(1)), int(m.group(2))
                if 1 <= n <= total <= 200:
                    marker = (n, total)
    return marker, issue, address


def check_document(pages: list[OcrPage]) -> DocumentCheck:
    """페이지 표식·발급확인번호·주소 줄로 '같은 등기부 전체인가'를 본다.

    표식이 아예 안 잡히면(잘린 사진 등) **판별 불가**로 두고 그냥 진행한다 —
    확인할 수 없다는 이유로 기능을 통째로 끄면 정상 사진에서도 아무것도 안 보인다.
    대신 로그에 "확인 불가"를 남긴다.
    """
    check = DocumentCheck()
    if not pages:
        return check

    facts = [_page_footer_facts(p) for p in pages]
    markers = [(i, m) for i, (m, _, _) in enumerate(facts) if m]
    issues = {iss for _, iss, _ in facts if iss}
    addresses = {addr for _, _, addr in facts if addr}

    # [진단] 사진 점검 실태 — 파일명·개수·참/거짓만 (발급확인번호 값·주소·이름 금지).
    # 모든 return 경로보다 앞에 두어, 어느 분기로 끝나든 한 줄은 반드시 남는다.
    _page_marks = [
        f"{p.name}={m[0]}/{m[1]}" if m else f"{p.name}=?/?"
        for p, (m, _, _) in zip(pages, facts)
    ]
    _issue_state = (
        "발급확인번호 없음" if not issues
        else "발급확인번호 일치" if len(issues) == 1
        else "발급확인번호 불일치"
    )
    if markers:
        _total = markers[0][1][1]
        _missing_state = (
            "누락 없음" if len(pages) >= _total else f"누락 의심({_total}쪽 중 {len(pages)}장)"
        )
    else:
        _missing_state = "누락 확인불가"
    if len(markers) >= 2:
        _seq = [m[0] for _, m in markers]
        _order_state = "순서 정상" if _seq == sorted(_seq) else "순서 어긋남"
    else:
        _order_state = "순서 확인불가"
    _log.info(
        f"[사진점검] {', '.join(_page_marks)}"
        f" | {_issue_state} | {_missing_state} | {_order_state}"
    )

    # ① 다른 등기부가 섞였는가 — 발급확인번호가 1순위, 상단 주소 줄이 2순위
    if len(issues) > 1:
        check.ok_to_highlight_any = False
        check.ok_to_highlight_money = False
        check.notice = "올린 사진들이 서로 다른 등기부로 보여요. 한 건물의 등기부만 올려 주세요."
        check.reasons.append(f"발급확인번호가 서로 다름: {sorted(issues)}")
        return check
    if not issues and len(addresses) > 1:
        check.ok_to_highlight_any = False
        check.ok_to_highlight_money = False
        check.notice = "올린 사진들의 주소가 서로 달라요. 한 건물의 등기부만 올려 주세요."
        check.reasons.append(f"상단 주소 줄이 서로 다름: {sorted(addresses)}")
        return check

    # ② 사진 순서가 뒤바뀌었는가 — 항목이 페이지를 걸쳐 이어지므로 순서가 틀리면 구조가 깨진다
    if len(markers) >= 2:
        seq = [m[0] for _, m in markers]
        if seq != sorted(seq):
            check.ok_to_highlight_any = False
            check.ok_to_highlight_money = False
            check.notice = "사진 순서가 등기부 쪽수와 달라요. 1쪽부터 순서대로 다시 올려 주세요."
            check.reasons.append(f"페이지 표식 순서 어긋남: {seq}")
            return check

    # ③ 빠진 페이지가 있는가 — 말소 근거 행이 그 페이지에 있을 수 있다
    if markers:
        total = markers[0][1][1]
        if len(pages) < total:
            check.ok_to_highlight_money = False
            check.notice = (
                f"등기부 {total}쪽 중 {len(pages)}쪽만 올리셨어요. "
                "빠진 쪽에 중요한 내용이 있을 수 있어 빚 표시는 생략했어요."
            )
            check.reasons.append(
                f"페이지 누락 의심: 표식은 총 {total}쪽인데 사진은 {len(pages)}장"
                " → 말소 근거 행이 빠진 쪽에 있을 수 있어 금액 표시를 보류"
            )
    else:
        check.reasons.append("페이지 표식(N/M) 미검출 — 순서·누락을 확인할 수 없음(사진이 잘렸을 수 있음)")
    return check


def _apply_cancellations(items: list[RegistryItem]) -> None:
    """'N번○○등기말소' 행을 찾아 같은 구역의 N번 항목을 말소로 표시한다.

    **근거 없이 말소로 단정하지 않는다** — 반드시 `cancel_evidence`에 어느 페이지/줄의
    어떤 문구 때문인지 남긴다. 근거를 못 만들면 말소로 표시하지 않는다(보수적 편향과
    같은 방향: 유효로 남겨 두면 형광펜이 칠해질 뿐, 위험을 숨기지는 않는다).
    """
    for item in items:
        # 권리 항목이 아닌 구역(표제부·매매목록)은 말소 판정 대상이 아니다.
        # 표지·꼬리말의 "말소사항 포함" 문구를 말소 근거로 오인하지 않기 위한 방어.
        if item.section not in RIGHTS_SECTIONS + (UNKNOWN_SECTION,):
            continue
        purpose = item.purpose
        m = _CANCEL_TARGET.search(purpose)
        if not m:
            if _CANCEL_ANY.search(purpose):
                item.is_cancel_record = True  # 말소 행이지만 대상 순위를 못 읽음
            continue
        item.is_cancel_record = True
        target_rank = m.group(1)
        evidence = f"{item.location} 의 '{m.group(0)}'"
        for target in items:
            if target is item:
                continue
            if target.rank == target_rank and _same_section(target.section, item.section):
                target.canceled = True
                target.cancel_evidence = evidence
                item.cancel_bound = True


def _same_section(a: str, b: str) -> bool:
    """구역이 같은가. **'미상'은 어느 권리 구역과도 같은 것으로 본다.**

    첫 페이지에 구역 머리(`【 을 구 】`)가 없으면(사진 순서가 뒤바뀌었거나 중간 장부터
    올렸을 때) 항목의 구역이 '미상'이 된다. 이때 엄격하게 비교하면 말소 근거 행과
    대상 항목이 서로 다른 구역으로 갈려 **말소를 놓친다** → 말소된 근저당에 형광펜이
    칠해진다. 놓치는 쪽보다 넓게 잡는 쪽이 안전하다(과잉 말소는 표시를 줄일 뿐이다)."""
    if a == b:
        return True
    return UNKNOWN_SECTION in (a, b) and {a, b} <= set(RIGHTS_SECTIONS + (UNKNOWN_SECTION,))
