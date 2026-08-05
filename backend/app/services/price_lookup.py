"""시세 자동조회 오케스트레이터 — 세 소스를 모아 `price_resolver`에 넘긴다.

`price_resolver`는 순수 함수(채택 규칙)만 담당하고, 이 모듈이 바깥 세계(HTTP·SQLite)를
맡는다. 그래서 채택 규칙은 네트워크 없이 테스트되고, 이 모듈은 실패를 삼키는 일만 한다.

════════════════════════════════════════════════════════════════════════════
⚠ **시세 조회 실패가 리포트를 실패시키지 않는다.**
  이 모듈의 모든 공개 함수는 예외를 밖으로 던지지 않는다. 무엇이 왜 안 됐는지는
  `notes`(사람이 읽는 문자열 목록)로 돌려주고, 값은 `None`으로 남긴다.
  `report_builder.analyze`는 그 `None`을 지금까지와 똑같이 처리한다 —
  전세가율이 '확인 필요'가 될 뿐 리포트는 완성된다.
════════════════════════════════════════════════════════════════════════════
"""

from __future__ import annotations

import logging
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeout
from datetime import date

from . import market_price, official_price, price_normalize as N, price_resolver as R
from .price_resolver import PriceCandidate, ResolvedPrice

_log = logging.getLogger("jeonseai")

# 실거래가 조회 **전체**에 주는 시간 예산.
#
# 근거: 2026-07-29 프로브에서 시군구 1개월 응답이 1초 미만이었다. 6개월 × 3유형 = 18회를
# 6워커로 나누면 3파이므로 정상이면 5초 안에 끝난다. 그런데 한 요청이
# `market_price.REQUEST_TIMEOUT_SECONDS`(20초)까지 버티면 최악 60초가 되어 분석 전체
# (IE 실측 17~26초)보다 길어진다. 시세는 **부가 정보**이므로 예산을 넘기면 포기하고
# 리포트를 완성한다 — 사용자를 기다리게 하느니 '확인 필요'가 낫다.
# (`extraction.py`/`ocr.py`의 REQUEST_TIMEOUT_SECONDS 패턴을 따르되, 이쪽은 한 요청이
#  아니라 조회 묶음 전체의 예산이라는 점이 다르다.)
MARKET_PRICE_BUDGET_SECONDS = 25


def _actual_trade_candidate(
    address: str, area_sqm: float, *, run_id: str | None, today: date | None
) -> tuple[PriceCandidate | None, list[str]]:
    """국토부 실거래가 → 후보 1건. 실패·0건이면 `(None, 사유들)`."""
    notes: list[str] = []
    parts = market_price.parse_address_parts(address)
    if parts is None:
        return None, ["[실거래가] 주소에서 시군구·지번을 읽지 못해 조회하지 않았습니다"]

    for lawd_cd in parts.lawd_codes:
        try:
            result, errors = market_price.lookup_market_price(
                lawd_cd=lawd_cd,
                umd_nm=parts.umd_nm,
                jibun=parts.jibun,
                area_sqm=area_sqm,
                today=today,
                run_id=run_id,
            )
        except market_price.MarketPriceError as e:
            # 키 없음·서버 오류 등 — 조회 불가일 뿐 분석 실패가 아니다. 코드를 더 시도해도
            # 같은 이유로 실패하므로 여기서 멈춘다.
            return None, [f"[실거래가] {e.detail}"]
        notes.extend(f"[실거래가] {e}" for e in errors)
        if result is not None:
            return (
                PriceCandidate(
                    price_won=result.price_won,
                    source=R.SOURCE_ACTUAL_TRADE,
                    source_name=result.source,
                    as_of=f"{result.period_from}~{result.period_to}",
                    sample_count=result.sample_count,
                    detail=f"{lawd_cd} · {result.months_used}개월",
                ),
                notes,
            )
    notes.append("[실거래가] 같은 지번·면적의 거래를 찾지 못했습니다")
    return None, notes


def _official_candidates(
    address: str, area_sqm: float | None
) -> tuple[list[PriceCandidate], list[str]]:
    """공시가격·기준시가 → 후보 0~2건."""
    results, notes = official_price.lookup_all(address=address, area_sqm=area_sqm)
    out: list[PriceCandidate] = []
    for r in results:
        detail = f"{r.lawd_cd} · 매칭 {r.match_method}"
        if r.umd_narrowed:
            detail += " · 읍면동 대조함"
        elif r.matched_count > 1:
            # 읍면동을 못 좁힌 채 여러 건이면 **다른 동네가 섞였을 수 있다** — 근거 공개 원칙상 밝힌다.
            detail += " · ⚠ 읍면동 대조 못함"
        if r.matched_count > 1:
            detail += f" · 같은 조건 {r.matched_count}건 중 최저가"
        if r.multiplier != 1.0:
            detail += f" · 공시가격 {r.base_price_won:,}원 × {r.multiplier}"
        if r.area_mismatch:
            detail += " · ⚠ 동·호는 맞지만 전용면적이 다름"
        if r.area_basis == "exclusive_plus_common":
            detail += " · 전용+공용면적 기준"
        out.append(
            PriceCandidate(
                price_won=r.price_won,
                source=r.source_key,
                source_name=r.source_name,
                as_of=r.as_of,
                sample_count=None,
                detail=detail,
            )
        )
    return out, notes


