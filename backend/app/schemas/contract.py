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
