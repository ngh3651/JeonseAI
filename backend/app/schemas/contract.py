"""앱↔서버 JSON 계약(docs/api-contract.md §2)의 Pydantic 스키마.

응답이 계약과 어긋나면 FastAPI가 바로 잡아주도록, 계약서의 데이터 모델을 그대로 코드화했다.
필드명·타입은 docs/api-contract.md와 1:1로 대응한다. (Phase D-2 더미 응답용)
"""

from __future__ import annotations

from typing import Literal, Optional

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
    # 이 카드의 **설명 문장**을 누가 썼는가 (2026-08-14 D26). additive — 없으면 앱이
    # 종전 라벨('자동 생성')을 그대로 쓴다.
    #   · LLM이 쓴 문장  → 실제 호출된 모델 문자열 (예: "solar-pro2")
    #   · 준비된 문구    → `explanation.FALLBACK_SOURCE_LABEL` ("준비된 문구")
    # ⚠ **판정 출처가 아니다.** 판정은 언제나 규칙 엔진이고 그 출처는 `sourceText`다.
    #   이 값은 설명 계층에만 해당하며, 카드마다 다를 수 있다(필드 단위 폴백).
    explanationSource: Optional[str] = None


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


# ── 사진 속 실명·주민번호 자리 (§9.8 — 2026-10-22 추가, **선택적**) ─────────────
# '사진 속 이름 가리기'가 켜지면 앱이 이 상자를 전부 불투명하게 덮는다. **글자는 담지 않는다 — 위치만.**
class PrivacyMask(BaseModel):
    """가릴 자리 하나 — 정규화 좌표(0~1). `page`는 업로드한 사진 순서(0부터).

    `x=0, y=0, w=1, h=1`은 "이 쪽은 이름 자리를 찾아보지 못했다(OCR 실패 등)"는 뜻이다 → 쪽 전체를 덮는다.
    """

    page: int
    x: float
    y: float
    w: float
    h: float


# ── 촬영 검사 (§9.9 — 2026-10-22 추가, **선택적**) ──────────────────────────────
# 판정이 아니라 **사진 품질**이다. 등급·근거 카드에 어떤 영향도 주지 않는다.
class CapturePageIssue(BaseModel):
    """문제가 있는 사진 한 장. 문제가 없는 장은 목록에 넣지 않는다."""

    index: int  # 업로드한 사진 순서 (0부터) — 화면에는 index+1쪽으로
    # blurry · too_dark · too_bright · low_contrast · no_text · low_resolution · cut_off
    issues: list[str] = Field(default_factory=list)
    severe: bool = False  # true = 분석하지 않고 거절한 장(크레딧 0원)
    tip: str = ""  # 왜 문제인지 + 어떻게 다시 찍는지 (쉬운 말 두 문장)


