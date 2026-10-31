"""보증보험 카드 '양호' (2026-10-31) — 등기부로 볼 수 있는 HUG 가입요건을 모두 통과할 때만.

규칙 감사(2026-10-31): ④ 명단은 **맞춰 봤고 같은 이름이 없을 때만** 통과다(명단을 아직 못 받았으면 모른다),
⑤ 처리 중인 등기 신청이 있으면 확정하지 않는다. 그래서 '양호' 시험은 같은 이름이 없는 명단(OTHER)을 넣고 돈다.
"""

from __future__ import annotations

from app.schemas.internal import EvidenceVerdict, Grade, Owner, RegistryExtract
from app.services import fallback_texts, rule_engine
from tests.test_compare import _extract

ADDR = "서울특별시 서초구 서초동 1557-8 제3층 제301호"


def _ex(**kw):
    ex = _extract(address=ADDR, **kw)
    ex.current_owners = [Owner(name="김철수")]
    return ex


def _ins(v):
    return next(e for e in v.evidences if e.id == "insurance")


#: 받아 둔 명단(집주인과 다른 이름) — 대조는 했고 같은 이름이 없다
OTHER = [{"name": "이영희"}]


def test_깨끗한_집은_양호_그리고_가입된다고_단정하지_않는다():
    v = rule_engine.evaluate(_ex(), deposit=150_000_000, market_price=300_000_000, blacklist_entries=OTHER)
    ins = _ins(v)
    assert ins.grade is Grade.GOOD and ins.facts["registry_conditions_passed"]
    text = fallback_texts.build(v)["evidences"]["insurance"]["easy_explanation"]
    assert "보증기관이 집값을 따로" in text and "가입할 수 있어요" not in text


def test_시세를_모르면_확인_필요():
    v = rule_engine.evaluate(_ex(), deposit=150_000_000, market_price=None, blacklist_entries=OTHER)
    assert _ins(v).grade is Grade.CAUTION


def test_전세가율이_주의면_확인_필요():
    v = rule_engine.evaluate(_ex(), deposit=255_000_000, market_price=300_000_000, blacklist_entries=OTHER)
    assert _ins(v).grade is Grade.CAUTION  # 85% — HUG 90% 안이지만 한 칸 보수적으로


def test_단독_다가구는_확인_필요():
    ex = _extract(address="서울특별시 관악구 신림동 123-4")
    ex.current_owners = [Owner(name="김철수")]
    v = rule_engine.evaluate(ex, deposit=100_000_000, market_price=900_000_000, blacklist_entries=OTHER)
    assert _ins(v).grade is Grade.CAUTION


def test_명단과_이름이_같으면_확인_필요():
    v = rule_engine.evaluate(_ex(), deposit=150_000_000, market_price=300_000_000,
                             blacklist_entries=[{"name": "김철수"}])
    assert _ins(v).grade is Grade.CAUTION


def test_사진이_빠졌으면_게이트가_확인_필요로():
    ex = _ex()
    ex.pages_incomplete = True
    ex.pages_incomplete_reason = "5쪽이 빠졌어요"
    v = rule_engine.evaluate(ex, deposit=150_000_000, market_price=300_000_000, blacklist_entries=OTHER)
    assert _ins(v).grade is Grade.CAUTION and _ins(v).facts.get("capped_reason")


def test_명단을_아직_못_받았으면_양호가_아니다_그리고_무엇을_기다리는지_밝힌다():
    """규칙 감사 위반 1 — '일치 안 나옴'과 '맞춰 보지 못함'은 다르다(보수 편향, decisions.md ④ '하나라도 모르면')."""
    v = rule_engine.evaluate(_ex(), deposit=150_000_000, market_price=300_000_000, blacklist_entries=[])
    ins = _ins(v)
    assert ins.grade is Grade.CAUTION and ins.facts["waiting_for"] == ["blacklist"]
    assert "아직 맞춰 보지 못해" in ins.detail_text and "—" not in ins.detail_text
    text = fallback_texts.build(v)["evidences"]["insurance"]["easy_explanation"]
    assert "통과했어요" in text and "명단과 아직 맞춰 보지 못해서" in text
    assert v.gauge_progress == 0.8  # 깨끗한 집이어도 명단 전에는 예전 게이지


def test_집주인_이름을_못_읽으면_명단을_못_맞춰_봐서_확인_필요():
    ex = _extract(address=ADDR)
    ex.current_owners = []
    v = rule_engine.evaluate(ex, deposit=150_000_000, market_price=300_000_000, blacklist_entries=OTHER)
    assert _ins(v).grade is Grade.CAUTION and "이름을 못 읽어" in _ins(v).detail_text


def test_처리_중인_등기_신청이_있으면_확정하지_않는다():
    """규칙 감사 경고 3 — 아직 안 적힌 근저당이 있을 수 있다."""
    ex = _ex()
    ex.pending_application = True
    v = rule_engine.evaluate(ex, deposit=150_000_000, market_price=300_000_000, blacklist_entries=OTHER)
    ins = _ins(v)
    assert ins.grade is Grade.CAUTION and ins.facts["waiting_for"] == ["pending"]
    assert "처리 중인 등기 신청" in ins.detail_text


def test_다시_판정은_원래_명단_결과를_따른다():
    """다시 판정 재료의 명단 카드는 matched가 비어 있다 — 일치였던 리포트가 '일치 없음'으로 새지 않게 등급을 본다."""
    from app.schemas.internal import EvidenceVerdict

    matched = EvidenceVerdict(id="blacklist", grade=Grade.CAUTION, status_label="명단 일치 · 직접 확인 필요",
                              detail_text="d", source_text="s", facts={"matched": [], "list_size": None})
    v = rule_engine.evaluate(_ex(), deposit=150_000_000, market_price=300_000_000, blacklist_override=matched)
    assert _ins(v).grade is Grade.CAUTION and "같은 이름이 있어" in _ins(v).detail_text


