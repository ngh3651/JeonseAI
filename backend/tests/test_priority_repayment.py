"""소액임차인 최우선변제 (2026-10-31) — 주택임대차보호법 제8조, 시행령 제10·11조 금액표.

규칙 계산이다. 표는 '가장 먼저 잡힌 담보의 날짜'로 고르고(개정 부칙 경과조치), 애매하면 덜 받는 쪽으로 본다.
"""

from __future__ import annotations

import json
from datetime import date

import pytest

from app.schemas.contract import Report, RiskFact
from app.services import ask_cards
from app.services import loss_estimate as L
from app.services import priority_repayment as P
from tests.test_loss_estimate import SEOUL, _table

TODAY = date(2026, 10, 31)


def _p(address: str, *, deposit: int = 100_000_000, facts=(), debt: int = 0, sale: int | None = 300_000_000,
       whole: bool | None = False) -> P.Priority:
    return P.compute(deposit=deposit, address=address, risk_facts=list(facts), senior_debt=debt,
                     expected_sale=sale, whole_building=whole, today=TODAY)


def _mortgage(d: str | None, amount: int = 120_000_000) -> RiskFact:
    return RiskFact(kind="근저당", receiptDate=d, amount=amount, holder="기관")


SEOUL_ADDR = "[집합건물] 서울특별시 서초구 서초동 1557-8 제3층 제301호"


# ── 표 모양 ─────────────────────────────────────────────────────────────────


def test_표는_날짜순이고_지역은_보호가_큰_곳부터():
    raw = json.loads(P.TABLE_PATH.read_text(encoding="utf-8"))
    starts = [t["from"] for t in raw["tables"]]
    assert starts == sorted(starts) and len(set(starts)) == len(starts)
    assert raw["latestAmendment"] == starts[-1] == "2023-02-21"
    for t in raw["tables"]:
        caps = [g["cap"] for g in t["groups"]]
        amounts = [g["amount"] for g in t["groups"]]
        assert caps == sorted(caps, reverse=True), t["from"]
        assert amounts == sorted(amounts, reverse=True), t["from"]
        assert t["groups"][-1]["region"] == "other"
        for g in t["groups"]:
            assert 0 < g["amount"] <= g["cap"]


def test_지금_표는_법령_그대로():
    """시행령 제10조·제11조 (2023.2.21 개정) — 서울 1억6천500만원/5천500만원 … 그 밖 7천500만원/2천500만원."""
    now = P.load_tables().pick("2026-10-31")
    got = {(g.region, g.cap, g.amount) for g in now.groups}
    assert got == {
        ("seoul", 165_000_000, 55_000_000),
        ("overcrowded", 145_000_000, 48_000_000),
        ("metro", 85_000_000, 28_000_000),
        ("other", 75_000_000, 25_000_000),
    }


# ── 계산 ───────────────────────────────────────────────────────────────────


def test_가장_먼저_잡힌_근저당_날짜의_표를_쓴다():
    """근저당 2021.6.30 → 2021.5.11 표(서울 1억5천만원 이하 · 5천만원). 2023년 표(5천500만원)가 아니다."""
    pr = _p(SEOUL_ADDR, facts=[_mortgage("2021-06-30"), _mortgage("2024-03-02")], debt=240_000_000)
    assert pr.status == "ok" and pr.table_from == "2021-05-11"
    assert pr.base_date == "2021-06-30" and pr.base_kind == "근저당"
    assert pr.cap == 150_000_000 and pr.limit == 50_000_000 and pr.amount == 50_000_000
    assert pr.region == "서울특별시"


def test_가압류도_기준일_후보다_더_이르면_더_옛_표():
    pr = _p(SEOUL_ADDR, facts=[_mortgage("2021-06-30"), RiskFact(kind="가압류", receiptDate="2017-05-01")],
            debt=120_000_000)
    assert pr.table_from == "2016-03-31" and pr.base_kind == "가압류"
    assert pr.limit == 34_000_000 and pr.cap == 100_000_000


def test_담보가_없으면_오늘_표():
    pr = _p(SEOUL_ADDR)
    assert pr.status == "ok" and pr.table_from == "2023-02-21" and pr.base_date is None
    assert pr.amount == 55_000_000


def test_보증금이_상한보다_크면_못_받는다():
    pr = _p(SEOUL_ADDR, deposit=200_000_000)
    assert pr.status == "over_cap" and pr.amount == 0 and pr.cap == 165_000_000


