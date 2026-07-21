"""판례 매칭 오케스트레이션 — 판정(RuleVerdict/Report) → 분기 검색 → (선택) Solar 설명.

아키텍처: **분기(Branch) RAG + 하이브리드 검색** (선정 근거: decisions.md 2026-07-22).
- 쿼리 원천이 사용자 자연어가 아니라 규칙 엔진의 **구조화된 판정**이므로,
  위험 태그별로 **결정적 질의 템플릿**을 만들어 태그 필터와 함께 각각 검색하고 병합한다.
  (LLM이 질의를 만들지 않는다 — 검색 단계까지 완전 결정적. HyDE류 질의 생성은
  환각 경로·비용 추가 대비 이득이 없어 탈락 — 우리 질의는 이미 구조화돼 있다.)

가드레일: 이 모듈은 rule_engine이 만든 판정을 **읽기만** 한다. 어떤 함수도 판정을
만들거나 바꾸지 않으며, rule_engine·report_builder는 이 모듈을 import하지 않는다
(판례 → 판정 방향의 코드 경로 자체가 없음).
"""

from __future__ import annotations

from pathlib import Path

from ...schemas.contract import Report
from ...schemas.internal import Grade, RuleVerdict
from .. import thresholds as T
from . import explainer
from .models import PrecedentSection, RetrievedPrecedent
from .retrieval import HybridRetriever

# 태그별 결정적 질의 템플릿 — 판례 검색 전용 문장(판정 아님).
# 법률 어휘(BM25 신호)와 상황 서술(벡터 신호)을 함께 담는다.
QUERY_TEMPLATES: dict[str, str] = {
    "신탁등기": "신탁등기된 부동산을 수탁자 신탁회사 동의 없이 임대차 계약한 임차인의 대항력과 보증금 반환",
    "선순위 채권": "선순위 근저당권이 설정된 주택이 경매될 때 후순위 임차인의 배당과 보증금 손실",
    "전세가율": "매매가에 육박하는 전세보증금 깡통전세 무자본 갭투자 전세사기 보증금 편취 사기죄",
    "임차권등기": "임차권등기명령에 따른 임차권등기와 임차인의 대항력 우선변제권 보증금 미반환",
    "압류·가압류": "가압류 압류 등기가 있는 주택을 임차한 임차인의 대항력과 경매 시 보증금",
    "경매": "주택 경매 경락 절차에서 임차인의 배당 순위와 낙찰인에 대한 대항력",
    "보증보험": "공인중개사가 선순위 임대차보증금 현황을 확인 설명하지 않은 경우 임차인 손해배상",
    "대항력": "주택임대차보호법 전입신고 주민등록에 따른 대항력 취득 시점과 확정일자 우선변제권",
}

# 시연·표시 파라미터 (인프라 수치)
TOP_K_PER_TAG = 2   # 태그(위험 유형)당 최대 후보
MAX_CASES = 4       # 판례 섹션 최대 카드 수

FALLBACK_NO_MATCH = (
    "이 매물의 위험 신호와 연결되는 판례를 아직 찾지 못했어요. "
    "판례가 없다는 뜻이 위험이 없다는 뜻은 아니에요 — 리포트의 확인 항목을 직접 점검해 주세요"
)
FALLBACK_NO_RISK = (
    "지금 리포트에서 판례와 연결할 위험 신호가 발견되지 않았어요. "
    "다만 등기부등본은 계약 직전에 최신본으로 한 번 더 확인하는 것이 좋아요"
)


def tags_from_verdict(verdict: RuleVerdict) -> list[str]:
    """판정 → 위험 태그 파생 (결정적 — patterns.derive_from_report의 세분화판).

    보수적 선택 메모:
    - 전세가율: **실측 비율이 주의 기준(thresholds.JEONSE_RATIO_CAUTION_PCT)을 넘은 경우만**
      태그. 시세 미입력이나 문서 불완전(floor_caution)으로 '확인 필요'가 된 카드에
      깡통전세 판례를 붙이면 과잉 매칭이다. 임계값은 판정과 동일한 단일 출처
      (thresholds.py)를 읽기만 한다 — 판정을 바꾸는 게 아니라 설명 노출 여부만 결정.
    - 보증보험: 구조적 '확인 필요'(모든 리포트 공통)는 제외, 결격 신호(위험)일 때만 태그.
    """
    tags: list[str] = []
    for ev in verdict.evidences:
        if ev.id == "jeonse_ratio" and ev.grade != Grade.GOOD:
            pct = ev.facts.get("jeonse_ratio_pct")
            if pct is not None and pct > T.JEONSE_RATIO_CAUTION_PCT:
                tags.append("전세가율")
        elif ev.id == "senior_debt" and ev.grade != Grade.GOOD:
            # 실제 유효 채권이 1건이라도 있을 때만 (문서 불완전 floor로 '확인 필요'가 된
            # 채권 0건 카드에 경매·배당 판례를 붙이지 않는다)
            debt_count = (
                ev.facts.get("mortgage_count", 0)
                + ev.facts.get("jeonse_right_count", 0)
                + ev.facts.get("unknown_amount_count", 0)
            )
            if debt_count > 0:
                tags.append("선순위 채권")
            if ev.facts.get("lease_registration_count", 0) > 0:
                tags.append("임차권등기")
        elif ev.id == "ownership" and ev.grade != Grade.GOOD:
            signals = ev.facts.get("signals", {})
            if signals.get("신탁등기", 0) > 0:
                tags.append("신탁등기")
            if any(signals.get(k, 0) > 0 for k in ("압류", "가압류", "가처분")):
                tags.append("압류·가압류")
            if signals.get("경매개시결정", 0) > 0:
                tags.append("경매")
        elif ev.id == "insurance" and ev.grade == Grade.DANGER:
            tags.append("보증보험")
    return list(dict.fromkeys(tags))  # 순서 보존 dedup