class CaptureCheck(BaseModel):
    ok: bool = True  # 문제가 하나도 없으면 true
    pages: list[CapturePageIssue] = Field(default_factory=list)


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
class RiskFact(BaseModel):
    """등기부의 살아 있는 위험 항목 하나 — 판례 맞춤 설명 재료 (2026-10-24, 화면 표시 없음·판정 미사용).

    이름은 담지 않는다(권리자는 '기관'/'개인'만).
    """

    kind: str  # 가압류 | 압류 | 가처분 | 경매개시결정 | 신탁 | 근저당 | 전세권 | 임차권등기
    receiptDate: Optional[str] = None
    amount: Optional[int] = None  # 청구금액·채권최고액·보증금(원)
    holder: Optional[str] = None  # "기관" | "개인"


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
    # [판례 설명 재료 — 2026-10-24] 살아 있는 위험 항목의 종류·접수일·금액·권리자 종류. 판정·화면에 쓰지 않는다.
    riskFacts: list[RiskFact] = Field(default_factory=list)
    # 이 분석을 **다음 등기부와 견줄 기준(baseline)으로 쓸 수 있는가** (2026-08-14 S-11).
    #
    # 대조는 판정 결과가 아니라 **추출 스냅샷**(소유자·빚·압류 항목)을 맞춰보는 것이라,
    # 스냅샷을 남기기 전에 만들어진 리포트는 견줄 재료가 없다. 그 사실을 앱이 미리 알아야
    # "사진부터 찍게 해 놓고 마지막에 못 한다고 말하는" 흐름을 피할 수 있다
    # (계약 여정 S-11 "기준 없음" 화면은 사진을 받기 전에 나온다).
    comparable: bool = False
    # 사진 속 **실명·주민번호 자리** (2026-10-22, P0-2b). '사진 속 이름 가리기'가 켜지면 앱이 전부 덮는다.
    # 글자는 없고 위치만 있다. 표시 전용 — 판정과 무관하다.
    privacyMasks: list[PrivacyMask] = Field(default_factory=list)
    # 위 목록을 **실제로 만들었는가**. false = 이 기능 전에 만든 기록(위치 정보 없음) →
    # 앱은 가리기가 켜져 있으면 사진을 통째로 덮는다(어디에 이름이 있는지 모르므로).
    privacyMasksReady: bool = False
    # 촬영 검사 결과 (2026-10-22, P1-1). 가벼운 문제(조금 흐림·쪽 번호 잘림 등)는 분석하되 여기서 알린다 —
    # 앱은 그 장에 '확인 필요'를 붙이고 다시 찍기를 권한다. 심한 문제는 분석 전에 400으로 거절된다(§9.9).
    # 없으면(None) 검사하지 않은 옛 기록이거나 서버에서 검사를 끈 것이다(`CAPTURE_CHECK=off`).
    captureCheck: Optional[CaptureCheck] = None
    # 이 등기부의 **사람 이름** 목록 (2026-10-22 — 화면엔 실명, 저장은 가린 사본 · api-contract §9.11).
    # 분석 응답에는 실명이 온다 — 앱의 '사진 속 이름 가리기'가 켜지면 화면 글자에서 이 이름들을 `홍○○`로 바꾼다.
    # 서버 기록에 남는 사본(기록 API·캐시 적중)에서는 이 목록도 가려져 있다(`name_privacy.mask_report_for_storage`).
    # 회사·은행·관공서 이름은 넣지 않는다(원래부터 그대로 보인다).
    personNames: list[str] = Field(default_factory=list)


# ── 판례 (§2.3 CaseMatch) ──────────────────────────────────────────────────
class CaseMatch(BaseModel):
    riskPattern: str
    caseNo: str
    summary: str
    result: str
    commonPoint: str
    # ── E-3 라우터 통합 (2026-08-07) — 전부 선택적. 기존 앱은 무시해도 동작한다. ──
    # 사용자가 판결문을 직접 찾아볼 수 있어야 한다(지어내기 금지 원칙의 검증 통로).
    sourceUrl: Optional[str] = None
    decided: Optional[str] = None          # 선고일 YYYYMMDD
    matchedTags: list[str] = Field(default_factory=list)
    # "이런 피해를 피하려면" — 큐레이션 전용. LLM이 만들지 않는다.
    advice: Optional[str] = None
    # 문구를 사람이 검수했는지. False면 화면에 "검수 전" 표시가 붙는다 —
    # 출처는 공식 DB로 확인됐지만 쉬운 말 문구는 아직 사람 손을 거치지 않았다는 뜻.
    # (2026-08-14 D22: 앱은 이 값을 더 이상 카드에 그리지 않지만, 서버 정렬 기준이자
    #  제안서 인용 근거라 응답에는 그대로 남긴다.)
    curated: bool = False
    # ── 읽기 보조 (2026-08-14 D20·D23) — 전부 additive. 없으면 아무 일도 안 난다. ──
    # 본문에 등장한 어려운 말 → 쉬운 설명. 근거 카드(EvidenceItem)와 **같은 구조·같은
    # 규칙**이다: 키가 본문에 그대로 있어야 앱이 indexOf로 찾아 점선 밑줄을 붙인다.
    termGlossary: dict[str, str] = Field(default_factory=dict)
    # `{필드명: [굵게 그릴 부분 문자열, ...]}` — 필드명은 이 모델의 이름 그대로
    # (`result` · `commonPoint` · `advice`). **본문을 바꾸지 않는 표시 지시**라,
    # 문구 변경이 금지된 `advice`에도 안전하다. 못 찾으면 굵기만 안 붙는다.
    emphasis: dict[str, list[str]] = Field(default_factory=dict)


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


