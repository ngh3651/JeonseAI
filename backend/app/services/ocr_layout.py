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
import math
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
# 등록번호: 개인 주민번호는 뒤 7자리가 마스킹(`900101-*******`),
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
# 2026-10-31: 전각 괄호(［ ］)·괄호 안 띄어쓰기('[집합 건물]')도 같은 머리말로 본다(사진 OCR에서 흔하다).
_PAGE_HEADER = re.compile(r"^\s*[\[［]\s*(집합\s*건물|건물|토지)\s*[\]］]")
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
#
# 2026-10-31: 꼬리말이 **띄어 쓴 `2 / 3`**이면 OCR이 `2`·`/`·`3` 세 낱말로 주기도 하고(같은 서류의
# 다른 쪽은 한 낱말로 줬다), 앞 문장에 붙여 `아닙니다.2/3`으로 주기도 한다. 예전엔 낱말 하나가 통째로
# `N/M`일 때만 읽어서 그 쪽이 '아래가 잘림' + '빠진 쪽'이 됐고 → 빚 형광펜이 전부 숨고 '양호'가 막혔다
# (2026-10-31 시연 샘플 스캔본 2쪽). 이제 이웃한 낱말 2~3개를 이어 보고, 낱말 끝에 붙은 표식도 읽는다.
_SLASH = "/／"
_PAGE_MARKER = re.compile(rf"^(\d{{1,3}})\s*[{_SLASH}]\s*(\d{{1,3}})$")
# 앞말에 붙은 표식 — 숫자·소수점 숫자(`38.42/…`)·쉼표 뒤는 아니다
_MARKER_TAIL = re.compile(rf"(?<![\d,{_SLASH}])(?<!\d\.)(\d{{1,3}})\s*[{_SLASH}]\s*(\d{{1,3}})$")
_NUM_ONLY = re.compile(r"^(\d{1,3})$")
_NUM_TAIL = re.compile(rf"(?<![\d,{_SLASH}])(?<!\d\.)(\d{{1,3}})$")
_NUM_SLASH_TAIL = re.compile(rf"(?<![\d,{_SLASH}])(?<!\d\.)(\d{{1,3}})[{_SLASH}]$")
_SLASH_NUM = re.compile(rf"^[{_SLASH}](\d{{1,3}})$")
_SLASH_ONLY = re.compile(rf"^[{_SLASH}]$")
# 이어 볼 낱말 사이 간격 상한 (× 글자 높이) — 멀리 떨어진 다른 칸 숫자를 이어 붙이지 않게
_MARKER_JOIN_GAP = 2.0
# 발급확인번호 — 같은 발급본이면 전 페이지 동일(실측: 1.png·5.png 모두 ABCD-EFGH-0000)
_ISSUE_NO = re.compile(r"([A-Z]{3,5}[-－][A-Z]{3,5}[-－]\d{3,5})")
# 열람일시 — **표시 전용**이다. 판정에 쓰지 않는다.
#
# 왜 필요한가: 등기부는 열람 시점의 스냅샷이다. 열람 뒤에 근저당이 새로 잡혔을 수 있고,
# 계약 직전 근저당 설정은 실제 전세사기 수법이다. 그런데 화면에는 '분석일'만 있어
# 사용자가 "오늘 서류"로 믿게 된다(실측 샘플: 열람 7/9, 분석 7/27 — 18일 차이).
#
# 이미 꼬리말 줄을 훑고 있으므로(_page_footer_facts) 같은 자리에서 함께 읽는다 —
# OCR을 새로 부르지 않는다. 실측 라인: `열람일시 : 2026년07월09일 17시12분20초`
_VIEWED_AT = re.compile(r"열람일시[^0-9]{0,4}(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일")

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
    # 기울기 보정 좌표(가운데 점) — **줄 묶기·칸 판정 전용** (2026-10-31, `group_lines`가 채운다).
    # 사진이 비스듬하면 같은 줄 글자도 y가 조금씩 달라 줄이 쪼개진다. 형광펜·가림 상자는 언제나
    # 위의 원본 좌표(`box`)로 그린다. None = 보정하지 않음(바로 선 사진) = 원본과 같다.
    lx: float | None = field(default=None, repr=False, compare=False)
    ly: float | None = field(default=None, repr=False, compare=False)
    # 기울어진 낱말의 상자는 실제 글자보다 키가 크다(비스듬한 직사각형을 감싼 상자) — 바로 세운 글자 높이.
    lh: float | None = field(default=None, repr=False, compare=False)

    @property
    def cx(self) -> float:
        return (self.x0 + self.x1) / 2

    @property
    def cy(self) -> float:
        return (self.y0 + self.y1) / 2

    # ── 보정 좌표 (줄·칸 판정용) — 보정하지 않았으면 원본 좌표 그대로 ──
    @property
    def lcx(self) -> float:
        return self.cx if self.lx is None else self.lx

    @property
    def lcy(self) -> float:
        return self.cy if self.ly is None else self.ly

    @property
    def lheight(self) -> float:
        return self.height if self.lh is None else self.lh

    @property
    def lx0(self) -> float:
        return self.lcx - (self.x1 - self.x0) / 2

    @property
    def lx1(self) -> float:
        return self.lcx + (self.x1 - self.x0) / 2

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
    # 글자가 바로 서도록 사진을 시계 방향으로 돌린 각도(0·90·180·270) — 좌표·크기는 **돌린 사진 기준**이다
    # (`orientation.py`, 2026-10-26). 앱은 폰의 원본 사진을 이만큼 돌려 그린다.
    rotation: int = 0


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


