"""리포트 조립 오케스트레이터 — 추출 → 규칙 판정 → 설명 문구 → Report(계약 §2.1).

가드레일(단일 조립 지점): Report의 [판정] 필드(grade·statusLabel·detailText·
sourceText·deposit·marketPrice·seniorDebtAmount·gaugeProgress)는 **RuleVerdict에서만**
복사한다. 설명([설명]) 필드는 지금은 fallback_texts가 채우고, E-2에서 Solar Pro가
성공하면 그 결과로 교체된다 — 어느 쪽이든 판정 필드에는 손대지 못한다.
"""

from __future__ import annotations

import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

from ..schemas.contract import Evidence, Highlight, Report
from ..schemas.internal import Grade, RegistryExtract, RuleVerdict
from . import (
    artifacts,
    cross_check,
    document_parse,
    explanation,
    extraction,
    fallback_texts,
    highlight,
    llm,
    ocr,
    rule_engine,
    store,
)
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


def _timed(fn, *args, **kwargs):
    """(결과 또는 예외, 걸린 시간)을 돌려준다 — 병렬 소요시간 로그용."""
    t0 = time.perf_counter()
    try:
        return fn(*args, **kwargs), None, time.perf_counter() - t0
    except Exception as e:  # noqa: BLE001 — 호출부가 판단한다
        return None, e, time.perf_counter() - t0


def _ocr_then_second_opinion(
    images: list[tuple[str, bytes]], run_id: str | None = None
) -> tuple[ocr.OcrResult, RegistryExtract | None, str | None, str | None]:
    """OCR → (성공하면) **두 번째 추출 경로**까지 한 스레드에서 이어 돌린다.

    왜 이어 붙이나: 두 번째 경로의 입력이 OCR 결과라 진짜 병렬이 될 수 없다. 대신
    OCR(장당 1.6~3.1초)이 IE(실측 17~26초)보다 훨씬 빨리 끝나므로, 그 뒤에 이어 붙이면
    **IE의 그림자 안에서** 끝나 전체 시간이 거의 늘지 않는다.

    반환: (OCR 결과, 두 번째 경로 추출본|None, provider 이름|None, 실패 사유|None)
    ⚠ 어떤 실패도 밖으로 던지지 않는다 — 이 경로가 없어도 리포트는 그대로 완성된다.
    """
    ocr_result = ocr.run_ocr(images, run_id=run_id)
    if not ocr_result.pages:
        return ocr_result, None, None, "OCR 결과 없음"

    provider = llm.structure_provider()
    if provider is None:
        return ocr_result, None, None, "두 번째 경로 꺼짐 또는 키 없음"

    try:
        layout_text = _layout_text_for(images, ocr_result, run_id)
        second = provider.structure(layout_text, timeout=llm.STRUCTURE_TIMEOUT_SECONDS)
        return ocr_result, second, provider.name, None
    except Exception as e:  # noqa: BLE001 — 두 번째 경로는 어떤 이유로도 분석을 막지 못한다
        _log.info(f"[LLM:{provider.name}] 구조화 실패 — 교차검증 없이 진행 ({type(e).__name__}: {e})")
        return ocr_result, None, provider.name, f"{type(e).__name__}"


def _layout_text_for(
    images: list[tuple[str, bytes]], ocr_result: ocr.OcrResult, run_id: str | None
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
        return llm.render_layout_text(ocr_result.pages)

    parsed = document_parse.run_document_parse(images, run_id=run_id)
    if not parsed.ok:
        _log.info(
            "[DP] 결과가 없어 ocr_layout 텍스트로 되돌아감"
            f" (실패 {len(parsed.errors)}건) — 분석은 그대로 진행"
        )
        return llm.render_layout_text(ocr_result.pages)
    text = document_parse.render_parsed_text(parsed.pages)
    _log.info(
        f"[DP] 레이아웃 출처 = document_parse ({parsed.elapsed:.1f}초, {len(text):,}자)"
        f" — 좌표는 여전히 Document OCR에서 옵니다"
    )
    return text


def analyze(
    images: list[tuple[str, bytes]],
    *,
    deposit: int,
    market_price: int | None,
    alias: str | None,
) -> Report:
    """업로드 이미지 → (IE ∥ OCR→구조화) → 판정 → 설명 생성 → 이력 저장. (/api/analyze의 본체)

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
    """
    t0 = time.perf_counter()
    # 이 분석 1회를 가리키는 이름. IE·OCR 원응답이 **같은 폴더**에 나란히 남아,
    # 나중에 "어느 IE 응답이 어느 OCR 응답과 짝인지"를 파일만 보고 알 수 있다.
    # 개발 모드가 아니면 아무것도 저장되지 않는다(`artifacts.SAVE_RAW`).
    run_id = artifacts.new_run_id()
    with ThreadPoolExecutor(max_workers=2, thread_name_prefix="analyze") as pool:
        ie_future = pool.submit(_timed, extraction.extract_registry, images, run_id=run_id)
        ocr_future = pool.submit(_timed, _ocr_then_second_opinion, images, run_id)
        extract, ie_error, ie_elapsed = ie_future.result()
        ocr_bundle, ocr_error, ocr_elapsed = ocr_future.result()

    total = time.perf_counter() - t0
    _log.info(
        f"[병렬] IE {ie_elapsed:.1f}초 / OCR+구조화 {ocr_elapsed:.1f}초 → 전체 {total:.1f}초"
        f" (순차였다면 {ie_elapsed + ocr_elapsed:.1f}초)"
    )
    if ie_error is not None:
        # IE 실패는 분석 실패다(지금과 동일). OCR이 성공했어도 판정할 수 없으므로 버린다.
        _log.info("[분석 중단] IE 실패 — OCR 결과가 있어도 판정 없이는 리포트를 만들 수 없음")
        raise ie_error
    if ocr_error is not None:  # run_ocr는 예외를 삼키지만, 만약을 대비한 최종 방어선
        _log.info(f"[OCR] 예기치 못한 예외 — 좌표 없이 계속 진행 ({type(ocr_error).__name__})")
        ocr_bundle = (ocr.OcrResult(), None, None, type(ocr_error).__name__)
    ocr_result, second_extract, second_provider, second_error = ocr_bundle

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
    # 두 경로 대조 — **표시와 고지에만** 쓴다. 아래 `rule_engine`에는 `extract`(IE)만 간다.
    check = cross_check.compare(
        extract, second_extract, provider=second_provider, error=second_error
    )

    try:
        highlight_result = highlight.build_highlights(extract, ocr_result, cross=check)
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
    # 진단용 원응답은 **최근 N회분만** 남긴다. 등기부 실명·주소가 담긴 파일이라,
    # "시연 전에 비운다"는 절차가 아니라 코드가 지운다(artifacts.py 참고).
    artifacts.prune_runs()
    artifacts.prune_legacy_flat_files()
    _log.info(
        f"[분석 완료] 주소: {report.address} | 선순위채권 합계: {format_won(report.seniorDebtAmount)}"
        f" | 판정: {report.grade} (게이지 {report.gaugeProgress}) | 설명: {explain_source}"
        f" | 하이라이트: {len(report.highlights)}건"
        f" | 교차검증: {'일치 ' + str(len(check.agreed)) + '종/불일치 ' + str(len(check.disagreed)) + '종' if check.ran else '없음(' + str(second_error) + ')'}"
        f" | 총 {time.perf_counter() - t0:.1f}초"
    )
    return report
