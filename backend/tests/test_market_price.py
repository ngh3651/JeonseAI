"""실거래가 조회·집계 테스트 (STEP 5).

**API를 호출하지 않는다.** 필터·집계는 순수 함수라 픽스처만으로 검증된다.
파싱 테스트는 2026-07-29 실호출에서 받은 **실제 XML 형태**를 옮긴 것이다
(값은 합성 — 실주소·실지번을 이 파일에 적지 않는다).

⚠ 이 모듈은 판정에 개입하지 않는다. 여기 숫자는 위험 임계값이 아니다.
"""

from __future__ import annotations

from datetime import date

import pytest

from app.services import market_price as mp
from app.services.market_price import (
    MarketPriceError,
    Trade,
    aggregate,
    filter_trades,
    month_codes,
    normalize_jibun,
    parse_amount_won,
)

UMD = "합성동"
JIBUN = "1234"


def trade(
    *,
    area: float = 84.88,
    price: int = 1_000_000_000,
    umd: str = UMD,
    jibun: str = JIBUN,
    canceled: bool = False,
    y: int = 2026,
    m: int = 6,
    d: int = 15,
    house_type: str = "apt",
) -> Trade:
    return Trade(
        house_type=house_type,
        umd_nm=umd,
        jibun=jibun,
        area_sqm=area,
        price_won=price,
        deal_year=y,
        deal_month=m,
        deal_day=d,
        floor="10",
        building_name="합성아파트",
        canceled=canceled,
    )


# ── 금액 단위 ────────────────────────────────────────────────────────────────


def test_거래금액은_만원단위_문자열을_원으로_바꾼다():
    """실측 형태: <dealAmount>235,000</dealAmount> = 235,000만원 = 23.5억원."""
    assert parse_amount_won("235,000") == 2_350_000_000
    assert parse_amount_won("52,500") == 525_000_000
    assert parse_amount_won(" 12,000 ") == 120_000_000
    assert parse_amount_won("9500") == 95_000_000  # 콤마 없는 경우도 있다


def test_빈_거래금액은_거부한다():
    with pytest.raises(ValueError):
        parse_amount_won("   ")


# ── 지번 정규화 ─────────────────────────────────────────────────────────────


def test_지번_부번_표기():
    """실측: API는 '1234'·'727-6' 형태로 준다."""
    assert normalize_jibun("1234") == "1234"
    assert normalize_jibun("727-6") == "727-6"
    assert normalize_jibun("0727-006") == "727-6"  # 앞자리 0 제거
    assert normalize_jibun("1234-0") == "1234"  # 부번 0은 없는 것과 같다
    assert normalize_jibun("") == ""
    assert normalize_jibun("산") == ""


# ── 조회 월 목록 ────────────────────────────────────────────────────────────


def test_최근_N개월_코드는_과거순으로_나온다():
    codes = month_codes(6, today=date(2026, 7, 29))
    assert codes == ["202602", "202603", "202604", "202605", "202606", "202607"]


def test_연도를_넘어가도_월이_이어진다():
    codes = month_codes(3, today=date(2026, 2, 10))
    assert codes == ["202512", "202601", "202602"]


# ── 필터 ────────────────────────────────────────────────────────────────────


def test_지번이_다른_거래는_제외된다():
    trades = [trade(), trade(jibun="9999")]
    assert len(filter_trades(trades, umd_nm=UMD, jibun=JIBUN, area_sqm=84.88)) == 1


def test_읍면동이_다른_거래는_제외된다():
    """지번 숫자는 동마다 겹친다 — 읍면동까지 봐야 한다."""
    trades = [trade(), trade(umd="다른동")]
    assert len(filter_trades(trades, umd_nm=UMD, jibun=JIBUN, area_sqm=84.88)) == 1


def test_면적이_허용오차_밖이면_제외된다():
    """±1% — 실측상 등기부 면적과 API 면적은 정확히 일치한다(114.756 ↔ 114.756)."""
    trades = [
        trade(area=84.88),  # 정확 일치
        trade(area=85.5),  # +0.73% → 통과
        trade(area=59.82),  # 다른 평형 → 제외
        trade(area=114.756),  # 다른 평형 → 제외
    ]
    got = filter_trades(trades, umd_nm=UMD, jibun=JIBUN, area_sqm=84.88)
    assert sorted(t.area_sqm for t in got) == [84.88, 85.5]


