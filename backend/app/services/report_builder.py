"""리포트 조립 오케스트레이터 — 추출 → 규칙 판정 → 설명 문구 → Report(계약 §2.1).

가드레일(단일 조립 지점): Report의 [판정] 필드(grade·statusLabel·detailText·
sourceText·deposit·marketPrice·seniorDebtAmount·gaugeProgress)는 **RuleVerdict에서만**
복사한다. 설명([설명]) 필드는 지금은 fallback_texts가 채우고, E-2에서 Solar Pro가
성공하면 그 결과로 교체된다 — 어느 쪽이든 판정 필드에는 손대지 못한다.
"""

from __future__ import annotations

import logging
import os
import threading
import time
import unicodedata
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import wait as wait_futures
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from ..schemas.contract import CaptureCheck, Evidence, Highlight, MarketPriceAlternative, Report
from ..schemas.internal import EvidenceVerdict, Grade, PriceProvenance, RegistryExtract, RuleVerdict
from . import (
    amount_recovery,
    artifacts,
    cancellation,
    capture_check,
    compare,
    cross_check,
    document_gate,
    document_parse,
    explanation,
    extraction,
    fallback_texts,
    highlight,
    lawd_code,
    llm,
    loss_estimate,
    name_privacy,
    ocr,
    ocr_layout,
    price_lookup,
    price_resolver,
    privacy_masks,
    registry_facts,
    rule_engine,
    store,
    terms,
)
from . import evidence_view, mark_plans, text_guard
from .formatting import format_won, short_address
from .patterns import tags_from_verdict as issue_tags_from_verdict

KST = timezone(timedelta(hours=9))
_log = logging.getLogger("jeonseai")

# 근거 카드 표시 순서: 심각한 것 먼저(결론 먼저 원칙), 같은 등급 안에서는 고정 순서
#: 앱이 분석을 중단했는지(연결을 끊었는지) IE·OCR을 기다리는 동안 몇 초마다 볼지 (2026-10-29)
CANCEL_POLL_SECONDS = 0.5


class AnalysisCancelled(Exception):
    """앱이 분석을 중단했다(연결을 끊음, 2026-10-29). 아직 시작 안 한 비싼 단계를 건너뛰었고 **아무것도 저장하지 않았다.**

    이미 시작한 Upstage 호출(IE 한 번·그 장의 OCR)은 멈출 수 없다 — 그 크레딧은 쓰인다.
    """


def _raise_if_cancelled(cancelled: "Callable[[], bool] | None", where: str) -> None:
    if cancelled is not None and cancelled():
        _log.info(f"[분석 중단] 앱이 연결을 끊음 — {where}부터 건너뜀(저장 안 함)")
        raise AnalysisCancelled(where)


# pending(신청사건 처리중, 2026-10-31)은 같은 등급 안에서 맨 앞 — "돈을 보내지 마세요"가 가장 먼저 읽혀야 한다
_CANONICAL_ORDER = ["pending", "jeonse_ratio", "senior_debt", "ownership", "insurance", "blacklist"]
_SEVERITY_ORDER = {Grade.DANGER: 0, Grade.CAUTION: 1, Grade.GOOD: 2}


