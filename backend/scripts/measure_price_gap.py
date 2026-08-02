"""실거래가 ↔ 공시 기준 **괴리 측정** CLI (데이터 도착 후 실행용).

무엇을 확정하기 위한 도구인가:
  ① 공시가격 × 140% 가 실제로 실거래가 수준인가 (HUG 배수 검증)
  ② 오피스텔 기준시가를 배수 없이 그대로 써도 되는가
  ③ 괴리 임계값(`price_resolver.TRADE_INFLATED_GAP_PCT` 등)을 어디에 둘 것인가

⚠ **지금은 실행할 수 없다.** 공시가격·기준시가 SQLite가 있어야 하고,
  실거래가 API 키도 필요하다. 준비 상태는 `python scripts/price_status.py`로 확인한다.

사용법:
    # 시군구 코드로 표본을 모아 잰다 (여러 개 줄 수 있다)
    python scripts/measure_price_gap.py --lawd 11680 --lawd 11470 --limit 100

    # 특정 소스만
    python scripts/measure_price_gap.py --lawd 11680 --source tax_base

어떻게 재나:
  ⑴ 지정한 시군구의 최근 6개월 실거래를 모은다(운영과 같은 경로).
  ⑵ 각 거래의 (읍면동·지번·전용면적)으로 공시/기준시가 DB를 조회한다.
  ⑶ 실거래가 ÷ 공시기준값 비율의 분포(중앙값·사분위·최소·최대)를 낸다.
  ⑷ 이상치(실거래가만 비정상적으로 높은 건)를 뽑아 공통점을 볼 수 있게 나열한다.

⚠ 출력에 주소·지번을 **찍지 않는다** — 법정동코드·면적·비율까지만 남긴다.
  (이상치 목록도 마찬가지다. 어느 물건인지 특정되면 안 된다.)
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from datetime import date
from pathlib import Path
from statistics import median, quantiles

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.services import market_price as MP  # noqa: E402
from app.services import official_price as OP  # noqa: E402
from app.services import price_normalize as N  # noqa: E402
from app.services import price_resolver as R  # noqa: E402
from app.services import price_sources as PS  # noqa: E402
from app.services import thresholds as T  # noqa: E402


def pct(values: list[float], q: int) -> float:
    if len(values) < 4:
        return values[0] if values else 0.0
    return quantiles(sorted(values), n=4)[q - 1]


def main() -> int:
    ap = argparse.ArgumentParser(description="실거래가 ↔ 공시 기준 괴리 측정")
    ap.add_argument("--lawd", action="append", required=True, help="시군구 코드 5자리 (여러 번 가능)")
    ap.add_argument("--months", type=int, default=MP.DEFAULT_MONTHS, help="조회 개월 수")
    ap.add_argument("--limit", type=int, default=100, help="시군구당 최대 표본 수")
    ap.add_argument(
        "--source",
        choices=PS.ALL_SOURCES,
        help="한 소스만 잰다 (기본: 둘 다 — 실거래 유형에 맞는 쪽이 자연히 걸린다)",
    )
    ap.add_argument("--outliers", type=int, default=10, help="나열할 이상치 개수")
    args = ap.parse_args()

    sources = [args.source] if args.source else list(PS.ALL_SOURCES)
    ready = []
    for key in sources:
        cfg = PS.load(key)
        if cfg.ready and OP.db_meta(key):
            ready.append(key)
        else:
            print(f"[건너뜀] {cfg.label} — 아직 준비되지 않았습니다 (price_status.py 참고)")
    if not ready:
        print("\n[중단] 잴 수 있는 공시 기준 소스가 하나도 없습니다.")
        return 2

    today = date.today()
    rows: list[dict] = []

    for lawd_cd in args.lawd:
        print(f"\n── {lawd_cd} · 최근 {args.months}개월 실거래 수집 ──")
        try:
            trades, errors = MP.collect_trades(lawd_cd, months=args.months, today=today)
        except MP.MarketPriceError as e:
            print(f"  [실패] {e.detail}")
            continue
        for msg in errors[:3]:
            print(f"  [일부 실패] {msg}")
        usable = [t for t in trades if not t.canceled and t.jibun and t.area_sqm > 0]
        print(f"  거래 {len(trades)}건 (해제·결측 제외 {len(usable)}건)")

        seen: set[tuple] = set()
        for t in usable:
            key = (t.umd_nm, MP.normalize_jibun(t.jibun), round(t.area_sqm, 2))
            if key in seen:
                continue
            seen.add(key)
            if len(seen) > args.limit:
                break
            # 조회 키를 직접 넣는다 — 실거래가 응답에는 동·호가 없으므로
            # **면적으로만** 좁힌다(운영보다 느슨한 매칭이라는 점을 감안해 읽을 것).
            for source_key in ready:
                r, _ = OP.lookup_by_key(
                    source_key,
                    lawd_codes=[lawd_cd],
                    jibun=MP.normalize_jibun(t.jibun),
                    area_sqm=t.area_sqm,
                )
                if r is None:
                    continue
                if r.price_won <= 0:
                    continue
                ratio = t.price_won / r.price_won
                rows.append(
                    {
                        "lawd_cd": lawd_cd,
                        "house_type": t.house_type,
                        "source": source_key,
                        "area": t.area_sqm,
                        "trade": t.price_won,
                        "base": r.base_price_won,
                        "house_price": r.price_won,
                        "ratio": ratio,
                        "gap_pct": R.compute_gap_pct(t.price_won, r.price_won),
                        "match": r.match_method,
                        "matched_count": r.matched_count,
                    }
                )

    if not rows:
        print("\n[결과 없음] 실거래와 공시 기준이 함께 걸린 물건이 하나도 없습니다.")
        print("  · 지역을 넓히거나(--lawd 추가) --limit 을 올려 보세요.")
        print("  · 공시가격 DB를 --region 으로 좁게 빌드했다면 그 지역으로 재 보세요.")
        return 1

    print("\n" + "═" * 74)
    print(f" 결과 — 표본 {len(rows)}건")
    print("═" * 74)

    by_source: dict[str, list[dict]] = {}
    for r in rows:
        by_source.setdefault(r["source"], []).append(r)

    for source_key, group in sorted(by_source.items()):
        ratios = [g["ratio"] for g in group]
        gaps = [g["gap_pct"] for g in group if g["gap_pct"] is not None]
        label = PS.load(source_key).label
        print(f"\n[{label}]  표본 {len(group)}건")
        print(f"  실거래가 ÷ (우리가 시세로 쓰는 값) 비율")
        print(f"    최소 {min(ratios):.2f} · Q1 {pct(ratios, 1):.2f} · 중앙 {median(ratios):.2f}"
              f" · Q3 {pct(ratios, 3):.2f} · 최대 {max(ratios):.2f}")
        if gaps:
            print(f"  괴리율(%)")
            print(f"    최소 {min(gaps):+d} · Q1 {pct([float(g) for g in gaps], 1):+.0f}"
                  f" · 중앙 {median(gaps):+.0f} · Q3 {pct([float(g) for g in gaps], 3):+.0f}"
                  f" · 최대 {max(gaps):+d}")
        types = Counter(g["house_type"] for g in group)
        print("  주택유형: " + " · ".join(f"{MP.HOUSE_TYPE_LABELS[k]} {v}건" for k, v in types.items()))
        matches = Counter(g["match"] for g in group)
        print("  매칭 방법: " + " · ".join(f"{k} {v}건" for k, v in matches.items()))

        if source_key == PS.SOURCE_OFFICIAL_PRICE:
            base_ratios = [g["trade"] / g["base"] for g in group if g["base"] > 0]
            print(
                f"\n  ▸ 현재 배수 {T.PUBLIC_PRICE_TO_HOUSE_PRICE_RATIO} 검증:"
                f" 실거래가 ÷ 공시가격(배수 적용 전) 중앙값 = {median(base_ratios):.2f}"
            )
            print(
                "    이 값이 곧 '공시가격을 몇 배 하면 실거래가가 되는가'다."
                f" 지금 우리가 쓰는 {T.PUBLIC_PRICE_TO_HOUSE_PRICE_RATIO}와 크게 다르면"
                " decisions.md에 기록하고 thresholds.py를 고친다."
            )
        if source_key == PS.SOURCE_TAX_BASE:
            print(
                "\n  ▸ 기준시가를 배수 없이 그대로 쓰는 것이 맞는지 확인:"
                f" 위 비율의 중앙값이 {median(ratios):.2f}다."
                " 1.0에서 크게 벗어나면 '그대로 쓴다'는 결정을 재검토해야 한다."
            )

    print("\n" + "═" * 74)
    print(f" 이상치 — 실거래가가 유난히 높은 {args.outliers}건 (부풀림 의심 후보)")
    print("═" * 74)
    print("  ⚠ 주소·지번은 찍지 않는다. 공통점은 유형·면적·매칭 방법으로 본다.")
    hot = sorted(rows, key=lambda r: -r["ratio"])[: args.outliers]
    print(f"  {'코드':<7}{'유형':<12}{'면적':>8}  {'실거래':>14}  {'우리값':>14}  {'비율':>6}  매칭")
    for r in hot:
        print(
            f"  {r['lawd_cd']:<7}{MP.HOUSE_TYPE_LABELS[r['house_type']]:<12}"
            f"{r['area']:>8.2f}  {r['trade']:>14,}  {r['house_price']:>14,}"
            f"  {r['ratio']:>6.2f}  {r['match']}"
        )
    hot_types = Counter(r["house_type"] for r in hot)
    print("\n  이상치의 유형 분포: " + " · ".join(
        f"{MP.HOUSE_TYPE_LABELS[k]} {v}건" for k, v in hot_types.items()
    ))
    print(
        f"\n  현재 잠정 임계값: 부풀림 의심 {R.TRADE_INFLATED_GAP_PCT:+d}% 이상 /"
        f" 하락 의심 {R.TRADE_DEPRESSED_GAP_PCT:+d}% 이하"
    )
    above = sum(1 for r in rows if (r["gap_pct"] or 0) >= R.TRADE_INFLATED_GAP_PCT)
    below = sum(1 for r in rows if (r["gap_pct"] or 0) <= R.TRADE_DEPRESSED_GAP_PCT)
    print(
        f"  그 기준이면 표본의 {above}/{len(rows)}건({above / len(rows) * 100:.1f}%)이 '부풀림 의심',"
        f" {below}건({below / len(rows) * 100:.1f}%)이 '하락 의심'으로 걸린다."
    )
    print(
        "\n  → 이 비율이 지나치게 높으면(정상 물건이 대부분 걸리면) 임계값을 올리고,"
        "\n    0에 가까우면 내린다. 정한 값과 근거를 docs/decisions.md에 기록한 뒤"
        "\n    price_resolver.py의 상수를 고친다."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
