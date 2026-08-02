"""앱↔서버 JSON 계약(docs/api-contract.md §2)의 Pydantic 스키마.

응답이 계약과 어긋나면 FastAPI가 바로 잡아주도록, 계약서의 데이터 모델을 그대로 코드화했다.
필드명·타입은 docs/api-contract.md와 1:1로 대응한다. (Phase D-2 더미 응답용)
"""

from __future__ import annotations

from typing import Optional

from pydantic import BaseModel, Field


# ── 근거 카드 (§2.2 Evidence) ──────────────────────────────────────────────
class Evidence(BaseModel):
    id: str  # jeonse_ratio | senior_debt | ownership | insurance | blacklist
    title: str
    termSubtitle: str
    grade: str  # "위험" | "확인 필요" | "양호"
    statusLabel: Optional[str] = None
    easyExplanation: str
    detailText: Optional[str] = None
    sourceText: Optional[str] = None
    actionLabel: Optional[str] = None
    termGlossary: dict[str, str] = Field(default_factory=dict)


# ── 원본 사진 하이라이트 (§2.7 — 2026-07-27 추가, **선택적**) ──────────────
# 앱이 이 필드를 통째로 무시해도 기존과 똑같이 동작한다(기본값 빈 목록).
# ⚠ 표시 전용이다. 등급·점수·근거 카드에 어떤 영향도 주지 않는다.
class HighlightBox(BaseModel):
    """정규화 좌표 (0~1). 원본 이미지 픽셀 ÷ 원본 크기.

    정규화하는 이유: 앱의 표시 크기는 기기·회전·줌에 따라 달라진다. 픽셀을 그대로
    보내면 앱이 원본 크기를 따로 알아야 하고, 하나라도 어긋나면 전부 밀린다.
    """

    x: float
    y: float
    w: float
    h: float


class Highlight(BaseModel):
    """사진 위 표시 1건."""

    id: str
    page: int  # 업로드한 사진 순서 (0부터) — 앱이 몇 번째 사진에 그릴지
    # 표시 종류. 앱은 모르는 값을 만나면 **위험 톤**으로 떨어뜨린다(보수적 편향).
    #   [대조할 곳] address · area · doc_title · owner · viewed_at
    #   [따져볼 곳] mortgage · jeonse · lease_registration · provisional_seizure ·
    #              seizure · auction · trust · separate_land · joint_collateral ·
    #              pending_application
    # 목록의 정본은 `app/services/highlight.py`의 `_SPECS`다.
    kind: str
    badge: int  # 화면에 붙일 번호 (1부터) — 색만으로 정보를 전달하지 않기 위함
    box: HighlightBox
    title: str
    body: str
    caution: Optional[str] = None
    # 이 문장이 어디서 왔는지 (근거 카드의 sourceText와 같은 역할 — 없으면 '앱이 그냥 하는 말'로 읽힌다)
    source: Optional[str] = None


# ── 시세 출처 (§2.8 — 2026-08-03 추가, **선택적**) ─────────────────────────
# 앱이 이 필드를 통째로 무시해도 기존과 똑같이 동작한다(전부 기본값 있음).
class MarketPriceAlternative(BaseModel):
    """채택되지 않은 시세 후보 — "왜 이 값을 썼나"를 사용자에게 공개하기 위한 것."""

    source: str  # manual | actual_trade | official_price | tax_base
    sourceName: str  # 사람이 읽는 출처명
    price: int  # 원
    asOf: Optional[str] = None  # 기준일 또는 조회 기간
    sampleCount: Optional[int] = None
    detail: Optional[str] = None


