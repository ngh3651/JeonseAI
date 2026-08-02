"""**대용량 합성 CSV 생성** — 실제 데이터가 오기 전에 규모를 흉내 내는 시험 도구.

왜 필요한가 (2026-08-03):
공동주택 공시가격은 1,500만 행을 넘길 수 있다. 실제 파일을 받은 날 처음으로
"메모리가 터진다 / 3시간 걸린다 / 인덱스가 없어 조회가 느리다"를 알게 되면 비싸다.
**규모는 데이터 없이도 흉내 낼 수 있으므로** 지금 재 둔다.

    python scripts/make_synthetic_price_csv.py --rows 10000000 --out data/price/synthetic_10m.csv
    python scripts/build_price_db.py data/price/synthetic_10m.csv --source official_price

⚠ 만들어진 파일은 **커밋 금지**다(`.gitignore`의 `backend/data/price/synthetic_*.csv`).
  측정이 끝나면 지운다. 남기는 것은 이 생성 스크립트뿐이다.
⚠ 컬럼 구조는 `tests/fixtures/price/official_price_sample.csv`와 같다 —
  즉 **우리 가정**이지 실제 파일 구조가 아니다.
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

HEADER = "단지코드,시도,시군구,읍면동,법정동코드,특수지구분,본번,부번,단지명,동명,호명,전용면적,공시가격,공시기준일"

# 실제 분포를 흉내 낸 값들. 정확할 필요는 없다 — 규모와 다양성이 목적이다.
# (법정동코드는 실재하는 시군구 코드에서 뽑아 lawd_cd 변환 경로도 함께 태운다.)
SIDO_SIGUNGU = [
    ("서울특별시", "강남구", "11680"), ("서울특별시", "양천구", "11470"),
    ("서울특별시", "노원구", "11350"), ("서울특별시", "송파구", "11710"),
    ("경기도", "성남시 분당구", "41135"), ("경기도", "수원시 장안구", "41111"),
    ("경기도", "고양시 일산동구", "41285"), ("경기도", "용인시 수지구", "41465"),
    ("인천광역시", "연수구", "28185"), ("부산광역시", "해운대구", "26350"),
    ("대구광역시", "수성구", "27260"), ("광주광역시", "서구", "29140"),
    ("대전광역시", "유성구", "30200"), ("울산광역시", "남구", "31140"),
    ("강원특별자치도", "춘천시", "51110"), ("전북특별자치도", "전주시 완산구", "52111"),
]
AREAS = [29.76, 39.52, 45.90, 49.53, 55.56, 59.82, 72.30, 74.19, 84.88, 84.97,
         99.60, 101.82, 114.76, 134.88, 148.20, 172.53]
# 면적 → 대략의 ㎡당 공시가격(원). 지역 배수와 곱해 쓴다.
BASE_PER_SQM = 6_000_000


def lcg(seed: int):
    """작은 선형합동생성기 — `Math.random` 없이 재현 가능한 난수를 만든다."""
    state = seed
    while True:
        state = (state * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        yield (state >> 33) / (1 << 31)


def main() -> int:
    ap = argparse.ArgumentParser(description="대용량 합성 공시가격 CSV 생성")
    ap.add_argument("--rows", type=int, default=10_000_000)
    ap.add_argument("--out", required=True)
    ap.add_argument("--encoding", default="cp949")
    ap.add_argument("--seed", type=int, default=20260803)
    args = ap.parse_args()

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    rnd = lcg(args.seed)

    t0 = time.perf_counter()
    written = 0
    # 한 줄씩 쓰되 버퍼를 크게 잡는다 — 1,000만 줄이라 flush 횟수가 곧 시간이다.
    with out.open("w", encoding=args.encoding, newline="", buffering=1 << 22) as f:
        f.write(HEADER + "\n")
        # 단지 하나당 여러 동·호를 만들어 실제와 비슷한 '같은 지번 다중 행'을 만든다.
        complex_no = 0
        while written < args.rows:
            complex_no += 1
            region = SIDO_SIGUNGU[int(next(rnd) * len(SIDO_SIGUNGU))]
            sido, sigungu, lawd = region
            bjd = lawd + f"{int(next(rnd) * 90) + 10:02d}" + "100"
            bon = int(next(rnd) * 2000) + 1
            bu = int(next(rnd) * 30) if next(rnd) < 0.35 else 0
            dongs = int(next(rnd) * 12) + 1
            floors = int(next(rnd) * 25) + 5
            per_floor = int(next(rnd) * 4) + 2
            area = AREAS[int(next(rnd) * len(AREAS))]
            region_mult = 0.5 + next(rnd) * 2.5
            umd = f"합성{complex_no % 97}동"
            name = f"합성{complex_no % 313}아파트"

            for d in range(1, dongs + 1):
                for fl in range(1, floors + 1):
                    for h in range(1, per_floor + 1):
                        if written >= args.rows:
                            break
                        ho = fl * 100 + h
                        # 층·호마다 조금씩 다르게 (같은 면적이라도 값이 갈리게)
                        price = int(area * BASE_PER_SQM * region_mult * (0.9 + fl * 0.004))
                        f.write(
                            f"A{complex_no:07d},{sido},{sigungu},{umd},{bjd},0,"
                            f"{bon},{bu},{name},{d * 100 + 1},{ho},{area},{price},20250101\n"
                        )
                        written += 1
                    if written >= args.rows:
                        break
                if written >= args.rows:
                    break
            if complex_no % 20000 == 0:
                print(f"  ... {written:,}행 ({time.perf_counter() - t0:.0f}초)", flush=True)

    size = out.stat().st_size
    print(
        f"\n생성 완료: {out}\n"
        f"  행 수  : {written:,}\n"
        f"  크기   : {size / (1 << 30):.2f} GB ({size / (1 << 20):,.0f} MB)\n"
        f"  인코딩 : {args.encoding}\n"
        f"  소요   : {time.perf_counter() - t0:.1f}초\n"
        f"\n⚠ 이 파일은 커밋하지 마세요. 측정이 끝나면 지웁니다."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