def collect(
    *,
    address: str | None,
    area_sqm: float | None,
    manual_price_won: int | None = None,
    run_id: str | None = None,
    today: date | None = None,
    auto: bool = True,
) -> ResolvedPrice:
    """사용자 입력 + 자동조회 → 채택된 시세 하나. **예외를 던지지 않는다.**

    `auto=False`면 자동조회를 아예 하지 않는다(테스트·오프라인용).
    """
    candidates: list[PriceCandidate] = []
    notes: list[str] = []

    if manual_price_won and manual_price_won > 0:
        candidates.append(
            PriceCandidate(
                price_won=int(manual_price_won),
                source=R.SOURCE_MANUAL,
                source_name="직접 입력하신 값",
                as_of="",
                detail="사용자 입력",
            )
        )

    if not auto:
        return _finish(candidates, notes)

    if not address:
        notes.append("[주소] 주소를 추출하지 못해 자동 조회를 하지 않았습니다")
        return _finish(candidates, notes)

    # 단독·다가구(통건물 등기)는 자동 조회를 **아예 하지 않는다.**
    # ⑴ 공동주택 공시가격·오피스텔 기준시가에는 애초에 없고,
    # ⑵ 같은 지번에 있는 다른 집합건물 한 건에 잘못 붙을 위험이 있으며,
    # ⑶ 무엇보다 이 유형은 전세가율 자체를 쓰지 않는다(rule_engine이 보류시킨다).
    if N.is_whole_building(address):
        notes.append(
            "[유형] 단독·다가구로 보여 자동 조회를 하지 않았습니다 — "
            "이 유형은 등기부가 1개라 앞순위 세입자 보증금 합계를 알 수 없어 "
            "전세가율로 판단하지 않습니다"
        )
        return _finish(candidates, notes)

    # ① 공시가격·기준시가 (로컬 SQLite — 빠르고 실패해도 즉시 끝난다)
    try:
        official, official_notes = _official_candidates(address, area_sqm)
        candidates.extend(official)
        notes.extend(official_notes)
    except Exception as e:  # noqa: BLE001 — 시세가 리포트를 죽이지 못한다
        _log.error("[시세] 공시가격·기준시가 조회에서 예기치 못한 예외", exc_info=True)
        notes.append(f"[공시가격] 조회 중 오류 ({type(e).__name__})")

    # ② 실거래가 (외부 HTTP — 시간 예산을 두고 넘기면 포기한다)
    if area_sqm and area_sqm > 0:
        pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="price")
        try:
            future = pool.submit(
                _actual_trade_candidate, address, area_sqm, run_id=run_id, today=today
            )
            trade, trade_notes = future.result(timeout=MARKET_PRICE_BUDGET_SECONDS)
            notes.extend(trade_notes)
            if trade is not None:
                candidates.append(trade)
        except FuturesTimeout:
            notes.append(
                f"[실거래가] {MARKET_PRICE_BUDGET_SECONDS}초 안에 끝나지 않아 "
                "이번 분석에서는 건너뛰었습니다"
            )
        except Exception as e:  # noqa: BLE001
            _log.error("[시세] 실거래가 조회에서 예기치 못한 예외", exc_info=True)
            notes.append(f"[실거래가] 조회 중 오류 ({type(e).__name__})")
        finally:
            # 예산을 넘긴 작업은 취소할 수 없다(requests가 자기 타임아웃으로 끝난다).
            # 기다리지 않고 넘어간다 — 사용자를 붙잡아 두지 않는 것이 목적이다.
            pool.shutdown(wait=False)
    else:
        notes.append("[실거래가] 전용면적을 읽지 못해 조회하지 않았습니다 (면적 없이는 매칭 불가)")

    return _finish(candidates, notes)


def _log_note(note: str) -> None:
    """안내 한 줄을 로그에 남긴다.

    · 이미 `[...]` 로 시작하는 문구에 `[시세]`를 덧붙이지 않는다(접두어 중복 방지).
    · 여러 줄짜리 안내(빌드 방법 등)는 **첫 줄만** 남긴다 — 전문은 `notes`에 있고,
      로그를 5줄씩 잡아먹으면 정작 중요한 결정 로그가 묻힌다.
    """
    first = note.splitlines()[0].strip()
    more = " (자세한 내용은 리포트 notes 참고)" if "\n" in note else ""
    _log.info(first + more if first.startswith("[") else f"[시세] {first}{more}")


def _finish(candidates: list[PriceCandidate], notes: list[str]) -> ResolvedPrice:
    # 이유(왜 못 찾았나)를 먼저, 결론(무엇을 채택했나)을 나중에 — 사람이 읽는 순서다.
    for n in notes:
        _log_note(n)
    resolved = R.resolve(candidates)
    R.log_decision(resolved)
    return ResolvedPrice(
        price_won=resolved.price_won,
        source=resolved.source,
        as_of=resolved.as_of,
        sample_count=resolved.sample_count,
        gap_pct=resolved.gap_pct,
        gap_direction=resolved.gap_direction,
        candidates=resolved.candidates,
        notes=notes,
    )
