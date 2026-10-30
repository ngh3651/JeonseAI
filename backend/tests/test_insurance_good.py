"""보증보험 카드 '양호' (2026-10-31) — 등기부로 볼 수 있는 HUG 가입요건을 모두 통과할 때만."""

from __future__ import annotations

from app.schemas.internal import Grade, Owner
from app.services import fallback_texts, rule_engine
from tests.test_compare import _extract

ADDR = "서울특별시 서초구 서초동 1557-8 제3층 제301호"


def _ex(**kw):
    ex = _extract(address=ADDR, **kw)
    ex.current_owners = [Owner(name="김철수")]
    return ex


def _ins(v):
    return next(e for e in v.evidences if e.id == "insurance")


def test_깨끗한_집은_양호_그리고_가입된다고_단정하지_않는다():
    v = rule_engine.evaluate(_ex(), deposit=150_000_000, market_price=300_000_000, blacklist_entries=[])
    ins = _ins(v)
    assert ins.grade is Grade.GOOD and ins.facts["registry_conditions_passed"]
    text = fallback_texts.build(v)["evidences"]["insurance"]["easy_explanation"]
    assert "보증기관이 집값을 따로" in text and "가입할 수 있어요" not in text


def test_시세를_모르면_확인_필요():
    v = rule_engine.evaluate(_ex(), deposit=150_000_000, market_price=None, blacklist_entries=[])
    assert _ins(v).grade is Grade.CAUTION


def test_전세가율이_주의면_확인_필요():
    v = rule_engine.evaluate(_ex(), deposit=255_000_000, market_price=300_000_000, blacklist_entries=[])
    assert _ins(v).grade is Grade.CAUTION  # 85% — HUG 90% 안이지만 한 칸 보수적으로


def test_단독_다가구는_확인_필요():
    ex = _extract(address="서울특별시 관악구 신림동 123-4")
    ex.current_owners = [Owner(name="김철수")]
    v = rule_engine.evaluate(ex, deposit=100_000_000, market_price=900_000_000, blacklist_entries=[])
    assert _ins(v).grade is Grade.CAUTION


def test_명단과_이름이_같으면_확인_필요():
    v = rule_engine.evaluate(_ex(), deposit=150_000_000, market_price=300_000_000,
                             blacklist_entries=[{"name": "김철수"}])
    assert _ins(v).grade is Grade.CAUTION


def test_사진이_빠졌으면_게이트가_확인_필요로():
    ex = _ex()
    ex.pages_incomplete = True
    ex.pages_incomplete_reason = "5쪽이 빠졌어요"
    v = rule_engine.evaluate(ex, deposit=150_000_000, market_price=300_000_000, blacklist_entries=[])
    assert _ins(v).grade is Grade.CAUTION and _ins(v).facts.get("capped_reason")
