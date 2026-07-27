"""리포트 조립 오케스트레이터 — 추출 → 규칙 판정 → 설명 문구 → Report(계약 §2.1).

가드레일(단일 조립 지점): Report의 [판정] 필드(grade·statusLabel·detailText·
sourceText·deposit·marketPrice·seniorDebtAmount·gaugeProgress)는 **RuleVerdict에서만**
복사한다. 설명([설명]) 필드는 지금은 fallback_texts가 채우고, E-2에서 Solar Pro가
성공하면 그 결과로 교체된다 — 어느 쪽이든 판정 필드에는 손대지 못한다.
"""

from __future__ import annotations

import logging
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

from ..schemas.contract import Evidence, Highlight, Report
from ..schemas.internal import Grade, RegistryExtract, RuleVerdict
from . import explanation, extraction, fallback_texts, highlight, ocr, rule_engine, store
from .formatting import format_won, short_address

KST = timezone(timedelta(hours=9))
_log = logging.getLogger("jeonseai")

# 근거 카드 표시 순서: 심각한 것 먼저(결론 먼저 원칙), 같은 등급 안에서는 고정 순서
_CANONICAL_ORDER = ["jeonse_ratio", "senior_debt", "ownership", "insurance", "blacklist"]
_SEVERITY_ORDER = {Grade.DANGER: 0, Grade.CAUTION: 1, Grade.GOOD: 2}


def build_report(
    extract: RegistryExtract,
    *,
    deposit: int,
    market_price: int | None,
    alias: str | None,
    report_id: str | None = None,
    analyzed_at: datetime | None = None,
    use_llm: bool = True,
) -> Report:
    """추출 결과 + 입력값 → 계약 §2.1 Report. (저장은 하지 않음 — analyze()가 담당)"""
    report, _ = _build(
        extract,
        deposit=deposit,
        market_price=market_price,
        alias=alias,
        report_id=report_id,
        analyzed_at=analyzed_at,
        use_llm=use_llm,
    )
    return report


def _build(
    extract: RegistryExtract,
    *,
    deposit: int,
    market_price: int | None,
    alias: str | None,
    report_id: str | None = None,
    analyzed_at: datetime | None = None,
    use_llm: bool = True,
    highlights: list[Highlight] | None = None,
    highlight_notice: str | None = None,
    checked_notes: list[str] | None = None,
    registry_viewed_at: str | None = None,
) -> tuple[Report, str]:
    """조립 본체 — (Report, 설명 출처 라벨)을 돌려준다."""
    verdict: RuleVerdict = rule_engine.evaluate(
        extract, deposit=deposit, market_price=market_price
    )
    if use_llm:
        # LLM은 설명 문장만 — 실패 시 내부에서 폴백으로 완성돼 돌아온다(리포트 항상 완성)
        explanation_result = explanation.generate(verdict)
        texts, explain_source = explanation_result.texts, explanation_result.source
    else:
        texts, explain_source = fallback_texts.build(verdict), "폴백(강제)"

    now = analyzed_at or datetime.now(KST)
    resolved_id = report_id or f"analysis-{int(now.timestamp() * 1000)}"
    address = verdict.address or "주소 미확인 (등기부 원본 확인 필요)"
    # 별칭 폴백은 축약 주소('○○동'부터) — 홈 카드 제목이 전체 주소로 길어지지 않게.
    # Report.address는 전체 주소 유지(리포트 화면에서 확인) — 계약 §3.1 해석 범위 내.
    resolved_alias = alias.strip() if (alias and alias.strip()) else short_address(address)

    ordered = sorted(
        verdict.evidences,
        key=lambda e: (_SEVERITY_ORDER[e.grade], _CANONICAL_ORDER.index(e.id)),
    )
    evidences = []
    for ev in ordered:
        t = texts["evidences"][ev.id]
        evidences.append(
            Evidence(
                id=ev.id,
                title=t["title"],
                termSubtitle=t["term_subtitle"],
                grade=ev.grade.value,  # [판정] — RuleVerdict에서만
                statusLabel=ev.status_label,  # [판정]
                easyExplanation=t["easy_explanation"],  # [설명]
                detailText=ev.detail_text,  # [판정]
                sourceText=ev.source_text,  # [판정]
                actionLabel=t["action_label"],  # [UI]
                termGlossary=t["term_glossary"],  # [설명]
            )
        )

    report = Report(
        id=resolved_id,
        alias=resolved_alias,
        address=address,
        analyzedAt=now.isoformat(),
        grade=verdict.grade.value,  # [판정]
        gaugeProgress=verdict.gauge_progress,  # [메타 — 판정 파생 공식]
        headline=texts["headline"],  # [설명]
        nextAction=texts["next_action"],  # [설명 — 결정적 템플릿 유지 (decisions.md 2026-07-07)]
        topRiskSummary=texts["top_risk_summary"],  # [설명]
        deposit=verdict.deposit,  # [판정]
        marketPrice=verdict.market_price,  # [판정]
        seniorDebtAmount=verdict.senior_debt_amount,  # [판정]
        evidences=evidences,
        highlights=highlights or [],  # [표시 전용] — 판정에 영향 없음
        highlightNotice=highlight_notice,  # [표시 전용] 사진 묶음 안내 (없으면 None)
        checkedNotes=checked_notes or [],  # [표시 전용] 무엇을 찾아봤는지 요약
        registryViewedAt=registry_viewed_at,  # [표시 전용] 등기부 열람일시 (없으면 None)
    )
    return report, explain_source


