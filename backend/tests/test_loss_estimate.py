"""손실 예상 (2026-10-28) — 지역·용도별 매각가율로 '경매로 가면 보증금이 얼마나 돌아오나'. 규칙 계산, AI 없음."""

from __future__ import annotations

import json

from app.schemas.contract import Report
from app.services import loss_estimate as L
from app.services import price_resolver as R
from app.services import store
from tests.test_analyze_smoke import client  # noqa: F401 — pytest 픽스처 재사용


def _report(**over) -> Report:
    base = dict(
        id="le-1",
        alias="테스트",
        address="[집합건물] 서울특별시 서초구 서초동 1557-8 제3층 제301호",
        analyzedAt="2026-10-28T10:00:00+09:00",
        grade="위험",
        gaugeProgress=0.9,
        headline="h",
        nextAction="n",
        topRiskSummary="t",
        deposit=150_000_000,
        marketPrice=400_000_000,
        seniorDebtAmount=200_000_000,
        evidences=[],
        houseTypes=["연립다세대"],
    )
    base.update(over)
    return Report(**base)


def _table(rows, period="2025.11~2026.10") -> L.RateTable:
    return L.parse_table({"source": "대법원 법원경매정보 매각통계", "period": period, "rows": rows})


SEOUL = [
    {"region": "서울", "use": "아파트", "sold": 874, "ratePct": 98.9},
    {"region": "서울", "use": "연립·다세대", "sold": 4808, "appraisalSum": 1_000_000_000, "saleSum": 750_000_000},
    {"region": "서울", "use": "오피스텔", "sold": 1424, "ratePct": 71.7},
    {"region": "전국", "use": "단독·다가구", "sold": 900, "ratePct": 70.0},
]


def test_지역_용도_매각가율로_돌려받을_돈을_계산한다():
    est = L.estimate(_report(), _table(SEOUL))
    assert est.status == "ok"
    assert est.region == "서울" and est.use == "연립다세대"
    assert est.ratePct == 75.0  # 합계로(금액 가중)
    assert est.expectedSale == 300_000_000  # 4억 × 75%
    assert est.expectedReturn == 100_000_000  # 3억 − 빚 2억
    assert est.expectedLoss == 50_000_000
    assert est.soldCount == 4808 and est.period == "2025.11~2026.10"
    assert not est.useGuessed and not est.regionFallback


def test_돌려받을_돈은_보증금을_넘지_않는다():
    est = L.estimate(_report(seniorDebtAmount=0), _table(SEOUL))
    assert est.expectedReturn == 150_000_000 and est.expectedLoss == 0


def test_빚이_집값_이상이면_전부_못_받는다():
    """실기기: 시세 5.7억에 빚 19억. 자료가 있으면 같은 계산(0원), 없어도 답은 0원(debt_exceeds)."""
    big = dict(marketPrice=572_600_000, seniorDebtAmount=1_900_000_000)
    est = L.estimate(_report(**big), _table(SEOUL))
    assert est.status == "ok" and est.expectedReturn == 0 and est.expectedLoss == 150_000_000
    assert est.ratePct == 75.0
    est = L.estimate(_report(**big), _table([]))
    assert est.status == "debt_exceeds"
    assert est.expectedReturn == 0 and est.expectedLoss == 150_000_000 and est.ratePct is None


def test_시세가_없으면_계산하지_않는다():
    """예전 화면은 보증금을 기준가로 썼다 — 근거 없는 숫자다. 쓸 매각가율은 먼저 알려 준다(낙찰가 꼬리표)."""
    est = L.estimate(_report(marketPrice=None), _table(SEOUL))
    assert est.status == "no_price" and est.expectedLoss is None and est.expectedReturn is None
    assert est.ratePct == 75.0 and est.region == "서울" and est.basePrice is None