def test_사실상_동일면적은_묶고_다른_평형은_제외한다():
    """실측: 같은 단지에 84.74·84.88(0.17% 차이)과 59.82가 함께 있다.

    ±1%(84.03~85.73)는 84.74를 **일부러 함께 담는다** — 같은 84타입이라 가격이 사실상
    같고, 표본이 늘면 Q1이 안정되기 때문이다. 막으려는 것은 59.82 같은 **다른 평형**이고,
    ±10%(76.4~93.4)였다면 그것까지 섞였을 것이다.
    """
    trades = [trade(area=84.74), trade(area=84.88), trade(area=59.82)]
    got = filter_trades(trades, umd_nm=UMD, jibun=JIBUN, area_sqm=84.88)
    assert sorted(t.area_sqm for t in got) == [84.74, 84.88]  # 59.82만 빠진다


def test_해제거래는_집계_전에_제외된다():
    """취소된 고가 거래가 섞이면 시세가 높아지고 → 전세가율이 낮게 나와 미탐이 된다.

    실측: 양천구 6개월 1,411건 중 41건(2.9%)이 cdealType='O'.
    """
    trades = [trade(price=1_000_000_000), trade(price=3_000_000_000, canceled=True)]
    got = filter_trades(trades, umd_nm=UMD, jibun=JIBUN, area_sqm=84.88)
    assert [t.price_won for t in got] == [1_000_000_000]


def test_면적이_없거나_0이면_아무것도_통과하지_않는다():
    """면적을 모르면 '이 집'을 특정할 수 없다 — 채우지 않는다."""
    trades = [trade()]
    assert filter_trades(trades, umd_nm=UMD, jibun=JIBUN, area_sqm=0) == []
    assert filter_trades(trades, umd_nm=UMD, jibun="", area_sqm=84.88) == []
    assert filter_trades(trades, umd_nm="", jibun=JIBUN, area_sqm=84.88) == []


# ── 집계 ────────────────────────────────────────────────────────────────────


def agg(prices: list[int]):
    return aggregate(
        [trade(price=p) for p in prices],
        period_from="2026-02",
        period_to="2026-07",
        months_used=6,
    )


def test_0건이면_None_추정하지_않는다():
    assert agg([]) is None


def test_1건이면_그_값을_쓴다():
    r = agg([1_500_000_000])
    assert r is not None
    assert r.price_won == 1_500_000_000
    assert r.sample_count == 1
    assert r.method == "min"


def test_표본_3건_이하는_최저가로_떨어진다():
    """분위수는 표본이 적으면 의미를 잃는다."""
    r = agg([1_800_000_000, 1_500_000_000, 2_000_000_000])
    assert r is not None
    assert r.price_won == 1_500_000_000
    assert r.method == "min"


def test_표본_4건_이상은_하위25_분위수를_쓴다():
    """평균·최고가·중앙값이 아니다 — 시세를 높게 잡으면 미탐 방향으로 틀린다."""
    prices = [1_000_000_000, 2_000_000_000, 3_000_000_000, 4_000_000_000]
    r = agg(prices)
    assert r is not None
    assert r.method == "quantile_25"
    # Q1은 최저가보다 크고 중앙값보다 작아야 한다 (보수편향 방향 유지)
    assert min(prices) <= r.price_won < 2_500_000_000  # 중앙값 = 25억


def test_채택값은_평균보다_낮다():
    """평균 금지 원칙이 실제로 지켜지는지 — 고가 이상치가 있을 때 특히 중요하다."""
    prices = [1_000_000_000, 1_100_000_000, 1_200_000_000, 5_000_000_000]
    r = agg(prices)
    assert r is not None
    assert r.price_won < sum(prices) / len(prices)


