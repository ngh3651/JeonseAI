"""손실 예상 — "이 집이 경매로 넘어가면 보증금이 얼마나 돌아오나" (2026-10-28, 손실 시뮬레이터 1단계).

**규칙 계산이다. AI가 개입하지 않는다.** 숫자는 전부 두 곳에서만 온다.
  ① 리포트에 이미 있는 값 — 보증금 · 시세(판정에 쓴 그 값) · 먼저 갚을 빚(채권최고액 합계)
  ② `data/auction_sale_rates.json` — 대법원 법원경매정보 매각통계를 **사람이 옮겨 적은** 지역·용도별 매각가율

계산 (한 줄):
    예상 낙찰가 = 시세 × 매각가율
    돌려받을 돈 = min(보증금, max(0, 예상 낙찰가 − 먼저 갚을 빚))
    못 돌려받는 돈 = 보증금 − 돌려받을 돈

지켜야 하는 것 (보수적 편향 — 애매하면 더 위험하게):
- **시세가 없으면 계산하지 않는다**(`no_price`). 예전 화면은 보증금을 기준가로 썼는데, 근거 없는 숫자다.
- **빚이 시세 이상이면 매각가율을 볼 것도 없다**(`debt_exceeds`). 어떤 값에 팔려도 내 차례가 오지 않는다.
- **용도를 모르면 후보 중 가장 낮은 매각가율**을 쓴다(`useGuessed`). 빌라를 아파트 값으로 계산하면 가장 위험한 집을
  가장 낙관적으로 보여 준다.
- **그 지역 표본이 적으면 전국 값**(`regionFallback`) — 몇 건짜리 값은 흔들린다.
- 매각가율 자료가 없으면 지어내지 않는다(`no_rate`).
- 매각가율은 **감정가 대비**다. 감정가가 없어 시세에 곱한다 — 화면이 이 사실을 말한다.
- 경매 비용·세금·최우선변제는 아직 넣지 않았다(2단계). 화면이 이 사실을 말한다.

판정 등급과는 무관하다(참고 정보). 판정 엔진은 이 파일을 모른다.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from pathlib import Path

from ..schemas.contract import LossEstimate, Report
from . import price_normalize as N
from . import price_resolver as R

_log = logging.getLogger("jeonseai")

RATES_PATH = Path(__file__).resolve().parents[2] / "data" / "auction_sale_rates.json"

#: 지역 값을 쓰려면 매각 건수가 이만큼은 돼야 한다 — 아래면 전국 값으로 올린다.
#: 근거: 매각가율은 금액 가중 비율이라 몇 건짜리는 한두 건의 고가·저가 낙찰에 좌우된다. 30은 통상적인 '작은 표본' 경계.
MIN_SOLD = 30

#: 용도 이름 (데이터 파일·화면 공통)
APT, ROW, OFFI, DETACHED, MULTI = "아파트", "연립다세대", "오피스텔", "단독주택", "다가구주택"
USES = (APT, ROW, OFFI, DETACHED, MULTI)

#: 실거래가·공시가격 유형 코드 → 용도
_HOUSE_TYPE_TO_USE = {"apt": APT, "row_house": ROW, "officetel": OFFI}

#: 데이터 파일에 사람이 적은 용도 표기 → 표준 이름 (사이트 표기가 조금씩 달라도 받는다)
_USE_ALIASES = {
    "아파트": APT,
    "연립다세대": ROW, "연립·다세대": ROW, "연립/다세대": ROW, "다세대": ROW, "연립": ROW, "빌라": ROW,
    "다세대(빌라)": ROW, "연립주택": ROW, "다세대주택": ROW,
    "오피스텔": OFFI, "오피스텔(주거)": OFFI,
    "단독주택": DETACHED, "단독": DETACHED,
    "다가구주택": MULTI, "다가구": MULTI, "다가구(원룸등)": MULTI,
}

#: 시도 표준 이름 — 주소 앞머리의 여러 표기를 받는다
_SIDO = (
    ("서울", ("서울특별시", "서울시", "서울")),
    ("부산", ("부산광역시", "부산시", "부산")),
    ("대구", ("대구광역시", "대구시", "대구")),
    ("인천", ("인천광역시", "인천시", "인천")),
    ("광주", ("광주광역시", "광주시")),  # ⚠ '광주'만으로는 경기 광주시와 헷갈려 받지 않는다
    ("대전", ("대전광역시", "대전시", "대전")),
    ("울산", ("울산광역시", "울산시", "울산")),
    ("세종", ("세종특별자치시", "세종시", "세종")),
    ("경기", ("경기도", "경기")),
    ("강원", ("강원특별자치도", "강원도", "강원")),
    ("충북", ("충청북도", "충북")),
    ("충남", ("충청남도", "충남")),
    ("전북", ("전북특별자치도", "전라북도", "전북")),
    ("전남", ("전라남도", "전남")),
    ("경북", ("경상북도", "경북")),
    ("경남", ("경상남도", "경남")),
    ("제주", ("제주특별자치도", "제주도", "제주")),
)
NATION = "전국"


def sido_of(address: str | None) -> str | None:
    """주소 → 시도 표준 이름. '[집합건물] 서울특별시 …'도 받는다. 모르면 None (지어내지 않는다)."""
    text = re.sub(r"^\s*\[[^\]]*\]\s*", "", address or "").strip()
    first = text.split(" ", 1)[0] if text else ""
    for name, forms in _SIDO:
        if first in forms:
            return name
    return None


def _norm_region(value: object) -> str | None:
    v = str(value or "").strip()
    if v in (NATION, "전국계", "합계", "계"):
        return NATION
    for name, forms in _SIDO:
        if v == name or v in forms:
            return name
    # 데이터 파일엔 '광주'를 시도 이름으로 적어도 된다(파일은 시도 단위라 헷갈릴 일이 없다)
    if v == "광주":
        return "광주"
    return None


# ── 자료 ─────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class _Cell:
    """지역 × 용도 한 칸."""

    sold: int
    appraisal_sum: int | None
    sale_sum: int | None
    rate_pct: float | None

    @property
    def rate(self) -> float | None:
        """매각가율(0~). 합계가 있으면 합계로(금액 가중), 없으면 적힌 %."""
        if self.appraisal_sum and self.sale_sum and self.appraisal_sum > 0:
            return self.sale_sum / self.appraisal_sum
        if self.rate_pct is not None and self.rate_pct > 0:
            return self.rate_pct / 100
        return None


@dataclass(frozen=True)
class RateTable:
    source: str
    period: str
    cells: dict[tuple[str, str], _Cell]

    def lookup(self, region: str | None, use: str) -> tuple[float, int, str, bool] | None:
        """(매각가율, 매각 건수, 쓴 지역, 전국으로 올렸나). 없으면 None."""
        if region:
            cell = self.cells.get((region, use))
            if cell and cell.rate and cell.sold >= MIN_SOLD:
                return cell.rate, cell.sold, region, False
        nation = self.cells.get((NATION, use)) or self._sum_regions(use)
        if nation and nation.rate:
            return nation.rate, nation.sold, NATION, region is not None and region != NATION
        return None

    def _sum_regions(self, use: str) -> _Cell | None:
        """'전국' 줄이 없으면 시도 줄을 더해 만든다 — 합계가 다 있을 때만(%만 있으면 매각 건수로 가중)."""
        rows = [c for (r, u), c in self.cells.items() if u == use and r != NATION and c.rate]
        if not rows:
            return None
        sold = sum(c.sold for c in rows)
        if all(c.appraisal_sum and c.sale_sum for c in rows):
            return _Cell(sold, sum(c.appraisal_sum for c in rows), sum(c.sale_sum for c in rows), None)  # type: ignore[misc]
        if sold <= 0:
            return None
        pct = sum((c.rate or 0) * 100 * c.sold for c in rows) / sold
        return _Cell(sold, None, None, pct)


def _int(v: object) -> int | None:
    if v is None or v == "":
        return None
    try:
        return int(str(v).replace(",", "").strip())
    except ValueError:
        return None


def _float(v: object) -> float | None:
    if v is None or v == "":
        return None
    try:
        return float(str(v).replace("%", "").replace(",", "").strip())
    except ValueError:
        return None


def parse_table(raw: dict) -> RateTable:
    """데이터 파일 → 표. 알아볼 수 없는 줄은 **로그를 남기고 건너뛴다**(한 줄 실수로 전체를 잃지 않게)."""
    cells: dict[tuple[str, str], _Cell] = {}
    for i, row in enumerate(raw.get("rows") or []):
        region = _norm_region(row.get("region"))
        use = _USE_ALIASES.get(str(row.get("use") or "").replace(" ", ""))
        sold = _int(row.get("sold"))
        if region is None or use is None or sold is None:
            _log.error(f"[손실예상] 매각가율 자료 {i + 1}번째 줄을 읽지 못해 건너뜁니다 — region·use·sold를 확인하세요")
            continue
        cell = _Cell(sold, _int(row.get("appraisalSum")), _int(row.get("saleSum")), _float(row.get("ratePct")))
        if cell.rate is None:
            _log.error(f"[손실예상] 매각가율 자료 {i + 1}번째 줄({region}·{use})에 감정가·매각가 합계나 매각가율이 없어 건너뜁니다")
            continue
        cells[(region, use)] = cell
    return RateTable(source=str(raw.get("source") or ""), period=str(raw.get("period") or ""), cells=cells)


_cache: tuple[float, RateTable] | None = None


def load_table(path: Path = RATES_PATH) -> RateTable:
    """파일이 바뀌면 다시 읽는다(서버를 다시 켜지 않아도 새 숫자가 나간다). 못 읽으면 빈 표."""
    global _cache
    try:
        mtime = path.stat().st_mtime
        if _cache and _cache[0] == mtime:
            return _cache[1]
        table = parse_table(json.loads(path.read_text(encoding="utf-8")))
        _cache = (mtime, table)
        return table
    except Exception as e:  # noqa: BLE001 — 자료가 깨져도 리포트·화면은 산다(no_rate)
        _log.error(f"[손실예상] ⚠ 매각가율 자료를 읽지 못했습니다 ({type(e).__name__}) — 손실 예상은 '자료 없음'으로 나갑니다")
        return RateTable(source="", period="", cells={})


# ── 용도 ─────────────────────────────────────────────────────────────────────


def house_types_from(candidates: list[R.PriceCandidate], address: str | None) -> list[str]:
    """이 집의 용도 후보 — 분석 때 한 번 정해 리포트(`houseTypes`)에 남긴다.

    ① 통건물 등기(단독·다가구로 의심) → 단독주택·다가구주택
    ② 실거래가가 매칭됐으면 그 거래의 유형 — 같은 지번·면적의 거래라 가장 강한 신호
    ③ 공시가격·기준시가가 매칭됐으면 그 유형(공동주택 공시가격은 아파트·연립다세대 중 어느 쪽인지 모른다)
    ④ 아무것도 없으면 집합건물 세 용도 전부(→ 가장 낮은 값을 쓰게 된다)
    """
    if address and N.is_whole_building(address):
        return [DETACHED, MULTI]
    trade = [c for c in candidates if c.source == R.SOURCE_ACTUAL_TRADE and c.house_types]
    picked: set[str] = set()
    if trade:
        for c in trade:
            picked.update(c.house_types)
    else:
        for c in candidates:
            if c.source in R.PUBLIC_SOURCES:
                picked.update(c.house_types)
    uses = [_HOUSE_TYPE_TO_USE[h] for h in ("apt", "row_house", "officetel") if h in picked]
    return uses or [APT, ROW, OFFI]


def _uses_for(report: Report) -> list[str]:
    known = [u for u in report.houseTypes if u in USES]
    if known:
        return known
    # houseTypes가 생기기 전(2026-10-28 전) 리포트 — 주소만으로 판단, 모르면 집합건물 세 용도
    addr = report.propertyAddress or report.address
    if addr and N.is_whole_building(addr):
        return [DETACHED, MULTI]
    return [APT, ROW, OFFI]


# ── 계산 ─────────────────────────────────────────────────────────────────────


def estimate(report: Report, table: RateTable | None = None) -> LossEstimate:
    """리포트 → 손실 예상. 예외를 던지지 않는다(못 하면 no_price / no_rate)."""
    table = table or load_table()
    deposit = int(report.deposit or 0)
    debt = int(report.seniorDebtAmount or 0)
    base = report.marketPrice if report.marketPrice and report.marketPrice > 0 else None
    common = dict(deposit=deposit, basePrice=base, seniorDebt=debt, source=table.source or None,
                  period=table.period or None)

    if base is None:
        return LossEstimate(status="no_price", **common)
    if debt >= base:
        # 어떤 값에 팔려도 시세를 넘지 않는 한 빚을 다 갚지 못한다 — 매각가율을 볼 필요가 없다
        return LossEstimate(status="debt_exceeds", expectedReturn=0, expectedLoss=deposit, **common)

    region = sido_of(report.propertyAddress) or sido_of(report.address)
    uses = _uses_for(report)
    found = [(use, hit) for use in uses if (hit := table.lookup(region, use)) is not None]
    if not found:
        return LossEstimate(status="no_rate", **common)
    # 용도를 모르면 가장 낮은 매각가율 — 같으면 앞 순서(아파트 → 연립다세대 → 오피스텔 …)
    use, (rate, sold, used_region, fallback) = min(found, key=lambda x: x[1][0])

    sale = int(base * rate)
    back = min(deposit, max(0, sale - debt))
    return LossEstimate(
        status="ok",
        ratePct=round(rate * 100, 1),
        region=used_region,
        regionFallback=fallback,
        use=use,
        useGuessed=len(uses) > 1,
        soldCount=sold,
        expectedSale=sale,
        expectedReturn=back,
        expectedLoss=deposit - back,
        **common,
    )
