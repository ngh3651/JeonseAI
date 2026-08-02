"""공시가격·기준시가 조회 — 실거래가가 없는 집에도 시세를 붙이기 위한 두 번째 경로.

왜 필요한가 (2026-08-03):
실거래가는 **거래가 있어야 값이 생긴다.** 실측한 두 등기부 모두 실패했다 —
114.756㎡ 아파트는 6개월간 같은 면적 거래 없음, 55.56㎡ 다세대는 같은 지번 거래 자체가
없음. 필터를 느슨하게 해서 풀 수 있는 문제가 아니라 **구조적 한계**다.
그런데 `marketPrice`가 비면 전세가율뿐 아니라 **선순위채권 비율 판정(60%·80%)까지
함께 죽고**, 종합 등급이 절대 '양호'가 될 수 없다 — 등급이 변별력을 잃는다.

공시가격·기준시가는 정부가 **매년 전수 산정**하므로 이 한계가 없다.

| 소스 | 대상 | 기준일 | 형태 |
|---|---|---|---|
| 국토부 공동주택 공시가격 | 아파트·연립·다세대 호별 | 매년 1월 1일 | CSV → SQLite |
| 국세청 오피스텔 기준시가 | 오피스텔 호별 | 매년 1월 1일 | CSV → SQLite |

⚠ 이 모듈은 **판정 규칙을 만들지 않는다.** `marketPrice` 값 하나를 돌려줄 뿐이고,
  판정은 기존 `rule_engine`이 그 값으로 한다.
⚠ **모르면 None.** 인접 평형·평균·추정으로 채우지 않는다.
⚠ 로그에 주소·번지·읍면동을 남기지 않는다 — **법정동코드(시군구 5자리)까지만.**
"""

from __future__ import annotations

import logging
import sqlite3
from dataclasses import dataclass
from pathlib import Path

from . import market_price, price_normalize as N, price_sources as PS, thresholds as T
from .price_sources import PriceSourceNotReady

_log = logging.getLogger("jeonseai")

_BACKEND_ROOT = Path(__file__).resolve().parents[2]
PRICE_DIR = _BACKEND_ROOT / "data" / "price"
RAW_DIR = PRICE_DIR / "raw"

DB_FILENAMES = {
    PS.SOURCE_OFFICIAL_PRICE: "official_price.sqlite",
    PS.SOURCE_TAX_BASE: "tax_base.sqlite",
}

TABLE_NAME = "price_row"
META_TABLE = "price_meta"
SCHEMA_VERSION = 1

# 면적 허용오차 — 실거래가 매칭과 **같은 값을 쓴다**(market_price.AREA_TOLERANCE_RATIO).
# 근거도 같다: 등기부 전유면적과 공적 장부의 전용면적은 같은 건축물대장에서 나오므로
# 값 자체는 일치하고, 허용오차는 OCR 반올림을 흡수하기 위한 것이다.
AREA_TOLERANCE_RATIO = market_price.AREA_TOLERANCE_RATIO


def db_path(source_key: str) -> Path:
    return PRICE_DIR / DB_FILENAMES[source_key]


# ── 결과 ─────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class OfficialPriceResult:
    """조회 결과. **숫자만 돌려주지 않는다** — 기준일·출처·매칭 방법이 항상 따라붙는다."""

    price_won: int  # 우리가 시세로 쓸 값 (주택가격)
    base_price_won: int  # 원자료 값 (공시가격 또는 기준시가 그대로)
    multiplier: float  # base → price 로 갈 때 곱한 배수 (기준시가는 1.0)
    source_key: str  # 'official_price' | 'tax_base'
    source_name: str  # 사람이 읽는 출처명
    as_of: str  # 기준일 'YYYY-MM-DD'
    match_method: str  # 'dong_ho' | 'ho' | 'area' | 'jibun_single'
    matched_count: int  # 같은 조건에 걸린 행 수 (2건 이상이면 최저가를 골랐다)
    lawd_cd: str
    area_sqm: float | None  # 매칭된 행의 전용면적
    area_basis: str  # 'exclusive' | 'exclusive_plus_common' — 가격이 어떤 면적 기준인지
    area_mismatch: bool  # 동·호는 맞는데 면적이 허용오차를 벗어남