def test_보증금이_한도보다_적으면_보증금까지만():
    pr = _p(SEOUL_ADDR, deposit=30_000_000)
    assert pr.amount == 30_000_000


def test_낙찰가의_절반까지만():
    pr = _p(SEOUL_ADDR, sale=80_000_000)
    assert pr.amount == 40_000_000 and pr.half_capped


def test_이미_경매가_시작된_집은_0원():
    pr = _p(SEOUL_ADDR, facts=[RiskFact(kind="경매개시결정", receiptDate="2026-09-01")])
    assert pr.status == "blocked_auction" and pr.amount == 0


def test_임차권등기가_남은_집은_그_뒤_세입자가_못_받는다():
    """주택임대차보호법 제3조의3 ⑥ — 임차권등기가 끝난 주택을 그 뒤에 빌린 세입자는 최우선변제를 받을 권리가 없다(2026-11-01)."""
    lease = RiskFact(kind="임차권등기", receiptDate="2025-03-02", amount=90_000_000)
    pr = _p(SEOUL_ADDR, facts=[_mortgage("2022-04-15"), lease], debt=120_000_000)
    assert pr.status == "blocked_lease" and pr.amount == 0
    # 단독·다가구는 다른 호실의 등기일 수 있어 원래대로 '나눠요'(더하지 않음)
    assert _p(SEOUL_ADDR, facts=[lease], whole=True).status == "shared"


def test_날짜를_못_읽으면_더하지_않는다():
    assert _p(SEOUL_ADDR, facts=[_mortgage(None)], debt=120_000_000).status == "unknown_date"
    # 빚은 있는데 항목 사실이 없다(옛 리포트) — 표를 고를 수 없다
    assert _p(SEOUL_ADDR, debt=120_000_000).status == "unknown_date"


def test_다가구는_나눠서_더하지_않는다():
    pr = _p("서울특별시 관악구 신림동 123-4", whole=True)
    assert pr.status == "shared" and pr.amount == 0 and pr.limit == 55_000_000