def test_시뮬레이터에서_넣은_매매_시세로_계산한다():
    """price를 주면 그 값으로만 계산 — 리포트 시세는 그대로다."""
    r = _report(marketPrice=None)
    est = L.estimate(r, _table(SEOUL), price=300_000_000)
    assert est.status == "ok" and est.basePrice == 300_000_000
    assert est.expectedSale == 225_000_000 and est.expectedReturn == 25_000_000
    assert r.marketPrice is None
    est = L.estimate(_report(), _table(SEOUL), price=500_000_000)
    assert est.basePrice == 500_000_000 and est.expectedReturn == 150_000_000


def test_자료가_없으면_지어내지_않는다():
    est = L.estimate(_report(), _table([]))
    assert est.status == "no_rate" and est.ratePct is None


def test_용도를_모르면_후보_중_가장_낮은_값():
    est = L.estimate(_report(houseTypes=["아파트", "연립다세대", "오피스텔"]), _table(SEOUL))
    assert est.use == "오피스텔" and est.ratePct == 71.7 and est.useGuessed


def test_지역_표본이_적으면_전국_값():
    rows = [
        {"region": "제주", "use": "연립다세대", "sold": 5, "ratePct": 95.0},
        {"region": "전국", "use": "연립다세대", "sold": 14603, "ratePct": 66.1},
    ]
    est = L.estimate(_report(address="제주특별자치도 제주시 연동 1-1 제101호"), _table(rows))
    assert est.region == "전국" and est.regionFallback
    assert est.ratePct == 66.1 and est.soldCount == 14603


def test_전국_줄이_없으면_시도를_더해_만들지_않는다():
    """받은 시·도만 더한 값은 전국이 아니다 — 그 지역 값이 없으면 '준비 중'."""
    rows = [{"region": "서울", "use": "연립다세대", "sold": 100, "appraisalSum": 100, "saleSum": 80}]
    est = L.estimate(_report(address="부산광역시 해운대구 우동 1 제101호"), _table(rows))
    assert est.status == "no_rate"


def test_시도를_못_알아보면_전국_값():
    rows = [{"region": "전국", "use": "연립다세대", "sold": 14603, "ratePct": 66.1}]
    est = L.estimate(_report(address="어딘가 이상한 주소 1-1", propertyAddress=None), _table(rows))
    assert est.status == "ok" and est.region == "전국" and est.ratePct == 66.1


def test_전국_줄이_있으면_그것을_쓴다():
    est = L.estimate(_report(address="부산광역시 해운대구 우동 1 제101호", houseTypes=["다가구주택"]), _table(SEOUL))
    assert est.region == "전국" and est.use == "단독·다가구" and est.ratePct == 70.0


def test_통건물_등기는_단독_다가구로_본다():
    assert L.house_types_from([], "[건물] 서울특별시 관악구 신림동 1-1") == ["단독·다가구"]


def test_예전_단독_다가구_두_후보는_소계_한_값으로():
    rows = [
        {"region": "서울", "use": "단독주택", "sold": 69, "ratePct": 69.0},
        {"region": "서울", "use": "단독·다가구", "sold": 276, "ratePct": 70.9},
    ]
    est = L.estimate(_report(address="[건물] 서울특별시 관악구 신림동 1-1", houseTypes=["단독주택", "다가구주택"]), _table(rows))
    assert est.use == "단독·다가구" and est.ratePct == 70.9 and not est.useGuessed


def test_실거래가가_매칭되면_그_유형():
    trade = R.PriceCandidate(price_won=1, source=R.SOURCE_ACTUAL_TRADE, source_name="", as_of="", house_types=("row_house",))
    public = R.PriceCandidate(price_won=1, source=R.SOURCE_OFFICIAL_PRICE, source_name="", as_of="", house_types=("apt", "row_house"))
    assert L.house_types_from([trade, public], "[집합건물] 서울특별시 서초구 서초동 1 제1호") == ["연립다세대"]
    assert L.house_types_from([public], "[집합건물] 서울특별시 서초구 서초동 1 제1호") == ["아파트", "연립다세대"]
    assert L.house_types_from([], "[집합건물] 서울특별시 서초구 서초동 1 제1호") == ["아파트", "연립다세대", "오피스텔"]