def _price_provenance(price_info) -> PriceProvenance:
    """`price_resolver.ResolvedPrice` → 설명용 시세 출처 (2026-08-05).

    채택된 후보의 `detail`(매칭 방법·배수 등 산정 근거)까지 옮긴다 — "어떻게 구한 값인가"를
    LLM이 한 줄로 밝힐 수 있어야 하기 때문이다(출처 공개 원칙).
    """
    picked = next(
        (
            c
            for c in price_info.candidates
            if c.source == price_info.source and c.price_won == price_info.price_won
        ),
        None,
    )
    return PriceProvenance(
        source=price_info.source,
        source_name=picked.source_name if picked else None,
        as_of=price_info.as_of or None,
        sample_count=price_info.sample_count,
        gap_pct=price_info.gap_pct,
        detail=(picked.detail or None) if picked else None,
        alternatives=[
            {
                "source": c.source,
                "source_name": c.source_name,
                "price": c.price_won,
                "as_of": c.as_of or None,
            }
            for c in price_info.alternatives
        ],
    )


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
    price_info: "price_resolver.ResolvedPrice | None" = None,
    blacklist_override: "EvidenceVerdict | None" = None,
) -> tuple[Report, "explanation.ExplanationResult"]:
    """조립 본체 — (Report, 설명 생성 결과)를 돌려준다.

    두 번째 값은 **로그·보고용**이다. 설명을 어느 provider·모델이 몇 초 만에 썼고
    폴백이 섞였는지가 [분석 완료] 요약에 그대로 실린다(2026-08-14 D9).

    `price_info`가 오면 **그것이 시세의 정본**이다 — `market_price` 인자를 덮어쓴다.
    (자동조회 결과와 판정에 들어간 값이 어긋나는 경로를 원천 차단한다.)
    """
    if price_info is not None:
        market_price = price_info.price_won
    verdict: RuleVerdict = rule_engine.evaluate(
        extract, deposit=deposit, market_price=market_price, blacklist_override=blacklist_override
    )
    # 시세 **출처**를 설명 계층에 넘긴다 (2026-08-05).
    # ⚠ 규칙 엔진이 판정을 끝낸 **뒤에** 붙인다 — 판정이 이 값을 볼 수 없게 하려는 것이다.
    #   출처가 무엇이든 등급은 같아야 하고, 실제로 rule_engine은 이 필드를 읽지 않는다.
    if price_info is not None:
        verdict.price_provenance = _price_provenance(price_info)
    # 등기부 자체의 사실도 같은 자리에서 붙인다 (2026-08-05 2차) — 판정 뒤, 설명 앞.
    verdict.registry_viewed_at = registry_viewed_at
    verdict.checked_notes = list(checked_notes or [])
    # 리포트 id를 **설명 생성보다 먼저** 확정한다 — 그림자 로그가 어느 분석인지
    # 가리키려면 id가 필요하다(계산은 now/report_id에만 의존하므로 순서를 옮겨도 안전).
    now = analyzed_at or datetime.now(KST)
    resolved_id = report_id or f"analysis-{int(now.timestamp() * 1000)}"
    if use_llm:
        # LLM은 설명 문장만 — 실패 시 내부에서 폴백으로 완성돼 돌아온다(리포트 항상 완성)
        explanation_result = explanation.generate(verdict, report_id=resolved_id)
    else:
        _forced = fallback_texts.build(verdict)
        explanation_result = explanation.ExplanationResult(
            texts=_forced,
            source="폴백(강제)",
            # LLM을 아예 부르지 않은 경로다 — 모든 카드가 준비된 문구다(D26).
            evidence_sources={
                eid: explanation.FALLBACK_SOURCE_LABEL for eid in _forced["evidences"]
            },
        )
    texts = explanation_result.texts

    # 용어 툴팁 자동 부착 (2026-08-05) — **최종 문장**을 훑는다.
    # LLM 문장이든 폴백 문장이든 여기를 지나므로, '용어가 본문에 등장해야 한다'는
    # 계약 §2.2 전제가 어느 경로에서도 깨지지 않는다.
    for _body in texts["evidences"].values():
        _body["term_glossary"] = terms.attach(_body.get("easy_explanation") or "")

    address = verdict.address or "주소 미확인 (등기부 원본 확인 필요)"
    # 별칭 폴백은 축약 주소('○○동'부터) — 홈 카드 제목이 전체 주소로 길어지지 않게.
    # Report.address는 전체 주소 유지(리포트 화면에서 확인) — 계약 §3.1 해석 범위 내.
    resolved_alias = alias.strip() if (alias and alias.strip()) else short_address(address)

    ordered = sorted(
        verdict.evidences,
        key=lambda e: (_SEVERITY_ORDER[e.grade], _CANONICAL_ORDER.index(e.id)),
    )
    risk_facts = registry_facts.build(extract)
    evidences = []
    for ev in ordered:
        t = texts["evidences"][ev.id]
        view = evidence_view.build(ev, verdict, risk_facts)  # [UI — 규칙 값만] 펼침의 숫자 줄·막대·할 일
        evidences.append(
            Evidence(
                id=ev.id,
                title=t["title"],
                termSubtitle=t["term_subtitle"],
                grade=ev.grade.value,  # [판정] — RuleVerdict에서만
                statusLabel=ev.status_label,  # [판정]
                easyExplanation=text_guard.soften_dashes(t["easy_explanation"]),  # [설명] 줄표 없이(2026-10-31)
                detailText=ev.detail_text,  # [판정]
                sourceText=ev.source_text,  # [판정]
                actionLabel=t["action_label"],  # [UI]
                termGlossary=t["term_glossary"],  # [설명]
                # [설명 출처 · D26] 이 카드의 문장을 모델이 썼는지 준비된 문구인지.
                # 카드마다 다를 수 있다(설명 폴백은 필드 단위다 — explanation.py 참고).
                explanationSource=explanation_result.evidence_sources.get(ev.id),
                points=view["points"],
                meter=view["meter"],
                todo=view["todo"],
            )
        )

    report = Report(
        id=resolved_id,
        alias=resolved_alias,
        address=address,
        analyzedAt=now.isoformat(),
        grade=verdict.grade.value,  # [판정]
        gaugeProgress=verdict.gauge_progress,  # [메타 — 판정 파생 공식]
        headline=text_guard.soften_dashes(texts["headline"]),  # [설명]
        nextAction=texts["next_action"],  # [설명 — 결정적 템플릿 유지 (decisions.md 2026-07-07)]
        topRiskSummary=texts["top_risk_summary"],  # [설명]
        deposit=verdict.deposit,  # [판정]
        marketPrice=verdict.market_price,  # [판정]
        # [출처 — 표시 전용] 판정에 쓰인 값이 어디서 왔는지. 판정에는 영향이 없다.
        marketPriceSource=price_info.source if price_info else None,
        marketPriceAsOf=(price_info.as_of or None) if price_info else None,
        marketPriceSampleCount=price_info.sample_count if price_info else None,
        marketPriceGapPct=price_info.gap_pct if price_info else None,
        marketPriceAlternatives=(
            [
                MarketPriceAlternative(
                    source=c.source,
                    sourceName=c.source_name,
                    price=c.price_won,
                    asOf=c.as_of or None,
                    sampleCount=c.sample_count,
                    detail=c.detail or None,
                )
                for c in price_info.alternatives
            ]
            if price_info
            else []
        ),
        seniorDebtAmount=verdict.senior_debt_amount,  # [판정]
        evidences=evidences,
        highlights=highlights or [],  # [표시 전용] — 판정에 영향 없음
        highlightNotice=highlight_notice,  # [표시 전용] 사진 묶음 안내 (없으면 None)
        checkedNotes=checked_notes or [],  # [표시 전용] 무엇을 찾아봤는지 요약
        registryViewedAt=registry_viewed_at,  # [표시 전용] 등기부 열람일시 (없으면 None)
        riskFacts=risk_facts,  # [판례 설명 재료] 판정·화면에 쓰지 않음, 이름 없음
        ownerFacts=registry_facts.owner_facts(extract),  # [4장 질문 재료] 판정·화면에 쓰지 않음, 이름 없음
        riskTags=issue_tags_from_verdict(verdict),  # [판례·질문 재료] 이 집에 실제로 걸린 문제 — 판정에 쓰지 않음
    )
    return report, explanation_result


def _timed(fn, *args, **kwargs):
    """(결과 또는 예외, 걸린 시간)을 돌려준다 — 병렬 소요시간 로그용."""
    t0 = time.perf_counter()
    try:
        return fn(*args, **kwargs), None, time.perf_counter() - t0
    except Exception as e:  # noqa: BLE001 — 호출부가 판단한다
        return None, e, time.perf_counter() - t0


@dataclass
class OcrPath:
    """OCR 경로(②③)가 한 스레드에서 만들어 오는 것 전부.

    예전에는 5-튜플이었다. 2026-08-14에 **단계별 소요 시간**을 [분석 완료] 요약에
    찍게 되면서 자리가 둘 더 늘어, 순서로 기억해야 하는 7-튜플이 되느니 이름을 붙였다.
    ⚠ 여기 담기는 것 중 판정에 들어가는 것은 **하나도 없다** — 좌표·교차검증·로그용이다.
    """

    ocr: "ocr.OcrResult"
    second_extract: RegistryExtract | None = None
    second_provider: str | None = None  # 2차 구조화를 맡은 provider 이름
    second_model: str | None = None  # 그 provider가 실제로 부른 모델명
    error: str | None = None  # 2차 경로가 없거나 실패한 사유 (사람이 읽는 한 줄)
    doc_check: "ocr_layout.DocumentCheck | None" = None
    ocr_elapsed: float = 0.0  # ② Document OCR에만 쓴 초
    structure_elapsed: float = 0.0  # ③ 2차 구조화에만 쓴 초


