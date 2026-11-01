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
from .. import fact_ledger, patterns as _patterns, terms, thresholds as T
from ..debt_order import label as _debt_label
from ..formatting import format_won
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
TOP_K_PER_TAG = 2   # 태그(위험 유형)당 최대 후보 — AI가 고르지 않을 때(키 없음·실패)
MAX_CASES = 4       # 판례 섹션 최대 카드 수
# AI가 고를 때(2026-10-24): 후보를 넉넉히 가져와 Solar가 이 집과 가장 닮은 4건을 고른다.
#   검색어는 여전히 미리 써 둔 문장(LLM은 질의를 만들지 않는다) — AI는 **검색된 후보 중에서만** 고른다.
TOP_K_PER_TAG_FOR_PICK = 3
MAX_CANDIDATES = 10

FALLBACK_NO_MATCH = (
    "이 매물의 위험 신호와 연결되는 판례를 아직 찾지 못했어요. "
    "판례가 없다는 뜻이 위험이 없다는 뜻은 아니에요 — 리포트의 확인 항목을 직접 점검해 주세요"
)
FALLBACK_NO_RISK = (
    "지금 리포트에서 판례와 연결할 위험 신호가 발견되지 않았어요. "
    "다만 등기부등본은 계약 직전에 최신본으로 한 번 더 확인하는 것이 좋아요"
)


# 태그 파생은 `patterns.py`로 옮겼다(2026-10-29) — 리포트 조립이 판례 검색 모듈을 불러오지 않고도
# 태그를 리포트에 저장하게. 이 이름은 기존 호출부·테스트를 위해 그대로 남긴다.
tags_from_verdict = _patterns.tags_from_verdict
tags_from_report = _patterns.tags_from_report


def _korean_date(raw: str) -> str:
    """'2021-08-26' → '2021년 8월 26일' — AI가 받은 모양 그대로 옮겨 써서, 컴퓨터식 날짜가 카드에 나갔다(2026-10-24 실기기)."""
    import re as _re

    m = _re.fullmatch(r"\s*(\d{4})[-./](\d{1,2})[-./](\d{1,2})\.?\s*", raw or "")
    if not m:
        return raw
    return f"{int(m.group(1))}년 {int(m.group(2))}월 {int(m.group(3))}일"


def _report_summary(report: Report, tags: list[str], ledger: "fact_ledger.Ledger | None" = None) -> dict:
    """저장된 리포트 → LLM 맞춤 설명 재료 (2026-10-23 — '이 매물'과 얼마나 닮았나를 쓰게).

    판정에서 나온 값만 싣는다: 종합 등급·보증금·시세·먼저 갚을 빚·위험 항목별 상세.
    ⚠ **주소·별칭·이름은 싣지 않는다** — 저장된 리포트는 이미 가린 사본이지만, 맞춤 설명에 필요 없는 정보는 아예 안 보낸다.
    """
    summary: dict = {
        "위험_태그": tags,
        "종합등급": report.grade,
        "보증금_원": report.deposit,
        "먼저_갚을_빚_원": report.seniorDebtAmount,
    }
    if report.marketPrice:
        summary["시세_원"] = report.marketPrice
    items = []
    for ev in report.evidences:
        if ev.grade == "양호":
            continue
        item = {"항목": ev.title, "등급": ev.grade}
        if ev.detailText:
            item["상세"] = ev.detailText
        items.append(item)
    if items:
        summary["위험_항목"] = items
    # 살아 있는 등기 항목(가압류·근저당 등)의 종류·접수일·금액 — 공통점이 '이 집의 숫자'를 짚게 (이름 없음)
    facts = []
    senior_lines: list[str] = []
    for f in getattr(report, "riskFacts", []) or []:
        fact = {"종류": f.kind}
        if getattr(f, "order", None):
            fact["받는_순서"] = f"{f.order}순위"  # 2026-11-01 — 살아 있는 빚끼리의 순서(등기부 칸 번호 아님)
        if f.receiptDate:
            fact["접수일"] = _korean_date(f.receiptDate)
        if f.amount is not None:
            fact["금액_원"] = f.amount
            fact["금액_표기"] = format_won(f.amount)
        if f.holder:
            fact["권리자"] = f.holder
        facts.append(fact)
        if f.kind in ("근저당", "전세권") and f.amount:
            senior_lines.append(
                f"{_debt_label(f.kind, getattr(f, 'order', None))} {format_won(f.amount)}"
                + (f" ({_korean_date(f.receiptDate)})" if f.receiptDate else "")
            )
    if facts:
        summary["등기_항목"] = facts
    # 이 집 숫자표(2026-11-01) — 같은 숫자를 같은 이름으로 부르게(공통점이 '선순위 3억 6,000만원'처럼 한 건만 말하지 않게)
    if ledger is not None:
        if senior_lines and all("순위" in x for x in senior_lines):
            senior_lines.sort()
        summary["이_집_숫자표"] = fact_ledger.sheet(ledger, senior_lines)
    summary["보증금_표기"] = format_won(report.deposit)
    if report.seniorDebtAmount:
        summary["먼저_갚을_빚_표기"] = format_won(report.seniorDebtAmount)
    if report.marketPrice:
        summary["시세_표기"] = format_won(report.marketPrice)
    return summary