def test_시도_표기():
    assert L.sido_of("[집합건물] 서울특별시 서초구 서초동") == "서울"
    assert L.sido_of("전북특별자치도 전주시") == "전북"
    assert L.sido_of("경기도 광주시 오포읍") == "경기"
    assert L.sido_of("광주 북구") is None  # 경기 광주와 헷갈린다 — 지어내지 않는다(→ 전국 값)
    assert L.sido_of("광주광역시 북구 용봉동") == "광주"
    assert L.sido_of(None) is None
    # 옛 이름 · 새 이름 · 붙여 쓴 주소
    assert L.sido_of("강원도 춘천시 효자동") == "강원"
    assert L.sido_of("[집합건물] 강원특별자치도 원주시 단계동") == "강원"
    assert L.sido_of("전라북도 전주시 완산구") == "전북"
    assert L.sido_of("제주특별자치도 서귀포시") == "제주"
    assert L.sido_of("세종특별자치시 한솔동") == "세종"
    assert L.sido_of("서울특별시강남구 역삼동") == "서울"
    assert L.sido_of("충청남도 천안시") == "충남"
    # 통합 특별시 — 뒤 구·군으로 가른다
    assert L.sido_of("전남광주통합특별시 광산구 수완동") == "광주"
    assert L.sido_of("전남광주통합특별시 순천시 조례동") == "전남"


def test_깨진_줄은_건너뛰고_나머지는_쓴다():
    t = _table([{"region": "화성", "use": "아파트", "sold": 1, "ratePct": 90}, *SEOUL])
    assert ("서울", "아파트") in t.cells and len(t.cells) == 4


def test_자료_파일이_깨져도_빈_표(tmp_path):
    bad = tmp_path / "rates.json"
    bad.write_text("{ 깨짐", encoding="utf-8")
    assert L.load_table(bad).cells == {}


def test_저장소의_자료_파일은_형식이_맞다():
    raw = json.loads(L.RATES_PATH.read_text(encoding="utf-8"))
    assert {"source", "period", "rows"} <= raw.keys()
    t = L.parse_table(raw)
    assert len(t.cells) == len(raw["rows"]), "읽지 못한 줄이 있다 — region·use·sold·합계를 확인"


def test_저장소_자료는_17개_시도와_전국을_모두_가진다():
    t = L.load_table()
    regions = {r for r, _ in t.cells}
    assert regions == {name for name, _ in L._SIDO} | {"전국"}
    for use in (L.APT, L.ROW, L.OFFI, L.HOUSE):
        assert (L.NATION, use) in t.cells, use
    # 대법원 매각통계 원본과 같은 값 (2025.11~2026.10, 소재지 기준)
    assert round(t.cells[("서울", L.ROW)].rate * 100, 1) == 75.4
    assert round(t.cells[(L.NATION, L.APT)].rate * 100, 1) == 84.9
    assert t.period == "2025.11~2026.10"


def test_엔드포인트는_부를_때마다_계산한다(client):
    device = "legacy-device"
    store.add(_report(id="le-api"), device_id=device)
    resp = client.get("/api/reports/le-api/loss-estimate")
    assert resp.status_code == 200, resp.text
    assert resp.json()["status"] == "ok"
    resp = client.get("/api/reports/le-api/loss-estimate?price=300000000")
    assert resp.status_code == 200 and resp.json()["basePrice"] == 300_000_000
    assert store.get("le-api", device_id=device).marketPrice == 400_000_000  # 리포트는 그대로
    assert client.get("/api/reports/le-api/loss-estimate?price=0").status_code == 422
    assert client.get("/api/reports/없는id/loss-estimate").status_code == 404