def _ocr_then_second_opinion(
    images: list[tuple[str, bytes]],
    run_id: str | None = None,
    stop: threading.Event | None = None,
) -> OcrPath:
    """OCR → (성공하면) **두 번째 추출 경로**까지 한 스레드에서 이어 돌린다.

    왜 이어 붙이나: 두 번째 경로의 입력이 OCR 결과라 진짜 병렬이 될 수 없다. 대신
    OCR(장당 1.6~3.1초)이 IE(실측 17~26초)보다 훨씬 빨리 끝나므로, 그 뒤에 이어 붙이면
    **IE의 그림자 안에서** 끝나 전체 시간이 거의 늘지 않는다.

    ⚠ **사진 묶음 점검을 여기서 먼저 한다.** 순서가 뒤섞인 사진을 그대로 LLM에 먹이면
      LLM만 뒤섞인 문서를 읽게 되고, 그 결과가 "빚은 문서 판독 3건 / 사진 판독 1건" 같은
      **무서운 교차검증 불일치**로 사용자에게 나간다 — 원인은 등기부가 아니라 우리
      파이프라인이다(2026-07-28 gap-checker 지적). 점검 결과는 `build_highlights`에
      그대로 넘겨 **같은 순서·중복 계산 없이** 쓴다.

    반환: [OcrPath] — 어떤 실패도 밖으로 던지지 않는다.
    이 경로가 통째로 없어도 리포트는 그대로 완성된다.

    `stop`: 앱이 분석을 중단하면 켜진다(2026-10-29) — 아직 안 부른 장의 OCR과 구조화(Solar)를 건너뛴다.
    """
    t_ocr = time.perf_counter()
    ocr_result = ocr.run_ocr(images, run_id=run_id, stop=stop)
    ocr_elapsed = time.perf_counter() - t_ocr
    if not ocr_result.pages:
        return OcrPath(ocr=ocr_result, error="OCR 결과 없음", ocr_elapsed=ocr_elapsed)

    check = ocr_layout.check_document(ocr_result.pages)
    if stop is not None and stop.is_set():  # 결과는 어차피 버린다 — 구조화(Solar) 크레딧을 아낀다
        _log.info("[분석 중단] 앱이 연결을 끊음 — 두 번째 경로(구조화)를 부르지 않음")
        return OcrPath(ocr=ocr_result, error="분석 중단", doc_check=check, ocr_elapsed=ocr_elapsed)
    provider = llm.structure_provider()
    if provider is None:
        return OcrPath(
            ocr=ocr_result,
            error="두 번째 경로 꺼짐 또는 키 없음",
            doc_check=check,
            ocr_elapsed=ocr_elapsed,
        )

    t_structure = time.perf_counter()
    try:
        # 정렬이 확정됐으면 **그 순서로** 텍스트를 만든다 (업로드 순서가 아니라).
        ordered, _, _ = highlight._apply_page_order(ocr_result.pages, check.page_order)
        # 돌려 세운 장은 바로 선 사진으로(DP 경로가 쓴다) — 2026-10-26
        layout_text = _layout_text_for(ocr_result.upright_images or images, ordered, run_id)
        second = provider.structure(layout_text, timeout=llm.STRUCTURE_TIMEOUT_SECONDS)
        return OcrPath(
            ocr=ocr_result,
            second_extract=second,
            second_provider=provider.name,
            second_model=provider.model,
            doc_check=check,
            ocr_elapsed=ocr_elapsed,
            structure_elapsed=time.perf_counter() - t_structure,
        )
    except Exception as e:  # noqa: BLE001 — 두 번째 경로는 어떤 이유로도 분석을 막지 못한다
        # 오류 문장은 남기지 않는다 — 등기부 글자(실명)가 섞일 수 있다(2026-10-30 보안). 종류만.
        _log.info(f"[LLM:{provider.name}] 구조화 실패 — 교차검증 없이 진행 ({type(e).__name__})")
        return OcrPath(
            ocr=ocr_result,
            second_provider=provider.name,
            second_model=provider.model,
            error=f"{type(e).__name__}",
            doc_check=check,
            ocr_elapsed=ocr_elapsed,
            structure_elapsed=time.perf_counter() - t_structure,
        )


def _layout_text_for(
    images: list[tuple[str, bytes]], pages: list, run_id: str | None
) -> str:
    """구조화 경로(경로 ③)에 넘길 **텍스트**를 만든다. `.env`의 `LAYOUT_SOURCE`가 고른다.

    | 값 | 무엇 | 비고 |
    |---|---|---|
    | `ocr_layout` (기본) | Document OCR 낱말 → 우리가 조립한 줄·칸 | 지금까지의 경로 |
    | `document_parse` | Upstage Document Parse의 표 HTML | 표 조립을 제품에 맡긴다 |

    ⚠ **좌표는 어느 쪽을 골라도 `ocr_layout`에서 온다.** DP는 낱말 좌표를 주지 않고
      표 하나당 사각형 하나만 주므로(실측: 페이지의 20~61%), 이름 하이라이트를
      만들 수 없다. 이 스위치가 바꾸는 것은 **LLM에 넘길 글자**뿐이다.
      근거: `docs/document-parse-probe-2026-07-28.md`

    DP 호출이 실패하면 **조용히 `ocr_layout` 텍스트로 되돌아간다.**
    """
    source = (os.environ.get("LAYOUT_SOURCE", "") or "ocr_layout").strip().lower()
    if source != "document_parse":
        return llm.render_layout_text(pages)

    parsed = document_parse.run_document_parse(images, run_id=run_id)
    # ⚠ **전 장이 성공했을 때만 쓴다.** 한 장이라도 빠지면 반쪽 문서를 LLM에 먹이는 셈이라
    #   항목 개수가 모자라고, 그 부족분이 "교차검증 불일치"로 둔갑해 사용자에게는
    #   등기부 문제로 읽힌다(2026-07-28 gap-checker 지적).
    if not parsed.ok or len(parsed.pages) != len(images):
        _log.info(
            f"[DP] {len(parsed.pages)}/{len(images)}장만 성공 → ocr_layout 텍스트로 되돌아감"
            f" (실패 {len(parsed.errors)}건) — 분석은 그대로 진행"
        )
        return llm.render_layout_text(pages)
    text = document_parse.render_parsed_text(parsed.pages)
    _log.info(
        f"[DP] 레이아웃 출처 = document_parse ({parsed.elapsed:.1f}초, {len(text):,}자)"
        f" — 좌표는 여전히 Document OCR에서 옵니다"
    )
    return text


# ══════════════════════════════════════════════════════════════════════════════
# 보증금·시세·별칭 고치기 (2026-10-29 QA) — 사진을 다시 읽지 않고 판정만 다시
# ══════════════════════════════════════════════════════════════════════════════

#: 고쳐도 그대로 두는 것 — 사진·등기부에서 나온 표시 정보(보증금·시세와 무관)
_KEEP_ON_REJUDGE = (
    "address", "analyzedAt", "highlights", "highlightNotice", "checkedNotes", "registryViewedAt",
    "privacyMasks", "privacyMasksReady", "captureCheck", "personNames", "pageOrder", "pageRotations",
    "propertyId", "propertyAddress", "missingPages", "pageNumbers", "houseTypes", "comparable",
    "changeFromPrevious",
)


def _add_house_type_to_address_mark(report: Report) -> None:
    """주소 표시에 '이 집을 어느 지역·용도로 계산했나'를 붙인다 (2026-10-31 — 이 집 맞춤 할 일). 표시 전용."""
    try:
        uses = [u for u in report.houseTypes if u]
        if not uses:
            return
        region = loss_estimate.sido_of(report.propertyAddress) or loss_estimate.sido_of(report.address)
        fact, plan = mark_plans.house_type_line(region, uses[0], len(uses) > 1)
        for h in report.highlights:
            if h.kind == "address":
                if fact:
                    h.facts = [*h.facts, fact]
                if plan:
                    h.plan = [plan, *h.plan]
    except Exception:  # noqa: BLE001 — 표시 한 줄 때문에 리포트를 잃지 않는다
        _log.error("[매칭] ⚠ 주소 표시에 용도를 붙이지 못했습니다", exc_info=True)


