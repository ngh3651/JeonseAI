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
  가장 낙관적으로 보여 준다. 화면엔 고른 값만 나간다(설명 문구 없음 — 2026-10-28 규혁).
- 통건물(단독·다가구 의심)은 **단독·다가구 소계**(겸용 포함) 한 값 — 표본이 가장 크다.
- **그 지역 표본이 적거나, 주소의 시·도를 못 알아보면 전국 값**(`regionFallback`) — 에러를 내지 않는다.
  시·도 표기는 옛 이름·새 이름(강원도/강원특별자치도, 전라북도/전북특별자치도 등)을 모두 받는다.
- 사용자가 시뮬레이터에서 매매 시세를 직접 넣으면 그 값으로만 계산한다(`price`) — 리포트는 바뀌지 않는다.
- 매각가율 자료가 없으면 지어내지 않는다(`no_rate`).
- 매각가율은 **감정가 대비**다. 감정가가 없어 시세에 곱한다.
- 경매 비용·세금은 아직 넣지 않았다.
- 2026-10-31: 소액임차인 **최우선변제**를 넣었다(`priority_repayment.py`). 낙찰가에서 **가장 먼저** 내 몫으로 빠지고,
  남은 돈에서 먼저 갚을 빚이 빠진 뒤 내 차례가 온다:
      돌려받을 돈 = min(보증금, 최우선 + max(0, 예상 낙찰가 − 최우선 − 먼저 갚을 빚))
  날짜를 못 읽었거나·다가구·이미 경매 중이면 더하지 않는다(보수적 편향).

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
#: 단독·다가구 소계(단독 + 다가구 + 겸용) — 통건물은 이 값을 쓴다
HOUSE = "단독·다가구"
USES = (APT, ROW, OFFI, DETACHED, MULTI, HOUSE)

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
    "단독·다가구": HOUSE, "단독다가구": HOUSE, "단독/다가구": HOUSE, "단독·다가구소계": HOUSE,
}

#: 시도 표준 이름 — 주소 앞머리의 여러 표기를 받는다
_SIDO = (
    ("서울", ("서울특별시", "서울시", "서울")),
    ("부산", ("부산광역시", "부산시", "부산")),
    ("대구", ("대구광역시", "대구시", "대구")),
    ("인천", ("인천광역시", "인천시", "인천")),
    ("광주", ("광주광역시",)),  # ⚠ '광주'·'광주시'만으로는 경기 광주시와 헷갈려 받지 않는다
    ("대전", ("대전광역시", "대전시", "대전")),
    ("울산", ("울산광역시", "울산시", "울산")),
    ("세종", ("세종특별자치시", "세종시", "세종")),
    ("경기", ("경기도", "경기")),
    ("강원", ("강원특별자치도", "강원자치도", "강원도", "강원")),
    ("충북", ("충청북도", "충북")),
    ("충남", ("충청남도", "충남")),
    ("전북", ("전북특별자치도", "전북자치도", "전라북도", "전북")),
    ("전남", ("전라남도", "전남")),
    ("경북", ("경상북도", "경북")),
    ("경남", ("경상남도", "경남")),
    ("제주", ("제주특별자치도", "제주도", "제주")),
)
#: 통합 특별시(예: 전남광주통합특별시) — 뒤 시·군·구로 광주/전남을 가른다
_MERGED_GJ = ("전남광주통합특별시", "광주전남통합특별시", "전남광주특별시", "광주전남특별시")
_GWANGJU_GU = ("동구", "서구", "남구", "북구", "광산구")
#: 모든 표기, 긴 것부터 (붙여 쓴 주소 '서울특별시강남구'도 앞머리로 맞춘다)
_FORMS = sorted(((f, n) for n, fs in _SIDO for f in fs), key=lambda x: -len(x[0]))
NATION = "전국"