# ── 리포트 (§2.1 Report) ───────────────────────────────────────────────────
class Report(BaseModel):
    id: str
    alias: str
    address: str
    analyzedAt: str  # ISO 8601
    grade: str  # "위험" | "확인 필요" | "양호"
    gaugeProgress: float
    headline: str
    nextAction: str
    topRiskSummary: str
    deposit: int
    # 채택된 최종 시세(원). **의미는 예전과 같다** — 판정에 들어가는 집값 하나.
    # 달라진 것은 이 값이 사용자 입력 말고 자동 조회에서도 올 수 있다는 점뿐이다.
    marketPrice: Optional[int] = None
    # ── 시세 출처 (2026-08-03 추가, 전부 선택적 — 기존 앱은 무시해도 동작) ──
    # 숫자만 보여주면 사용자는 그 값이 어디서 왔는지 알 수 없다. "근거를 항상 공개한다"는
    # 원칙에 따라, 채택된 값에는 **출처·기준일·표본 수**가 늘 따라붙는다.
    marketPriceSource: Optional[str] = None  # manual|actual_trade|official_price|tax_base
    marketPriceAsOf: Optional[str] = None  # 공시는 기준일, 실거래가는 조회기간 'YYYY-MM~YYYY-MM'
    marketPriceSampleCount: Optional[int] = None  # 실거래가일 때만
    # 실거래가와 공시 기준이 **둘 다** 있을 때의 괴리율(%). 실거래가가 공시 기준보다
    # 몇 % 높은지. ⚠ **판정에 쓰지 않는다** — 임계값의 권위 있는 출처가 없어 정보 계층에만 둔다.
    marketPriceGapPct: Optional[int] = None
    # 채택되지 않은 후보들 — 근거 전면 공개용. 앱은 "다른 기준으로는 얼마였는지"를 보여줄 수 있다.
    marketPriceAlternatives: list[MarketPriceAlternative] = Field(default_factory=list)
    seniorDebtAmount: int
    evidences: list[Evidence]
    # 선택적 추가 (2026-07-27). 좌표를 못 구하면 빈 목록 — 그래도 리포트는 완성된다.
    highlights: list[Highlight] = Field(default_factory=list)
    # 사진 묶음 관련 안내 한 줄 (다른 등기부 섞임·순서 어긋남·쪽 누락). 없으면 None.
    highlightNotice: Optional[str] = None
    # "무엇을 찾아봤고 무엇을 왜 표시하지 않았는지" 요약. 표시 전용 — 판정과 무관하다.
    # 침묵하면 사용자가 "AI가 안 봤다"로 읽어 신뢰가 깎인다(2026-07-27 리뷰 3인 공통 지적).
    checkedNotes: list[str] = Field(default_factory=list)
    # 등기부에 인쇄된 **열람일시** `YYYY.MM.DD` (2026-07-27 추가). 표시 전용이다.
    #
    # 등기부는 열람 시점의 스냅샷이라, 그 뒤에 잡힌 근저당은 이 서류에 없다.
    # 계약 직전 근저당 설정은 실제 전세사기 수법이라 "언제 뗀 서류인가"를 사용자가
    # 알아야 한다(실측 샘플: 열람 7/9, 분석 7/27 — 18일 차이).
    # ⚠ 못 읽으면 None이다. **앱은 분석일(analyzedAt)로 대체하지 않는다** — 분석일을
    #   대신 쓰면 "오늘 서류"라고 믿게 만들어 아무것도 안 쓰느니만 못하다.
    registryViewedAt: Optional[str] = None


# ── 판례 (§2.3 CaseMatch) ──────────────────────────────────────────────────
class CaseMatch(BaseModel):
    riskPattern: str
    caseNo: str
    summary: str
    result: str
    commonPoint: str


# ── 질문 생성기 (§2.4 QuestionGroup / QuestionItem) ────────────────────────
class QuestionItem(BaseModel):
    question: str
    why: str
    safeAnswer: str
    riskyAnswer: str


class QuestionGroup(BaseModel):
    riskLabel: str
    items: list[QuestionItem]


# ── 용어 챗봇 (§2.5 GlossaryTerm) ──────────────────────────────────────────
class GlossaryTerm(BaseModel):
    term: str
    description: str


# ── 계약 여정 (§2.6 JourneyStage / JourneyItem) ────────────────────────────
class JourneyItem(BaseModel):
    text: str
    why: str


class JourneyStage(BaseModel):
    title: str
    subtitle: str
    items: list[JourneyItem]