# ── 조회 ─────────────────────────────────────────────────────────────────────


def _connect(source_key: str) -> sqlite3.Connection | None:
    """읽기 전용 연결. 열 수 없으면 `sqlite3.Error`를 그대로 올린다(호출부가 안내로 바꾼다)."""
    path = db_path(source_key)
    if not path.is_file():
        return None
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def db_meta(source_key: str) -> dict[str, str] | None:
    """빌드된 DB의 메타(기준일·행 수·원본 파일 등). 없으면 None."""
    conn = _connect(source_key)
    if conn is None:
        return None
    try:
        rows = conn.execute(f"SELECT key, value FROM {META_TABLE}").fetchall()
        return {r["key"]: r["value"] for r in rows}
    except sqlite3.Error:
        return None
    finally:
        conn.close()


def missing_db_guide(source_key: str) -> str:
    cfg_label = {
        PS.SOURCE_OFFICIAL_PRICE: "공동주택 공시가격",
        PS.SOURCE_TAX_BASE: "오피스텔 기준시가",
    }[source_key]
    return (
        f"{cfg_label} 데이터베이스가 없습니다: {db_path(source_key)}\n"
        f"  ① 원본 CSV/ZIP을 {RAW_DIR} 에 둔다\n"
        f"  ② python scripts/inspect_price_source.py <원본파일> --source {source_key} --write\n"
        f"  ③ backend/data/price_sources.json 을 검토하고 verified 를 true 로\n"
        f"  ④ python scripts/build_price_db.py --source {source_key} <원본파일>\n"
        f"  진행 상황 확인: python scripts/price_status.py"
    )


def _select_rows(conn: sqlite3.Connection, lawd_cd: str, jibun: str) -> list[sqlite3.Row]:
    return conn.execute(
        f"SELECT * FROM {TABLE_NAME} WHERE lawd_cd = ? AND jibun = ?", (lawd_cd, jibun)
    ).fetchall()


def _narrow(
    rows: list[sqlite3.Row], *, dong: str, ho: str, area_sqm: float | None
) -> tuple[list[sqlite3.Row], str, bool] | None:
    """행 후보를 좁힌다. 좁힐 근거가 하나도 없으면 `None`(추측하지 않는다)."""
    area_ok: list[sqlite3.Row] = []
    if area_sqm and area_sqm > 0:
        lo, hi = area_sqm * (1 - AREA_TOLERANCE_RATIO), area_sqm * (1 + AREA_TOLERANCE_RATIO)
        area_ok = [r for r in rows if r["area_sqm"] is not None and lo <= r["area_sqm"] <= hi]

    unit_pool: list[sqlite3.Row] = []
    method = ""
    if ho:
        by_ho = [r for r in rows if (r["ho_nm"] or "") == ho]
        if dong:
            by_dong_ho = [r for r in by_ho if (r["dong_nm"] or "") == dong]
            if by_dong_ho:
                unit_pool, method = by_dong_ho, "dong_ho"
        if not unit_pool and by_ho:
            # 동이 없거나 동까지는 못 맞춘 경우 — 호만으로 좁힌다.
            # 단, 같은 지번에 동이 여럿인데 호만 맞은 것은 **여러 동의 같은 호수**일 수
            # 있으므로 그대로 두고(matched_count로 드러난다), 아래에서 최저가를 고른다.
            unit_pool, method = by_ho, "ho"

    if unit_pool:
        if area_ok:
            # ⚠ `r in area_ok` 로 쓰지 않는다 — sqlite3.Row 의 동등 비교에 기대면
            #   값이 같은 다른 행까지 같다고 볼 수 있다. id()로 같은 객체만 고른다.
            area_ids = {id(r) for r in area_ok}
            both = [r for r in unit_pool if id(r) in area_ids]
            if both:
                return both, method, False
            return unit_pool, method, True  # 동·호는 맞는데 면적이 어긋남 → 플래그
        return unit_pool, method, False

    if area_ok:
        return area_ok, "area", False

    if len(rows) == 1 and not (area_sqm and area_sqm > 0):
        # 지번에 딱 한 건이고 면적 정보 자체가 없을 때만 인정한다.
        return rows, "jibun_single", False

    return None