class GlossaryAnswer(BaseModel):
    """챗봇 답 하나 (§3.9 — 2026-08-14 S-12).

    **404를 200으로 바꿨다.** 예전에는 사전에 없으면 404가 나가고 앱이 거절 문구를
    하드코딩해 띄웠다. 그러면 ⑴ 화면 문구를 서버가 못 정하고 ⑵ LLM 답과 거절을 서로
    다른 경로로 다뤄야 한다. 이제 **모든 답이 한 모양**으로 나간다.

    `outOfScope=true`면 앱이 답변 아래에 유도 버튼(리포트/분석)을 붙인다 —
    거절도 정상 답변 톤으로 그린다(경고색·에러 아이콘 금지).
    """

    answer: str  # 화면에 그대로 그릴 문장 (거절 문구도 여기 들어온다)
    outOfScope: bool = False
    # 이 문장을 누가 썼는가 — "검수된 용어 사전" | 실제 모델명 | "준비된 문구"
    source: str = ""
    # 답변에 등장한 어려운 말 → 쉬운 설명 (근거 카드·판례와 **같은 메커니즘**)
    termGlossary: dict[str, str] = Field(default_factory=dict)
    # 사전 직격일 때만 그 용어명. 자연어 답변·거절이면 None.
    term: Optional[str] = None
    # 옛 앱 호환용 거울 필드 — 옛 앱은 `{term, description}`을 기대한다.
    # 새 앱은 `answer`만 읽는다. 두 값은 항상 같다.
    description: str = ""


# ── 챗봇 (§2.11 / §3.21 — 2026-10-24 대화형) ────────────────────────────────
class ChatMessage(BaseModel):
    """대화 한 줄. 앱이 최근 대화를 통째로 보낸다(서버는 대화를 저장하지 않는다)."""

    role: Literal["user", "assistant"]
    content: str = Field(max_length=2000)


class ChatRequest(BaseModel):
    """`POST /api/chat` — 마지막 줄이 이번 질문(`user`)이어야 한다. 앞의 것은 맥락."""

    messages: list[ChatMessage] = Field(min_length=1, max_length=20)


class ChatResponse(BaseModel):
    """챗봇 답 하나. **등급·점수·금액 칸이 없다** — 판정은 리포트(규칙 엔진)만 한다."""

    answer: str  # 화면에 그릴 글. `**굵게**` 표시(최대 3곳)와 줄바꿈(\n)이 들어 있다
    # normal = AI 답 / careful = 규칙이 판정 요구를 알아채 '판단 없이' 답함 / fallback = AI 대신 기본 문장
    mode: str = "normal"
    model: str = ""  # 답을 쓴 모델(예: solar-pro2). 기본 문장이면 ""


# ── 계약 여정 (§2.6 JourneyStage / JourneyItem) ────────────────────────────
class JourneyItem(BaseModel):
    text: str
    why: str


class JourneyStage(BaseModel):
    title: str
    subtitle: str
    items: list[JourneyItem]
    # ── S-11 재설계 (2026-08-14) — 아래는 전부 선택적. 옛 앱은 무시해도 종전과 같이 동작한다.
    # 단계는 이제 **체크박스 목록이 아니라 매물에 붙은 타임라인**이라, 각 단계가 어떤
    # 성격인지(끝난 일/할 일/한참 뒤 일)와 어떤 행동을 붙일지를 데이터가 들고 있어야 한다.
    #
    # analysis: 분석 기록이 있으면 자동 완료 · action: 지금 할 일 · later: 1~2년 뒤 일
    kind: str = "action"
    # 이 단계에 [다시 떼서 대조하기] 버튼을 붙일지 — 등기부를 다시 떼야 하는 시점인가.
    compare: bool = False
    # 이 단계에서 일정 입력을 권할지 (계약서에 날짜가 적히는 시점)
    askDates: bool = False
    # 어디서 하는 일인지 알려주는 칩 (예: "주민센터에서", "HUG · HF · SGI")
    agency: Optional[str] = None
    # 이 단계에 붙는 사용자 일정 키. 날짜 자체는 **기기에만** 저장되므로 서버는 키만 준다.
    #   downPayment | contract | balance | moveIn | moveInNext
    #   (moveInNext = 이사일 다음 날 — 사용자가 따로 넣지 않고 앱이 계산한다)
    dateKey: Optional[str] = None