def sido_of(address: str | None) -> str | None:
    """주소 → 시도 표준 이름. '[집합건물] 서울특별시 …'도 받는다. 모르면 None (지어내지 않는다)."""
    text = re.sub(r"^\s*\[[^\]]*\]\s*", "", address or "").strip()
    if not text:
        return None
    for merged in _MERGED_GJ:
        if text.startswith(merged):
            rest = text[len(merged):].strip().split(" ", 1)[0]
            return "광주" if rest in _GWANGJU_GU else "전남"
    first = text.split(" ", 1)[0]
    for form, name in _FORMS:
        if first == form:
            return name
    # 띄어쓰기 없이 붙은 주소 — 2글자 약칭('서울'·'경기')은 붙은 글자가 다른 뜻일 수 있어 정식 이름만 앞머리로 본다
    for form, name in _FORMS:
        if len(form) >= 3 and form.endswith(("시", "도")) and first.startswith(form):
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
        # 전국 줄은 데이터 파일에 **적힌 것만** 쓴다 — 받은 시·도만 더해 '전국'인 척하지 않는다
        nation = self.cells.get((NATION, use))
        if nation and nation.rate:
            return nation.rate, nation.sold, NATION, region != NATION
        return None


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


def house_types_from(
    candidates: list[R.PriceCandidate], address: str | None, *, registry_use: str | None = None
) -> list[str]:
    """이 집의 용도 후보 — 분석 때 한 번 정해 리포트(`houseTypes`)에 남긴다.

    ① 통건물 등기(단독·다가구로 의심) → 단독·다가구(소계 한 값)
    ② **등기부 표제부 건물내역의 용도**('4층 다세대주택' → 연립다세대, 2026-10-31) — 서류 자체에 적힌 말이라 가장 강하다
    ③ 실거래가가 매칭됐으면 그 거래의 유형 — 같은 지번·면적의 거래
    ④ 공시가격·기준시가가 매칭됐으면 그 유형(공동주택 공시가격은 아파트·연립다세대 중 어느 쪽인지 모른다)
    ⑤ 아무것도 없으면 집합건물 세 용도 전부(→ 가장 낮은 값을 쓰게 된다)
    """
    if address and N.is_whole_building(address):
        return [HOUSE]
    if registry_use in (APT, ROW, OFFI, HOUSE):
        return [registry_use]
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


def chosen_use(report: Report, table: "RateTable | None" = None) -> str | None:
    """손실 예상이 **실제로 쓰는** 용도 하나 — 후보가 여럿이면 그 지역 매각가율이 가장 낮은 것(`estimate`와 같은 규칙)."""
    uses = _uses_for(report)
    if len(uses) == 1:
        return uses[0]
    try:
        table = table or load_table()
        region = sido_of(report.propertyAddress) or sido_of(report.address)
        found = [(use, hit) for use in uses if (hit := table.lookup(region, use)) is not None]
        return min(found, key=lambda x: x[1][0])[0] if found else uses[0]
    except Exception:  # noqa: BLE001 — 표시 한 줄용이다
        return uses[0]


def _uses_for(report: Report) -> list[str]:
    known = [u for u in report.houseTypes if u in USES]
    # 단독주택·다가구주택 두 후보로 남긴 리포트(10-28 첫 배포분) → 소계 한 값
    if known and set(known) <= {DETACHED, MULTI, HOUSE}:
        return [HOUSE]
    if known:
        return known
    # houseTypes가 생기기 전(2026-10-28 전) 리포트 — 주소만으로 판단, 모르면 집합건물 세 용도
    addr = report.propertyAddress or report.address
    if addr and N.is_whole_building(addr):
        return [HOUSE]
    return [APT, ROW, OFFI]


# ── 계산 ─────────────────────────────────────────────────────────────────────


def _priority_fields(report: Report, sale: int | None) -> tuple[int, dict]:
    """최우선변제 → (돌려받음에 더할 금액, 계약 칸들). 실패해도 0과 빈 칸(손실 계산은 그대로 산다)."""
    from . import priority_repayment as P  # 순환 import 방지(그쪽이 sido_of를 이 파일에서 가져간다)

    try:
        pr = P.compute(
            deposit=int(report.deposit or 0),
            address=report.propertyAddress or report.address,
            risk_facts=report.riskFacts,
            senior_debt=int(report.seniorDebtAmount or 0),
            expected_sale=sale,
            whole_building=N.is_whole_building(report.propertyAddress or report.address or ""),
        )
    except Exception:  # noqa: BLE001 — 최우선변제 하나 때문에 손실 계산을 잃지 않는다
        _log.error("[최우선변제] ⚠ 계산 실패 — 최우선변제 없이 계산합니다", exc_info=True)
        return 0, {}
    fields = dict(
        priorityStatus=pr.status,
        priorityAmount=pr.amount if pr.status == "ok" else 0,
        priorityLimit=pr.limit,
        priorityCap=pr.cap,
        priorityRegion=pr.region,
        priorityRegionUnsure=pr.region_unsure,
        priorityTableFrom=pr.table_from,
        priorityBaseDate=pr.base_date,
        priorityBaseKind=pr.base_kind,
        priorityHalfCapped=pr.half_capped,
        prioritySource=pr.source,
        priorityTableStale=_table_stale(),
    )
    return (pr.amount if pr.status == "ok" else 0), fields