@dataclass(frozen=True)
class Skew:
    """사진 기울기 — 글자 줄의 기울기(dy/dx)를 y에 따라 1차식으로 본다: `slope(y) = slope0 + per_y·(y − yc)`.

    한 각도(종이를 돌려 찍음)면 `per_y = 0`. 폰을 옆으로 비스듬히 들면(원근) 위·아래 줄의 기울기가 달라져
    `per_y`가 생긴다. **AI가 아니라 OCR 낱말 좌표의 기하 계산**이다(사진 픽셀은 건드리지 않는다).
    """

    slope0: float
    per_y: float
    xc: float
    yc: float
    pairs: int

    def slope_at(self, y: float) -> float:
        return self.slope0 + self.per_y * (y - self.yc)

    @property
    def degrees(self) -> float:
        return math.degrees(math.atan(self.slope0))


# 기울기 보정 기준 — **사진 기하 기준(위험 임계값 아님)**. 왜: 줄 묶기 허용 오차가 글자 높이의 0.6배라
# 폭 1,900px 사진에서 1°만 기울어도 줄 양 끝이 33px(글자 높이 25px 안팎) 어긋나 같은 줄이 쪼개진다
# → 순위번호와 금액이 '다른 줄'이 돼 빚 형광펜이 사라진다(합성 을구로 잰 값: 2°부터 사라짐 — 테스트).
_SKEW_MIN_PAIRS = 12  # 이웃 낱말 쌍이 이보다 적으면 기울기를 믿지 않는다(보정 안 함)
_SKEW_MIN_SLOPE = math.tan(math.radians(0.25))  # 이보다 덜 기울면 바로 선 것으로 본다 — 예전과 똑같이 묶는다
_SKEW_MAX_SLOPE = math.tan(math.radians(25))  # 이보다 더 기울면 보정하지 않는다(옆으로 찍은 사진은 orientation 몫)
_SKEW_PAIR_GAP = 3.0  # 이웃으로 볼 낱말 사이 x 간격 상한 (× 글자 높이)
_SKEW_PAIR_DY = 0.9  # 이웃으로 볼 y 차이 상한 (× 글자 높이) — 윗줄·아랫줄 낱말과 짝짓지 않게
_SKEW_BINS = 8  # 높이를 이만큼 구간으로 나눠 구간마다 가운데 기울기를 본다(원근 사진은 위·아래가 다르다)
_SKEW_INLIER = math.tan(math.radians(1.5))  # 1차식에서 이만큼 넘게 벗어난 쌍은 버린다(다른 줄과 짝지은 것)
_SKEW_RESIDUAL = math.tan(math.radians(0.8))  # 다시 맞춘 뒤 이만큼 넘게 벗어난 쌍은 한 번 더 버린다
_SKEW_SPAN_FOR_TREND = 0.3  # 쌍들이 글자 높이 범위의 이만큼 넘게 퍼져 있어야 위·아래 기울기 차이를 믿는다


def _weighted_median(values: list[float], weights: list[float]) -> float:
    order = sorted(range(len(values)), key=values.__getitem__)
    half = sum(weights) / 2
    acc = 0.0
    for i in order:
        acc += weights[i]
        if acc >= half:
            return values[i]
    return values[order[-1]]


def _fit_slope(pairs: list[tuple[float, float, float]]) -> tuple[float, float, float]:
    """(기울기, 무게, y) 쌍들 → 가중 최소제곱 1차식 (a, b, ybar): slope(y) = a + b·(y − ybar)."""
    total = sum(p[1] for p in pairs)
    ybar = sum(p[1] * p[2] for p in pairs) / total
    a = sum(p[1] * p[0] for p in pairs) / total
    syy = sum(p[1] * (p[2] - ybar) ** 2 for p in pairs)
    b = sum(p[1] * (p[2] - ybar) * (p[0] - a) for p in pairs) / syy if syy > 0 else 0.0
    return a, b, ybar


def _neighbor_pairs(usable: list[Word]) -> list[tuple[float, float, float]]:
    """낱말마다 **바로 오른쪽 이웃**(간격이 좁고 높이가 비슷한 같은 줄 낱말)과 짝 → (기울기, 가로 거리, 가운데 y)."""
    by_x0 = sorted(usable, key=lambda w: w.x0)
    pairs: list[tuple[float, float, float]] = []
    for i, w in enumerate(by_x0):
        h = w.height
        best: tuple[float, Word] | None = None
        for v in by_x0[i + 1 :]:
            if v.x0 > w.x1 + _SKEW_PAIR_GAP * h:
                break  # x0 순으로 줄 세웠으니 여기부터는 전부 더 멀다
            if v.x0 < w.x1 - 0.5 * h:
                continue  # 가로로 겹친다 = 윗줄·아랫줄 낱말
            if not 0.6 <= v.height / h <= 1.67:
                continue
            if abs(v.cy - w.cy) > _SKEW_PAIR_DY * max(h, v.height):
                continue
            gap = v.x0 - w.x1
            if best is None or gap < best[0]:
                best = (gap, v)
        if best is not None:
            v = best[1]
            dx = v.cx - w.cx
            if dx > 0:
                pairs.append(((v.cy - w.cy) / dx, dx, (w.cy + v.cy) / 2))
    return pairs


