"""잔금 당일 빈틈 (2026-10-31) — 등기부의 '신청사건 처리중'을 판정·대조·질문·리포트에 잇는다.

근거: 등기예규 제1815호(부동산등기사항증명서 발급처리지침) 2.다.1) — 신청사건이 처리 중인 등기기록은
매 장에 '신청사건처리중'을 음영으로 표시하고, 처리 결과에 따라 등기기록이 **접수 시로 소급해** 바뀔 수 있다고 적어 발급한다.
"""

from __future__ import annotations

from app.schemas.contract import Highlight, HighlightBox, Report
from app.schemas.internal import Grade, Owner, RegistryExtract
from app.services import ask_cards, compare, fallback_texts, report_builder, rule_engine
from app.services.patterns import TAG_PENDING, tags_from_report, tags_from_verdict
from tests.test_compare import _extract, _snapshot


def _clean_extract(**kw) -> RegistryExtract:
    # 집합건물 호수까지 있는 주소 — 단독·다가구 안전망(전세가율 보류)에 걸리지 않게
    ex = _extract(address="경기 성남시 분당구 정자동 456-7 제5층 제502호", **kw)
    ex.current_owners = [Owner(name="김철수")]
    return ex


def _pending_highlight() -> Highlight:
    return Highlight(
        id="h-pending",
        page=0,
        kind="pending_application",
        badge=1,
        box=HighlightBox(x=0.1, y=0.1, w=0.3, h=0.02),
        title="처리 중인 등기 신청 (신청사건)",
        body="무슨 신청인지 확인될 때까지 계약금·잔금을 보내지 마세요.",
    )


# ── 규칙 엔진 ───────────────────────────────────────────────────────────────


def test_신청사건이_없으면_카드도_없고_등급도_그대로():
    ex = _clean_extract()
    verdict = rule_engine.evaluate(ex, deposit=100_000_000, market_price=300_000_000, blacklist_entries=[])
    assert "pending" not in {e.id for e in verdict.evidences}


def test_신청사건이_있으면_확인_필요_카드가_생기고_종합도_양호가_아니다():
    ex = _clean_extract()
    before = rule_engine.evaluate(ex, deposit=100_000_000, market_price=300_000_000, blacklist_entries=[])
    assert before.grade is Grade.GOOD  # 깨끗한 집 — 이 신호 하나만 본다

    ex.pending_application = True
    after = rule_engine.evaluate(ex, deposit=100_000_000, market_price=300_000_000, blacklist_entries=[])
    card = next(e for e in after.evidences if e.id == "pending")
    assert card.grade is Grade.CAUTION and card.status_label == "확인 필요"
    assert "신청사건" in card.detail_text and "1815" in card.source_text
    assert after.grade is Grade.CAUTION
    # 다른 카드의 판정은 그대로다
    keep = {e.id: e.grade for e in before.evidences}
    assert {e.id: e.grade for e in after.evidences if e.id != "pending"} == keep


def test_위험한_집은_위험_그대로():
    ex = _clean_extract(auction_commencements=[{"receipt_date": "2026-09-01", "is_canceled": False}])
    ex.pending_application = True
    verdict = rule_engine.evaluate(ex, deposit=100_000_000, market_price=300_000_000, blacklist_entries=[])
    assert verdict.grade is Grade.DANGER


def test_설명_기본_문장과_태그():
    ex = _clean_extract()
    ex.pending_application = True
    verdict = rule_engine.evaluate(ex, deposit=100_000_000, market_price=300_000_000, blacklist_entries=[])
    texts = fallback_texts.build(verdict)["evidences"]["pending"]
    assert texts["title"] == "아직 처리 중인 등기 신청이 있나요?"
    assert "접수한 때 생긴 걸로" in texts["easy_explanation"]
    assert "—" not in texts["easy_explanation"]  # 대시 없이
    assert texts["action_label"] == "무슨 신청인지 묻기"
    assert TAG_PENDING in tags_from_verdict(verdict)


