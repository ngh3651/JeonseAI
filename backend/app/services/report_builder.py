"""리포트 조립 오케스트레이터 — 추출 → 규칙 판정 → 설명 문구 → Report(계약 §2.1).

가드레일(단일 조립 지점): Report의 [판정] 필드(grade·statusLabel·detailText·
sourceText·deposit·marketPrice·seniorDebtAmount·gaugeProgress)는 **RuleVerdict에서만**
복사한다. 설명([설명]) 필드는 지금은 fallback_texts가 채우고, E-2에서 Solar Pro가
성공하면 그 결과로 교체된다 — 어느 쪽이든 판정 필드에는 손대지 못한다.
"""

from __future__ import annotations

import logging
import time
from datetime import datetime, timedelta, timezone

from ..schemas.contract import Evidence, Report
from ..schemas.internal import Grade, RegistryExtract, RuleVerdict
from . import extraction, fallback_texts, rule_engine, store
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
) -> Report:
    """추출 결과 + 입력값 → 계약 §2.1 Report. (저장은 하지 않음 — analyze()가 담당)"""
    verdict: RuleVerdict = rule_engine.evaluate(
        extract, deposit=deposit, market_price=market_price
    )
    texts = fallback_texts.build(verdict)  # E-2: explanation(LLM) 성공 시 이 값 대신 사용

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

    return Report(
        id=resolved_id,
        alias=resolved_alias,
        address=address,
        analyzedAt=now.isoformat(),
        grade=verdict.grade.value,  # [판정]
        gaugeProgress=verdict.gauge_progress,  # [메타 — 판정 파생 공식]
        headline=texts["headline"],  # [설명]
        nextAction=texts["next_action"],  # [설명]
        topRiskSummary=texts["top_risk_summary"],  # [설명]
        deposit=verdict.deposit,  # [판정]
        marketPrice=verdict.market_price,  # [판정]
        seniorDebtAmount=verdict.senior_debt_amount,  # [판정]
        evidences=evidences,
    )


def analyze(
    images: list[tuple[str, bytes]],
    *,
    deposit: int,
    market_price: int | None,
    alias: str | None,
) -> Report:
    """업로드 이미지 → 추출 → 판정 → 리포트 생성 → 이력 저장. (/api/analyze의 본체)"""
    t0 = time.perf_counter()
    extract = extraction.extract_registry(images)
    report = build_report(extract, deposit=deposit, market_price=market_price, alias=alias)
    store.add(report)
    _log.info(
        f"[분석 완료] 주소: {report.address} | 선순위채권 합계: {format_won(report.seniorDebtAmount)}"
        f" | 판정: {report.grade} (게이지 {report.gaugeProgress}) | 총 {time.perf_counter() - t0:.1f}초"
    )
    return report
