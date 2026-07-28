"""교차검증 — 두 추출 경로의 불일치를 **화면에 드러내되, 판정에는 닿지 않게** 한다.

이 파일의 절반은 문구 테스트고, 나머지 절반은 **경계 테스트**다.
경계란 이것이다: 두 번째 경로(LLM 구조화)가 항목을 더 찾아도, 덜 찾아도,
**등급·게이지·선순위채권합계는 한 글자도 달라지지 않는다.**

왜 이 경계가 위험한가: 두 번째 경로가 IE보다 정확한 순간이 실제로 있다
(2026-07-28 실측 — IE는 압류/가압류에 같은 순위번호를 중복 배정했고, OCR 등기목적만이
그것을 갈랐다). 그러면 "더 정확한 쪽을 판정에 쓰자"는 생각이 자연스럽게 든다.
그 순간 CLAUDE.md 3절("LLM은 판정 결과를 바꿀 수 없다")이 깨진다.
더 정확한 경로를 판정에 쓰려면 **규칙 엔진의 입력을 바꾸는 결정**을 문서화해야 하고,
그건 이 파일을 고치는 일이 아니라 decisions.md에 스토리를 남기는 일이다.
"""

from __future__ import annotations

from app.schemas.internal import MoneyEntry, Owner, RegistryEntry, RegistryExtract
from app.services import cross_check, highlight, report_builder, rule_engine
from app.services.ocr import OcrResult

from tests.test_highlight import as_result, eul_gu_page, gap_gu_page


def ie_extract() -> RegistryExtract:
    """문서 판독(IE) — 압류 3건이라고 본다."""
    return RegistryExtract(
        address="서울특별시 서초구 서초동 123-4",
        current_owners=[Owner(name="홍길동")],
        mortgages=[MoneyEntry(rank_number="1", amount=36_000_000, is_canceled=False)],
        seizures=[
            RegistryEntry(rank_number=str(r), is_canceled=False) for r in ("2", "4", "9")
        ],
    )


def llm_extract(seizure_ranks: tuple[str, ...] = ("9",)) -> RegistryExtract:
    """사진 판독(LLM) — 등기목적을 읽어 압류를 더 적게(정확하게) 본다."""
    return RegistryExtract(
        address="서울특별시 서초구 서초동 123-4",
        current_owners=[Owner(name="홍길동")],
        mortgages=[MoneyEntry(rank_number="1", amount=36_000_000, is_canceled=False)],
        seizures=[RegistryEntry(rank_number=r, is_canceled=False) for r in seizure_ranks],
    )


# ══════════════════════════════════════════════════════════════════════════════
# 대조 자체
# ══════════════════════════════════════════════════════════════════════════════


def test_두_경로가_같으면_일치로_센다():
    check = cross_check.compare(ie_extract(), ie_extract(), provider="exaone")
    assert check.ran is True
    assert check.disagreed == []
    labels = {c.label for c in check.agreed}
    assert "빚(근저당)" in labels and "압류" in labels


def test_두_경로가_다르면_불일치로_센다():
    check = cross_check.compare(ie_extract(), llm_extract(), provider="exaone")
    disagreed = {c.label: (c.ie_count, c.llm_count) for c in check.disagreed}
    assert disagreed == {"압류": (3, 1)}


def test_말소된_항목은_양쪽_다_세지_않는다():
    """말소분까지 세면 '개수가 다르다'는 거짓 경보가 난다."""
    ie = RegistryExtract(
        seizures=[
            RegistryEntry(rank_number="2", is_canceled=True),
            RegistryEntry(rank_number="9", is_canceled=False),
        ]
    )
    llm = RegistryExtract(seizures=[RegistryEntry(rank_number="9", is_canceled=False)])
    assert cross_check.compare(ie, llm).disagreed == []


def test_두_번째_경로가_없으면_그_사실을_말한다():
    """예전에는 빈 목록이라 429·타임아웃·키 없음이 화면에서 전부 똑같이 '무음'이었다.
    그러면 교차검증 문장이 있다가 없다가 하는 이유를 아무도 알 수 없다."""
    check = cross_check.compare(ie_extract(), None, error="키 없음")
    assert check.ran is False
    notes = cross_check.to_notes(check)
    assert len(notes) == 1
    assert "한 가지 방법으로만" in notes[0]
    assert "분석 결과에는 영향이 없어요" in notes[0]


# ══════════════════════════════════════════════════════════════════════════════
# 사용자에게 보이는 문장
# ══════════════════════════════════════════════════════════════════════════════


def test_일치하면_두_방법으로_확인했다고_말해준다():
    """'두 방법으로 읽어 봤다'는 사실 자체가 가장 강한 신뢰 장치다."""
    notes = cross_check.to_notes(cross_check.compare(ie_extract(), ie_extract()))
    joined = " ".join(notes)
    assert "2가지 방법으로 교차 확인" in joined
    assert "일치" in joined