def test_사진_표시가_판정의_단_하나의_기준이다():
    assert report_builder.has_pending_application([_pending_highlight()]) is True
    assert report_builder.has_pending_application([]) is False
    assert report_builder.has_pending_application(None) is False


def test_조립하면_카드가_맨_앞_같은_등급에서():
    ex = _clean_extract()
    ex.pending_application = True
    report, _ = report_builder._build(ex, deposit=100_000_000, market_price=None, alias="테스트", use_llm=False)
    cautions = [e.id for e in report.evidences if e.grade == "확인 필요"]
    assert cautions[0] == "pending"
    assert TAG_PENDING in (report.riskTags or [])


def test_보증금_고치기도_신청사건을_잊지_않는다():
    """다시 판정은 이름 가린 재료로 한다 — 옛 재료엔 칸이 없어도 사진 표시로 다시 켠다."""
    ex = _clean_extract()
    old, _ = report_builder._build(
        ex, deposit=100_000_000, market_price=300_000_000, alias="테스트", use_llm=False,
        highlights=[_pending_highlight()],
    )
    kit = report_builder.rejudge_kit(ex, old)
    kit["extract"].pop("pending_application", None)  # 옛 재료 흉내
    fresh = report_builder.rejudge(old, kit, deposit=120_000_000, market_price=300_000_000, alias=None)
    assert "pending" in {e.id for e in fresh.evidences}


def test_옛_리포트_태그도_카드로_고른다():
    r = Report(
        id="r1", alias="a", address="서울 서초구 서초동 1", analyzedAt="2026-10-31T09:00:00+09:00",
        grade="확인 필요", gaugeProgress=0.5, headline="h", nextAction="n", topRiskSummary="t",
        deposit=1, seniorDebtAmount=0,
        evidences=[{"id": "pending", "title": "t", "termSubtitle": "s", "grade": "확인 필요",
                    "easyExplanation": "e"}],
    )
    assert tags_from_report(r) == [TAG_PENDING]


# ── 대조 (잔금 날 다시 뗀 등기부) ───────────────────────────────────────────


def test_이번_서류에_신청사건이_있으면_맨_위_멈춤_줄():
    base = _snapshot(_extract(), report_id="base")
    cur_ex = _extract()
    cur_ex.pending_application = True
    cur = _snapshot(cur_ex, report_id="cur")
    result = compare.compare(base, cur)
    top = result.rows[0]
    assert top.group == "pending" and top.tone == "danger" and top.kind == "changed"
    assert "잔금을 보내지 마세요" in (top.subtitle or "")
    # 나머지는 모두 그대로여도 '달라진 점 없음'이라고 말하지 않는다
    assert result.headline == compare.PENDING_TITLE
    assert result.result == "changed"


def test_신청사건이_끝났으면_조용한_한_줄():
    base_ex = _extract()
    base_ex.pending_application = True
    base = _snapshot(base_ex, report_id="base")
    cur = _snapshot(_extract(), report_id="cur")
    result = compare.compare(base, cur)
    row = next(r for r in result.rows if r.group == "pending")
    assert row.tone == "neutral" and row.kind == "same"
    assert result.headline == "달라진 점은 없었어요"


def test_옛_스냅샷은_신청사건_없음으로_읽힌다():
    from app.services import store

    snap = _snapshot(_extract())
    raw = store.snapshot_to_json(snap).replace('"pending_application": false, ', "").replace(
        ', "pending_application": false', ""
    )
    assert "pending_application" not in raw
    assert store.snapshot_from_json(raw).pending_application is False


# ── 4장 질문 ───────────────────────────────────────────────────────────────


def test_질문_카드가_맨_앞에_나온다():
    ex = _clean_extract()
    ex.pending_application = True
    report, _ = report_builder._build(ex, deposit=100_000_000, market_price=None, alias="테스트", use_llm=False,
                                      registry_viewed_at="2026.10.31")
    cards = ask_cards.build(report).cards
    assert cards[0].id == "pending"
    assert "신청사건 처리중" in cards[0].facts[0]
    assert "2026.10.31" in cards[0].facts[0]