def _table_stale() -> bool:
    try:
        from . import law_watch

        return law_watch.priority_table_stale()
    except Exception:  # noqa: BLE001
        return False


def estimate(
    report: Report, table: RateTable | None = None, price: int | None = None, *, priority: bool = True
) -> LossEstimate:
    """리포트 → 손실 예상. 예외를 던지지 않는다(못 하면 no_price / no_rate).

    [price]: 시뮬레이터에서 사용자가 넣은 매매 시세(원). 있으면 리포트 시세 대신 쓴다 — 리포트는 바꾸지 않는다.
    [priority]: 최우선변제를 더할지(2026-10-31). 4장 질문 합격선은 **더하지 않고** 본다 — 최우선변제는 전입·입주
      시점 같은 조건이 붙는 돈이라, '빚을 그대로 둬도 된다'는 판단에 기대지 않게 한다(보수적 편향).
    """
    table = table or load_table()
    deposit = int(report.deposit or 0)
    debt = int(report.seniorDebtAmount or 0)
    if price is not None and price > 0:
        base: int | None = int(price)
    else:
        base = report.marketPrice if report.marketPrice and report.marketPrice > 0 else None
    common = dict(deposit=deposit, basePrice=base, seniorDebt=debt, source=table.source or None,
                  period=table.period or None)

    region = sido_of(report.propertyAddress) or sido_of(report.address)
    uses = _uses_for(report)
    found = [(use, hit) for use in uses if (hit := table.lookup(region, use)) is not None]
    picked = min(found, key=lambda x: x[1][0]) if found else None
    if base is None:
        # 시세가 없어도 쓸 매각가율은 정해진다 — 화면이 '낙찰가 N%' 꼬리표를 먼저 보여 준다
        # 최우선변제 한도도 알린다(낙찰가를 몰라 절반 한도는 아직 못 본다 — 더하지 않는다)
        pfields = _priority_fields(report, None)[1] if priority else {}
        if picked is None:
            return LossEstimate(status="no_price", **common, **pfields)
        use, (rate, sold, used_region, fallback) = picked
        return LossEstimate(status="no_price", ratePct=round(rate * 100, 1), region=used_region,
                            regionFallback=fallback, use=use, useGuessed=len(uses) > 1, soldCount=sold,
                            **common, **pfields)
    if picked is None:
        if debt >= base:
            # 매각가율 자료가 없어도 빚 ≥ 시세면 답이 정해진다 — 어떤 값에 팔려도 내 차례가 오지 않는다.
            # 화면은 ok와 같은 모양(0원 · 막대 전부 빨강)으로 그리고, 낙찰가 줄만 뺀다 (2026-10-28 화면 하나로)
            return LossEstimate(status="debt_exceeds", expectedReturn=0, expectedLoss=deposit, **common)
        return LossEstimate(status="no_rate", **common)
    # 용도를 모르면 가장 낮은 매각가율 — 같으면 앞 순서(아파트 → 연립다세대 → 오피스텔 …)
    use, (rate, sold, used_region, fallback) = picked

    sale = int(base * rate)
    first, pfields = _priority_fields(report, sale) if priority else (0, {})
    # 최우선변제가 낙찰가에서 가장 먼저 빠지고(내 몫), 남은 돈에서 먼저 갚을 빚 → 그다음 내 차례
    back = min(deposit, first + max(0, sale - first - debt))
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
        **pfields,
    )
