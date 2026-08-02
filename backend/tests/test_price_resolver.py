"""시세 채택 규칙·괴리 탐지·배선 테스트 (2026-08-03).

⚠ 네트워크를 쓰지 않는다. `price_resolver`는 순수 함수라 후보 목록만으로 검증되고,
  `price_lookup`은 조회 함수를 monkeypatch 해서 본다.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.schemas.internal import Grade, RegistryExtract
from app.services import price_lookup as PL
from app.services import price_resolver as R
from app.services import questions, report_builder, rule_engine

FIXTURES = Path(__file__).parent / "fixtures" / "registry"


def cand(price: int, source: str, *, as_of: str = "2025-01-01", n: int | None = None):
    return R.PriceCandidate(
        price_won=price,
        source=source,
        source_name=R.SOURCE_LABELS[source],
        as_of=as_of,
        sample_count=n,
    )


# ── 채택 규칙: 낮은 쪽 ───────────────────────────────────────────────────────


def test_후보가_없으면_전부_None이고_추정하지_않는다():
    r = R.resolve([])
    assert r.price_won is None and r.source is None and r.gap_pct is None


def test_둘_다_있으면_낮은_쪽을_쓴다():
    r = R.resolve([cand(1_050_000_000, R.SOURCE_ACTUAL_TRADE, n=5), cand(200_000_000, R.SOURCE_OFFICIAL_PRICE)])
    assert r.price_won == 200_000_000
    assert r.source == R.SOURCE_OFFICIAL_PRICE


def test_평균을_쓰지_않는다():
    r = R.resolve([cand(1_000_000_000, R.SOURCE_ACTUAL_TRADE), cand(500_000_000, R.SOURCE_OFFICIAL_PRICE)])
    assert r.price_won == 500_000_000  # 평균 7.5억이 아니다


def test_사용자_입력값이_더_높으면_자동값을_쓴다():
    r = R.resolve([cand(900_000_000, R.SOURCE_MANUAL), cand(600_000_000, R.SOURCE_OFFICIAL_PRICE)])
    assert r.price_won == 600_000_000
    assert r.source == R.SOURCE_OFFICIAL_PRICE
    assert r.manual_and_auto_both_present


def test_사용자_입력값이_더_낮으면_그것을_쓴다():
    r = R.resolve([cand(300_000_000, R.SOURCE_MANUAL), cand(600_000_000, R.SOURCE_OFFICIAL_PRICE)])
    assert r.price_won == 300_000_000
    assert r.source == R.SOURCE_MANUAL


def test_0이나_음수_후보는_무시한다():
    r = R.resolve([cand(0, R.SOURCE_MANUAL), cand(-1, R.SOURCE_ACTUAL_TRADE), cand(5, R.SOURCE_TAX_BASE)])
    assert r.price_won == 5
    assert r.source == R.SOURCE_TAX_BASE


def test_채택되지_않은_후보가_alternatives에_남는다():
    r = R.resolve([cand(900_000_000, R.SOURCE_MANUAL), cand(600_000_000, R.SOURCE_OFFICIAL_PRICE)])
    assert [a.source for a in r.alternatives] == [R.SOURCE_MANUAL]


def test_같은_값_같은_출처가_둘이면_하나만_채택으로_빠진다():
    r = R.resolve([cand(500, R.SOURCE_MANUAL), cand(500, R.SOURCE_MANUAL)])
    assert len(r.alternatives) == 1


# ── 괴리 ─────────────────────────────────────────────────────────────────────


def test_실거래가만_있으면_괴리를_계산하지_않는다():
    r = R.resolve([cand(1_000_000_000, R.SOURCE_ACTUAL_TRADE)])
    assert r.gap_pct is None and r.gap_direction is None


def test_실거래가가_공시_기준보다_크게_높으면_부풀림_의심():
    r = R.resolve([cand(1_050_000_000, R.SOURCE_ACTUAL_TRADE), cand(200_000_000, R.SOURCE_OFFICIAL_PRICE)])
    assert r.gap_pct == 425
    assert r.gap_direction == "trade_inflated"
    assert "부풀" in R.gap_message(r)


def test_실거래가가_공시_기준보다_크게_낮으면_하락_가능성():
    r = R.resolve([cand(300_000_000, R.SOURCE_ACTUAL_TRADE), cand(600_000_000, R.SOURCE_OFFICIAL_PRICE)])
    assert r.gap_pct == -50
    assert r.gap_direction == "trade_depressed"
    assert "내려가고" in R.gap_message(r)


def test_비슷하면_방향이_없다():
    r = R.resolve([cand(510_000_000, R.SOURCE_ACTUAL_TRADE), cand(500_000_000, R.SOURCE_OFFICIAL_PRICE)])
    assert r.gap_pct == 2
    assert r.gap_direction is None


def test_공시가격이_기준시가보다_먼저_괴리_기준이_된다():
    r = R.resolve([
        cand(1_000_000_000, R.SOURCE_ACTUAL_TRADE),
        cand(500_000_000, R.SOURCE_OFFICIAL_PRICE),
        cand(100_000_000, R.SOURCE_TAX_BASE),
    ])
    assert r.gap_pct == 100  # 공시가격(5억) 기준. 기준시가(1억) 기준이면 900이 된다.


def test_기준선이_0이면_나누지_않는다():
    assert R.compute_gap_pct(1_000, 0) is None


# ── 오케스트레이터 ───────────────────────────────────────────────────────────


def test_자동조회를_끄면_사용자_입력값만_쓴다():
    r = PL.collect(address="[집합건물] 서울특별시 강남구 합성동 1234 제101동 제5층 제501호",
                   area_sqm=84.88, manual_price_won=500_000_000, auto=False)
    assert r.price_won == 500_000_000
    assert r.source == R.SOURCE_MANUAL


def test_주소가_없으면_자동조회를_건너뛰고_이유를_남긴다():
    r = PL.collect(address=None, area_sqm=84.88, manual_price_won=None)
    assert r.price_won is None
    assert any("주소를 추출하지 못해" in n for n in r.notes)


def test_단독다가구는_자동조회_자체를_하지_않는다(monkeypatch):
    called = []
    monkeypatch.setattr(PL, "_official_candidates", lambda *a, **k: (called.append("official"), ([], []))[1])
    monkeypatch.setattr(PL, "_actual_trade_candidate", lambda *a, **k: (called.append("trade"), (None, []))[1])
    r = PL.collect(address="[건물] 서울특별시 강남구 합성동 1234", area_sqm=200.0)
    assert called == []
    assert r.price_won is None
    assert any("단독·다가구" in n for n in r.notes)


def test_공시가격_조회가_터져도_리포트_경로가_살아남는다(monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("DB 폭발")

    monkeypatch.setattr(PL, "_official_candidates", boom)
    monkeypatch.setattr(PL, "_actual_trade_candidate", lambda *a, **k: (None, []))
    r = PL.collect(
        address="[집합건물] 서울특별시 강남구 합성동 1234 제101동 제5층 제501호",
        area_sqm=84.88,
        manual_price_won=400_000_000,
    )
    assert r.price_won == 400_000_000  # 사용자 입력값은 살아남는다
    assert any("RuntimeError" in n for n in r.notes)


def test_실거래가가_시간_예산을_넘기면_포기하고_계속한다(monkeypatch):
    import time

    def slow(*a, **k):
        time.sleep(2)
        return None, []

    monkeypatch.setattr(PL, "MARKET_PRICE_BUDGET_SECONDS", 0.2)
    monkeypatch.setattr(PL, "_official_candidates", lambda *a, **k: ([], []))
    monkeypatch.setattr(PL, "_actual_trade_candidate", slow)
    r = PL.collect(
        address="[집합건물] 서울특별시 강남구 합성동 1234 제101동 제5층 제501호",
        area_sqm=84.88,
        manual_price_won=400_000_000,
    )
    assert r.price_won == 400_000_000
    assert any("건너뛰었습니다" in n for n in r.notes)


def test_면적이_없으면_실거래가를_조회하지_않는다(monkeypatch):
    monkeypatch.setattr(PL, "_official_candidates", lambda *a, **k: ([], []))
    monkeypatch.setattr(PL, "_actual_trade_candidate", lambda *a, **k: pytest.fail("불려선 안 됨"))
    r = PL.collect(
        address="[집합건물] 서울특별시 강남구 합성동 1234 제101동 제5층 제501호", area_sqm=None
    )
    assert any("전용면적을 읽지 못해" in n for n in r.notes)


# ── 리포트 계약 배선 ─────────────────────────────────────────────────────────


def load(name: str) -> dict:
    return json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))


def test_price_info가_없으면_새_필드는_전부_비어_있다():
    data = load("clean_house")
    report = report_builder.build_report(
        RegistryExtract.from_raw(data["registry"]),
        deposit=data["inputs"]["deposit"],
        market_price=data["inputs"].get("market_price"),
        alias=None,
    )
    assert report.marketPriceSource is None
    assert report.marketPriceAsOf is None
    assert report.marketPriceSampleCount is None
    assert report.marketPriceGapPct is None
    assert report.marketPriceAlternatives == []


def test_price_info가_오면_출처가_리포트에_실린다():
    data = load("clean_house")
    resolved = R.resolve([
        cand(1_050_000_000, R.SOURCE_ACTUAL_TRADE, as_of="2026-02~2026-07", n=5),
        cand(200_000_000, R.SOURCE_OFFICIAL_PRICE),
    ])
    report, _ = report_builder._build(
        RegistryExtract.from_raw(data["registry"]),
        deposit=data["inputs"]["deposit"],
        market_price=None,
        alias=None,
        use_llm=False,
        price_info=resolved,
    )
    assert report.marketPrice == 200_000_000  # 낮은 쪽이 판정에도 들어간다
    assert report.marketPriceSource == R.SOURCE_OFFICIAL_PRICE
    assert report.marketPriceAsOf == "2025-01-01"
    assert report.marketPriceGapPct == 425
    assert [a.source for a in report.marketPriceAlternatives] == [R.SOURCE_ACTUAL_TRADE]
    assert report.marketPriceAlternatives[0].sampleCount == 5


def test_price_info가_market_price_인자를_덮어쓴다():
    """자동조회 결과와 판정에 들어간 값이 어긋나는 경로를 원천 차단한다."""
    data = load("clean_house")
    resolved = R.resolve([cand(200_000_000, R.SOURCE_OFFICIAL_PRICE)])
    report, _ = report_builder._build(
        RegistryExtract.from_raw(data["registry"]),
        deposit=100_000_000,
        market_price=999_999_999_999,  # 무시돼야 한다
        alias=None,
        use_llm=False,
        price_info=resolved,
    )
    assert report.marketPrice == 200_000_000


# ── 단독·다가구 안전망 ───────────────────────────────────────────────────────


def _extract_with_address(address: str | None) -> RegistryExtract:
    data = load("clean_house")
    raw = dict(data["registry"])
    raw["address"] = address
    return RegistryExtract.from_raw(raw)


def test_다가구는_시세가_있어도_양호가_되지_않는다():
    extract = _extract_with_address("서울특별시 강남구 합성동 1234")  # 호수 표기 없음
    v = rule_engine.evaluate(extract, deposit=200_000_000, market_price=2_000_000_000)
    jeonse = next(e for e in v.evidences if e.id == "jeonse_ratio")
    # 전세가율 10%지만 '양호'가 아니다 — 앞순위 세입자 보증금을 알 수 없기 때문.
    assert jeonse.grade is Grade.CAUTION
    assert jeonse.status_label == rule_engine.WHOLE_BUILDING_PENDING_LABEL
    assert jeonse.facts["jeonse_ratio_pct"] is None
    assert jeonse.facts["whole_building"] is True
    assert "전입세대" in jeonse.detail_text


def test_집합건물은_지금까지처럼_판정한다():
    extract = _extract_with_address("[집합건물] 서울특별시 강남구 합성동 1234 제101동 제5층 제501호")
    v = rule_engine.evaluate(extract, deposit=200_000_000, market_price=2_000_000_000)
    jeonse = next(e for e in v.evidences if e.id == "jeonse_ratio")
    assert jeonse.grade is Grade.GOOD
    assert jeonse.facts["jeonse_ratio_pct"] == 10


def test_호수가_마스킹돼_있어도_집합건물로_본다():
    """'제○○○호'는 호수 표기가 **있는** 것이다 — 숫자를 못 읽었을 뿐이다."""
    extract = _extract_with_address("서울특별시 양천구 신정동 12○○ ○○아파트 제1○○동 제○○층 제○○○호")
    v = rule_engine.evaluate(extract, deposit=200_000_000, market_price=2_000_000_000)
    assert next(e for e in v.evidences if e.id == "jeonse_ratio").grade is Grade.GOOD


def test_주소가_없으면_보수적으로_보류한다():
    extract = _extract_with_address(None)
    v = rule_engine.evaluate(extract, deposit=200_000_000, market_price=2_000_000_000)
    assert next(e for e in v.evidences if e.id == "jeonse_ratio").grade is not Grade.GOOD


# ── 질문 생성기 조건 ─────────────────────────────────────────────────────────


def _report_with(**kwargs):
    data = load("clean_house")
    resolved = R.resolve(kwargs.pop("candidates", []))
    report, _ = report_builder._build(
        RegistryExtract.from_raw(data["registry"]),
        deposit=data["inputs"]["deposit"],
        market_price=None,
        alias=None,
        use_llm=False,
        price_info=resolved,
    )
    return report


def test_자동조회값일_때_실거래_자료를_요구하는_질문이_나온다():
    report = _report_with(candidates=[cand(200_000_000, R.SOURCE_OFFICIAL_PRICE)])
    texts = [i.question for g in questions.build_question_groups(report) for i in g.items]
    assert any("공공데이터로 자동 조회한 값" in t for t in texts)


def test_직접_입력값일_때는_자동조회_안내_질문이_나오지_않는다():
    report = _report_with(candidates=[cand(200_000_000, R.SOURCE_MANUAL)])
    texts = [i.question for g in questions.build_question_groups(report) for i in g.items]
    assert not any("공공데이터로 자동 조회한 값" in t for t in texts)


def test_부풀림_의심이면_가격_근거를_묻는_질문이_나온다():
    report = _report_with(candidates=[
        cand(1_050_000_000, R.SOURCE_ACTUAL_TRADE),
        cand(200_000_000, R.SOURCE_OFFICIAL_PRICE),
    ])
    texts = [i.question for g in questions.build_question_groups(report) for i in g.items]
    assert any("공시 기준보다 많이 높아요" in t for t in texts)


def test_괴리가_없으면_괴리_질문이_나오지_않는다():
    report = _report_with(candidates=[cand(200_000_000, R.SOURCE_OFFICIAL_PRICE)])
    texts = [i.question for g in questions.build_question_groups(report) for i in g.items]
    assert not any("공시 기준보다 많이 높아요" in t for t in texts)
    assert not any("시세가 내려가고 있나요" in t for t in texts)


def test_모르는_condition_키는_여전히_질문을_숨긴다():
    report = _report_with(candidates=[])
    assert questions._condition_met({"뭔가이상한키": 1}, report, "전세가율") is False