@pytest.mark.parametrize(
    ("address", "region", "limit", "unsure"),
    [
        ("경기도 수원시 영통구 이의동 123 제101동 제1층 제101호", "수도권 과밀억제권역(서울 제외)", 48_000_000, False),
        ("경기도 용인시 수지구 풍덕천동 1 제1층 제101호", "수도권 과밀억제권역(서울 제외)", 48_000_000, False),
        ("세종특별자치시 한솔동 1 제1층 제101호", "수도권 과밀억제권역(서울 제외)", 48_000_000, False),
        ("경기도 광주시 오포읍 1 제1층 제101호", "광역시(과밀억제권역·군 지역 제외)", 28_000_000, False),
        ("광주광역시 서구 치평동 1 제1층 제101호", "광역시(과밀억제권역·군 지역 제외)", 28_000_000, False),
        ("부산광역시 해운대구 우동 1 제1층 제101호", "광역시(과밀억제권역·군 지역 제외)", 28_000_000, False),
        ("부산광역시 기장군 기장읍 1 제1층 제101호", "그 밖의 지역", 25_000_000, False),
        ("인천광역시 부평구 부평동 1 제1층 제101호", "수도권 과밀억제권역(서울 제외)", 48_000_000, False),
        # 인천 경제자유구역(송도) — 동의 일부만이라 애매 → 보호가 적은 쪽(광역시)
        ("인천광역시 연수구 송도동 1 제1층 제101호", "광역시(과밀억제권역·군 지역 제외)", 28_000_000, True),
        ("인천광역시 강화군 강화읍 1 제1층 제101호", "그 밖의 지역", 25_000_000, False),
        ("경기도 남양주시 다산동 1 제1층 제101호", "그 밖의 지역", 25_000_000, False),
        ("경기도 남양주시 도농동 1 제1층 제101호", "수도권 과밀억제권역(서울 제외)", 48_000_000, False),
        ("충청북도 청주시 상당구 용암동 1 제1층 제101호", "그 밖의 지역", 25_000_000, False),
    ],
)
def test_지역_묶음(address, region, limit, unsure):
    pr = _p(address, deposit=20_000_000_0 // 10)  # 2천만원 — 모든 지역 상한 아래
    assert pr.region == region, address
    assert pr.limit == limit and pr.region_unsure is unsure


def test_2018년_표에서_김포는_광역시_묶음():
    """2018.9.18 표: 과밀억제권역 묶음에 세종·용인·화성, 광역시 묶음에 안산·김포·광주·파주 (김포는 2021년에 올라감)."""
    pr = _p("경기도 김포시 구래동 1 제1층 제101호", facts=[_mortgage("2019-01-02")], debt=1)
    assert pr.table_from == "2018-09-18" and pr.region.startswith("광역시") and pr.limit == 20_000_000


# ── 손실 시뮬레이터에 넣기 ───────────────────────────────────────────────────


def _report(**over) -> Report:
    base = dict(
        id="pr-1", alias="테스트", address=SEOUL_ADDR, propertyAddress=SEOUL_ADDR,
        analyzedAt="2026-10-31T10:00:00+09:00", grade="위험", gaugeProgress=0.2, headline="h",
        nextAction="n", topRiskSummary="t", deposit=100_000_000, marketPrice=400_000_000,
        seniorDebtAmount=300_000_000, evidences=[], houseTypes=["연립다세대"],
        riskFacts=[_mortgage("2021-06-30", 300_000_000)],
    )
    base.update(over)
    return Report(**base)


def test_낙찰가에서_가장_먼저_빠지고_남은_돈에서_빚이_빠진다():
    """4억 × 75% = 3억. 최우선 5천만원 먼저 → 남은 2억5천만원에서 빚 3억 → 0 → 내 몫 = 5천만원."""
    est = L.estimate(_report(), _table(SEOUL))
    assert est.expectedSale == 300_000_000
    assert est.priorityStatus == "ok" and est.priorityAmount == 50_000_000
    assert est.expectedReturn == 50_000_000 and est.expectedLoss == 50_000_000
    assert est.priorityTableFrom == "2021-05-11" and est.priorityBaseDate == "2021-06-30"
    assert est.prioritySource == "주택임대차보호법 시행령 제10·11조"


def test_빚이_적으면_최우선을_빼도_다_돌아온다():
    est = L.estimate(_report(seniorDebtAmount=100_000_000, riskFacts=[_mortgage("2021-06-30", 100_000_000)]),
                     _table(SEOUL))
    assert est.expectedReturn == 100_000_000 and est.expectedLoss == 0


def test_끄면_예전_계산():
    est = L.estimate(_report(), _table(SEOUL), priority=False)
    assert est.expectedReturn == 0 and est.priorityStatus is None


def test_경매_중이면_더하지_않는다():
    est = L.estimate(_report(riskFacts=[_mortgage("2021-06-30", 300_000_000),
                                        RiskFact(kind="경매개시결정", receiptDate="2026-09-01")]), _table(SEOUL))
    assert est.priorityStatus == "blocked_auction" and est.expectedReturn == 0


def test_시세가_없어도_한도는_알린다():
    est = L.estimate(_report(marketPrice=None), _table(SEOUL))
    assert est.status == "no_price" and est.priorityStatus == "ok" and est.priorityLimit == 50_000_000


def test_질문_합격선은_최우선변제를_빼고_본다():
    """빚을 그대로 둬도 된다는 판단을 조건이 붙는 돈에 기대지 않는다 — 근저당 말소 질문이 그대로 나온다."""
    report = _report(seniorDebtAmount=260_000_000, riskFacts=[_mortgage("2021-06-30", 260_000_000)],
                     registryViewedAt="2026.10.31")
    ids = [c.id for c in ask_cards.build(report).cards]
    assert "debt" in ids
    debt = next(c for c in ask_cards.build(report).cards if c.id == "debt")
    assert "말소" in debt.passLine.text


# ── 법령 지켜보기 (매주) ─────────────────────────────────────────────────────


def test_한국어_금액을_읽는다():
    from app.services import law_watch as W

    assert W.parse_won("1억6천500만원") == 165_000_000
    assert W.parse_won("8천500만원") == 85_000_000
    assert W.parse_won("5천500만원") == 55_000_000
    assert W.amounts_in("1. 서울특별시: 1억6천500만원\n4. 그 밖의 지역: 7천500만원") == [165_000_000, 75_000_000]


def _law_json(eff: str, art10: str, art11: str):
    search = {"LawSearch": {"law": [{"법령명한글": "주택임대차보호법 시행령", "시행일자": eff, "법령일련번호": "1"}]}}
    body = {"법령": {"조문": {"조문단위": [
        {"조문내용": "제10조(보증금 중 일정액의 범위 등) " + art10},
        {"조문내용": "제11조(우선변제를 받을 임차인의 범위) " + art11},
        {"조문내용": "제12조(등기명령 신청서의 기재사항 등)"},
    ]}}}
    return lambda url, params: search if "lawSearch" in url else body


NOW10 = "1. 서울특별시: 5천500만원 2. 과밀억제권역: 4천800만원 3. 광역시: 2천800만원 4. 그 밖의 지역: 2천500만원"
NOW11 = "1. 서울특별시: 1억6천500만원 2. 과밀억제권역: 1억4천500만원 3. 광역시: 8천500만원 4. 그 밖의 지역: 7천500만원"


def test_시행일이_그대로면_그대로(tmp_path, monkeypatch):
    from app.services import law_watch as W

    monkeypatch.setattr(W, "status_path", lambda: tmp_path / "law_watch.json")
    st = W.check(get_json=_law_json("20230221", NOW10, NOW11))
    assert st["stale"] is False and st["lawEffective"] == "2023-02-21"
    assert W.priority_table_stale() is False


def test_다른_조만_고친_개정이면_그대로(tmp_path, monkeypatch):
    from app.services import law_watch as W

    monkeypatch.setattr(W, "status_path", lambda: tmp_path / "law_watch.json")
    st = W.check(get_json=_law_json("20251001", NOW10, NOW11))
    assert st["stale"] is False and "금액 그대로" in st["note"]


def test_금액이_바뀌면_확인_중_표시(tmp_path, monkeypatch):
    from app.services import law_watch as W

    monkeypatch.setattr(W, "status_path", lambda: tmp_path / "law_watch.json")
    st = W.check(get_json=_law_json("20261101", NOW10.replace("5천500", "6천"), NOW11.replace("1억6천500", "1억8천")))
    assert st["stale"] is True
    assert W.priority_table_stale() is True
    est = L.estimate(_report(), _table(SEOUL))
    assert est.priorityTableStale is True


def test_확인이_실패해도_아무것도_바꾸지_않는다(tmp_path, monkeypatch):
    from app.services import law_watch as W

    monkeypatch.setattr(W, "status_path", lambda: tmp_path / "law_watch.json")

    def boom(url, params):
        raise RuntimeError("법제처 API 사용자 검증 실패")

    st = W.check(get_json=boom)
    assert st["stale"] is False and "확인 실패" in st["note"]


def test_사실이_넘쳐도_최우선변제가_기대는_사실은_남는다():
    """압류류가 30건을 넘어도 경매개시결정·가장 먼저 잡힌 담보·날짜 못 읽은 담보는 잘리지 않는다 (규칙 감사 2026-10-31)."""
    from app.services import registry_facts as RF

    facts = [RiskFact(kind="가압류", receiptDate=f"2025-01-{i % 28 + 1:02d}", amount=1_000_000, holder="개인")
             for i in range(RF.MAX_FACTS + 5)]
    facts += [RiskFact(kind="경매개시결정", receiptDate="2026-03-02", amount=None, holder="기관"),
              _mortgage("2020-05-01"), _mortgage(None), _mortgage("2009-02-03")]
    kept = RF._trim(facts)
    assert len(kept) == RF.MAX_FACTS
    kinds = [(f.kind, f.receiptDate) for f in kept]
    assert ("경매개시결정", "2026-03-02") in kinds
    assert ("근저당", "2009-02-03") in kinds and ("근저당", None) in kinds
    assert _p(SEOUL_ADDR, facts=kept, debt=120_000_000).status == "blocked_auction"
    assert RF._trim(facts[:5]) == facts[:5]  # 넘치지 않으면 그대로


def test_사실이_넘쳐도_임차권등기는_남는다():
    """임차권등기가 잘리면 '임차권등기 집은 0원'이 안 걸려 최우선변제를 더하게 된다(2026-11-01 검토)."""
    from app.services import registry_facts as RF

    facts = [RiskFact(kind="압류", receiptDate=f"2025-02-{i % 28 + 1:02d}", amount=1_000_000, holder="기관")
             for i in range(RF.MAX_FACTS + 5)]
    facts += [_mortgage("2020-05-01"), RiskFact(kind="임차권등기", receiptDate="2025-06-01", amount=90_000_000)]
    kept = RF._trim(facts)
    assert any(f.kind == "임차권등기" for f in kept)
    assert _p(SEOUL_ADDR, facts=kept, debt=120_000_000).status == "blocked_lease"