def has_pending_application(highlights: list[Highlight] | None) -> bool:
    """사진 위 표시에 '신청사건 처리중'이 있나 — 판정에 넣는 단 하나의 기준(2026-10-31)."""
    return any(h.kind == "pending_application" for h in (highlights or []))


def rejudge_kit(extract: RegistryExtract, report: Report) -> dict:
    """다시 판정 재료 — IE가 읽은 등기부(사람 이름은 가린 사본) + 실명이 필요했던 명단 대조 결과."""
    names = name_privacy.person_names(extract) or list(report.personNames)
    masked = name_privacy._mask_value(extract.model_dump(mode="json"), names)
    blacklist = next((e for e in report.evidences if e.id == "blacklist"), None)
    kit: dict = {"version": 1, "extract": masked}
    if blacklist is not None:
        kit["blacklist"] = {
            "id": "blacklist",
            "grade": blacklist.grade,
            "status_label": blacklist.statusLabel,
            "detail_text": blacklist.detailText,
            "source_text": blacklist.sourceText,
            "action_label": None,
            # 명단 대조 사실(일치 이름은 원래 가린 꼴) — 설명 재료
            "facts": {"matched": [], "list_size": None, "from_original_analysis": True},
        }
    return kit


def rejudge(
    old: Report,
    kit: dict,
    *,
    deposit: int,
    market_price: int | None,
    alias: str | None,
) -> Report:
    """같은 등기부를 새 보증금·시세로 **다시 판정**한다 — 같은 리포트 id, IE·OCR 호출 없음(설명 문장만 AI).

    판정은 규칙 엔진이 새로 낸다(앱은 숫자를 만들지 않는다). 사진에서 나온 표시 정보는 그대로 둔다.
    시세는 분석 때와 같은 방식으로 다시 고른다 — 넣은 값이 있으면 그 값, 없으면 자동 조회(시세 DB·공공데이터, AI 아님).
    """
    extract = RegistryExtract.model_validate(kit["extract"])
    # 옛 재료(2026-10-31 전)엔 이 칸이 없다 — 같은 리포트의 사진 표시로 다시 켠다
    extract.pending_application = extract.pending_application or has_pending_application(old.highlights)
    blacklist = EvidenceVerdict.model_validate(kit["blacklist"]) if kit.get("blacklist") else None
    try:
        price_info = price_lookup.collect(
            address=extract.address, area_sqm=extract.exclusive_area_sqm, manual_price_won=market_price
        )
    except Exception:  # noqa: BLE001
        _log.error("[다시판정] ⚠ 시세 다시 고르기 실패 — 넣은 값만 씁니다", exc_info=True)
        price_info = price_lookup.collect(
            address=None, area_sqm=None, manual_price_won=market_price, auto=False
        )
    fresh, _ = _build(
        extract,
        deposit=deposit,
        market_price=market_price,
        alias=alias if alias is not None else old.alias,
        report_id=old.id,
        use_llm=True,
        highlights=old.highlights,
        highlight_notice=old.highlightNotice,
        checked_notes=old.checkedNotes,
        registry_viewed_at=old.registryViewedAt,
        price_info=price_info,
        blacklist_override=blacklist,
    )
    keep = {k: getattr(old, k) for k in _KEEP_ON_REJUDGE if hasattr(old, k)}
    return fresh.model_copy(update=keep)


def _incomplete_reason(
    missing_pages: list[int], misread_indexes: list[int], page_numbers: list, unnumbered: bool
) -> str:
    """사진 묶음이 불완전한 이유 한 줄 — 앱의 '다시 올리기' 카드와 같은 말로(쪽 번호 = 꼬리말 번호, 없으면 올린 순서)."""
    def page_of(i: int) -> int:
        n = page_numbers[i] if 0 <= i < len(page_numbers) else None
        return n if isinstance(n, int) else i + 1

    parts: list[str] = []
    if missing_pages:
        parts.append(f"{'·'.join(str(n) for n in sorted(missing_pages))}쪽이 빠졌어요")
    misread = sorted({page_of(i) for i in misread_indexes})
    if misread:
        parts.append(f"{'·'.join(str(n) for n in misread)}쪽이 잘 안 읽혔어요")
    if not parts and unnumbered:
        parts.append("쪽 번호가 안 보이는 사진이 있어 빠진 쪽이 없는지 확인하지 못했어요")
    return " · ".join(parts) or "등기부 쪽이 빠졌거나 잘 안 읽혔을 수 있어요"