def tags_from_report(report: Report) -> list[str]:
    """저장된 Report만 있을 때의 태그 파생 (facts 없음 — detailText 키워드로 세분화).

    한계: detailText 문구 의존이라 verdict 경로보다 거칠다. E-3에서 리포트에
    위험 태그를 저장하는 additive 확장을 권장 (docs/precedent-rag.md §확장 지점).
    """
    tags: list[str] = []
    for ev in report.evidences:
        if ev.grade == "양호":
            continue
        detail = ev.detailText or ""
        if ev.id == "jeonse_ratio":
            # 실측 비율이 표시된 경우만 (시세 미입력 카드에는 % 계산값이 없다)
            if "%" in detail:
                tags.append("전세가율")
        elif ev.id == "senior_debt":
            tags.append("선순위 채권")
            if "임차권등기" in detail:
                tags.append("임차권등기")
        elif ev.id == "ownership":
            if "신탁" in detail:
                tags.append("신탁등기")
            if any(k in detail for k in ("압류", "가압류", "가처분")):
                tags.append("압류·가압류")
            if "경매" in detail:
                tags.append("경매")
        elif ev.id == "insurance" and ev.grade == "위험":
            tags.append("보증보험")
    return list(dict.fromkeys(tags))


def _verdict_summary(verdict: RuleVerdict | None, tags: list[str]) -> dict:
    """LLM 공통점 서술용 판정 요약 — 판정에서 파생한 값만 (원본 추출·이미지 없음)."""
    summary: dict = {"위험_태그": tags}
    if verdict is not None:
        summary["종합등급"] = verdict.grade.value
        for ev in verdict.evidences:
            if ev.grade != Grade.GOOD and ev.detail_text:
                summary.setdefault("근거_상세", []).append({"id": ev.id, "상세": ev.detail_text})
    return summary


class PrecedentService:
    """판례 섹션 조립기 — E-3 라우터 통합의 진입점.

    사용:
        svc = PrecedentService()                      # 기본 인덱스·백엔드
        section = svc.match_for_verdict(verdict)      # 분석 직후 (정밀 태그)
        section = svc.match_for_report(report)        # 저장 리포트 재열람
    """

    def __init__(self, index_dir: Path | None = None, retriever: HybridRetriever | None = None):
        self._retriever = retriever if retriever is not None else HybridRetriever(index_dir)

    def search_by_tags(self, tags: list[str]) -> list[RetrievedPrecedent]:
        """태그별 분기 검색 → 병합 → 정렬 (매칭 태그 수 우선 — 피드백 A6)."""
        merged: dict[str, RetrievedPrecedent] = {}
        for tag in tags:
            query = QUERY_TEMPLATES.get(tag)
            if not query:
                continue
            for m in self._retriever.search(query, risk_tags=[tag], top_k=TOP_K_PER_TAG):
                prev = merged.get(m.doc.case_id)
                if prev is None or m.hybrid_score > prev.hybrid_score:
                    matched = sorted(set(m.doc.risk_tags) & set(tags))
                    merged[m.doc.case_id] = m.model_copy(update={"matched_tags": matched})
        ranked = sorted(
            merged.values(), key=lambda m: (len(m.matched_tags), m.hybrid_score), reverse=True
        )
        return ranked[:MAX_CASES]

    def _build_section(
        self, tags: list[str], verdict: RuleVerdict | None, *, explain: bool
    ) -> PrecedentSection:
        if not tags:
            return PrecedentSection(cases=[], fallback_text=FALLBACK_NO_RISK)
        matches = self.search_by_tags(tags)
        if not matches:
            return PrecedentSection(cases=[], fallback_text=FALLBACK_NO_MATCH)

        explanations: dict = {}
        source = "자동 생성"  # LLM 미호출·폴백은 "자동 생성" (라벨 정직성 — decisions.md 2026-07-09)
        if explain:
            explanations, llm_source = explainer.explain_matches(
                matches, _verdict_summary(verdict, tags)
            )
            if llm_source != "폴백":
                source = llm_source

        cases = []
        for m in matches:
            exp = explanations.get(m.doc.case_id)
            cases.append(
                {
                    # [메타 — 검색된 문서에서 복사 (LLM 불개입)]
                    "riskPattern": (m.matched_tags or m.doc.risk_tags or ["기타"])[0],
                    "matchedTags": m.matched_tags,
                    "caseNo": f"{m.doc.court} {m.doc.case_no}".strip(),
                    "decided": m.doc.decided,
                    "sourceUrl": m.doc.source_url,
                    # [설명 — LLM 생성 성공 시만, 실패·미호출은 결정적 폴백]
                    "summary": exp.easy_summary if exp else explainer.fallback_summary(m),
                    "commonPoint": exp.common_point if exp else explainer.fallback_common_point(m),
                    # [판정·조언 — LLM 불가침]
                    "result": m.doc.outcome or "결과는 원문을 확인해 주세요",
                    "advice": m.doc.advice,
                }
            )
        return PrecedentSection(cases=cases, explanation_source=source)

    def match_for_verdict(self, verdict: RuleVerdict, *, explain: bool = False) -> PrecedentSection:
        return self._build_section(tags_from_verdict(verdict), verdict, explain=explain)

    def match_for_report(self, report: Report, *, explain: bool = False) -> PrecedentSection:
        return self._build_section(tags_from_report(report), None, explain=explain)