# ── 등기부 대조 (§2.9 CompareResult — 2026-08-14 S-11) ─────────────────────
# **규칙 기반이다.** 두 등기부의 항목을 그대로 맞춰본 결과이고 LLM은 개입하지 않는다.
# 문구도 이 계층에서 만든다(설명 생성 아님 — 값에서 결정되는 고정 문장).
class CompareDoc(BaseModel):
    """대조에 참여한 등기부 한 쪽."""

    reportId: Optional[str] = None
    alias: Optional[str] = None
    address: Optional[str] = None
    viewedAt: Optional[str] = None  # 등기부에 인쇄된 열람일 'YYYY.MM.DD' (못 읽으면 None)
    analyzedAt: Optional[str] = None  # ISO 8601
    grade: Optional[str] = None  # "위험" | "확인 필요" | "양호"
    pageCount: Optional[int] = None  # 이번에 올린 사진 장수


class CompareRow(BaseModel):
    """대조 결과 한 줄 — 화면의 카드 1장."""

    # added(새로 생김) | removed(없어짐) | changed(내용이 달라짐) | same(그대로) |
    # unknown(대조 못 함) | grade(안전도 변화)
    kind: str
    tone: str  # danger | caution | neutral — 앱이 색을 고르는 기준
    marker: str  # 카드 왼쪽 원 안 글자: + − ≠ = ? !
    title: str
    subtitle: Optional[str] = None
    detail: Optional[str] = None  # 회색 상세 박스 (수치·건수)
    # 새로 생긴 항목의 접수일 'YYYY-MM-DD'. 앱이 사용자의 계약 일정(기기 저장)과 견줘
    # "계약서 쓴 다음 날이에요" 같은 한 줄을 덧붙일 수 있게 하는 재료다.
    receiptDate: Optional[str] = None
    gradeBefore: Optional[str] = None
    gradeAfter: Optional[str] = None
    # 이 줄에 붙는 행동 — recapture(빠진 쪽 다시 찍기) | analyze(새로 분석)
    action: Optional[str] = None
    actionLabel: Optional[str] = None


class CompareResult(BaseModel):
    # changed(대조함) | partial(일부 못 함) | no_baseline(기준 없음) | different_property(다른 집)
    result: str
    headline: str
    subline: Optional[str] = None
    baseline: CompareDoc
    current: CompareDoc
    daysBetween: Optional[int] = None  # 두 서류 날짜 차이(일). 한쪽이라도 없으면 None
    comparedCount: int = 0
    totalCount: int = 0
    rows: list[CompareRow] = Field(default_factory=list)
    # 대조 자체에 대한 고지 (예: 같은 집인지 확인하지 못함). 화면 하단 회색 카드.
    notices: list[str] = Field(default_factory=list)
    # 같은 집인지 무엇으로 확인했나: "고유번호" | "소재지" | None(확인 못 함)
    identityBasis: Optional[str] = None
    # 이번에 뗀 등기부로 만들어진 새 리포트 id. **다른 집이면 None** — 기준 매물의
    # 보증금으로 계산된 값이라 그 집의 판정으로 쓸 수 없어 이력에서도 지운다.
    newReportId: Optional[str] = None


# ── 요금제·테스트 결제 (§3.12~§3.14 — 2026-10-22, P2-1) ───────────────────────
# 가격은 팀 확정 전까지 **예시**다(`label`). 결제 금액은 서버가 `data/pricing.json`의 price로
# 검사한다 — 앱이 보낸 금액을 믿지 않는다. 결제는 토스페이먼츠 **테스트 키로만** 승인한다.