def _verdict_summary(
    verdict: RuleVerdict | None, tags: list[str], ledger: "fact_ledger.Ledger | None" = None
) -> dict:
    """LLM 공통점 서술용 판정 요약 — 판정에서 파생한 값만 (원본 추출·이미지 없음)."""
    summary: dict = {"위험_태그": tags}
    if verdict is not None:
        summary["종합등급"] = verdict.grade.value
        for ev in verdict.evidences:
            if ev.grade != Grade.GOOD and ev.detail_text:
                summary.setdefault("근거_상세", []).append({"id": ev.id, "상세": ev.detail_text})
    if ledger is not None:
        from ..explanation import senior_lines

        summary["이_집_숫자표"] = fact_ledger.sheet(ledger, senior_lines(verdict) if verdict is not None else None)
    return summary


#: 카드에서 읽기 보조를 붙일 본문 필드 — 앱이 쓰는 이름 그대로 쓴다(계약 §2.3).
#: `summary`는 이미 굵게 나가므로 강조 대상이 아니고, 용어 툴팁만 받는다.
_BODY_FIELDS = ("summary", "result", "commonPoint", "advice")
_EMPHASIS_FIELDS = ("summary", "result", "commonPoint", "advice")
#: 앱 필드 이름 → LLM이 emphasis를 고를 때 쓰는 키 이름.
#:
#: 2026-10-23부터 조언(advice)도 Solar가 이 매물에 맞춰 쓴다(decisions.md). 강조는 여전히 **최종 문장의
#:   부분 문자열**이어야 붙는다 — Solar 조언이 검사에서 떨어져 큐레이션 조언이 나가면, Solar가 고른 강조도
#:   그 문장에 없으니 버려지고 결정적 폴백(금액·비율·기간)으로 내려간다.
_LLM_EMPHASIS_KEY = {
    "summary": "easy_summary",
    "commonPoint": "common_point",
    "result": "result",
    "advice": "advice",
}


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

    def search_by_tags(
        self, tags: list[str], *, top_k: int = TOP_K_PER_TAG, limit: int = MAX_CASES
    ) -> list[RetrievedPrecedent]:
        """태그별 분기 검색 → 병합 → 정렬 (매칭 태그 수 우선 — 피드백 A6)."""
        merged: dict[str, RetrievedPrecedent] = {}
        for tag in tags:
            query = QUERY_TEMPLATES.get(tag)
            if not query:
                continue
            for m in self._retriever.search(query, risk_tags=[tag], top_k=top_k):
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
        return ranked[:limit]

    def _build_section(
        self,
        tags: list[str],
        verdict: RuleVerdict | None,
        *,
        explain: bool,
        summary: dict | None = None,
        ledger: "fact_ledger.Ledger | None" = None,
    ) -> PrecedentSection:
        if not tags:
            return PrecedentSection(cases=[], fallback_text=FALLBACK_NO_RISK)
        if explain:
            # AI가 고른다: 후보를 넉넉히 → Solar가 이 집과 닮은 순서로 최대 4건(+설명). 실패하면 점수 순 4건.
            candidates = self.search_by_tags(
                tags, top_k=TOP_K_PER_TAG_FOR_PICK, limit=MAX_CANDIDATES
            )
        else:
            candidates = self.search_by_tags(tags)
        if not candidates:
            return PrecedentSection(cases=[], fallback_text=FALLBACK_NO_MATCH)

        explanations: dict = {}
        source = "자동 생성"  # LLM 미호출·폴백은 "자동 생성" (라벨 정직성 — decisions.md 2026-07-09)
        if explain:
            explanations, llm_source = explainer.explain_matches(
                candidates,
                summary if summary is not None else _verdict_summary(verdict, tags, ledger),
                ledger,
            )
            if llm_source != "폴백":
                source = llm_source
        if explanations:
            by_id = {m.doc.case_id: m for m in candidates}
            matches = [by_id[cid] for cid in explanations if cid in by_id][:MAX_CASES]
        else:
            # AI 설명이 하나도 없으면: **사람이 쉬운 말 요약을 써 둔 판례를 앞에** — 원문 요지(법률 문장)가
            # 그대로 나가는 카드를 줄인다(2026-10-24 실기기). 순서는 그다음 점수 순 그대로.
            matches = sorted(candidates, key=lambda m: 0 if m.doc.summary_easy else 1)[:MAX_CASES]

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
                    # [요약·공통점·조언 = Solar 먼저] 2026-10-23 규혁 결정(decisions.md):
                    #   판례는 "우리 집과 얼마나 닮았나"가 궁금해서 보는 것이라 이 매물에 맞춰 Solar가 쓴다.
                    #   사람이 쓴 요약·조언은 Solar에게 **재료**로 주고, Solar가 실패·검사 탈락하면 그대로 나간다.
                    "summary": (
                        (exp.easy_summary if exp else None)
                        or m.doc.summary_easy
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
                    "advice": (exp.advice if exp else None) or m.doc.advice,
                }
            )
            _attach_reading_aids(case, exp)
            cases.append(case)
        return PrecedentSection(cases=cases, explanation_source=source)

    def match_for_verdict(self, verdict: RuleVerdict, *, explain: bool = False) -> PrecedentSection:
        ledger = _ledger_for_verdict(verdict) if explain else None
        return self._build_section(tags_from_verdict(verdict), verdict, explain=explain, ledger=ledger)

    def match_for_report(self, report: Report, *, explain: bool = False) -> PrecedentSection:
        tags = tags_from_report(report)
        ledger = _ledger_for_report(report) if explain else None
        return self._build_section(
            tags, None, explain=explain, summary=_report_summary(report, tags, ledger), ledger=ledger
        )


def _ledger_for_report(report: Report) -> "fact_ledger.Ledger | None":
    """저장된 리포트 → 이 집 숫자 장부(손실 계산 포함 — 리포트 2장·시뮬레이터와 같은 함수). 실패하면 None(검사만 빠진다)."""
    try:
        from ..loss_estimate import estimate

        return fact_ledger.for_report(report, estimate(report))
    except Exception:  # noqa: BLE001 — 장부 하나 때문에 판례를 잃지 않는다
        return None


def _ledger_for_verdict(verdict: RuleVerdict) -> "fact_ledger.Ledger | None":
    try:
        return fact_ledger.for_verdict(verdict)
    except Exception:  # noqa: BLE001
        return None


# ── 싱글턴 (2026-08-07 라우터 통합) ──────────────────────────────────────────
# 인덱스 적재(문서·청크·BM25 코퍼스)는 요청마다 할 일이 아니다. 프로세스 수명 동안
# 한 번만 만들고 재사용한다. 색인을 다시 만든 뒤에는 서버를 재시작해야 반영된다.
_service: "PrecedentService | None" = None


def get_service() -> PrecedentService:
    global _service
    if _service is None:
        _service = PrecedentService()
    return _service