def analyze(
    images: list[tuple[str, bytes]],
    *,
    deposit: int,
    market_price: int | None,
    alias: str | None,
    device_id: str,
    capture: CaptureCheck | None = None,
    cancelled: Callable[[], bool] | None = None,
) -> Report:
    """업로드 이미지 → (IE ∥ OCR→구조화) → 판정 → 설명 생성 → 이력 저장. (/api/analyze의 본체)

    `cancelled`: 앱이 분석을 중단했는가(연결을 끊었나)를 묻는 함수(2026-10-29, 라우터가 준다). 단계 사이마다 물어
    참이면 [AnalysisCancelled] — **아직 시작 안 한** IE·OCR·Solar 호출을 건너뛰고 아무것도 저장하지 않는다.
    이미 보낸 호출(IE·그 장의 OCR)은 멈출 수 없다. 이 함수를 부르는 스레드(라우터 스레드)에서만 부른다.

    `device_id`: 이 분석을 요청한 기기(`dependencies.get_current_user`). 리포트·대조 기준이
    이 기기의 기록으로 저장된다 — 다른 기기에서는 보이지 않는다(2026-10-21).

    `capture`: 라우터가 IE·OCR **전에** 돌린 촬영 검사 결과(2026-10-22). 심한 장이 있으면 라우터가 이미
    거절했으므로 여기 오는 것은 '문제 없음' 또는 '가벼운 문제'뿐이다. OCR 뒤의 발견(쪽 번호 잘림)을 더해
    `Report.captureCheck`에 싣는다. 2026-10-27부터 잘 안 읽힌 장·빠진 쪽이 있으면 **'양호'만 막는다**
    (`RegistryExtract.pages_incomplete` → doc_incomplete 게이트). 위험·확인 필요는 그대로다.

    **세 경로가 있고, 판정에 들어가는 것은 하나뿐이다** (2026-07-28):

    | 경로 | 무엇을 주나 | 판정에 쓰나 |
    |---|---|---|
    | ① Information Extract | 등기 필드(뜻) | **쓴다 — 이것만** |
    | ② Document OCR | 단어·좌표(위치) | 안 쓴다 (표시 전용) |
    | ③ LLM 구조화 (②의 텍스트) | 두 번째 등기 필드 | 안 쓴다 (교차검증·고지 전용) |

    ①과 (②→③)을 **병렬로** 부른다. 순차로 하면 대기 시간이 그대로 더해진다
    (실측 IE 17~26초 + OCR 장당 1.6~3.1초 + 구조화 수 초).
    ③은 ②의 결과가 있어야 시작할 수 있어 같은 스레드에서 이어 붙이는데,
    ②+③을 합쳐도 ①보다 짧아 **전체 시간이 거의 늘지 않는다.**

    ⚠ 판정 경로는 그대로다 — `extraction.extract_registry` → `rule_engine`.
      ②·③은 실패해도 리포트가 지금과 똑같이 완성된다.
    ⚠ ③이 항목을 더 찾아도 **등급은 바뀌지 않는다.** 불일치는 `checkedNotes`로
      사용자에게 말해줄 뿐이다(`tests/test_cross_check.py`가 이 경계를 못 박는다).

    **무엇이 이 함수를 실패시킬 수 있는가** (2026-07-28 전수 점검 — 실기기 500의 교훈):

    | 단계 | 실패하면 | 왜 |
    |---|---|---|
    | ① IE 추출 | **분석 실패(그대로 던진다)** | 판정할 재료가 없다 |
    | 규칙 판정·리포트 조립 | **분석 실패** | 보여줄 결론 자체가 없다 |
    | ② OCR / ③ 구조화 | 좌표·교차검증 없이 진행 | 표시 전용 |
    | 교차검증 대조 | 고지 없이 진행 | 표시 전용 |
    | 하이라이트 매칭 | 좌표 없이 진행 | 표시 전용 |
    | 설명 문장 생성 | 폴백 문구로 진행 | 판정은 이미 나와 있다 |
    | 이력 저장·원응답 정리·완료 로그 | **그냥 진행** | 리포트가 이미 완성된 뒤다 |

    아래 두 줄이 이 표의 전부다: **판정과 조립만 실패할 수 있다.** 나머지 계층은
    `try/except Exception` + `_log.error(exc_info=True)`로 감싼다 — 조용히 삼키지는
    않되, 사용자에게서 리포트를 빼앗지도 않는다.
    """
    t0 = time.perf_counter()
    # 이 분석 1회를 가리키는 이름. IE·OCR 원응답이 **같은 폴더**에 나란히 남아,
    # 나중에 "어느 IE 응답이 어느 OCR 응답과 짝인지"를 파일만 보고 알 수 있다.
    # `SAVE_RAW_RESPONSES=1`이 아니면 아무것도 저장되지 않는다(`artifacts.save_enabled`).
    run_id = artifacts.new_run_id()
    # 앱이 분석을 중단했으면(2026-10-29) 여기서 멈춘다 — IE·OCR을 한 번도 부르지 않는다(크레딧 0원)
    _raise_if_cancelled(cancelled, "IE·OCR")
    stop = threading.Event()  # 켜지면 OCR 쪽이 남은 장·구조화(Solar)를 건너뛴다
    with ThreadPoolExecutor(max_workers=2, thread_name_prefix="analyze") as pool:
        ie_future = pool.submit(_timed, extraction.extract_registry, images, run_id=run_id)
        ocr_future = pool.submit(_timed, _ocr_then_second_opinion, images, run_id, stop)
        if cancelled is not None:
            # 기다리는 동안 앱이 끊었는지 본다. IE는 이미 보낸 한 번의 호출이라 멈출 수 없고 끝날 때까지 기다린다.
            while not (ie_future.done() and ocr_future.done()):
                wait_futures([ie_future, ocr_future], timeout=CANCEL_POLL_SECONDS)
                if not stop.is_set() and cancelled():
                    stop.set()
        extract, ie_error, ie_elapsed = ie_future.result()
        ocr_bundle, ocr_error, ocr_path_elapsed = ocr_future.result()
    if stop.is_set():
        _log.info("[분석 중단] 앱이 연결을 끊음 — IE·OCR 결과를 버림(판정·설명·저장 안 함)")
        raise AnalysisCancelled("IE·OCR 뒤")

    total = time.perf_counter() - t0
    _log.info(
        f"[병렬] IE {ie_elapsed:.1f}초 / OCR+구조화 {ocr_path_elapsed:.1f}초 → 전체 {total:.1f}초"
        f" (순차였다면 {ie_elapsed + ocr_path_elapsed:.1f}초)"
    )
    if ie_error is not None:
        # IE 실패는 분석 실패다(지금과 동일). OCR이 성공했어도 판정할 수 없으므로 버린다.
        _log.info("[분석 중단] IE 실패 — OCR 결과가 있어도 판정 없이는 리포트를 만들 수 없음")
        raise ie_error
    if ocr_error is not None:  # run_ocr는 예외를 삼키지만, 만약을 대비한 최종 방어선
        _log.info(f"[OCR] 예기치 못한 예외 — 좌표 없이 계속 진행 ({type(ocr_error).__name__})")
        ocr_bundle = OcrPath(ocr=ocr.OcrResult(), error=type(ocr_error).__name__)
    ocr_result = ocr_bundle.ocr
    second_extract = ocr_bundle.second_extract
    second_provider = ocr_bundle.second_provider
    second_error = ocr_bundle.error
    doc_check = ocr_bundle.doc_check

    assert extract is not None  # ie_error가 없으면 반드시 값이 있다
    # 가로·거꾸로 찍은 장을 OCR이 바로 세웠으면(2026-10-26) IE도 **바로 선 사진으로** 한 번 더 읽는다 —
    # 판정 재료(IE)가 누운 글자를 잘못 읽은 채로 남지 않게. 실패하면 처음 읽은 결과를 그대로 쓴다.
    rotation_note: str | None = None
    if ocr_result.rotated:
        _raise_if_cancelled(cancelled, "바로 세운 사진 다시 읽기(IE)")
        turned = [i + 1 for i, r in enumerate(ocr_result.rotations(len(images))) if r]
        _log.info(f"[방향] {turned}번째 사진을 바로 세움 → IE를 바로 선 사진으로 다시 읽음")
        try:
            reread = extraction.extract_registry(ocr_result.upright_images, run_id=run_id)
            # 보수적 편향(CLAUDE.md §2-3): 다시 읽은 쪽이 위험 항목을 **덜** 찾았으면 처음 결과를 쓴다 —
            # 위험을 놓치는 쪽으로 바뀌지 않게. 같거나 더 찾았으면 바로 선 사진으로 읽은 결과를 쓴다.
            before, after = document_gate.entry_count(extract), document_gate.entry_count(reread)
            if after >= before:
                extract = reread
            else:
                _log.info(f"[방향] 다시 읽은 쪽이 등기 항목을 덜 찾음({before}→{after}) — 처음 결과를 그대로 씀")
                rotation_note = (
                    f"{', '.join(map(str, turned))}번째 사진이 옆으로·거꾸로 찍혀 바로 세워 다시 읽었는데 결과가 달랐어요 "
                    "— 더 많이 찾은 쪽으로 판정했어요. 바로 세워 다시 찍으면 더 정확해요"
                )
        except Exception as e:  # noqa: BLE001 — 다시 읽기가 실패해도 처음 결과로 계속
            _log.info(f"[방향] IE 다시 읽기 실패 — 처음 읽은 결과로 계속 ({type(e).__name__})")
            rotation_note = (
                f"{', '.join(map(str, turned))}번째 사진이 옆으로·거꾸로 찍혀 글자를 잘못 읽었을 수 있어요 "
                "— 바로 세워 다시 찍어 주세요"
            )
    # 등기부가 아닌 사진(키보드·화면 등)이면 여기서 멈춘다 — 리포트·기록을 만들지 않는다 (2026-10-24).
    # 등기부인데 못 읽은 것과 가른다: IE가 아무것도 못 찾았고 OCR에도 등기부 낱말이 없을 때만.
    if document_gate.looks_not_registry(extract, ocr_result.pages):
        _log.info(
            f"[분석 중단] 등기부가 아닌 사진 — IE 내용 없음 · OCR 등기부 낱말 "
            f"{document_gate.ocr_marker_count(ocr_result.pages)}개"
        )
        raise extraction.ExtractionError(400, document_gate.NOT_REGISTRY_DETAIL)
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
    # ── 말소 확인분 제외 (2026-08-14 D10) ────────────────────────────────────
    # **판정에 들어가는 사실을 여기서 한 번 바로잡는다.** OCR이 'N번○○등기말소' 행을
    # 특정 (구역, 순위)에 결합해 확인한 항목에만 `is_canceled`를 찍는다. 규칙 엔진은
    # 원래부터 유효 항목만 세므로 규칙은 한 줄도 바뀌지 않는다 — 사실이 바뀔 뿐이다.
    #
    # ⚠ **왜 여기인가.** 교차검증·하이라이트·판정이 **같은 사실**을 보게 하려면 그 셋보다
    #   앞이어야 한다. 뒤에 두면 "표시에서는 뺐는데 계산에서는 셌다"가 그대로 남고,
    #   교차검증은 말소로 이미 설명된 개수 차이를 불일치라고 말하게 된다.
    # ⚠ 안전 조건(미결 말소·사진 묶음 점검·등기목적 일치)은 전부 `cancellation` 안에 있다.
    #   하나라도 애매하면 아무것도 빼지 않고 종전대로 센다.
    try:
        cancel_result = cancellation.apply_confirmed_cancellations(
            extract, ocr_result, check=doc_check
        )
    except Exception:  # noqa: BLE001 — 사실 보정이 분석을 깨뜨리면 안 된다(종전 계산 유지)
        _log.error("[판정] ⚠ 말소 제외 중 예기치 못한 예외 — 종전대로 계산합니다", exc_info=True)
        cancel_result = cancellation.CancellationResult(skipped_reason="예외")
    if cancel_result.skipped_reason:
        _log.info(f"[판정] 말소 제외를 적용하지 않았습니다 — {cancel_result.skipped_reason}")

    # ── 못 읽은 빚 금액 다시 읽기 (2026-10-29 QA) ────────────────────────────
    # IE가 금액만 비운 살아 있는 빚을 **같은 사진의 같은 항목 줄(OCR)**에서 다시 읽는다. 말소 제외처럼
    # 규칙은 그대로이고 규칙에 들어가는 사실(빈 금액)만 채운다. 그래도 못 읽으면 아래에서 그 쪽을 다시 찍게 한다.
    try:
        recovery = amount_recovery.recover_missing_amounts(extract, ocr_result.pages, check=doc_check)
    except Exception:  # noqa: BLE001 — 금액 다시 읽기가 분석을 깨뜨리면 안 된다(빈 금액 그대로 '확인 필요')
        _log.error("[금액] ⚠ 빈 금액 다시 읽기 실패 — IE 결과 그대로 판정합니다", exc_info=True)
        recovery = amount_recovery.RecoveryResult()

    # 두 경로 대조 — **표시와 고지에만** 쓴다. 아래 `rule_engine`에는 `extract`(IE)만 간다.
    try:
        check = cross_check.compare(
            extract, second_extract, provider=second_provider, error=second_error
        )
    except Exception as e:  # noqa: BLE001 — 고지 계층이 분석을 깨뜨리면 안 된다
        _log.error("[교차검증] ⚠ 예기치 못한 예외 — 교차검증 없이 진행", exc_info=True)
        check = cross_check.CrossCheck(ran=False, provider=second_provider, error=type(e).__name__)

    try:
        highlight_result = highlight.build_highlights(
            extract,
            ocr_result,
            cross=check,
            check=doc_check,
            canceled_excluded=cancel_result.count,
        )
    except Exception as e:  # noqa: BLE001 — 표시 기능이 분석을 깨뜨리면 안 된다
        _log.error(f"[매칭] 실패 — 좌표 없이 리포트 완성 ({type(e).__name__})")
        highlight_result = highlight.HighlightResult([])

    # 사진 속 실명·주민번호 **자리** (2026-10-22, P0-2b) — 표시 전용. 판정과 하이라이트를 건드리지 않는다.
    # 실패하면 `privacyMasksReady=False`로 나가고, 앱은 가리기가 켜져 있으면 사진을 통째로 덮는다.
    try:
        mask_result = privacy_masks.build_privacy_masks(
            ocr_result, extract, page_count=len(images)
        )
    except Exception:  # noqa: BLE001
        _log.error("[가리기] ⚠ 가림 상자를 만들지 못함 — 앱이 사진을 통째로 덮습니다", exc_info=True)
        mask_result = None

    # ── 시세 자동조회 ────────────────────────────────────────────────────────
    # 주소는 **OCR/IE 이후에야** 알 수 있으므로 여기가 가장 이른 시점이다.
    # ⚠ 어떤 실패도 리포트를 막지 못한다. `price_lookup.collect`는 스스로 예외를
    #   삼키지만, 그 안에서 예상 못 한 일이 나도 여기서 한 번 더 막는다.
    #   조회가 통째로 죽어도 `price_info`는 사용자 입력값만 담은 결과가 되고,
    #   그것마저 없으면 `price_won=None` — 지금까지와 똑같이 '확인 필요'로 흐른다.
    try:
        price_info = price_lookup.collect(
            address=extract.address,
            area_sqm=extract.exclusive_area_sqm,
            manual_price_won=market_price,
            run_id=run_id,
        )
    except Exception as e:  # noqa: BLE001
        _log.error(f"[시세] ⚠ 자동조회에서 예기치 못한 예외 — 입력값만 사용 ({type(e).__name__})", exc_info=True)
        price_info = price_lookup.collect(
            address=None, area_sqm=None, manual_price_won=market_price, auto=False
        )

    # 촬영 검사 + OCR 뒤 발견(쪽 번호 안 보임 = 잘림 의심) — **판정 전에** 모은다 (2026-10-27).
    # 빠진 쪽이나 잘 안 읽힌 장이 있으면 '양호'를 막는다(`RegistryExtract.pages_incomplete` → doc_incomplete 게이트).
    try:
        capture_after = capture_check.add_ocr_findings(capture, ocr_result.pages, len(images))
    except Exception:  # noqa: BLE001 — 안내 한 줄 때문에 리포트를 잃지 않는다
        _log.error("[촬영검사] ⚠ OCR 뒤 검사 실패 — 분석 전 검사 결과만 싣습니다", exc_info=True)
        capture_after = capture
    missing_pages = list(doc_check.missing_pages) if doc_check is not None else []
    # 쪽 번호를 못 읽은 장 — 촬영 검사가 꺼졌거나 실패해도(capture=None) 게이트는 이걸로 막는다 (규칙 감사 2026-10-27)
    unnumbered = doc_check is not None and any(n is None for n in doc_check.page_numbers)
    extract.pages_incomplete = (
        bool(missing_pages) or unnumbered or bool(capture_after and capture_after.pages)
    )
    if extract.pages_incomplete:
        extract.pages_incomplete_reason = _incomplete_reason(
            missing_pages,
            [p.index for p in (capture_after.pages if capture_after else [])],
            list(doc_check.page_numbers) if doc_check is not None else [],
            unnumbered,
        )
        _log.info(
            f"[판정] 사진 묶음 불완전 — 빠진 쪽 {missing_pages or '없음'} · 잘 안 읽힌 장 "
            f"{[p.index + 1 for p in (capture_after.pages if capture_after else [])] or '없음'} → '양호' 금지"
        )

    # 그래도 못 읽은 빚 → 그 쪽을 '다시 찍기' 대상으로(2순위). 게이트 계산 **뒤에** 더한다 — 금액 하나 못 읽은 것으로
    # 다른 카드(소유권 등)까지 '확인 필요'로 올리지 않는다. 빚 카드는 금액 미상으로 이미 '확인 필요'다.
    if recovery.still_unknown and recovery.unread_pages:
        capture_after = capture_check.add_unread_amount_pages(
            capture_after, recovery.unread_pages, len(images)
        )

    # 잔금 당일 빈틈 (2026-10-31) — 등기부에 '신청사건 처리중'이 찍혀 있으면 규칙 엔진이 '확인 필요' 카드를 더한다.
    # 사진 위 표시(OCR 글자 규칙)와 **같은 근거**로 켠다 — 화면의 형광펜과 카드가 어긋나지 않게.
    extract.pending_application = has_pending_application(highlight_result.highlights)

    _raise_if_cancelled(cancelled, "설명 생성(Solar)")
    report, explain = _build(
        extract,
        deposit=deposit,
        market_price=market_price,
        alias=alias,
        use_llm=True,
        highlights=highlight_result.highlights,
        highlight_notice=highlight_result.notice,
        checked_notes=highlight_result.checked_notes,
        registry_viewed_at=highlight_result.viewed_at,
        price_info=price_info,
    )
    if mask_result is not None:
        report.privacyMasks = mask_result.masks
        report.privacyMasksReady = True
    # 사진 순서·방향 (2026-10-26) — 표시 전용. 뷰어가 1쪽부터 정렬하고 글자가 바로 서게 돌려 그린다.
    if doc_check is not None and doc_check.page_order:
        report.pageOrder = list(doc_check.page_order)
    if ocr_result.pages:
        report.pageRotations = ocr_result.rotations(len(images))
    if rotation_note:
        report.checkedNotes = [*report.checkedNotes, rotation_note]
    if recovery.notes:
        report.checkedNotes = [*report.checkedNotes, *recovery.notes]
    # 같은 집 묶기의 첫 기준 (2026-10-27) — 표시·판정에 쓰지 않는다. 주소는 읽을 때마다 글자가 조금씩 달라진다.
    report.propertyId = store.property_id(extract.unique_number)
    # 용도 후보 (2026-10-28) — 손실 예상이 어느 매각가율을 쓸지 고르는 데만 쓴다. 판정과 무관하다.
    try:
        report.houseTypes = loss_estimate.house_types_from(
            list(price_info.candidates) if price_info else [],
            (doc_check.header_address if doc_check is not None else None) or extract.address,
        )
    except Exception:  # noqa: BLE001 — 용도를 못 정해도 리포트는 나간다(손실 예상이 세 용도 중 낮은 값을 쓴다)
        _log.error("[손실예상] ⚠ 용도 후보를 정하지 못했습니다", exc_info=True)
    _add_house_type_to_address_mark(report)
    if doc_check is not None:
        # 두 번째 기준(쪽 머리 주소) · 빠진 쪽 · 장마다 쪽 번호 — 표시·묶기 전용
        report.propertyAddress = doc_check.header_address
        report.missingPages = missing_pages
        report.pageNumbers = list(doc_check.page_numbers)
    # 화면엔 실명, 저장은 가린 사본 (2026-10-22) — 사람 이름 목록. 앱 가리기 스위치가 쓰고, `store.add`가 이 목록으로
    # 가린 사본을 만든다. ⚠ 목록이 비면 저장 사본에 실명(집주인 제목)이 남으므로, 실패해도 집주인 이름만은 꼭 넣는다.
    try:
        report.personNames = name_privacy.person_names(extract)
    except Exception:  # noqa: BLE001
        _log.error("[이름] ⚠ 사람 이름 목록을 만들지 못함 — 집주인 이름만으로 가립니다", exc_info=True)
        report.personNames = name_privacy.owner_names_fallback(extract)
    # 촬영 검사 결과(판정 전에 모은 것) — 리포트의 '다시 올리기' 카드
    report.captureCheck = capture_after
    # ── 여기서부터 리포트는 **이미 완성됐다.** 아래는 기록·정리·로그뿐이다 ──────────
    # 완성된 리포트를 손에 들고 뒷정리에서 죽는 것만큼 아까운 실패가 없다.
    # 2026-07-28 실기기 500이 정확히 이 모양이었다(리포트 완성 → 마지막 문장에서 사망).
    # 그래서 이 아래 전부를 감싼다 — 실패해도 사용자는 리포트를 받는다.
    # 단, 설명을 쓰는 동안 앱이 끊었으면 **저장하지 않는다** — 받을 사람이 없는 리포트가 기록에 남지 않게.
    _raise_if_cancelled(cancelled, "기록 저장")
    try:
        # 다음에 등기부를 다시 뗐을 때 견줄 **기준**을 남긴다 (S-11 대조).
        # 실패해도 이번 리포트는 그대로 나간다 — 대조를 못 하게 될 뿐이고,
        # 그 사실은 `comparable=False`로 앱에 정직하게 전달된다.
        store.put_snapshot(
            report.id,
            compare.build_snapshot(
                extract,
                # 스냅샷도 서버에 남는다 — 별칭 등에 든 사람 이름까지 가린 사본에서 옮긴다(이름은 원래 해시뿐)
                report=name_privacy.mask_report_for_storage(report),
                page_count=len(images),
                manual_market_price=market_price,
                name_salt=store.name_salt(),
            ),
            device_id=device_id,
        )
        report.comparable = True
    except Exception:  # noqa: BLE001
        _log.error("[대조] ⚠ 기준 스냅샷을 남기지 못했습니다 — 이 리포트는 대조 기준이 될 수 없어요", exc_info=True)
    try:
        # 보증금·시세를 나중에 고치면 사진을 다시 읽지 않고 판정만 다시 한다(2026-10-29) — 그 재료(이름 가린 사본)
        store.put_rejudge_kit(report.id, rejudge_kit(extract, report), device_id=device_id)
        report.rejudgeReady = True
    except Exception:  # noqa: BLE001 — 재료를 못 남기면 고치기 때 사진으로 다시 분석한다(앱이 그렇게 안내)
        _log.error("[다시판정] ⚠ 재료를 남기지 못했습니다 — 이 리포트는 사진으로만 다시 분석돼요", exc_info=True)
    try:
        store.add(report, device_id=device_id)
    except Exception:  # noqa: BLE001 — 이력 저장 실패로 이번 분석을 잃지 않는다
        _log.error("[이력] ⚠ 저장 실패 — 이번 리포트는 응답으로만 나갑니다", exc_info=True)
    try:
        # 진단용 원응답은 **최근 N회분만** 남긴다. 등기부 실명·주소가 담긴 파일이라,
        # "시연 전에 비운다"는 절차가 아니라 코드가 지운다(artifacts.py 참고).
        artifacts.prune_runs()
        artifacts.prune_legacy_flat_files()
    except Exception:  # noqa: BLE001 — 뒷정리 실패는 다음 분석 때 다시 시도된다
        _log.error("[진단저장] ⚠ 원응답 정리 실패", exc_info=True)
    try:
        # ⚠ 주소 전체를 찍지 않는다(2026-08-03) — 로그 파일만으로 물건이 특정된다.
        #   `lawd_code.address_head` 관례대로 앞 2토큰(시도+시군구)까지만 남긴다.
        _addr_head = " ".join(lawd_code.address_head(report.address).split()[:2]) or "(미확인)"
        _price_note = (
            f"{price_resolver.SOURCE_LABELS.get(report.marketPriceSource, '?')}"
            f" {format_won(report.marketPrice)}"
            if report.marketPrice
            else "없음"
        )
        _cross_note = (
            f"일치 {len(check.agreed)}종/불일치 {len(check.disagreed)}종"
            if check.ran
            else f"없음({second_error})"
        )
        _log.info(
            _summary_block(
                stages=[
                    ("① 정보 추출(IE)", _vendor("upstage", extraction.MODEL), ie_elapsed),
                    (
                        "② 문서 OCR",
                        f"{_vendor('upstage', ocr.OCR_MODEL)} · {len(ocr_result.pages)}장",
                        ocr_bundle.ocr_elapsed,
                    ),
                    (
                        "③ 2차 구조화",
                        _vendor(ocr_bundle.second_provider, ocr_bundle.second_model)
                        if ocr_bundle.second_provider
                        else f"건너뜀 ({second_error})",
                        ocr_bundle.structure_elapsed,
                    ),
                    ("④ 설명 생성", _vendor(explain.provider, explain.model), explain.elapsed),
                ],
                total=time.perf_counter() - t0,
                facts=[
                    ("판정", f"{report.grade} (게이지 {report.gaugeProgress})"),
                    ("설명 출처", explain.source),
                    ("지역", _addr_head),
                    ("시세", _price_note),
                    ("선순위채권 합계", format_won(report.seniorDebtAmount)),
                    ("하이라이트", f"{len(report.highlights)}건"),
                    ("가림 상자", f"{len(report.privacyMasks)}개" if report.privacyMasksReady else "없음(실패)"),
                    (
                        "촬영 검사",
                        "꺼짐"
                        if report.captureCheck is None
                        else "문제 없음"
                        if report.captureCheck.ok
                        else ", ".join(
                            f"{p.index + 1}쪽 {'/'.join(p.issues)}" for p in report.captureCheck.pages
                        ),
                    ),
                    ("교차검증", _cross_note),
                ],
            )
        )
    except Exception:  # noqa: BLE001 — 로그 한 줄 만들다 요청을 죽이는 일은 없어야 한다
        _log.error("[분석 완료] 요약 로그 생성 실패 (리포트는 정상)", exc_info=True)
    return report