def _timed(fn, *args):
    """(결과 또는 예외, 걸린 시간)을 돌려준다 — 병렬 소요시간 로그용."""
    t0 = time.perf_counter()
    try:
        return fn(*args), None, time.perf_counter() - t0
    except Exception as e:  # noqa: BLE001 — 호출부가 판단한다
        return None, e, time.perf_counter() - t0


def analyze(
    images: list[tuple[str, bytes]],
    *,
    deposit: int,
    market_price: int | None,
    alias: str | None,
) -> Report:
    """업로드 이미지 → (추출 ∥ OCR) → 판정 → 설명 생성 → 이력 저장. (/api/analyze의 본체)

    IE와 OCR을 **병렬로** 부른다. 순차로 하면 대기 시간이 그대로 더해진다
    (실측 IE 30초대 + OCR 장당 1.6~3.1초).

    ⚠ 판정 경로는 그대로다 — `extraction.extract_registry` → `rule_engine`.
      OCR은 좌표만 만들며, 실패해도 리포트는 지금과 똑같이 완성된다.
    """
    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=2, thread_name_prefix="analyze") as pool:
        ie_future = pool.submit(_timed, extraction.extract_registry, images)
        ocr_future = pool.submit(_timed, ocr.run_ocr, images)
        extract, ie_error, ie_elapsed = ie_future.result()
        ocr_result, ocr_error, ocr_elapsed = ocr_future.result()

    total = time.perf_counter() - t0
    _log.info(
        f"[병렬] IE {ie_elapsed:.1f}초 / OCR {ocr_elapsed:.1f}초 → 전체 {total:.1f}초"
        f" (순차였다면 {ie_elapsed + ocr_elapsed:.1f}초)"
    )
    if ie_error is not None:
        # IE 실패는 분석 실패다(지금과 동일). OCR이 성공했어도 판정할 수 없으므로 버린다.
        _log.info("[분석 중단] IE 실패 — OCR 결과가 있어도 판정 없이는 리포트를 만들 수 없음")
        raise ie_error
    if ocr_error is not None:  # run_ocr는 예외를 삼키지만, 만약을 대비한 최종 방어선
        _log.info(f"[OCR] 예기치 못한 예외 — 좌표 없이 계속 진행 ({type(ocr_error).__name__})")
        ocr_result = ocr.OcrResult()

    assert extract is not None  # ie_error가 없으면 반드시 값이 있다
    # [진단] IE 응답 실태 — 개수/참·거짓만 (이름·등록번호 금지). rank_number 채움 여부 확인용.
    _rank_filled = sum(
        1 for m in extract.mortgages if str(getattr(m, "rank_number", "") or "").strip()
    )
    _log.info(
        f"[IE] 현재소유자 {len(extract.current_owners)}명"
        f" | 근저당 {len(extract.mortgages)}건(rank_number 있는 것 {_rank_filled}건)"
        f" | 압류·가압류 {len(extract.seizures) + len(extract.provisional_seizures)}건"
        f" | 경매·신탁 {len(extract.auction_commencements) + len(extract.trust_registrations)}건"
    )
    try:
        highlight_result = highlight.build_highlights(extract, ocr_result)
    except Exception as e:  # noqa: BLE001 — 표시 기능이 분석을 깨뜨리면 안 된다
        _log.info(f"[매칭] 실패 — 좌표 없이 리포트 완성 ({type(e).__name__}: {e})")
        highlight_result = highlight.HighlightResult([])

    report, explain_source = _build(
        extract,
        deposit=deposit,
        market_price=market_price,
        alias=alias,
        use_llm=True,
        highlights=highlight_result.highlights,
        highlight_notice=highlight_result.notice,
        checked_notes=highlight_result.checked_notes,
        registry_viewed_at=highlight_result.viewed_at,
    )
    store.add(report)
    _log.info(
        f"[분석 완료] 주소: {report.address} | 선순위채권 합계: {format_won(report.seniorDebtAmount)}"
        f" | 판정: {report.grade} (게이지 {report.gaugeProgress}) | 설명: {explain_source}"
        f" | 하이라이트: {len(report.highlights)}건 | 총 {time.perf_counter() - t0:.1f}초"
    )
    return report