class PricingPlan(BaseModel):
    id: str  # free | guardian_pass | institution
    name: str
    tagline: str
    price: Optional[int] = None  # 원. None이면 결제할 수 없다(문의)
    priceText: str  # 화면에 그대로 쓰는 값 ("9,900원" · "문의")
    period: Optional[str] = None  # "계약 1건" 등
    purchasable: bool = False  # 결제 버튼을 붙이는가
    contact: bool = False  # "문의" 요금제인가
    features: list[str] = Field(default_factory=list)


class Pricing(BaseModel):
    label: str  # "예시 가격(확정 전)" — 결제 화면 가격 밑에 붙인다(요금제 화면은 짧게 "예시 가격")
    currency: str = "KRW"
    testMode: bool = True  # 결제가 테스트 결제인가 (실제 청구 없음)
    testNotice: str = "테스트 결제 — 실제 청구 없음"
    plans: list[PricingPlan]


class PaymentConfirmRequest(BaseModel):
    """결제위젯이 성공으로 돌려준 값 + 산 요금제. **amount는 검사용**일 뿐 승인 금액은 서버가 정한다."""

    planId: str
    orderId: str = Field(pattern=r"^[A-Za-z0-9_-]{6,64}$")  # 토스 주문번호 규칙
    paymentKey: str = Field(min_length=1, max_length=200)
    amount: int = Field(ge=0)


class GuardianPass(BaseModel):
    """계약 지킴이 패스 한 장(= 결제 기록 한 건). 카드 번호·영수증 주소는 담지 않는다."""

    planId: str
    planName: str
    orderId: str
    amount: int
    method: Optional[str] = None  # 토스가 준 결제수단 ("카드" · "간편결제" 등)
    approvedAt: Optional[str] = None  # 토스 승인 시각 (ISO 8601)
    testMode: bool = True


class PaymentConfirmResponse(BaseModel):
    model_config = {"populate_by_name": True}

    testMode: bool = True
    notice: str = "테스트 결제 — 실제 청구 없음"
    guardianPass: GuardianPass = Field(alias="pass")


class PassStatus(BaseModel):
    model_config = {"populate_by_name": True}

    active: bool
    testMode: bool = True
    notice: str = "테스트 결제 — 실제 청구 없음"
    guardianPass: Optional[GuardianPass] = Field(default=None, alias="pass")


# ── 로그인 (§3.15~§3.18 — 2026-10-22, P2-1 카카오 로그인) ───────────────────────
# 카카오에서는 **회원번호만** 받는다(이름·이메일·닉네임·프로필 사진은 받지 않는다).
# 회원번호도 서버에는 HMAC 값(계정 키)으로만 남는다 — 아래 응답 어디에도 회원번호는 없다.


class KakaoLoginRequest(BaseModel):
    """카카오 SDK가 준 **액세스 토큰**. 서버가 카카오에 물어 우리 앱의 토큰인지·누구인지(회원번호) 확인한다."""

    accessToken: str = Field(min_length=1, max_length=4096)


class SessionResponse(BaseModel):
    """로그인 성공 — 앞으로 모든 요청에 `Authorization: Bearer <sessionToken>`을 싣는다."""

    sessionToken: str  # 무작위 값. 서버에는 SHA-256만 남는다
    expiresAt: str  # 만료 시각 (ISO 8601, UTC)
    customerKey: str  # 토스 결제위젯 customerKey — 계정에서 만든 값(회원번호와 무관)


class MeResponse(BaseModel):
    """지금 로그인 상태. 로그인 안 했으면 `loggedIn=false`(둘러보기 = 기기 id)."""

    loggedIn: bool
    provider: Optional[str] = None  # "kakao"
    customerKey: Optional[str] = None  # 로그인했을 때만
    displayName: Optional[str] = None  # 사용자가 앱에서 정한 이름(2026-10-24) — 없으면 null


class DisplayNameRequest(BaseModel):
    """`POST /api/me/name` — 표시 이름 정하기(빈 값이면 지우기)."""

    displayName: str = ""


class PrecedentStatus(BaseModel):
    """판례 창고 상태 (계약 §3.11 — 2026-10-24 판례 자동 업데이트)."""

    docCount: Optional[int] = None  # 창고에 든 판례 수
    updatedAt: Optional[str] = None  # 마지막 업데이트 날짜 "YYYY-MM-DD"