def test_판정_기준을_사실대로_말한다():
    """"더 엄격한 쪽으로 계산했다"고 쓰면 거짓말이 된다 — 판정은 언제나 IE 기준이고
    IE가 **더 적게** 잡는 경우가 실제로 있다. 그때는 적게 잡았다고 그대로 말해야 한다."""
    # IE가 더 많이 잡은 경우
    more = cross_check.to_notes(cross_check.compare(ie_extract(), llm_extract(("9",))))
    assert "더 많이 잡은 3건 기준" in " ".join(more)
    # IE가 **더 적게** 잡은 경우
    fewer = cross_check.to_notes(
        cross_check.compare(llm_extract(("9",)), ie_extract())
    )
    joined = " ".join(fewer)
    assert "1건 기준으로 했지만 다른 방법에서는 3건" in joined
    assert "등기부 원본을 꼭 한 번 더 확인하세요" in joined


def test_불일치하면_숫자를_그대로_말해준다():
    """조용히 넘어가면 사용자는 '앱이 놓쳤다'로 읽는다 — 개수와 이유를 함께 댄다."""
    check = cross_check.compare(ie_extract(), llm_extract())
    notes = cross_check.to_notes(check, unplaced={"seizures": 2})
    joined = " ".join(notes)
    assert "(3건 / 1건)" in joined
    assert "2건은 위치를 짚지 못해" in joined
    # 앱은 이 표식이 든 문장만 화면에 그린다 — 없으면 조용히 사라진다
    assert "표시하지 않았어요" in joined
    # 조사가 맞아야 한다 ("압류은" 금지)
    assert "압류은" not in joined


def test_불일치_문장에_실명이_들어가지_않는다():
    """개수와 참·거짓만 — 이름·주소가 checkedNotes로 새어 나가면 안 된다."""
    ie = ie_extract()
    notes = cross_check.to_notes(cross_check.compare(ie, llm_extract()), unplaced={"seizures": 2})
    joined = " ".join(notes)
    assert "홍길동" not in joined
    assert "서초동" not in joined


def test_교차검증_문구가_checkedNotes에_실린다():
    check = cross_check.compare(ie_extract(), llm_extract())
    result = highlight.build_highlights(
        ie_extract(), as_result(gap_gu_page(0), eul_gu_page()), cross=check
    )
    assert any("교차 확인" in n or "문서 판독에서" in n for n in result.checked_notes)


# ══════════════════════════════════════════════════════════════════════════════
# 경계 — 두 번째 경로는 판정에 닿지 않는다
# ══════════════════════════════════════════════════════════════════════════════


def test_두_번째_경로가_더_많이_찾아도_등급이_같다():
    """이 테스트가 깨지면 LLM이 판정을 만든 것이다 — CLAUDE.md 3절 위반."""
    ie = ie_extract()
    kwargs = dict(deposit=100_000_000, market_price=300_000_000)
    base = rule_engine.evaluate(ie, **kwargs)

    for ranks in ((), ("9",), ("2", "4", "9"), ("2", "3", "4", "5", "9")):
        cross_check.compare(ie, llm_extract(ranks))  # 대조를 돌려도
        after = rule_engine.evaluate(ie, **kwargs)  # 판정은 그대로다
        assert after.grade == base.grade
        assert after.gauge_progress == base.gauge_progress
        assert after.senior_debt_amount == base.senior_debt_amount


def test_교차검증_결과가_리포트_판정_필드를_바꾸지_않는다():
    ie = ie_extract()
    kwargs = dict(deposit=100_000_000, market_price=300_000_000, alias=None)
    plain = report_builder.build_report(ie, **kwargs)

    check = cross_check.compare(ie, llm_extract(("2", "3", "4", "5", "9")))
    marked = highlight.build_highlights(ie, as_result(gap_gu_page(0)), cross=check)
    with_cross = report_builder._build(
        ie,
        **kwargs,
        highlights=marked.highlights,
        checked_notes=marked.checked_notes,
    )[0]

    for field in ("grade", "gaugeProgress", "deposit", "marketPrice", "seniorDebtAmount"):
        assert getattr(plain, field) == getattr(with_cross, field)
    assert [(e.id, e.grade) for e in plain.evidences] == [
        (e.id, e.grade) for e in with_cross.evidences
    ]
    # 그런데 고지 문장은 늘어야 한다 — 조용하면 안 된다
    assert any("두 방법으로 읽었더니" in n or "교차 확인" in n for n in with_cross.checkedNotes)


def test_두_번째_경로_실패는_분석을_막지_않는다():
    """LLM이 죽어도 리포트는 지금과 똑같이 완성된다."""
    check = cross_check.compare(ie_extract(), None, provider="exaone", error="LlmError")
    result = highlight.build_highlights(ie_extract(), as_result(gap_gu_page(0)), cross=check)
    assert result.highlights, "두 번째 경로가 없다고 표시까지 사라지면 안 된다"
    assert result.checked_notes


def test_OCR이_전멸해도_침묵하지_않는다():
    """예전에는 빈 결과만 돌려줘 화면에 사진만 뜨고 범례·회색 줄이 통째로 사라졌다 —
    사용자는 "표시할 게 없다"와 "못 읽었다"를 구분할 수 없다."""
    check = cross_check.compare(ie_extract(), None, error="OCR 결과 없음")
    result = highlight.build_highlights(ie_extract(), OcrResult(errors=["timeout"]), cross=check)
    assert result.highlights == []
    assert result.checked_notes, "OCR 전멸 시 아무 말도 안 하면 안 된다"
    assert result.notice and "읽지 못" in result.notice
    assert any("표시하지 않았어요" in n for n in result.checked_notes)
