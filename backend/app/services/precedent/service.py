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
from .. import terms, thresholds as T
from . import emphasis as emphasis_picker, explainer
from .models import OUTCOME_TEXT, OUTCOME_UNKNOWN, PrecedentSection, RetrievedPrecedent
from .retrieval import HybridRetriever

# 태그별 결정적 질의 템플릿 — 판례 검색 전용 문장(판정 아님).
# 법률 어휘(BM25 신호)와 상황 서술(벡터 신호)을 함께 담는다.
QUERY_TEMPLATES: dict[str, str] = {
    "신탁등기": "신탁등기된 부동산을 수탁자 신탁회사 동의 없이 임대차 계약한 임차인의 대항력과 보증금 반환",
    "선순위 채권": "선순위 근저당권이 설정된 주택이 경매될 때 후순위 임차인의 배당과 보증금 손실",
    # ★ 판결문은 "전세가율"·"깡통전세"라는 말을 쓰지 않는다. 이 위험은 법리 쟁점이
    #   아니라 사실관계로 나타난다 — 다가구주택에서 앞 세입자들 보증금 합계가 집값을
    #   넘어 뒤 세입자가 배당을 못 받는 구조다. 질의를 '깡통전세' 어휘로만 쓰면
    #   실제 판례와 의미가 멀어 유사도 하한(0.45)에 전부 막힌다
    #   (실측 2026-08-12: 태그가 붙은 7건 중 통과 0건, 최고 0.362).
    #   그래서 판례가 실제로 쓰는 말로 질의한다.
    "전세가율": (
        "다가구주택에서 선순위 임차인들의 임대차보증금 합계가 매각대금을 초과하여 "
        "후순위 임차인이 경매 배당절차에서 보증금을 배당받지 못한 사안, "
        "소액임차인 최우선변제, 매매가에 육박하는 전세보증금 깡통전세 갭투자"
    ),
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


#: 카드에서 읽기 보조를 붙일 본문 필드 — 앱이 쓰는 이름 그대로 쓴다(계약 §2.3).
#: `summary`는 이미 굵게 나가므로 강조 대상이 아니고, 용어 툴팁만 받는다.
_BODY_FIELDS = ("summary", "result", "commonPoint", "advice")
_EMPHASIS_FIELDS = ("result", "commonPoint", "advice")
#: 앱 필드 이름 → LLM이 emphasis를 고를 때 쓰는 키 이름.
#:
#: ⚠ `advice`가 여기 들어 있는 것은 **의도적**이며, "advice는 LLM 불가침"
#:   (decisions.md 2026-07-09) 원칙과 어긋나지 않는다. 그 원칙이 막는 것은 **문구 변경**인데,
#:   emphasis는 문구를 담지 않는다 — 본문의 부분 문자열이 아니면 `emphasis.validate`가
#:   폐기하므로 LLM은 advice를 **가리킬 수만 있고 고쳐 쓸 수는 없다**(구조적 보장).
#:   출력 모델(PrecedentExplanation)에도 여전히 `advice` 필드는 존재하지 않는다.
#: ⚠ 되돌리려면 이 표에서 `"advice"` 한 줄만 지우면 된다. 그러면 advice의 강조는
#:   결정적 폴백(금액·비율·기간)만 남고, 실측상 큐레이션 조언에는 숫자가 거의 없어
#:   **굵게가 사라진다** — 그 사실을 알고 지워야 한다.
_LLM_EMPHASIS_KEY = {"commonPoint": "common_point", "result": "result", "advice": "advice"}


def _attach_reading_aids(case: dict, exp) -> None:
    """완성된 카드에 **읽기 보조 두 가지**를 붙인다 — 용어 툴팁(D20)·강조 구간(D23).

    ⚠ **본문을 절대 바꾸지 않는다.** 두 필드 모두 "본문의 어디를 어떻게 그릴지"만
      가리킨다. 그래서 큐레이션 문구(`advice`)에도 안전하게 붙일 수 있다
      (문구 변경 금지 — decisions.md 2026-07-09).

    ⚠ **여기가 합류점이다.** LLM 성공 경로와 폴백 경로가 위에서 이미 하나로 합쳐진 뒤라,
      어느 경로로 왔든 화면에 나가는 최종 문장에 대해 **한 번만** 계산된다. 위쪽 분기마다
      따로 붙였다면 폴백 카드에만 툴팁이 빠지는 식으로 갈렸을 것이다.
    """
    # ① 용어 툴팁 — 최종 문장에 **실제로 등장한** 검수된 용어만 (terms.load 게이트가
    #    `verified=false`를 이미 걸러낸다). 키가 본문에 없으면 앱이 밑줄을 못 붙일 뿐이다.
    joined = "\n".join(str(case.get(f) or "") for f in _BODY_FIELDS)
    case["termGlossary"] = terms.attach(joined)

    # ② 강조 구간 — LLM이 고른 것이 검증을 통과하면 그것, 아니면 금액·비율·기간 폴백.
    llm_picks = getattr(exp, "emphasis", None) or {}
    picked: dict[str, list[str]] = {}
    for field in _EMPHASIS_FIELDS:
        text = str(case.get(field) or "")
        if not text:
            continue
        key = _LLM_EMPHASIS_KEY.get(field)
        raw = llm_picks.get(key) if key else None
        chosen = emphasis_picker.choose(text, raw if isinstance(raw, list) else None)
        if chosen:
            picked[field] = chosen
    case["emphasis"] = picked


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
        # 정렬 우선순위 (2026-08-12):
        #   ① 매칭 태그 수 — 판정과 많이 겹칠수록 위 (피드백 A6)
        #   ② 사람 문구 검수 여부 — **같은 관련도라면 검수된 판례를 먼저 보여준다**
        #   ③ 하이브리드 점수
        #
        # ②를 ①보다 위에 두지 않는 것이 중요하다. 검수됐다는 이유만으로 덜 맞는 판례가
        # 대표 카드가 되면, 판례를 붙이는 목적("이 매물과 닮은 사례") 자체가 무너진다.
        # 검수 여부는 **동점일 때의 기준**이지 관련성을 이기는 기준이 아니다.
        ranked = sorted(
            merged.values(),
            key=lambda m: (len(m.matched_tags), m.doc.verified, m.hybrid_score),
            reverse=True,
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
            case = (
                {
                    # [메타 — 검색된 문서에서 복사 (LLM 불개입)]
                    "riskPattern": (m.matched_tags or m.doc.risk_tags or ["기타"])[0],
                    "matchedTags": m.matched_tags,
                    "caseNo": f"{m.doc.court} {m.doc.case_no}".strip(),
                    "decided": m.doc.decided,
                    "sourceUrl": m.doc.source_url,
                    # [검수 상태 — 표시 전용] 출처는 공식 DB로 확인됐지만 문구를 사람이
                    #   아직 읽지 않은 판례가 섞여 있다. 숨기지 않고 화면에 밝힌다.
                    #   (2026-08-07 검증 2단계 분리 — models.PrecedentDoc 참고)
                    "curated": m.doc.verified,
                    # [설명 — LLM 생성 성공 시만, 실패·미호출은 결정적 폴백]
                    # [요약] 큐레이션이 있으면 **그것이 정본** — outcome·advice와 같은 원칙.
                    #   사람이 원문과 대조해 확정한 문구인데 LLM이 매번 새로 쓰면
                    #   화면에 나가는 문장이 검수한 문장과 달라져 검수 자체가 무의미해진다.
                    #   (검수 뒤 seed_cases.json에 summary_easy로 굳힌다)
                    "summary": (
                        m.doc.summary_easy
                        or (exp.easy_summary if exp else None)
                        or explainer.fallback_summary(m)
                    ),
                    "commonPoint": exp.common_point if exp else explainer.fallback_common_point(m),
                    # [결과 — 문구는 코드가 정한다. LLM은 분류만 골랐다]
                    #   ① 큐레이션 outcome이 있으면 그것이 정본
                    #   ② 없으면 LLM이 고른 분류를 고정 문구로 치환 (OUTCOME_TEXT)
                    #   ③ 분류도 없으면 낙관하지 않는 폴백 (OUTCOME_UNKNOWN)
                    # 자유 문장을 쓰게 두면 승소 판례가 "청구 가능"으로 나와
                    # 안심 신호로 읽힌다 — models.OutcomeKind docstring 참고.
                    "result": (
                        m.doc.outcome
                        or (
                            OUTCOME_TEXT.get(exp.outcome_kind)
                            if exp and exp.outcome_kind
                            else None
                        )
                        or OUTCOME_UNKNOWN
                    ),
                    "advice": m.doc.advice,
                }
            )
            _attach_reading_aids(case, exp)
            cases.append(case)
        return PrecedentSection(cases=cases, explanation_source=source)

    def match_for_verdict(self, verdict: RuleVerdict, *, explain: bool = False) -> PrecedentSection:
        return self._build_section(tags_from_verdict(verdict), verdict, explain=explain)

    def match_for_report(self, report: Report, *, explain: bool = False) -> PrecedentSection:
        return self._build_section(tags_from_report(report), None, explain=explain)


# ── 싱글턴 (2026-08-07 라우터 통합) ──────────────────────────────────────────
# 인덱스 적재(문서·청크·BM25 코퍼스)는 요청마다 할 일이 아니다. 프로세스 수명 동안
# 한 번만 만들고 재사용한다. 색인을 다시 만든 뒤에는 서버를 재시작해야 반영된다.
_service: "PrecedentService | None" = None


def get_service() -> PrecedentService:
    global _service
    if _service is None:
        _service = PrecedentService()
    return _service