def estimate_skew(words: list[Word]) -> Skew | None:
    """OCR 낱말 좌표로 사진 기울기를 잰다. 바로 섰거나(0.25° 미만) 믿을 근거가 부족하면 None. 예외 없음.

    ① 이웃 낱말 쌍의 기울기 → ② 높이 구간마다 **가운데 값**(윗줄·아랫줄과 잘못 짝지은 쌍은 가운데 값이 밀어낸다)
    → ③ 구간 가운데 값들로 y에 따른 1차식 → ④ 그 선에서 벗어난 쌍을 버리고 쌍으로 다시 맞춘다.
    """
    usable = [w for w in words if w.text.strip() and w.x1 > w.x0 and w.y1 > w.y0]
    if len(usable) <= _SKEW_MIN_PAIRS:
        return None
    h_med = statistics.median(w.height for w in usable)
    usable = [w for w in usable if 0.5 * h_med <= w.height <= 2.0 * h_med]
    pairs = _neighbor_pairs(usable)
    if len(pairs) < _SKEW_MIN_PAIRS:
        return None

    y_min, y_max = min(p[2] for p in pairs), max(p[2] for p in pairs)
    n_bins = max(1, min(_SKEW_BINS, len(pairs) // 6))
    step = (y_max - y_min) / n_bins or 1.0
    bins: list[list[tuple[float, float, float]]] = [[] for _ in range(n_bins)]
    for p in pairs:
        bins[min(n_bins - 1, int((p[2] - y_min) / step))].append(p)
    centers = [
        (
            _weighted_median([q[0] for q in b], [q[1] for q in b]),
            sum(q[1] for q in b),
            sum(q[1] * q[2] for q in b) / sum(q[1] for q in b),
        )
        for b in bins
        if len(b) >= 3
    ]
    if not centers:
        return None
    a, b, ybar = _fit_slope(centers)
    inliers = [p for p in pairs if abs(p[0] - (a + b * (p[2] - ybar))) <= _SKEW_INLIER]
    if len(inliers) < _SKEW_MIN_PAIRS:
        return None
    a, b, ybar = _fit_slope(inliers)
    refit = [p for p in inliers if abs(p[0] - (a + b * (p[2] - ybar))) <= _SKEW_RESIDUAL]
    if len(refit) >= _SKEW_MIN_PAIRS:
        inliers = refit
        a, b, ybar = _fit_slope(inliers)

    ys = [w.cy for w in usable]
    y_lo, y_hi = min(ys), max(ys)
    pair_ys = [p[2] for p in inliers]
    if (max(pair_ys) - min(pair_ys)) < _SKEW_SPAN_FOR_TREND * max(1.0, y_hi - y_lo):
        b = 0.0  # 쌍이 한쪽에 몰려 있으면 위·아래 차이를 믿지 않는다 — 한 각도로만 본다
        a = sum(p[1] * p[0] for p in inliers) / sum(p[1] for p in inliers)
    ends = (a + b * (y_lo - ybar), a + b * (y_hi - ybar))
    worst = max(abs(e) for e in ends)
    if worst < _SKEW_MIN_SLOPE or worst > _SKEW_MAX_SLOPE:
        return None
    xc = statistics.median(w.cx for w in usable)
    return Skew(slope0=a, per_y=b, xc=xc, yc=ybar, pairs=len(inliers))


def apply_skew(words: list[Word], skew: Skew | None) -> None:
    """낱말마다 보정 y(`ly`)를 채운다 — **그 높이의 줄 기울기만큼 비스듬한 선을 수평으로 편 값**. None이면 지운다.

    x는 고치지 않는다(`lx = None`): 원근 사진은 가로줄만 기울고 세로 칸은 그대로라, 사진을 통째로 돌리듯 x까지
    고치면 오히려 칸이 밀린다. 칸이 아래로 갈수록 옆으로 밀리는 것은 `build_items`의 밴드 따라가기가 맡는다.
    """
    for w in words:
        w.lx = None
        if skew is None:
            w.ly = w.lh = None
            continue
        slope = skew.slope_at(w.cy)
        w.ly = w.cy - slope * (w.cx - skew.xc)
        # 너비 W·높이 H 글자가 θ만큼 기울면 상자 높이 = W·sinθ + H·cosθ, 너비 = W·cosθ + H·sinθ → H를 거꾸로 푼다
        theta = math.atan(abs(slope))
        c, si = math.cos(theta), math.sin(theta)
        denom = c * c - si * si
        box_w, box_h = w.x1 - w.x0, w.y1 - w.y0
        upright = (box_h * c - box_w * si) / denom if denom > 0.1 else box_h
        w.lh = min(box_h, max(0.5 * box_h, upright))


class _Auto:
    pass


_AUTO = _Auto()


def group_lines(
    words: list[Word], tol_ratio: float = 0.6, *, skew: Skew | None | _Auto = _AUTO
) -> list[Line]:
    """y중심과 글자높이로 같은 줄을 묶는다 (표 형식이라 같은 y의 다른 칸도 한 줄이 된다).

    2026-10-31: 사진이 비스듬하면 **기울기만큼 바로잡은 좌표**로 묶는다(`estimate_skew` — 0.25° 미만이면
    예전과 똑같다). 줄 안의 낱말 순서도 바로잡은 x로. 낱말의 원본 좌표(`box`)는 그대로다.
    """
    if not words:
        return []
    if isinstance(skew, _Auto):
        skew = estimate_skew(words)
    apply_skew(words, skew)
    ordered = sorted(words, key=lambda w: (w.lcy, w.lx0))
    buckets: list[list[Word]] = [[ordered[0]]]
    for w in ordered[1:]:
        cur = buckets[-1]
        ref_cy = statistics.median([x.lcy for x in cur])
        ref_h = statistics.median([x.height for x in cur] + [w.height])
        if abs(w.lcy - ref_cy) <= tol_ratio * ref_h:
            cur.append(w)
        else:
            buckets.append([w])
    return [Line(index=i, words=sorted(b, key=lambda w: w.lx0)) for i, b in enumerate(buckets)]


def median_height(words: list[Word]) -> float:
    """글자 높이 가운데 값 — 칸 사이 간격·이름 간격의 잣대. 기울어진 사진이면 바로 세운 높이로(상자 높이는 부풀어 있다)."""
    return statistics.median([w.lheight for w in words]) if words else 16.0


# ══════════════════════════════════════════════════════════════════════════════
# 컬럼 밴드 / 구역
# ══════════════════════════════════════════════════════════════════════════════


def _group_by_gap(words: list[Word], gap: float) -> list[list[Word]]:
    """x간격이 `gap`을 넘으면 다른 컬럼으로 본다."""
    if not words:
        return []
    groups: list[list[Word]] = [[words[0]]]
    for w in words[1:]:
        if w.lx0 - groups[-1][-1].lx1 > gap:
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
    rank = (groups[0][0].lx0, groups[0][-1].lx1)
    if len(groups) >= 3:
        purpose = (rank[1], groups[2][0].lx0)
    elif len(groups) == 2:
        purpose = (rank[1], groups[1][-1].lx1)
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
        if lo - margin <= w.lcx <= hi + margin and _RANK_TEXT.match(w.text.strip()):
            return w
    return None


def _follow_rank(bands: ColumnBands | None, rank_word: Word) -> ColumnBands | None:
    """찾은 순위번호 쪽으로 칸 밴드를 옮긴다 (2026-10-31).

    폰을 비스듬히 들고 찍으면(원근) 위가 좁고 아래가 넓어져 **아래 줄로 갈수록 칸이 옆으로 밀린다**.
    밴드는 표 머리 줄(맨 위)에서 한 번 정하므로, 쪽 아래쪽 순위번호가 밴드 밖으로 나가 항목이 통째로 빠진다.
    순위번호는 칸 가운데에 찍히므로, 찾을 때마다 밴드 가운데를 그 순위번호에 맞춘다 — 바로 이어지는 다음
    항목은 거의 같은 자리라 놓치지 않는다. 바로 찍은 사진은 순위번호가 이미 가운데라 거의 안 움직인다.
    """
    if bands is None:
        return None
    lo, hi = bands.rank
    delta = rank_word.lcx - (lo + hi) / 2
    if abs(delta) < 1.0:
        return bands
    return ColumnBands(
        kind=bands.kind,
        rank=(lo + delta, hi + delta),
        purpose=(bands.purpose[0] + delta, bands.purpose[1] + delta),
        origin=bands.origin,
    )


def _purpose_words(line: Line, bands: ColumnBands | None) -> list[Word]:
    if bands is None:
        return []
    lo, hi = bands.purpose
    return [w for w in line.words if lo <= w.lcx <= hi]


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

    문자 단위 정규식(줄 전체를 공백 없이 이어붙여 매칭)은 `매매`+`홍길동`을 한 덩어리로
    삼켜 bbox가 옆 칸까지 번진다(실측 181px). word 단위로 가면 43px로 정확히 좁혀진다.
    """
    hits: list[NameHit] = []
    max_gap = _NAME_GAP_RATIO * med_h
    for i, w in enumerate(line.words):
        m = _ID_PATTERN.search(w.text)
        if not m:
            continue
        kind = "법인" if m.group(2).isdigit() else "개인"

        # ⑴ 같은 word 안에 이름이 붙어 온 경우 ("홍길동900101-*******")
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
                if prev.lx1 < w.lx0 - max_gap * back:
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
                bands = _follow_rank(bands, rank_word)
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
    # 사진 순서가 등기부 쪽수와 다를 때, **문서 순서로 다시 세운 업로드 인덱스 목록**.
    # 예: `[3, 2, 1, 0, 4]` = 4번째로 올린 사진이 1쪽이다.
    #
    # None이면 정렬하지 않는다 — 순서가 이미 맞거나, **믿고 정렬할 수 없는 상태**다.
    # 믿을 수 있는 조건은 엄격하다(`_resolve_order` 참고): 모든 사진에서 표식이 읽혔고,
    # 중복이 없고, 1..M이 빠짐없이 채워질 때만이다. 한 장이라도 `?/?`면 정렬하지 않는다 —
    # 잘못 세운 순서로 항목을 이으면 **말소 판정이 통째로 어긋난다.**
    page_order: list[int] | None = None
    # 등기부 꼬리말의 열람일시 `YYYY.MM.DD` — **표시 전용**. 못 읽으면 None이고,
    # 그때는 앱이 그 줄을 아예 그리지 않는다(분석일로 대체하지 않는다 — 분석일을 쓰면
    # 오히려 "오늘 서류"라고 믿게 만들어 지금보다 나빠진다).
    viewed_at: str | None = None
    # 등기부 꼬리말 표식(N/M)으로 본 **빠진 쪽 번호**(1부터, 2026-10-27). 표식을 하나도 못 읽었으면 빈 목록.
    # 판정 게이트(빠진 쪽이 있으면 '양호' 금지)와 리포트의 '다시 올리기' 안내가 쓴다.
    missing_pages: list[int] = field(default_factory=list)
    # 올린 순서마다 꼬리말에 찍힌 쪽 번호 (못 읽은 장은 None) — 앱이 "1쪽이 잘 안 읽혔어요"를 **문서 쪽 번호로** 말한다.
    page_numbers: list[int | None] = field(default_factory=list)
    # 쪽 머리의 '[집합건물] …' 주소(띄어쓰기 한 칸으로 정리, 머리표 뗌) — 같은 집 묶기용. 표시·판정에 쓰지 않는다.
    # 모든 쪽 머리에 같은 줄이 찍혀 있어 **어느 쪽을 올렸든** 같은 값이 나온다(호수까지 들어 있다).
    header_address: str | None = None
    # 그 머리표 — '집합건물' · '건물' · '토지' (2026-10-31). 시세 조회 주소를 쪽 머리로 채울 때 등기 종류를 함께 넘긴다.
    header_kind: str | None = None
    # 쪽 번호가 잘렸지만 앞뒤 쪽 번호로 쪽을 정한 사진 (`pages` 순서의 위치, 2026-10-31) — `page_numbers`엔 정한 번호가 들어 있다
    inferred_pages: list[int] = field(default_factory=list)


def header_address(pages: list[OcrPage]) -> str | None:
    """쪽 머리의 '[집합건물] 서울특별시 … 제602호' → '서울특별시 … 제602호'. 없으면 None."""
    for page in pages:
        for line in page.lines:
            if _PAGE_HEADER.match(line.display):
                text = " ".join(_PAGE_HEADER.sub("", line.display).split())
                if text:
                    return text
    return None


# 표제부 '건물내역'의 용도 낱말 → 경매 통계 용도 이름 (`loss_estimate`와 같은 글자).
# 실제 표기: '철근콘크리트구조 (철근)콘크리트지붕 4층 다세대주택' · '… 15층 아파트' · '… 20층 업무시설(오피스텔)' ·
# '… 5층 공동주택(아파트)' · '… 제2종근린생활시설 및 다세대주택'. 오피스텔을 먼저 본다('업무시설(오피스텔)').
_USE_WORDS: tuple[tuple[str, str], ...] = (
    ("오피스텔", "오피스텔"),
    ("아파트", "아파트"),
    ("다세대", "연립다세대"),
    ("연립", "연립다세대"),
    ("다가구", "단독·다가구"),
    ("단독주택", "단독·다가구"),
)
# 건물내역 자리 — 용도 낱말 바로 앞에 'N층'·'지붕'·'구조'가 있으면 건물 이름이 아니라 건물내역이다
_USE_CONTEXT = re.compile(r"(\d+층|지붕|구조)[^0-9]{0,14}$")


def building_use(pages: list[OcrPage]) -> str | None:
    """등기부 표제부의 건물 용도 — '4층 다세대주택' → '연립다세대' (2026-10-31). 못 찾으면 None.

    왜: 손실 시뮬레이터의 경매 매각가율은 용도마다 다르다. 예전엔 시세 자료의 종류로만 짐작해서(공동주택 공시가격은
    아파트인지 빌라인지 모른다) 늘 '용도 확실하지 않음' + 가장 낮은 용도로 계산했다. 그런데 **등기부 표제부
    건물내역에 용도가 글자로 적혀 있다.** 갑구가 시작되기 전(표제부) 글자만 본다. 건물내역 자리('N층 ○○')에서
    찾은 것을 먼저 쓰고, 없으면 표제부 전체에서 한 가지 용도만 보일 때 쓴다(건물 이름 '○○아파트' 같은 것).
    """
    text: list[str] = []
    section: str | None = None
    for page in pages:  # 구역은 쪽을 넘어 이어진다(표제부가 2쪽까지 갈 수 있다)
        for line in page.lines:
            section = detect_section(line) or section
            if section == "표제부":
                text.append(line.squeezed)
    if not text:
        # 구역 머리(【표제부】)를 못 읽었으면 — '건물내역'이 있는 쪽의 갑구·을구 전 글자로
        for page in pages:
            lines = []
            for line in page.lines:
                if detect_section(line) in ("갑구", "을구"):
                    break
                lines.append(line.squeezed)
            if any("건물내역" in t or "건물의표시" in t for t in lines):
                text.extend(lines)
    joined = "".join(text)
    strong: list[tuple[int, str]] = []
    weak: set[str] = set()
    for word, use in _USE_WORDS:
        for m in re.finditer(word, joined):
            if _USE_CONTEXT.search(joined[max(0, m.start() - 20) : m.start()]):
                strong.append((m.start(), use))
            else:
                weak.add(use)
    if strong:
        return min(strong)[1]  # 표제부에서 먼저 나온 건물내역(1동의 건물의 표시)
    return weak.pop() if len(weak) == 1 else None


def header_kind(pages: list[OcrPage]) -> str | None:
    """쪽 머리의 머리표 '[집합건물]' → '집합건물'(띄어쓰기 없앰). 없으면 None."""
    for page in pages:
        for line in page.lines:
            m = _PAGE_HEADER.match(line.display)
            if m:
                return re.sub(r"\s+", "", m.group(1))
    return None


def _page_footer_facts(
    page: OcrPage,
) -> tuple[tuple[int, int] | None, str | None, str | None, str | None]:
    """(페이지 표식 (n, m), 발급확인번호, 상단 주소 줄, 열람일시) — 없으면 각각 None."""
    marker: tuple[int, int] | None = None
    issue: str | None = None
    address: str | None = None
    viewed: str | None = None
    for line in page.lines:
        squeezed = line.squeezed
        if address is None and _PAGE_HEADER.match(line.display):
            address = re.sub(r"\s+", "", line.display)
        if issue is None:
            m = _ISSUE_NO.search(squeezed)
            if m:
                issue = m.group(1).replace("－", "-")
        if viewed is None:
            m = _VIEWED_AT.search(squeezed)
            if m:
                y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
                # 말이 안 되는 날짜는 버린다 — 잘못 읽은 값을 화면에 내보내느니 없는 편이 낫다
                if 2000 <= y <= 2100 and 1 <= mo <= 12 and 1 <= d <= 31:
                    viewed = f"{y}.{mo:02d}.{d:02d}"
        found = _line_page_marker(line)
        if found is not None:
            marker = found  # 아래 줄일수록 꼬리말이다 — 마지막에 읽힌 것을 쓴다(예전과 같음)
    return marker, issue, address, viewed


def _line_page_marker(line: Line) -> tuple[int, int] | None:
    """줄 하나에서 쪽 번호 `N/M`을 찾는다 — 한 낱말 · 앞말에 붙은 낱말 · 이웃한 2~3 낱말. 없으면 None."""
    words = line.words
    texts = [w.text.strip() for w in words]
    found: tuple[int, int] | None = None

    def close(i: int, j: int) -> bool:
        a, b = words[i], words[j]
        return b.lx0 - a.lx1 <= _MARKER_JOIN_GAP * max(a.height, b.height)

    for i, t in enumerate(texts):
        m = _PAGE_MARKER.match(t) or _MARKER_TAIL.search(t)
        pair: tuple[str, str] | None = (m.group(1), m.group(2)) if m else None
        if pair is None and i + 1 < len(texts) and close(i, i + 1):
            a, b = _NUM_TAIL.search(t), _SLASH_NUM.match(texts[i + 1])
            if a and b:
                pair = (a.group(1), b.group(1))
            a, b = _NUM_SLASH_TAIL.search(t), _NUM_ONLY.match(texts[i + 1])
            if pair is None and a and b:
                pair = (a.group(1), b.group(1))
        if pair is None and i + 2 < len(texts) and close(i, i + 1) and close(i + 1, i + 2):
            a, b = _NUM_TAIL.search(t), _NUM_ONLY.match(texts[i + 2])
            if a and b and _SLASH_ONLY.match(texts[i + 1]):
                pair = (a.group(1), b.group(1))
        if pair is not None:
            n, total = int(pair[0]), int(pair[1])
            if 1 <= n <= total <= 200:
                found = (n, total)
    return found


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
    markers = [(i, m) for i, (m, _, _, _) in enumerate(facts) if m]
    issues = {iss for _, iss, _, _ in facts if iss}
    addresses = {addr for _, _, addr, _ in facts if addr}

    # 쪽 번호만 잘린 장 — 앞뒤 쪽 번호로 몇 쪽인지 **빈틈없이 한 가지로** 정해질 때만 채운다 (2026-10-31)
    inferred = _infer_page_numbers(pages, markers)
    if inferred:
        facts = [
            ((inferred[i], markers[0][1][1]), iss, addr, viewed) if i in inferred else (m, iss, addr, viewed)
            for i, (m, iss, addr, viewed) in enumerate(facts)
        ]
        markers = [(i, m) for i, (m, _, _, _) in enumerate(facts) if m]
        check.inferred_pages = sorted(inferred)
        check.reasons.append(
            "쪽 번호가 잘린 사진의 쪽을 앞뒤 쪽 번호로 정함: "
            + ", ".join(f"{pages[i].name}={n}쪽" for i, n in sorted(inferred.items()))
        )

    # 쪽 번호·빠진 쪽·머리 주소 — **모든 return 경로보다 앞에서** 채운다 (2026-10-27).
    # 예전에는 빠진 쪽을 ③에서만 셌다 → 순서가 어긋난 채 일부 쪽만 올리면(②에서 먼저 끝남)
    # "순서가 달라요"만 나오고 빠진 쪽은 아무 말이 없었다(실기기: 5쪽 중 2·3·4쪽만 올림).
    check.page_numbers = [m[0] if m else None for m, _, _, _ in facts]
    check.header_address = header_address(pages)
    check.header_kind = header_kind(pages)
    # 쪽 번호를 못 읽은 사진이 있으면 그 사진이 '빠진 쪽'일 수 있다 → 어느 쪽이 빠졌는지 단정하지 않는다
    # (그 사진은 촬영 검사가 '아래가 잘림'으로 따로 알리고, 판정 게이트도 그쪽으로 막힌다).
    if markers and len(markers) == len(pages):
        # 전체 쪽수는 가장 큰 값으로 — 표식마다 M이 다르게 읽혀도 빠진 쪽을 놓치지 않게(규칙 감사)
        _total_pages = max(m[1] for _, m in markers)
        _covered = {n for _, (n, _) in markers}
        check.missing_pages = sorted(set(range(1, _total_pages + 1)) - _covered)

    # 열람일시 — 어느 쪽에서든 처음 읽힌 값. **모든 return 경로보다 앞에서** 채운다.
    # 사진 묶음 점검에 걸려 표시를 못 하더라도 "언제 뗀 서류인가"는 알려줘야 한다.
    for _, _, _, viewed in facts:
        if viewed:
            check.viewed_at = viewed
            break

    # [진단] 사진 점검 실태 — 파일명·개수·참/거짓만 (발급확인번호 값·주소·이름 금지).
    # 모든 return 경로보다 앞에 두어, 어느 분기로 끝나든 한 줄은 반드시 남는다.
    _page_marks = [
        f"{p.name}={m[0]}/{m[1]}" if m else f"{p.name}=?/?"
        for p, (m, _, _, _) in zip(pages, facts)
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
        f" | 열람일시 {'읽음' if check.viewed_at else '못읽음'}"
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

    # ①-b 같은 쪽 사진이 두 장인가 — 순서가 맞아 보여도 구조가 깨진다.
    #
    # 실측 시나리오(2026-07-28 gap-checker): 5쪽 완본 + 3쪽 사본 1장 = 6장.
    # 표식이 `[1,2,3,3,4,5]`라 **정렬돼 있어** 순서 점검을 건너뛰고, 1..5가 다 채워져
    # 누락 점검도 통과한다. 그런데 `build_items`가 3쪽을 두 번 파싱해 같은 항목이 두 번
    # 생기고, 소유자 표시는 "가장 마지막 등기" 규칙 때문에 **사본 쪽**으로 간다.
    # 중복 자체가 "무엇이 진짜인지 모른다"는 뜻이므로 금액 표시를 보류한다.
    if markers:
        numbers = [m[0] for _, m in markers]
        dupes = sorted({n for n in numbers if numbers.count(n) > 1})
        if dupes:
            check.ok_to_highlight_money = False
            check.notice = (
                "같은 쪽 사진이 두 번 올라와 있어요. 한 쪽당 한 장씩만 올리면 "
                "빚 표시까지 보여 드릴 수 있어요."
            )
            check.reasons.append(
                f"쪽 번호 중복: {dupes} (표식 {numbers}) → 같은 항목이 두 번 읽혀"
                " 금액 표시를 보류"
            )
            return check

    # ② 사진 순서가 뒤바뀌었는가 — 항목이 페이지를 걸쳐 이어지므로 순서가 틀리면 구조가 깨진다.
    #
    # 2026-07-28 변경: 예전에는 **무조건 전부 표시 안 함**이었다. 그런데 서버는 올바른
    # 순서를 이미 알고 있다(표식을 다 읽었으므로). 알면서 화면을 비우는 건 낭비다.
    # → **믿고 정렬할 수 있는 조건일 때만** 내부적으로 순서를 세운다(`_resolve_order`).
    #   조건을 못 채우면 예전처럼 보류한다. 이 경계가 이 변경의 본체다.
    if len(markers) >= 2:
        seq = [m[0] for _, m in markers]
        if seq != sorted(seq):
            order = _resolve_order(pages, markers)
            if order is None:
                check.ok_to_highlight_any = False
                check.ok_to_highlight_money = False
                check.notice = (
                    # 빠진 쪽이 있으면 그 말이 먼저다 — 순서만 맞춰 다시 올려도 빠진 쪽은 그대로 빠져 있다
                    f"등기부 {markers[0][1][1]}쪽 중 "
                    f"{'·'.join(map(str, check.missing_pages))}쪽이 빠졌어요. 빠진 쪽까지 다시 올려 주세요."
                    if check.missing_pages
                    else "사진 순서가 등기부 쪽수와 달라요. 1쪽부터 순서대로 다시 올려 주세요."
                )
                check.reasons.append(f"페이지 표식 순서 어긋남 + 자동 정렬 조건 미충족: {seq}")
                return check
            check.page_order = order
            check.reasons.append(
                f"페이지 표식 순서 어긋남({seq}) → 자동 정렬 적용 (업로드 인덱스 {order})"
            )

    # ③ 빠진 페이지가 있는가 — 말소 근거 행이 그 페이지에 있을 수 있다.
    #
    # 2026-07-28 버그 수정: 예전에는 `len(pages) < total`로 봤다. 그러면 **등기부가 아닌
    # 사진 한 장이 장수를 채워** 이 방어가 통째로 무력화된다(실측: 표식 2/5·3/5·4/5·5/5
    # 네 장 + 무관한 사진 한 장 → 5장이므로 "누락 없음"으로 통과했다. 정작 빠진 1쪽에는
    # 표제부·표지가 있었다). **장수가 아니라 실제로 읽힌 쪽 번호**로 판단해야 한다.
    if markers:
        total = markers[0][1][1]
        covered = {n for _, (n, _) in markers}
        missing = sorted(set(range(1, total + 1)) - covered)
        unread = len(pages) - len(markers)
        if missing:
            check.ok_to_highlight_money = False
            check.notice = (
                f"등기부 {total}쪽 중 {len(covered)}쪽만 확인됐어요. "
                "빠진 쪽에 중요한 내용이 있을 수 있어 빚 표시는 생략했어요."
            )
            check.reasons.append(
                f"페이지 누락: 총 {total}쪽 중 읽힌 쪽 {sorted(covered)} / 안 읽힌 쪽 {missing}"
                f" (사진 {len(pages)}장, 표식 못 읽은 사진 {unread}장)"
                " → 말소 근거 행이 빠진 쪽에 있을 수 있어 금액 표시를 보류"
            )
        elif unread:
            # 쪽 번호는 1..M이 다 나왔는데 표식 없는 사진이 더 있다 = 다른 서류가 섞였을 수 있다.
            # 같은 등기부라면 모든 쪽 꼬리말에 표식이 찍힌다.
            check.ok_to_highlight_money = False
            check.notice = (
                "쪽 번호가 안 보이는 사진이 섞여 있어요. 쪽 번호(예: 1/5)가 나오게 "
                "다시 찍으면 빚 표시까지 보여 드릴 수 있어요."
            )
            check.reasons.append(
                f"표식 없는 사진 {unread}장 — 등기부라면 모든 쪽에 표식이 있다"
                " → 다른 서류 혼입 가능성, 금액 표시를 보류"
            )
    else:
        check.reasons.append("페이지 표식(N/M) 미검출 — 순서·누락을 확인할 수 없음(사진이 잘렸을 수 있음)")
    return check


#: 쪽 번호를 짐작해 채울 사진이 등기부 쪽으로 보이려면 낱말이 이만큼은 있어야 한다(빈 종이·다른 물건 사진 걸러내기)
_INFER_MIN_WORDS = 20
_REGISTRY_CUES = ("순위번호", "표시번호", "이하여백", "권리자및기타사항", "등기목적", "등기원인")


def _looks_like_registry_page(page: OcrPage) -> bool:
    """등기부 한 쪽으로 보이나 — 표 머리 낱말·구역 머리·'이하 여백'·쪽 머리 주소 중 하나가 있다."""
    if len(page.words) < _INFER_MIN_WORDS:
        return False
    for line in page.lines:
        sq = line.squeezed
        if detect_section(line) or _PAGE_HEADER.match(line.display) or any(c in sq for c in _REGISTRY_CUES):
            return True
    return False


def _infer_page_numbers(
    pages: list[OcrPage], markers: list[tuple[int, tuple[int, int]]]
) -> dict[int, int]:
    """쪽 번호를 못 읽은 사진 → 쪽 번호. **한 가지로만 정해질 때만** 채우고, 아니면 빈 dict (2026-10-31).

    실촬영에서 가장 흔한 '다시 찍기'는 맨 아래 쪽 번호가 화면 밖으로 잘린 것이다. 그런데 나머지 쪽 번호가 다 읽혔고
    올린 순서대로라면 그 사진이 몇 쪽인지 알 수 있다 — 예: `1/3 · ? · 3/3` → 가운데는 2쪽.

    채우는 조건(하나라도 어긋나면 안 채운다 — [2026-07-28] '무관한 사진이 빠진 쪽 자리를 채우는' 사고 방어):
      ① 읽힌 쪽 번호의 전체 쪽수(M)가 모두 같고, 쪽 번호가 겹치지 않고, **올린 순서대로 커진다**
      ② 사진 장수가 정확히 M장이다(빠진 쪽이 없다)
      ③ 못 읽은 사진들이 끼어 있는 자리마다 들어갈 쪽 번호 개수가 그 자리의 사진 장수와 **정확히 같다**
      ④ 못 읽은 사진이 등기부 쪽으로 보인다(낱말 20개 이상 + 표 머리·구역 머리·'이하 여백'·쪽 머리 주소 중 하나)
    """
    if not markers or len(markers) == len(pages):
        return {}
    totals = {m[1] for _, m in markers}
    if len(totals) != 1:
        return {}
    total = totals.pop()
    if len(pages) != total:
        return {}
    numbers = [m[0] for _, m in markers]
    if len(set(numbers)) != len(numbers) or numbers != sorted(numbers):
        return {}
    known = dict(markers)
    out: dict[int, int] = {}
    prev_number = 0
    run: list[int] = []
    for i in range(len(pages) + 1):
        if i < len(pages) and i not in known:
            run.append(i)
            continue
        next_number = known[i][0] if i < len(pages) else total + 1
        if run:
            if next_number - prev_number - 1 != len(run):
                return {}
            for offset, idx in enumerate(run, start=1):
                out[idx] = prev_number + offset
            run = []
        elif i < len(pages) and next_number - prev_number - 1 != 0:
            return {}  # 이웃한 두 사진 사이에 쪽이 빠졌다 — 빠진 쪽은 빠진 쪽이다
        prev_number = next_number
    if not all(_looks_like_registry_page(pages[i]) for i in out):
        return {}
    return out


def _resolve_order(
    pages: list[OcrPage], markers: list[tuple[int, tuple[int, int]]]
) -> list[int] | None:
    """**믿고 정렬해도 되는가**를 판정하고, 되면 문서 순서의 업로드 인덱스 목록을 준다.

    이 함수가 이 기능의 전부다. 순서를 잘못 세우면 항목이 엉뚱하게 이어져
    **말소 판정이 깨지고, 말소된 근저당에 형광펜이 간다** — 이 기능 최악의 오류다.
    그래서 조건을 하나라도 못 채우면 **None**(= 정렬하지 않고 보류)을 돌려준다.

    조건 넷:
    1. **모든 사진**에서 표식이 읽혔다 (한 장이라도 `?/?`면 안 된다)
    2. 표식의 총 쪽수(M)가 전부 같다
    3. 쪽 번호에 **중복이 없다**
    4. 1..M이 **빠짐없이** 채워지고, 사진 장수가 정확히 M이다
    """
    if len(markers) != len(pages):
        return None  # ① 표식을 못 읽은 사진이 있다
    totals = {m[1][1] for m in markers}
    if len(totals) != 1:
        return None  # ② 총 쪽수가 서로 다르다 → 다른 등기부가 섞였을 수 있다
    total = totals.pop()
    numbers = [m[1][0] for m in markers]
    if len(set(numbers)) != len(numbers):
        return None  # ③ 같은 쪽 번호가 두 번 나왔다
    if set(numbers) != set(range(1, total + 1)) or len(pages) != total:
        return None  # ④ 1..M이 다 채워지지 않았다
    by_number = {m[1][0]: pages[m[0]].index for m in markers}
    return [by_number[n] for n in range(1, total + 1)]


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