def _multiplier_for(source_key: str) -> tuple[float, str]:
    """소스별 (환산 배수, 면적 기준). 근거는 thresholds.py 주석에 있다."""
    if source_key == PS.SOURCE_OFFICIAL_PRICE:
        return T.PUBLIC_PRICE_TO_HOUSE_PRICE_RATIO, "exclusive"
    # 기준시가에는 환산 배수가 없다 — 공식이 존재하지 않는다(2026-08-03 사용자 결정).
    # 다만 국세청 산식이 '단위면적 기준시가 × (전용+공유)'라 **면적 기준이 다르다**.
    # 실거래가(전용면적 기준)와 비교할 때 이 차이를 화면에서 밝힌다.
    return 1.0, "exclusive_plus_common"


def lookup(
    source_key: str, *, address: str, area_sqm: float | None
) -> tuple[OfficialPriceResult | None, list[str]]:
    """주소 문자열로 조회. `(결과|None, 안내·실패 메시지 목록)`.

    실패를 예외로 던지지 않는다 — 시세 조회 실패가 리포트를 실패시키면 안 된다.
    대신 사람이 읽을 수 있는 메시지를 목록으로 돌려준다.
    """
    parts = market_price.parse_address_parts(address)
    if parts is None:
        try:
            label = PS.load(source_key).label
        except PriceSourceNotReady:
            label = source_key
        return None, [f"[{label}] 주소에서 시군구·지번을 읽지 못해 조회하지 않았습니다"]
    return lookup_by_key(
        source_key,
        lawd_codes=parts.lawd_codes,
        jibun=parts.jibun,
        dong=N.extract_dong(address),
        ho=N.extract_ho(address),
        area_sqm=area_sqm,
    )