def test_집계결과에_기간과_건수가_반드시_붙는다():
    """숫자만 내려보내지 않는다 — '몇 월부터 몇 월까지 몇 건'이 항상 따라다닌다."""
    r = agg([1_000_000_000, 1_100_000_000])
    assert r is not None
    assert r.period_from == "2026-02"
    assert r.period_to == "2026-07"
    assert r.sample_count == 2
    assert r.months_used == 6
    assert r.source == "국토교통부 실거래가 공개시스템"


def test_표본_범위와_최근거래일이_함께_온다():
    """화면에는 계산 방식이 아니라 기간·건수·범위를 보여준다."""
    trades = [
        trade(price=1_000_000_000, y=2026, m=3, d=1),
        trade(price=2_000_000_000, y=2026, m=6, d=20),
    ]
    r = aggregate(trades, period_from="2026-02", period_to="2026-07", months_used=6)
    assert r is not None
    assert r.low_won == 1_000_000_000
    assert r.high_won == 2_000_000_000
    assert r.latest_deal_date == date(2026, 6, 20)


# ── XML 파싱 (실호출에서 받은 형태, 값은 합성) ──────────────────────────────


def _xml(items_xml: str, result_code: str = "000") -> str:
    return (
        '<?xml version="1.0" encoding="utf-8" standalone="yes"?>'
        f"<response><header><resultCode>{result_code}</resultCode>"
        "<resultMsg>OK</resultMsg></header>"
        f"<body><items>{items_xml}</items>"
        "<numOfRows>1000</numOfRows><pageNo>1</pageNo>"
        "<totalCount>1</totalCount></body></response>"
    )


ITEM = (
    "<item><aptDong> </aptDong><aptNm>합성아파트</aptNm><buildYear>2002</buildYear>"
    "<cdealDay> </cdealDay><cdealType> </cdealType><dealAmount>235,000</dealAmount>"
    "<dealDay>24</dealDay><dealMonth>6</dealMonth><dealYear>2026</dealYear>"
    "<excluUseAr>84.88</excluUseAr><floor>3</floor><jibun>1234</jibun>"
    "<sggCd>11470</sggCd><umdNm>합성동</umdNm></item>"
)


def test_XML_한건을_Trade로_옮긴다():
    got = mp._parse_items(_xml(ITEM), "apt")
    assert len(got) == 1
    t = got[0]
    assert t.price_won == 2_350_000_000
    assert t.area_sqm == 84.88
    assert t.umd_nm == "합성동"
    assert t.jibun == "1234"
    assert t.deal_date == date(2026, 6, 24)
    assert t.canceled is False
    assert t.building_name == "합성아파트"


def test_해제거래_표시를_읽는다():
    """실측: 정상 거래는 cdealType이 공백, 해제는 'O'."""
    canceled = ITEM.replace("<cdealType> </cdealType>", "<cdealType>O</cdealType>")
    assert mp._parse_items(_xml(canceled), "apt")[0].canceled is True


def test_거래가_없으면_빈_목록():
    assert mp._parse_items(_xml(""), "apt") == []


def test_HTTP200이어도_resultCode가_에러면_예외를_올린다():
    """본문에 에러가 담겨 오는 경우가 있다 — 200만 보고 넘기면 안 된다."""
    with pytest.raises(MarketPriceError) as exc:
        mp._parse_items(_xml("", result_code="30"), "apt")
    assert exc.value.status_code == 502


def test_깨진_XML은_예외를_올린다():
    with pytest.raises(MarketPriceError):
        mp._parse_items("<response><broken>", "apt")


def test_한_건이_깨져도_나머지는_살린다():
    """금액이 비어 있는 항목 하나 때문에 전체 조회가 무너지면 안 된다."""
    broken = ITEM.replace("<dealAmount>235,000</dealAmount>", "<dealAmount> </dealAmount>")
    got = mp._parse_items(_xml(broken + ITEM), "apt")
    assert len(got) == 1


def test_연립다세대는_다른_건물명_필드를_쓴다():
    """실측: 아파트는 aptNm, 연립다세대는 mhouseNm."""
    rh = ITEM.replace("<aptNm>합성아파트</aptNm>", "<mhouseNm>합성빌라</mhouseNm>")
    assert mp._parse_items(_xml(rh), "row_house")[0].building_name == "합성빌라"