# ── [분석 완료] 요약 블록 (2026-08-14 D9) ───────────────────────────────────────
# 이 블록은 **터미널을 그대로 캡처해 제안서에 넣기 위한 것**이다. 그래서 한 줄에
# 몰아넣지 않고, 단계마다 "어느 회사 어느 모델이 몇 초를 썼는지"를 눈으로 세로로
# 훑을 수 있게 세운다. 값은 전부 실행 중에 실제로 잰 것이고, 모델명은 코드 상수와
# `.env` 덮어쓰기를 반영한 **실제 호출값**이다(추정·수기 입력 없음).

#: provider 이름 → 캡처에 쓸 회사 표기. 모르는 이름은 그대로 찍는다(거짓말보다 낫다).
_VENDOR_LABEL = {"upstage": "Upstage"}


def _vendor(provider: str | None, model: str | None) -> str:
    """`upstage` + `solar-pro2` → `Upstage solar-pro2`."""
    if not provider or provider == "-":
        return "-"
    return f"{_VENDOR_LABEL.get(provider, provider)} {model or '?'}".strip()


def _cells(text: str) -> int:
    """터미널에서 차지하는 **칸 수**. 한글·전각 문자는 2칸이다."""
    return sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in text)


def _pad(text: str, width: int) -> str:
    """`str.ljust`는 글자 수로 세서 한글이 섞이면 열이 어긋난다 — 칸 수로 채운다."""
    return text + " " * max(0, width - _cells(text))


