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
    kind: str  # "owner" | "mortgage" | "jeonse"
    badge: int  # 화면에 붙일 번호 (1부터) — 색만으로 정보를 전달하지 않기 위함
    box: HighlightBox
    title: str
    body: str
    caution: Optional[str] = None


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
    marketPrice: Optional[int] = None
    seniorDebtAmount: int
    evidences: list[Evidence]
    # 선택적 추가 (2026-07-27). 좌표를 못 구하면 빈 목록 — 그래도 리포트는 완성된다.
    highlights: list[Highlight] = Field(default_factory=list)


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
