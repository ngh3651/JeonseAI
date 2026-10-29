"""리포트 4장 '중개사에게 물어볼 질문' (2026-10-29) — 규칙이 고르고, 합격선은 손실 계산과 같은 경매 통계로."""

from __future__ import annotations

import json

from app.schemas.contract import OwnerFacts, Report, RiskFact
from app.services import ask_cards as A
from app.services import loss_estimate as L
from app.services.formatting import format_won
from app.services import store
from app.services.registry_facts import norm_date
from tests.test_analyze_smoke import client  # noqa: F401 — pytest 픽스처 재사용


def _report(**over) -> Report:
    base = dict(
        id="ask-1",
        alias="성산동 빌라",
        address="[집합건물] 서울특별시 마포구 성산동 1-1 제3층 제302호",
        analyzedAt="2026-10-29T10:00:00+09:00",
        grade="확인 필요",
        gaugeProgress=0.5,
        headline="h",
        nextAction="n",
        topRiskSummary="t",
        deposit=160_000_000,
        marketPrice=240_000_000,
        seniorDebtAmount=48_000_000,
        evidences=[],
        houseTypes=["연립다세대"],
        registryViewedAt="2026.10.27",
        riskFacts=[RiskFact(kind="근저당", receiptDate="2026-08-12", amount=48_000_000, holder="기관")],
        riskTags=["선순위 채권"],
        ownerFacts=OwnerFacts(ownerCount=1, latestTransferDate="2026-08-12", latestCause="매매"),
    )
    base.update(over)
    return Report(**base)


def _clean(**over) -> Report:
    base = dict(
        id="ask-2",
        address="[집합건물] 경기도 성남시 분당구 정자동 1 제10층 제1001호",
        deposit=280_000_000,
        marketPrice=400_000_000,
        seniorDebtAmount=0,
        houseTypes=["아파트"],
        riskFacts=[],
        riskTags=[],
        ownerFacts=OwnerFacts(ownerCount=1, latestTransferDate="2015-03-02", latestCause="매매"),
        grade="양호",
    )
    base.update(over)
    return _report(**base)


def test_위험한_빌라는_빚정리_세금_산지얼마안된집():
    b = A.build(_report())
    ids = [c.id for c in b.cards]
    assert ids == ["debt", "tax", "recent", "insurance"]
    debt = b.cards[0]
    # 손실 계산(2장)과 같은 숫자 — 서울 연립다세대 매각가율 × 2억 4,000만 − 빚 4,800만
    est = L.estimate(_report())
    assert est.expectedLoss > 0
    assert debt.passLine.sub == f"안 되면 경매 때 {format_won(est.expectedLoss)}을 못 받는 계산이에요"
    assert debt.passLine.tone == "danger"
    assert debt.facts[0] == "2026.8.12 · 집주인이 이 집을 삼"  # 산 날 = 근저당 접수일
    assert "같은 날" in debt.why
    tax = b.cards[1]
    assert tax.legal and tax.passLine.big == "0원"
    assert tax.passLine.text == f"빚을 말소하면 {format_won(est.expectedSale - 160_000_000)}까지"
    assert b.cards[2].title == "산 지 2개월 된 집"
    assert "4,800만원" in debt.clause


def test_깨끗한_아파트는_세금이_먼저_여유는_이집숫자():
    b = A.build(_clean())
    assert [c.id for c in b.cards] == ["tax", "insurance"]
    # 경기 아파트 매각가율 × 4억 − 보증금 2억 8,000만
    cushion = format_won(L.estimate(_clean()).expectedSale - 280_000_000)
    assert b.cards[0].passLine.text == f"많아도 {cushion} 이하"
    assert cushion in b.cards[0].why
    assert "70%" in b.cards[1].facts[0]


def test_작은빚은_말소대신_대출_더_안받기():
    b = A.build(_clean(seniorDebtAmount=60_000_000,
                       riskFacts=[RiskFact(kind="근저당", receiptDate="2019-05-01", amount=60_000_000, holder="기관")]))
    ids = [c.id for c in b.cards]
    assert ids[0] == "tax" and "debt" in ids  # 작은 빚은 맨 앞에 오지 않는다
    debt = next(c for c in b.cards if c.id == "debt")
    assert debt.passLine.text.startswith("대출 더 안 받기")


def test_경매_중인_집은_질문_대신_멈춤():
    b = A.build(_report(riskTags=["경매"]))
    assert b.cards == [] and b.stop


def test_질문은_최대_4개_가장_위험한_것이_먼저():
    r = _report(
        riskTags=["임차권등기", "압류·가압류", "신탁등기", "선순위 채권"],
        riskFacts=[
            RiskFact(kind="임차권등기", receiptDate="2025-02-03", amount=100_000_000, holder="개인"),
            RiskFact(kind="가압류", receiptDate="2026-05-01", amount=40_000_000, holder="개인"),
            RiskFact(kind="근저당", receiptDate="2026-08-12", amount=48_000_000, holder="기관"),
            RiskFact(kind="신탁", receiptDate="2024-01-02"),
        ],
    )
    b = A.build(r)
    assert len(b.cards) == A.MAX_CARDS
    assert [c.id for c in b.cards][:2] == ["lease", "tax"]
    assert "임차권등기 1억원" in b.cards[0].facts[0]


def test_공동소유_법인_다가구():
    b = A.build(_clean(ownerFacts=OwnerFacts(ownerCount=2, corporate=True)))
    tax = b.cards[0]
    assert "법인" in tax.ask and tax.facts[0] == "집주인이 회사(법인)"
    assert any(c.id == "owners" and c.title == "집주인이 2명" for c in b.cards)
    whole = A.build(_report(address="서울특별시 마포구 성산동 1-1", houseTypes=["다가구주택"]))
    assert any(c.id == "tenants" and c.legal for c in whole.cards)


def test_시세가_없으면_한도_대신_안내():
    b = A.build(_clean(marketPrice=None))
    assert b.cards[0].passLine.sub == "시세를 넣으면 이 집 한도를 계산해요"


def test_날짜_정리():
    assert norm_date("2026년 8월 12일") == "2026-08-12"
    assert norm_date("2026.8.12") == "2026-08-12"
    assert norm_date("모름") is None


def test_why_다듬기는_검사를_통과한_것만():
    r = _report(id="ask-polish")
    b = A.build(r)

    def fake(messages):
        return json.dumps({"cards": [
            {"id": "debt", "why": "집주인이 산 같은 날 근저당 4,800만원이 잡혔어요. 잔금 날 말소를 글로 받아 두세요."},
            {"id": "tax", "why": "밀린 세금이 9억원 있을 수 있어요."},  # 입력에 없는 숫자 → 버림
        ]}, ensure_ascii=False)

    b = A.polish(r, b, call=fake)
    debt, tax = b.cards[0], b.cards[1]
    assert debt.whyByAi and "4,800만원" in debt.why
    assert not tax.whyByAi and "9억" not in tax.why


def test_엔드포인트(client):
    store.add(_report(id="ask-api"), device_id="legacy-device")
    resp = client.get("/api/reports/ask-api/ask-cards")
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert [c["id"] for c in body["cards"]][:2] == ["debt", "tax"]
    assert "납세증명서" in body["shareText"]
    assert client.get("/api/reports/없는id/ask-cards").status_code == 404