# ── 규칙 감사·페르소나 리뷰 반영 (2026-10-31) ──────────────────────────────────


def test_형광펜을_못_칠해도_글자가_있으면_판정_재료로_켠다():
    """상자 계산이 실패하거나 표시 단계가 예외로 끝나도 '신청사건' 글자만 있으면 카드가 생긴다(감사 경고 5)."""
    from app.services import highlight, ocr
    from app.services.ocr_layout import OcrPage, group_lines
    from tests.test_highlight import PAGE_H, PAGE_W, W, eul_gu_page

    base = eul_gu_page()
    words = list(base.words) + [W("신청사건처리중", 300, 30, 140)]
    page = OcrPage(name="p1.jpg", index=0, words=words, lines=group_lines(words), width=PAGE_W, height=PAGE_H)
    assert highlight.pending_text_found(ocr.OcrResult(pages=[page], elapsed=1.0)) is True
    assert highlight.pending_text_found(ocr.OcrResult(pages=[eul_gu_page()], elapsed=1.0)) is False
    assert highlight.pending_text_found(None) is False


def test_신청사건만_있으면_윗줄은_멈춤부터():
    """'그대로예요'를 앞세우면 잔금을 보내도 되는 줄 안다(페르소나 리뷰) — 그대로인 줄은 아래 목록에."""
    base = _snapshot(_extract(), report_id="base")
    cur_ex = _extract()
    cur_ex.pending_application = True
    result = compare.compare(base, _snapshot(cur_ex, report_id="cur"))
    assert result.subline.startswith("잔금은 아직 보내지 마세요")
    assert "그대로예요" not in result.subline and "—" not in result.subline


def test_펼친_카드의_체크는_반올림이_아니라_판정과_같은_비교로():
    """빚이 시세의 60.3%면 빚 카드는 '위험' — 보증보험 펼침에 '60% 이하 ✓'가 뜨면 안 된다(감사 경고 1)."""
    from app.services import evidence_view
    from app.schemas.internal import MoneyEntry

    ex = _clean_extract()
    ex.mortgages = [MoneyEntry(rank_number="1", receipt_date="2021-06-30", amount=180_900_000, mortgagee="○○은행")]
    v = rule_engine.evaluate(ex, deposit=60_000_000, market_price=300_000_000, blacklist_entries=[{"name": "이영희"}])
    senior = next(e for e in v.evidences if e.id == "senior_debt")
    assert senior.grade is Grade.DANGER and senior.facts["senior_ratio_pct"] == 60
    ins = next(e for e in v.evidences if e.id == "insurance")
    pts = {p.label: p for p in evidence_view.build(ins, v)["points"]}
    assert pts["빚이 시세의 60% 이하"].tone == "danger"


def test_명단_카드_펼침은_카드_결과를_따른다():
    """집주인 이름을 못 읽었는데 'N명과 맞춰봤어요 · 같은 사람 없음'(초록)이 뜨면 안 된다(감사 위반 2)."""
    from app.services import evidence_view

    ex = _clean_extract()
    ex.current_owners = []
    v = rule_engine.evaluate(ex, deposit=100_000_000, market_price=300_000_000, blacklist_entries=[{"name": "이영희"}])
    bl = next(e for e in v.evidences if e.id == "blacklist")
    pt = evidence_view.build(bl, v)["points"][0]
    assert pt.tone == "caution" and "못 읽어" in pt.value
    # 같은 이름이면 '이름이 같은 사람'(나이는 아직 대조하지 않는다)
    ex.current_owners = [Owner(name="이영희")]
    v = rule_engine.evaluate(ex, deposit=100_000_000, market_price=300_000_000, blacklist_entries=[{"name": "이영희"}])
    bl = next(e for e in v.evidences if e.id == "blacklist")
    pt = evidence_view.build(bl, v)["points"][0]
    assert "이름이 같은 사람" in pt.value and "나이" not in pt.value
