"""실거래가 조회 검증 CLI (개발 도구 — 크레딧 없음, 공공 API).

주소·전용면적을 주면 법정동코드 후보 → 실거래가 조회 → 필터·집계까지 돌려
사람이 읽을 형태로 찍는다. **아직 앱·판정에 배선돼 있지 않다** — 숫자가 맞는지
터미널에서 먼저 확인하기 위한 도구다.

사용법:
    python scripts/check_market_price.py "<주소>" <전용면적> [--months 6] [--all]

    python scripts/check_market_price.py "서울특별시 ○○구 ○○동 1234" 84.88
    python scripts/check_market_price.py "..." 114.756 --months 12 --all

⚠ 실주소는 **인자로만** 넘긴다. 이 파일·테스트·문서에 실주소를 적지 않는다.
⚠ 출력에는 소유자 이름·등록번호가 나오지 않는다(실거래가 응답에 애초에 없다).
"""

from __future__ import annotations

import argparse
import sys
from datetime import date
from pathlib import Path
from statistics import median, quantiles

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.services import market_price as mp  # noqa: E402
from app.services.lawd_code import LawdCodeError, lawd_candidates  # noqa: E402


def won(v: float) -> str:
    """원 → '23억 5,000만원' 형태."""
    v = int(v)
    eok, rest = divmod(v, 100_000_000)
    man = rest // 10_000
    if eok and man:
        return f"{eok}억 {man:,}만원"
    if eok:
        return f"{eok}억원"
    return f"{man:,}만원"


def main() -> int:
    ap = argparse.ArgumentParser(description="국토부 실거래가 조회 검증")
    ap.add_argument("address", help="등기부 주소 (따옴표로 감쌀 것)")
    ap.add_argument("area", type=float, help="전용면적(㎡)")
    ap.add_argument("--months", type=int, default=None, help="조회 개월 수 (기본: 6→0건이면 12)")
    ap.add_argument("--all", action="store_true", help="매칭된 거래를 전부 나열")
    args = ap.parse_args()

    today = date.today()
    print(f"오늘: {today}  ·  전용면적: {args.area}㎡")

    # 1) 주소 → 법정동코드 후보
    try:
        candidates = lawd_candidates(args.address)
    except LawdCodeError as e:
        print(f"\n[중단] {e}")
        return 2
    if not candidates:
        print("\n[결과] 법정동코드를 찾지 못했습니다 → 시세를 채우지 않습니다(None).")
        return 1
    print("\n[1] 법정동코드 후보 (우선순위 순)")
    for c in candidates:
        print(f"    {c.lawd_cd}  {c.name}  ({'존재' if c.active else '폐지'})")

    parts = mp.parse_address_parts(args.address)
    if parts is None:
        print("\n[결과] 주소에서 읍면동·지번을 확정하지 못했습니다 → 시세를 채우지 않습니다(None).")
        return 1
    print(f"\n[2] 매칭 키 — 읍면동={parts.umd_nm}  지번={parts.jibun}")
    print("    (건물명·층·호는 쓰지 않습니다 — 등기부와 실거래가의 건물명이 다르고,")
    print("     공동주택의 동·호는 실거래가에 공개되지 않습니다)")

    # 2) 후보를 순서대로 시도 — 잘못된 코드도 '0건'으로 오므로 이 방법뿐이다
    month_plan = [args.months] if args.months else [mp.DEFAULT_MONTHS, mp.FALLBACK_MONTHS]
    matched: list[mp.Trade] = []
    used_code = None
    used_months = None
    for months in month_plan:
        for cand in candidates:
            trades, errors = mp.collect_trades(cand.lawd_cd, months=months, today=today)
            hit = mp.filter_trades(
                trades, umd_nm=parts.umd_nm, jibun=parts.jibun, area_sqm=args.area
            )
            same_jibun = [
                t
                for t in trades
                if t.umd_nm == parts.umd_nm
                and mp.normalize_jibun(t.jibun) == parts.jibun
                and not t.canceled
            ]
            print(
                f"\n[3] {cand.lawd_cd} · 최근 {months}개월 — 전체 {len(trades)}건 / "
                f"같은 지번 {len(same_jibun)}건 / 면적까지 일치 {len(hit)}건"
            )
            if errors:
                print(f"    조회 실패 {len(errors)}건: {errors[:2]}")
            if same_jibun and not hit:
                seen = sorted({t.area_sqm for t in same_jibun})
                print(f"    ⚠ 같은 지번의 전용면적: {seen}")
                print(f"      → {args.area}㎡와 ±{mp.AREA_TOLERANCE_RATIO:.0%} 안에서 일치하는 것이 없습니다.")
                print("        다른 평형 가격을 끌어다 쓰지 않습니다(추정 금지).")
            if hit:
                matched, used_code, used_months = hit, cand.lawd_cd, months
                break
        if matched:
            break

    if not matched:
        print("\n[결과] 조건에 맞는 거래가 없습니다 → **시세를 채우지 않습니다(None)**.")
        print("        전세가율은 '확인 필요'로 남고, 사용자가 직접 입력하게 됩니다.")
        return 1

    # 3) 집계 — 방식별로 나란히 찍어 실제 차이를 잰다
    period_from, period_to = mp._period_bounds(used_months, today)
    result = mp.aggregate(
        matched, period_from=period_from, period_to=period_to, months_used=used_months
    )
    assert result is not None
    prices = sorted(t.price_won for t in matched)

    print(f"\n[4] 집계 — {period_from} ~ {period_to} · {len(prices)}건 · LAWD_CD={used_code}")
    if used_months != mp.DEFAULT_MONTHS:
        print(f"    ⚠ 최근 {mp.DEFAULT_MONTHS}개월에는 거래가 없어 {used_months}개월로 넓혔습니다.")
    print(f"    최저가   {won(prices[0]):>16}")
    q1 = quantiles(prices, n=4)[0] if len(prices) >= mp.QUANTILE_MIN_SAMPLES else prices[0]
    print(f"    하위25%  {won(q1):>16}   ← 채택 방식")
    print(f"    중앙값   {won(median(prices)):>16}")
    print(f"    최고가   {won(prices[-1]):>16}")
    if len(prices) >= 2 and prices[0] > 0:
        print(
            f"    차이: 최저↔하위25% {(q1 - prices[0]) / prices[0] * 100:+.1f}%  ·  "
            f"하위25%↔중앙 {(median(prices) - q1) / q1 * 100:+.1f}%"
        )

    print(f"\n[5] 채택값 — {won(result.price_won)}  (방식 {result.method})")
    print(f"    표본 {result.sample_count}건 · {result.period_from} ~ {result.period_to}")
    print(f"    범위 {won(result.low_won)} ~ {won(result.high_won)}")
    print(f"    가장 최근 거래일 {result.latest_deal_date}")
    print(f"    출처 {result.source}")
    print("\n    화면 표기 예시(사용자용 — 계산 방식은 노출하지 않는다):")
    print(
        f"      \"최근 {result.months_used}개월 실거래 {result.sample_count}건 "
        f"({won(result.low_won)}~{won(result.high_won)})\""
    )

    if args.all:
        print("\n[6] 매칭된 거래 전부")
        for t in sorted(matched, key=lambda x: x.deal_date):
            print(
                f"    {t.deal_date}  {t.area_sqm:>9}㎡  {won(t.price_won):>16}  "
                f"{t.floor:>3}층  [{mp.HOUSE_TYPE_LABELS[t.house_type]}] {t.building_name}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