# ── 주소 파싱 ───────────────────────────────────────────────────────────────

pytestmark_lawd = pytest.mark.skipif(
    not mp.lawd_code.LAWD_CODE_FILE.exists(), reason="lawd_codes.txt 없음"
)


@pytestmark_lawd
def test_주소에서_읍면동과_지번을_뽑는다():
    parts = mp.parse_address_parts("서울특별시 양천구 합성동 1234 합성아파트 제101동 제5층 제501호")
    assert parts is not None
    assert parts.umd_nm == "합성동"
    assert parts.jibun == "1234"
    assert "11470" in parts.lawd_codes


@pytestmark_lawd
def test_구가_있는_시는_구를_경계로_잡는다():
    """'경기도 수원시 장안구 ○○동 1'에서 읍면동은 4번째 토큰이다."""
    parts = mp.parse_address_parts("경기도 수원시 장안구 정자동 123-4")
    assert parts is not None
    assert parts.umd_nm == "정자동"
    assert parts.jibun == "123-4"


@pytestmark_lawd
def test_세종은_한_토큰이_경계다():
    parts = mp.parse_address_parts("세종특별자치시 어진동 500")
    assert parts is not None
    assert parts.umd_nm == "어진동"
    assert parts.jibun == "500"


@pytestmark_lawd
def test_지번이_숫자가_아니면_None():
    """'산 12-3' 같은 산번지 — 실거래가 표기 대응을 확인하지 못했으므로 추측하지 않는다."""
    assert mp.parse_address_parts("서울특별시 양천구 합성동 산 12-3") is None


@pytestmark_lawd
def test_법정동코드를_못_찾으면_None():
    assert mp.parse_address_parts("없는시도 없는구 없는동 1") is None


# ── 기간 확장 금지 (봉인) ───────────────────────────────────────────────────


def test_0건일_때_기간을_자동으로_넓히지_않는다(monkeypatch):
    """운영 경로는 6개월만 본다. 0건이면 None으로 끝난다.

    한때 '0건이면 12개월로 1회 확장'이 들어갔다가 되돌렸다 — 그 동작이 만든 값이
    8.5개월 전 거래 1건을 오늘의 시세로 쓰는 것이었다. 다시 들어오지 못하게 봉인한다.
    """
    calls: list[int] = []

    def fake_collect(lawd_cd, *, months, house_types, today, run_id):
        calls.append(months)
        return [], []  # 항상 0건

    monkeypatch.setattr(mp, "collect_trades", fake_collect)
    monkeypatch.setattr(mp, "_load_api_key", lambda: "dummy")

    result, _ = mp.lookup_market_price(
        lawd_cd="11470", umd_nm=UMD, jibun=JIBUN, area_sqm=84.88, today=date(2026, 7, 29)
    )
    assert result is None
    assert calls == [mp.DEFAULT_MONTHS]  # 6개월 한 번만. 재시도 없음
    assert not hasattr(mp, "FALLBACK_MONTHS")  # 확장 상수 자체가 없어야 한다


def test_매칭되면_6개월_결과를_그대로_쓴다(monkeypatch):
    def fake_collect(lawd_cd, *, months, house_types, today, run_id):
        return [trade(price=1_500_000_000)], []

    monkeypatch.setattr(mp, "collect_trades", fake_collect)
    result, _ = mp.lookup_market_price(
        lawd_cd="11470", umd_nm=UMD, jibun=JIBUN, area_sqm=84.88, today=date(2026, 7, 29)
    )
    assert result is not None
    assert result.months_used == 6
    assert result.period_from == "2026-02"
    assert result.period_to == "2026-07"


# ── 단독·다가구 제외 ────────────────────────────────────────────────────────


def test_단독다가구는_조회_대상에_없다():
    """실거래가 공개 정책상 지번이 일부만 제공돼 지번 매칭이 불가능하다.

    전세사기가 가장 많은 유형이라 이 한계는 숨기지 않고 문서에 명시한다.
    """
    assert "detached" not in mp.ENDPOINTS
    assert set(mp.ALL_HOUSE_TYPES) == {"apt", "row_house", "officetel"}