def lookup_by_key(
    source_key: str,
    *,
    lawd_codes: list[str],
    jibun: str,
    dong: str = "",
    ho: str = "",
    area_sqm: float | None = None,
) -> tuple[OfficialPriceResult | None, list[str]]:
    """이미 뽑아 둔 조회 키로 조회한다 (측정 스크립트가 주소 문자열 없이 쓴다)."""
    notes: list[str] = []
    try:
        cfg = PS.load(source_key)
        cfg.require_ready()
    except PriceSourceNotReady as e:
        return None, [str(e)]

    try:
        conn = _connect(source_key)
    except sqlite3.Error as e:
        return None, [
            f"[{cfg.label}] 데이터베이스를 열지 못했습니다 ({type(e).__name__}: {e})\n"
            + missing_db_guide(source_key)
        ]
    if conn is None:
        return None, [missing_db_guide(source_key)]

    try:
        if not jibun:
            notes.append(f"[{cfg.label}] 지번을 알 수 없어 조회하지 않았습니다")
            return None, notes
        for lawd_cd in lawd_codes:
            rows = _select_rows(conn, lawd_cd, jibun)
            if not rows:
                continue
            narrowed = _narrow(rows, dong=dong, ho=ho, area_sqm=area_sqm)
            if narrowed is None:
                notes.append(
                    f"[{cfg.label}] {lawd_cd} 지번에 {len(rows)}건이 있으나 "
                    "동·호·면적 중 무엇으로도 특정하지 못해 채우지 않았습니다"
                )
                continue
            pool, method, area_mismatch = narrowed
            # 여러 건이면 **최저가**를 고른다 — 시세를 높게 잡으면 전세가율이 낮아져
            # 위험한 집을 안전하다고 말하게 된다(미탐). 보수적 편향의 방향은 그 반대다.
            picked = min(pool, key=lambda r: r["price_won"])
            multiplier, area_basis = _multiplier_for(source_key)
            base = int(picked["price_won"])
            result = OfficialPriceResult(
                price_won=int(round(base * multiplier)),
                base_price_won=base,
                multiplier=multiplier,
                source_key=source_key,
                source_name=cfg.source_name,
                as_of=str(picked["as_of"] or cfg.as_of or ""),
                match_method=method,
                matched_count=len(pool),
                lawd_cd=lawd_cd,
                area_sqm=picked["area_sqm"],
                area_basis=area_basis,
                area_mismatch=area_mismatch,
            )
            _log.info(
                f"[시세] {cfg.label} 조회 — {lawd_cd} · {result.as_of} 기준 · "
                f"매칭 {method} {len(pool)}건 → "
                f"{base:,}원 × {multiplier} = {result.price_won:,}원"
                + (" ⚠ 동·호는 맞지만 면적 불일치" if area_mismatch else "")
            )
            return result, notes

        notes.append(f"[{cfg.label}] 해당 지번을 찾지 못했습니다 (조회 코드 {len(lawd_codes)}개 시도)")
        return None, notes
    except sqlite3.Error as e:
        # DB 파일이 손상됐거나 스키마가 다를 때 — 조용히 넘기지 않는다.
        return None, [
            f"[{cfg.label}] 데이터베이스를 읽지 못했습니다 ({type(e).__name__}: {e}). "
            f"다시 빌드하세요: python scripts/build_price_db.py --source {source_key} <원본파일>"
        ]
    finally:
        conn.close()


def lookup_all(
    *, address: str, area_sqm: float | None
) -> tuple[list[OfficialPriceResult], list[str]]:
    """공시가격·기준시가를 **둘 다** 조회한다.

    등기부만으로는 아파트인지 오피스텔인지 확실히 알 수 없다(표제부 '건물내역'은
    표기가 제각각이다). 유형을 판별해 한쪽만 부르면 오판했을 때 통째로 못 찾는다.
    두 소스 모두 지번·호수로 좁히므로 엉뚱한 값이 나올 수 없고, 둘 다 나오면
    **낮은 쪽**을 쓰는 규칙(`price_resolver`)이 이어받는다.
    """
    results: list[OfficialPriceResult] = []
    notes: list[str] = []
    for key in PS.ALL_SOURCES:
        r, ns = lookup(key, address=address, area_sqm=area_sqm)
        notes.extend(ns)
        if r is not None:
            results.append(r)
    return results, notes


# ── 참고 계산 (판정에 쓰지 않음) ─────────────────────────────────────────────


def hug_recognized_limit(public_price_won: int) -> int:
    """HUG가 담보로 인정하는 최대 금액 = 공시가격 × 140% × 담보인정비율 90%.

    ⚠ **이 값을 `marketPrice`로 쓰지 않는다.** `marketPrice`는 '집값'이어야 하고,
      담보인정비율 90%는 이미 `thresholds.COMBINED_RATIO_DANGER_PCT`가 판정 단계에서
      적용한다. 여기서 한 번 더 곱하면 같은 비율을 두 번 적용하는 셈이 된다.
      이 함수는 진단·설명용이다(예: "HUG 기준으로는 최대 X원까지 인정").

    126%를 상수 하나로 박지 않는 이유: 제도가 한쪽만 바뀔 수 있다.
    """
    return int(
        round(
            public_price_won
            * T.PUBLIC_PRICE_TO_HOUSE_PRICE_RATIO
            * T.HUG_COLLATERAL_RECOGNITION_RATIO
        )
    )