def _summary_block(
    *, stages: list[tuple[str, str, float]], total: float, facts: list[tuple[str, str]]
) -> str:
    """(단계, 모델, 초) 목록과 사실 목록을 정렬된 한 덩어리로 만든다."""
    name_w = max((_cells(n) for n, _, _ in stages), default=0)
    model_w = max((_cells(m) for _, m, _ in stages), default=0)
    lines = ["[분석 완료] ─────────────────────────────────────────────────"]
    for name, model, seconds in stages:
        lines.append(f"  {_pad(name, name_w)}  {_pad(model, model_w)}  {seconds:>5.1f}초")
    lines.append(f"  {' ' * name_w}  {_pad('총 소요', model_w)}  {total:>5.1f}초")
    # ⚠ 이 한 줄이 없으면 캡처를 본 사람이 위 네 값을 더해 보고 안 맞는다고 여긴다.
    #   ①(IE)과 ②(OCR)는 다른 스레드에서 **동시에** 돌고, ③은 ② 뒤에 이어 붙는다.
    lines.append("  (①과 ②는 동시에 돕니다 — 총 소요는 네 값의 합이 아니라 실제 걸린 시간)")
    lines.append("  ─────────────────────────────────────────────────────────")
    label_w = max((_cells(k) for k, _ in facts), default=0)
    for key, value in facts:
        lines.append(f"  {_pad(key, label_w)}  {value}")
    return "\n".join(lines)
