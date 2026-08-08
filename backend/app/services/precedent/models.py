"""판례 RAG 데이터 모델.

계층 구분(가드레일):
- `PrecedentDoc`  : 큐레이션·수집 데이터 (사람이 만든 사실 — LLM이 생성·수정 불가).
  특히 `advice`는 정민재 큐레이션 전용 필드로, LLM 입력·재작성 대상에서 스키마 레벨로
  분리한다 (decisions.md 2026-07-09 "E-3 설계 메모").
- `PrecedentExplanation` : LLM(Solar Pro)이 채울 수 있는 필드의 전부 — extra="forbid",
  판정(등급·점수)·사건번호·조언 필드가 존재하지 않는다. 사건번호·출처는 서버가
  검색된 문서에서 복사한다(LLM이 지어낼 통로 차단).
"""

from __future__ import annotations

from typing import Optional

from pydantic import BaseModel, ConfigDict, Field

# ── 위험 패턴 태그 어휘 ──────────────────────────────────────────────────────
# patterns.ID_TO_LABEL(고정 어휘 4종)의 상위 집합. 검색 필터·평가셋이 공용으로 쓴다.
# 세분 태그는 규칙 엔진 facts에서 파생 가능한 신호와 1:1로 맞춘다(service.py 참고).
RISK_TAGS = (
    "전세가율",        # jeonse_ratio 근거 (깡통전세)
    "선순위 채권",     # senior_debt 근거 (근저당·배당)
    "신탁등기",        # ownership.facts.signals["신탁등기"]
    "압류·가압류",     # ownership.facts.signals 압류/가압류/가처분
    "경매",            # ownership.facts.signals["경매개시결정"] + 배당 일반
    "임차권등기",      # senior_debt.facts.lease_registration_count
    "보증보험",        # insurance 근거
    "대항력",          # 교차 주제 (전입신고·확정일자·우선변제권) — 보조 태그
)


class PrecedentDoc(BaseModel):
    """판례 1건 — 수집(법제처 API)·수기 큐레이션 공통 양식.

    `verified=False`인 문서는 검색 인덱스에 실을 수는 있으나 서비스 노출이 차단된다
    (retrieval.py 게이트). 사건번호·출처가 확인된 문서만 사용자에게 나간다.
    """

    model_config = ConfigDict(extra="forbid")

    case_id: str                      # 내부 식별자 (예: "prec-2005da4529")
    case_no: str                      # 사건번호 — 판결문 표기 그대로 (인용 필수 요소)
    court: str                        # 법원명 (예: "대법원")
    decided: Optional[str] = None     # 선고일 (예: "2005-06-09")
    title: Optional[str] = None       # 사건명
    risk_tags: list[str] = Field(default_factory=list)  # RISK_TAGS 어휘
    holding: str                      # 판시사항·판결요지 (검색 대상 핵심 텍스트)
    outcome: Optional[str] = None     # 임차인(피해자) 관점 결과 한 줄
    summary_easy: Optional[str] = None  # 쉬운 한 줄 요약 (큐레이션 — 없으면 LLM 폴백 전 원문 표시)
    advice: Optional[str] = None      # "이런 피해를 피하려면" — 큐레이션 전용, LLM 불가침
    source_url: str                   # 출처 링크 (필수 — 지어내기 금지 원칙)
    full_text: Optional[str] = None   # 판례 전문 (법제처 API 수집 시)
    # ── 검증 2단계 (2026-08-07) ──────────────────────────────────────────
    # 원래 `verified` 하나가 "공식 DB + 사람 검증" AND 조건이었다. 그런데 법제처
    # 공식 API로 수집하고 관련성까지 판정한 판례 148건이 "사람이 한 줄씩 읽지 않았다"는
    # 이유로 전부 노출 차단돼, 색인 1,900청크 중 6건만 보이는 상태가 됐다.
    # 그래서 두 축을 분리한다 — 숨기지 않되, 섞지도 않는다.
    #   source_verified : 출처가 공식 DB이고 사건번호·링크가 실재한다 (자동 판정 가능)
    #   verified        : 사람이 문구까지 검수했다 (기존 의미 그대로)
    # 노출 게이트는 source_verified를 본다. verified=False인 판례는 나가되,
    # 화면에 "문구 검수 전"임을 밝힌다 (retrieval.py 게이트 · 카드 라벨).
    source_verified: bool = False     # 출처 확인 — 미확인이면 노출 차단
    verified: bool = False            # 사람 문구 검수 — 미검수여도 노출은 되되 표시가 붙는다
    curated_by: Optional[str] = None
    collected_at: Optional[str] = None


class PrecedentChunk(BaseModel):
    """검색 단위 — 판결요지 중심 청킹의 산출물. 문서 메타데이터를 상속한다."""

    model_config = ConfigDict(extra="forbid")

    chunk_id: str                     # f"{case_id}#{n}"
    case_id: str
    section: str                      # "판결요지" | "판시사항" | "전문" | "요약"
    text: str
    risk_tags: list[str] = Field(default_factory=list)


class RetrievedPrecedent(BaseModel):
    """검색 결과 1건 — 점수 내역을 함께 운반해 게이트·디버깅·평가가 추적 가능하게 한다."""

    model_config = ConfigDict(extra="forbid")

    doc: PrecedentDoc
    chunk: PrecedentChunk
    vector_score: float               # 코사인 유사도 [-1, 1]
    keyword_score: float              # BM25 정규화 점수 [0, 1]
    hybrid_score: float               # 가중 결합 점수
    matched_tags: list[str] = Field(default_factory=list)  # 판정과 겹친 위험 태그


class PrecedentExplanation(BaseModel):
    """LLM이 채울 수 있는 필드의 전부 — 판정·사건번호·조언 필드는 존재하지 않는다.

    LLM이 여분 키(grade, case_no, advice 등)를 실어 보내면 pydantic 검증 실패 → 폴백.
    """

    model_config = ConfigDict(extra="forbid")

    case_id: str                      # 어떤 검색 결과에 대한 설명인지 (서버가 대조 검증)
    easy_summary: str                 # 사건 쉬운 요약 (1~2문장, 해요체)
    common_point: str                 # 이 매물 판정과의 공통점 (1문장, 해요체)


class PrecedentSection(BaseModel):
    """리포트에 붙는 판례 섹션의 서버 내부 표현 (api-contract 갱신안의 원형).

    `cases`가 비어 있으면 `fallback_text`가 정직한 폴백 문구를 담는다 —
    "관련 판례를 찾지 못했어요"를 그대로 노출한다(지어내기·유사도 미달 노출 금지).
    """

    model_config = ConfigDict(extra="forbid")

    cases: list[dict] = Field(default_factory=list)   # CaseMatch 호환 dict (service.py가 조립)
    fallback_text: Optional[str] = None
    # "AI 생성" | "AI 생성(일부 폴백)" | "자동 생성" — E-2 라벨 정직성 결정(2026-07-09)과 동일 원칙.
    # E-3 라우터 통합 시 계약 갱신안(explanationSource)에 배선한다.
    explanation_source: str = "자동 생성"