def test_보증보험_설명은_명단_사정을_바르게_말한다():
    """일치·이름 못 읽음·명단 전 — 준비된 문구가 셋을 다르게 말한다(재감사 경고 1)."""
    matched = rule_engine.evaluate(_ex(), deposit=150_000_000, market_price=300_000_000,
                                   blacklist_entries=[{"name": "김철수"}])
    assert _ins(matched).facts["blacklist_state"] == "matched"
    text = fallback_texts.build(matched)["evidences"]["insurance"]["easy_explanation"]
    assert "같은 이름이 있어서" in text
    pending = rule_engine.evaluate(_ex(), deposit=150_000_000, market_price=300_000_000, blacklist_entries=[])
    assert _ins(pending).facts["blacklist_state"] == "pending"


def test_다시_판정_재료가_원래_결과를_지킨다():
    """재감사 경고 2·3 — 재료에 명단 결과가 없으면 가린 이름으로 다시 맞추지 않고, 사진 때문에 올라간 '같은 이름 없음'은 그대로."""
    from app.services import evidence_view, report_builder

    ex = _ex()
    old, _ = report_builder._build(ex, deposit=150_000_000, market_price=300_000_000, alias="t", use_llm=False)
    kit = report_builder.rejudge_kit(ex, old)
    kit.pop("blacklist", None)
    fresh = report_builder.rejudge(old, kit, deposit=150_000_000, market_price=300_000_000, alias=None)
    bl = next(e for e in fresh.evidences if e.id == "blacklist")
    assert bl.statusLabel == rule_engine.BLACKLIST_PENDING_LABEL
    assert next(e for e in fresh.evidences if e.id == "insurance").grade == "확인 필요"

    # 원래 '맞춰 봤고 같은 이름 없음'인데 쪽이 빠져 '확인 필요'로 올라간 카드
    ex2 = _ex()
    ex2.pages_incomplete = True
    ex2.pages_incomplete_reason = "5쪽이 빠졌어요"
    v = rule_engine.evaluate(ex2, deposit=150_000_000, market_price=300_000_000, blacklist_entries=OTHER)
    bl2 = next(e for e in v.evidences if e.id == "blacklist")
    assert bl2.grade is Grade.CAUTION and bl2.facts.get("capped_reason")
    old2, _ = report_builder._build(ex2, deposit=150_000_000, market_price=300_000_000, alias="t", use_llm=False,
                                    blacklist_override=bl2)
    kit2 = report_builder.rejudge_kit(ex2, old2)
    assert kit2["blacklist"]["facts"].get("capped_reason")
    re = rule_engine.evaluate(RegistryExtract.model_validate(kit2["extract"]), deposit=150_000_000,
                              market_price=300_000_000,
                              blacklist_override=EvidenceVerdict.model_validate(kit2["blacklist"]))
    ins = _ins(re)
    assert ins.grade is Grade.CAUTION and ins.facts.get("capped_reason")  # 문서 게이트가 다시 막는다
    assert "이름을 못 읽어" not in (ins.detail_text or "")
    bl3 = next(e for e in re.evidences if e.id == "blacklist")
    assert evidence_view.build(bl3, re)["points"][0].value.endswith("같은 이름 없음")


# ── 2026-11-01: 빚이 HUG 기준을 넘으면 보증보험도 '위험' (decisions.md 2026-11-01) ─────────────────────


def _with_mortgage(amount: int):
    from app.schemas.internal import MoneyEntry

    ex = _ex()
    ex.mortgages = [MoneyEntry(amount=amount, rank_number="1", receipt_date="2022-04-15", mortgagee="주식회사가상은행")]
    return ex


def test_빚이_HUG_기준을_넘으면_보증보험도_위험_종합은_그대로():
    v = rule_engine.evaluate(_with_mortgage(291_000_000), deposit=150_000_000, market_price=300_000_000,
                             blacklist_entries=OTHER)
    ins = _ins(v)
    senior = next(e for e in v.evidences if e.id == "senior_debt")
    assert senior.grade is Grade.DANGER
    assert ins.grade is Grade.DANGER
    assert ins.facts["rights_signals"] == [] and len(ins.facts["debt_signals"]) == 2
    assert "빚이 시세의 97% (HUG 기준 60% 이하)" in ins.detail_text and "(HUG 가입요건)" in ins.detail_text
    # 종합 등급은 빚 카드가 이미 '위험'이라 그대로 — 판정이 넓어지지 않았다
    assert v.grade is Grade.DANGER
    # 화면 ①줄(권리침해)은 '없음' — 빚 신호를 압류처럼 말하지 않는다
    from app.services import evidence_view

    pts = evidence_view.build(ins, v)["points"]
    assert pts[0].label.startswith("압류") and pts[0].value == "없음" and pts[0].tone == "ok"
    assert pts[1].tone == "danger" and pts[2].tone == "danger"
    # 준비된 문구도 빚을 이유로 말한다(압류라고 하지 않는다)
    text = fallback_texts.build(v)["evidences"]["insurance"]["easy_explanation"]
    assert text.startswith("**빚이 HUG 기준을 넘었어요**") and "압류" not in text
    # 홈 요약 줄은 같은 이유를 두 번 세지 않는다
    assert "보증보험" not in fallback_texts.top_risk_summary(v)


def test_빚이_기준_안이면_예전과_같다():
    v = rule_engine.evaluate(_with_mortgage(60_000_000), deposit=150_000_000, market_price=300_000_000,
                             blacklist_entries=OTHER)
    assert _ins(v).grade is Grade.GOOD  # 빚 20% · 빚+보증금 70% · 전세가율 50%
