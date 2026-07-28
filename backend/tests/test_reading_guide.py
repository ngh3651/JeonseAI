"""등기부 읽기 가이드 — 2026-07-28에 늘어난 표시 종류 12개의 매칭 규칙.

형광펜을 "위험 표시"에서 "**등기부 읽기 가이드**"로 넓힌 작업의 테스트다.
은행원이 볼펜으로 서명란을 짚어주듯, 처음 보는 사람이 어디를 봐야 하는지 종이 위에서
안내한다. 칠하는 기준은 **그 자리에서 사용자가 할 일이 생기는 항목만**이다.

⚠ 전부 **표시 전용**이다. 판정(등급·점수)을 다루는 테스트는 여기 하나도 없다 —
  그쪽은 `test_verdict_regression.py`가 따로 봉인한다.

합성 페이지를 쓰는 이유: 실제 등기부에는 소유자 실명이 있어 커밋할 수 없다.
실데이터로만 확인 가능한 것은 `docs/ocr-highlight-findings.md`에 실측값으로 남긴다.
"""

from __future__ import annotations

import pytest

from app.schemas.internal import MoneyEntry, Owner, RegistryEntry, RegistryExtract
from app.services import highlight
from app.services.ocr import OcrResult
from app.services.ocr_layout import OcrPage, group_lines

from tests.test_highlight import (
    PAGE_H,
    PAGE_W,
    W,
    as_result,
    extract_with,
    header_row,
    make_page,
    section_row,
    viewed_at_row,
)


def kinds_of(result) -> list[str]:
    return [h.kind for h in result.highlights]


def marks(result, kind: str) -> list:
    return [h for h in result.highlights if h.kind == kind]


# ══════════════════════════════════════════════════════════════════════════════
# 합성 페이지 — 갑구 압류 계열
# ══════════════════════════════════════════════════════════════════════════════


def gap_gu_claims_page(index: int = 0) -> OcrPage:
    """갑구 1장 — 가압류(순위2, 청구금액 있음) · 압류(순위3) · 경매개시결정(순위4) · 신탁(순위5).

    실측 그대로의 배치다(2026-07-28 `out/ocr_page_*.json`):
    등기목적 키워드는 **활성 항목 8/8이 순위번호와 같은 줄**에 있었다.
    """
    rows = [section_row("갑구", 40), header_row(90)]
    # 순위2 가압류 — 청구금액이 같은 줄 (3앵커)
    rows.append([
        W("2", 66, 150, 11), W("가압류", 117, 150, 52),
        W("2019년3월4일", 269, 150, 95), W("서울중앙지방법원", 391, 150, 120),
        W("청구금액", 515, 150, 62), W("금50,000,000원", 590, 150, 108),
    ])
    # 순위3 압류 — 청구금액 칸이 **원래 없다** (2앵커)
    rows.append([
        W("3", 66, 220, 11), W("압류", 117, 220, 36),
        W("2020년5월6일", 269, 220, 95), W("압류", 391, 220, 36),
        W("권리자", 515, 220, 46),
    ])
    # 순위4 경매개시결정 (2앵커)
    rows.append([
        W("4", 66, 290, 11), W("임의경매개시결정", 117, 290, 124),
        W("2021년7월8일", 269, 290, 95), W("임의경매개시결정", 391, 290, 124),
    ])
    # 순위5 신탁 (2앵커)
    rows.append([
        W("5", 66, 360, 11), W("신탁", 117, 360, 36),
        W("2022년1월2일", 269, 360, 95), W("신탁", 391, 360, 36),
    ])
    return make_page(index, rows)


def eul_gu_lease_page(index: int = 0) -> OcrPage:
    """을구 1장 — 주택임차권(순위3, 임차보증금 있음)."""
    rows = [section_row("을구", 40), header_row(90)]
    rows.append([
        W("3", 66, 150, 11), W("주택임차권", 117, 150, 78),
        W("2023년4월5일", 269, 150, 95), W("임차권등기명령", 391, 150, 108),
        W("임차보증금", 515, 150, 74), W("금120,000,000원", 600, 150, 115),
    ])
    return make_page(index, rows)


def header_page(index: int = 0, *, area_text: str = "39.52㎡") -> OcrPage:
    """표제부·표지 1장 — 문서 제목 · 주소 줄 · 전용면적 · 토지 별도등기."""
    rows = [
        [W("등기사항전부증명서(말소사항", 200, 20, 210), W("포함)", 420, 20, 42),
         W("-", 470, 20, 8), W("집합건물", 486, 20, 62)],
        [W("[집합건물]", 33, 70, 74), W("서울특별시서초구서초동123-4", 116, 70, 220)],
        [W("전유부분의", 60, 140, 78), W("건물의", 145, 140, 46), W("표시", 198, 140, 32)],
        [W("철근콘크리트구조", 200, 190, 130), W(area_text, 340, 190, 70)],
        [W("1토지에", 200, 250, 56), W("관하여", 262, 250, 46),
         W("별도등기", 315, 250, 62), W("있음", 384, 250, 32)],
    ]
    return make_page(index, rows)


def footer_page(index: int = 0) -> OcrPage:
    """꼬리말 1장 — 열람일시 · 공동담보목록 · 신청사건 처리중."""
    rows = [
        [W("공동담보목록", 200, 100, 92), W("제2019-123호", 300, 100, 100)],
        [W("신청사건", 200, 200, 62), W("처리중", 270, 200, 46)],
    ]
    words = [w for r in rows for w in r] + viewed_at_row(950)
    return OcrPage(name=f"page_{index + 1}.jpg", index=index, words=words,
                   lines=group_lines(words), width=PAGE_W, height=PAGE_H)


def entry(**kwargs) -> RegistryEntry:
    return RegistryEntry(**kwargs)


# ══════════════════════════════════════════════════════════════════════════════
# 2앵커 — 금액 칸이 원래 없는 유형 (압류 · 경매개시결정 · 신탁)
# ══════════════════════════════════════════════════════════════════════════════


def test_압류는_순위번호와_등기목적_두_앵커로_좌표를_준다():
    """실측 근거: 압류에는 문서상 청구금액 칸이 없다(6건 중 금액이 있는 3건은 전부 가압류).

    '부분 매칭 금지'의 원래 이유는 "같은 금액이 여러 줄에 나와 항목을 지목할 수 없다"인데,
    금액이 아예 없는 유형은 그 위험이 성립하지 않는다.
    """
    extract = extract_with(seizures=[entry(rank_number="3", is_canceled=False)])
    result = highlight.build_highlights(extract, as_result(gap_gu_claims_page()))
    assert kinds_of(result) == ["seizure"]
    h = result.highlights[0]
    assert h.title == "집이 묶여 있어요 (압류)"
    assert "국가·기관이 이 집을 묶어 둔 상태" in h.body
    assert h.source and "갑구" in h.source


def test_2앵커_박스는_순위번호부터_등기목적까지만_칠한다():
    """줄 전체 폭을 쓰면 압류가 여러 건일 때 갑구가 통째로 가로 띠가 된다(findings §9.5)."""
    extract = extract_with(seizures=[entry(rank_number="3", is_canceled=False)])
    box = highlight.build_highlights(extract, as_result(gap_gu_claims_page())).highlights[0].box
    # 순위번호(x=66) ~ 등기목적 끝(x=153) → 페이지 폭의 15%를 넘지 않는다
    assert box.x < 70 / PAGE_W
    assert box.w < 0.15, "2앵커 박스가 줄 전체로 번졌다"


def test_경매개시결정과_신탁도_2앵커로_잡힌다():
    extract = extract_with(
        auction_commencements=[entry(rank_number="4", is_canceled=False)],
        trust_registrations=[entry(rank_number="5", is_canceled=False)],
    )
    result = highlight.build_highlights(extract, as_result(gap_gu_claims_page()))
    assert sorted(kinds_of(result)) == ["auction", "trust"]
    trust = marks(result, "trust")[0]
    assert "신탁원부" in trust.body  # 계약 상대가 누구인지 확인하라는 실행 가능한 지시


def test_등기목적이_다른_줄에_있으면_2앵커도_좌표를_주지_않는다():
    """앵커를 같은 줄로 묶는 조건은 2앵커에서도 그대로다 — 다른 줄 글자를 끌어오지 않는다."""
    rows = [
        section_row("갑구", 40),
        header_row(90),
        [W("3", 66, 220, 11), W("2020년5월6일", 269, 220, 95)],  # 순위번호만
        [W("압류", 117, 260, 36)],                                # 등기목적은 다음 줄
    ]
    extract = extract_with(seizures=[entry(rank_number="3", is_canceled=False)])
    result = highlight.build_highlights(extract, as_result(make_page(0, rows)))
    assert result.highlights == []


# ══════════════════════════════════════════════════════════════════════════════
# 압류 ↔ 가압류 — IE가 헷갈려도 OCR 등기목적이 가른다 (교차검증)
# ══════════════════════════════════════════════════════════════════════════════


def test_IE가_압류라고_해도_등기목적이_가압류면_칠하지_않는다():
    """실측(2026-07-28): IE는 `seizures`와 `provisional_seizures`에 **같은 순위번호**
    (2,4,7,8,9)를 중복 배정한다. OCR 등기목적이 유일한 판별 근거다.

    `압류`가 `가압류`의 부분 문자열이라 부정 전방탐색이 없으면 같은 자리에 표시가
    두 개 생긴다 — 사용자는 압류와 가압류가 둘 다 있는 줄로 읽는다.
    """
    extract = extract_with(seizures=[entry(rank_number="2", is_canceled=False)])
    result = highlight.build_highlights(extract, as_result(gap_gu_claims_page()))
    assert result.highlights == [], "가압류 행이 압류로도 잡혔다"


def test_가압류는_청구금액까지_있어야_칠한다():
    """가압류에는 청구금액 칸이 있으므로 3앵커를 유지한다(같은 금액의 다른 항목 방어)."""
    extract = extract_with(
        provisional_seizures=[entry(rank_number="2", claim_amount=50_000_000, is_canceled=False)]
    )
    result = highlight.build_highlights(extract, as_result(gap_gu_claims_page()))
    assert kinds_of(result) == ["provisional_seizure"]
    assert "5,000만원" in result.highlights[0].title


def test_가압류_금액이_사진과_다르면_칠하지_않는다():
    extract = extract_with(
        provisional_seizures=[entry(rank_number="2", claim_amount=99_000_000, is_canceled=False)]
    )
    assert highlight.build_highlights(extract, as_result(gap_gu_claims_page())).highlights == []


def test_임차권등기는_보증금까지_있어야_칠한다():
    extract = extract_with(
        lease_registrations=[entry(rank_number="3", deposit_amount=120_000_000, is_canceled=False)]
    )
    result = highlight.build_highlights(extract, as_result(eul_gu_lease_page()))
    assert kinds_of(result) == ["lease_registration"]
    assert "임차권등기명령" in result.highlights[0].body


# ══════════════════════════════════════════════════════════════════════════════
# 말소 방어 — 새 종류에도 그대로 걸린다 (자기 공격 테스트)
# ══════════════════════════════════════════════════════════════════════════════


def gap_gu_canceled_seizure_page() -> OcrPage:
    """갑구 — 순위3 압류 + 순위6 '3번압류등기말소' (말소 근거 행)."""
    rows = [section_row("갑구", 40), header_row(90)]
    rows.append([
        W("3", 66, 220, 11), W("압류", 117, 220, 36),
        W("2020년5월6일", 269, 220, 95), W("압류", 391, 220, 36),
    ])
    rows.append([
        W("6", 66, 400, 11), W("3번압류등기말소", 117, 400, 118),
        W("2021년9월9일", 269, 400, 95), W("해제", 391, 400, 30),
    ])
    return make_page(0, rows)


def test_말소된_압류에는_좌표가_가지_않는다():
    """새 종류에서도 이 기능 최악의 오류(이미 없어진 것을 현재 위험으로 보이게)를 막는다."""
    extract = extract_with(seizures=[entry(rank_number="3", is_canceled=False)])
    result = highlight.build_highlights(extract, as_result(gap_gu_canceled_seizure_page()))
    assert result.highlights == []


def test_말소_근거_행_자체에도_좌표가_가지_않는다():
    """'3번압류등기말소' 행의 등기목적에도 '압류'가 들어 있다 — 이 행을 칠하면
    사용자는 **말소를 기록한 줄**을 현재 압류로 읽는다."""
    extract = extract_with(seizures=[entry(rank_number="6", is_canceled=False)])
    result = highlight.build_highlights(extract, as_result(gap_gu_canceled_seizure_page()))
    assert result.highlights == []


def test_IE가_말소로_보면_새_종류도_애초에_대상이_아니다():
    extract = extract_with(
        seizures=[entry(rank_number="3", is_canceled=True)],
        auction_commencements=[entry(rank_number="4", is_canceled=True)],
        trust_registrations=[entry(rank_number="5", is_canceled=True)],
    )
    assert highlight.build_highlights(extract, as_result(gap_gu_claims_page())).highlights == []


def test_쪽_누락_보류는_금액_앵커_종류만_막는다():
    """쪽이 빠지면 '말소 근거 행이 그 쪽에 있을 수 있다'는 이유로 금액 표시를 보류한다.

    그 논리는 **금액을 앵커로 쓰는 종류**에만 해당한다. 압류·경매·신탁까지 같이 막으면
    빠진 쪽 때문에 오히려 위험을 숨기게 된다(보수적 편향의 방향이 뒤집힌다).
    """
    from tests.test_highlight import footer_row

    base = gap_gu_claims_page()
    words = list(base.words) + footer_row(1000, page_no=1, total=5, issue="AAPI-GJBJ-1806")
    page = OcrPage(name="p1.jpg", index=0, words=words, lines=group_lines(words),
                   width=PAGE_W, height=PAGE_H)
    extract = extract_with(
        seizures=[entry(rank_number="3", is_canceled=False)],
        provisional_seizures=[entry(rank_number="2", claim_amount=50_000_000, is_canceled=False)],
    )
    result = highlight.build_highlights(extract, as_result(page))
    assert "seizure" in kinds_of(result), "금액과 무관한 압류까지 막으면 위험을 숨긴다"
    assert "provisional_seizure" not in kinds_of(result), "금액 앵커 종류는 보류해야 한다"


# ══════════════════════════════════════════════════════════════════════════════
# OCR 텍스트 감지 (IE 스키마에 없는 3종)
# ══════════════════════════════════════════════════════════════════════════════


def test_토지_별도등기를_표제부에서_찾는다():
    """인터뷰 §R4 — 땅에 따로 걸린 빚은 이 등기부에 자세히 안 나온다."""
    result = highlight.build_highlights(extract_with(), as_result(header_page()))
    assert "separate_land" in kinds_of(result)
    body = marks(result, "separate_land")[0].body
    assert "토지 등기부도 함께 보여 달라" in body


def test_별도등기_없음은_표시하지_않는다():
    """'별도등기 없음'은 위험이 아니라 그 반대다 — 부정 표기를 잡으면 거짓 경고가 된다."""
    rows = [[W("1토지에", 200, 250, 56), W("관하여", 262, 250, 46),
             W("별도등기", 315, 250, 62), W("없음", 384, 250, 32)]]
    result = highlight.build_highlights(extract_with(), as_result(make_page(0, rows)))
    assert "separate_land" not in kinds_of(result)


def test_공동담보목록과_신청사건_처리중을_찾는다():
    result = highlight.build_highlights(extract_with(), as_result(footer_page()))
    assert "joint_collateral" in kinds_of(result)
    assert "pending_application" in kinds_of(result)
    assert "몇 채가 함께 묶여" in marks(result, "joint_collateral")[0].body


def test_텍스트_감지_3종은_판정에_쓰이지_않는다():
    """인터뷰 §R4는 이 3종을 '확인 필요' 룰로 올리라고 권고하지만, 등급을 바꾸려면
    권위 출처 + decisions.md 선기록이 필요하다(2026-07-28 보류). 표시만 한다."""
    from app.services import rule_engine

    extract = extract_with(current_owners=[Owner(name="소유자D")])
    before = rule_engine.evaluate(extract, deposit=100_000_000, market_price=200_000_000)
    highlight.build_highlights(extract, as_result(header_page(), footer_page(1)))
    after = rule_engine.evaluate(extract, deposit=100_000_000, market_price=200_000_000)
    assert before.grade == after.grade
    assert before.gauge_progress == after.gauge_progress


# ══════════════════════════════════════════════════════════════════════════════
# 문서 스칼라 — 주소 · 면적 · 서류 종류 · 뗀 날
# ══════════════════════════════════════════════════════════════════════════════


def test_주소와_서류종류와_면적을_짚어준다():
    extract = extract_with(address="서울특별시 서초구 서초동 123-4", exclusive_area_sqm=39.52)
    result = highlight.build_highlights(extract, as_result(header_page()))
    assert "address" in kinds_of(result)
    assert "doc_title" in kinds_of(result)
    assert "area" in kinds_of(result)
    assert "39.52㎡" in marks(result, "area")[0].title
    assert "말소사항 포함" in marks(result, "doc_title")[0].body


def test_IE가_주소를_못_읽었으면_주소를_짚지_않는다():
    """IE 결과가 기준이라는 원칙을 새 종류에도 유지한다 — 사진에만 있는 것을 가리키지 않는다."""
    result = highlight.build_highlights(extract_with(), as_result(header_page()))
    assert "address" not in kinds_of(result)


def test_면적_숫자가_사진에_없으면_짚지_않는다():
    """IE 값과 사진이 어긋나면 표시 보류 — 틀린 자리에 칠하는 것보다 낫다."""
    extract = extract_with(exclusive_area_sqm=84.98)
    result = highlight.build_highlights(extract, as_result(header_page(area_text="39.52㎡")))
    assert "area" not in kinds_of(result)


def test_주소_줄은_여러_쪽에_반복돼도_한_곳만_짚는다():
    """주소는 모든 쪽 머리에 인쇄된다. 다 칠하면 '확인할 곳'이 쪽수만큼 부풀어
    개수 문구가 거짓말이 된다."""
    extract = extract_with(address="서울특별시 서초구 서초동 123-4")
    result = highlight.build_highlights(
        extract, as_result(header_page(0), header_page(1), header_page(2))
    )
    assert len(marks(result, "address")) == 1
    assert marks(result, "address")[0].page == 0  # 가장 앞 쪽


def test_뗀_날을_꼬리말에서_짚어준다():
    """인터뷰 E3 '발급 당일 원칙' — 이미 글자로 띄우고 있는데, 종이의 그 줄을 짚으면 더 세다."""
    result = highlight.build_highlights(extract_with(), as_result(footer_page()))
    assert "viewed_at" in kinds_of(result)
    assert "2026.07.09" in marks(result, "viewed_at")[0].title
    assert "서명하는 날" in marks(result, "viewed_at")[0].body


# ══════════════════════════════════════════════════════════════════════════════
# 줄무늬 방지 — 종류별 상한 · 읽는 순서
# ══════════════════════════════════════════════════════════════════════════════


def many_mortgages_page() -> OcrPage:
    """을구 — 유효 근저당 7건 (상한 5건을 넘긴다)."""
    rows = [section_row("을구", 40), header_row(90)]
    for i in range(1, 8):
        y = 150 + (i - 1) * 60
        rows.append([
            W(str(i), 66, y, 11), W("근저당권설정", 117, y, 91),
            W("2020년1월1일", 269, y, 95), W("설정계약", 391, y, 60),
            W("채권최고액", 515, y, 74), W(f"금{i}0,000,000원", 606, y, 105),
        ])
    return make_page(0, rows)


def test_같은_종류가_5건을_넘으면_큰_것부터_5건만_칠한다():
    extract = extract_with(
        mortgages=[
            MoneyEntry(rank_number=str(i), amount=i * 10_000_000, is_canceled=False)
            for i in range(1, 8)
        ]
    )
    result = highlight.build_highlights(extract, as_result(many_mortgages_page()))
    assert len(marks(result, "mortgage")) == highlight.MAX_MARKS_PER_KIND
    # 금액 내림차순 상위 5건 = 7,6,5,4,3천만원
    titles = " ".join(h.title for h in marks(result, "mortgage"))
    assert "7,000만원" in titles and "3,000만원" in titles
    assert "1,000만원" not in titles and "2,000만원" not in titles


def test_상한으로_생략한_것은_사용자에게_말해준다():
    """침묵하면 사용자는 '앱이 2건을 놓쳤다'로 읽는다 — 개수가 안 맞는 이유를 대야 한다."""
    extract = extract_with(
        mortgages=[
            MoneyEntry(rank_number=str(i), amount=i * 10_000_000, is_canceled=False)
            for i in range(1, 8)
        ]
    )
    result = highlight.build_highlights(extract, as_result(many_mortgages_page()))
    joined = " ".join(result.checked_notes)
    assert "7건 중 큰 것부터 5건만" in joined
    assert "나머지 2건" in joined
    # ⚠ 앱은 `kUnmarkedNoteMarkers`(표시하지 않았·찾지 못했·생략했)가 든 문장만 그린다.
    #   예전 문구는 "…5건만 표시했어요"로 끝나 **화면에 아예 안 나왔다**(페르소나 2인이 각각 발견).
    assert "표시하지 않았어요" in joined
    assert "빚은 7건" in joined  # 조사도 맞아야 한다


def test_표시는_등기부_읽는_순서로_번호가_매겨진다():
    """뱃지 번호 순서 자체가 '등기부는 이렇게 읽는 겁니다' 가이드가 된다.

    표제부(주소·면적·별도등기) → 표지(서류 종류) → 갑구(소유자 → 압류 계열)
    → 을구(근저당 → 임차권 → 공동담보) → 문서 상태 → 꼬리말(뗀 날)
    """
    extract = extract_with(
        address="서울특별시 서초구 서초동 123-4",
        exclusive_area_sqm=39.52,
        seizures=[entry(rank_number="3", is_canceled=False)],
        lease_registrations=[entry(rank_number="3", deposit_amount=120_000_000, is_canceled=False)],
    )
    result = highlight.build_highlights(
        extract,
        as_result(header_page(0), gap_gu_claims_page(1), eul_gu_lease_page(2), footer_page(3)),
    )
    order = kinds_of(result)
    expected = [
        "address", "area", "separate_land", "doc_title",
        "seizure", "lease_registration", "joint_collateral",
        "pending_application", "viewed_at",
    ]
    assert order == expected
    assert [h.badge for h in result.highlights] == list(range(1, len(order) + 1))


@pytest.mark.parametrize("kind", sorted(highlight._SPECS))
def test_모든_종류에_문구와_출처가_있다(kind: str):
    """문구 없는 종류가 섞이면 시트가 빈 채로 열린다 — 화면에서만 드러나는 사고다."""
    spec = highlight._SPECS[kind]
    if kind != "owner":  # owner만 개인/법인 분기라 body가 비어 있다
        assert spec.body.strip(), f"{kind}에 설명 문구가 없다"
    assert spec.source and "등기부" in spec.source


def test_종류_정의와_문구_표가_어긋나지_않는다():
    """`_SPECS`(문구)와 `_KIND_NOUN`(개수 문구)이 갈라지면 안내 문장이 kind 문자열을 노출한다."""
    assert set(highlight._SPECS) == set(highlight._KIND_NOUN)


# ══════════════════════════════════════════════════════════════════════════════
# 자기 공격 — "말소된 항목에 좌표가 가는 경로"를 스스로 찾아 막는다
#
# 라운드 4에서 근저당에 했던 것과 같은 방식이다. 종류가 15개로 늘면서 조합이 폭발했으므로,
# **말소를 못 가려낸 상태에서 무엇이 새어 나가는지**를 종류별로 다시 훑는다.
# ══════════════════════════════════════════════════════════════════════════════


def unbound_cancel_page() -> OcrPage:
    """갑구 — 압류(순위3) + **대상을 못 찾는 말소 근거 행**(존재하지 않는 순위 99를 말소).

    "무언가 말소됐는데 무엇인지 모른다" 상태를 만든다. 이건 추정이 아니라 **사실**이다 —
    올린 쪽에 말소 행이 있는데 우리가 그 대상을 못 찾았다.
    """
    rows = [section_row("갑구", 40), header_row(90)]
    rows.append([
        W("3", 66, 220, 11), W("압류", 117, 220, 36),
        W("2020년5월6일", 269, 220, 95), W("압류", 391, 220, 36),
    ])
    rows.append([
        W("4", 66, 400, 11), W("99번압류등기말소", 117, 400, 124),
        W("2021년9월9일", 269, 400, 95),
    ])
    return make_page(0, rows)


def test_말소를_못_가려낸_상태면_2앵커_종류도_막는다():
    """2026-07-28 자기 공격으로 찾은 구멍.

    처음엔 "2앵커 종류는 금액과 무관하니 보류에서 빼자"고 했는데, **말소 미결**은
    금액 문제가 아니라 **말소 판정이 지금 깨져 있다는 증거**다. 그 상태에서 압류를 칠하면
    말소된 압류를 칠할 수 있다. → 이 경우에는 표 항목을 전부 막는다.
    """
    extract = extract_with(seizures=[entry(rank_number="3", is_canceled=False)])
    result = highlight.build_highlights(extract, as_result(unbound_cancel_page()))
    assert result.highlights == [], "말소 미결 상태에서 압류가 새어 나갔다"
    assert result.notice and "말소" in result.notice


def test_말소_미결이_아니면_2앵커_종류는_계속_보인다():
    """반대 방향 방어 — 쪽이 한 장 잘렸다고 가장 심각한 위험까지 화면에서 지우면 안 된다."""
    from tests.test_highlight import footer_row

    base = gap_gu_claims_page()
    words = list(base.words) + footer_row(1000, page_no=1, total=5, issue="AAPI-GJBJ-1806")
    page = OcrPage(name="p1.jpg", index=0, words=words, lines=group_lines(words),
                   width=PAGE_W, height=PAGE_H)
    extract = extract_with(seizures=[entry(rank_number="3", is_canceled=False)])
    result = highlight.build_highlights(extract, as_result(page))
    assert "seizure" in kinds_of(result)


@pytest.mark.parametrize(
    "field,rank",
    [
        ("seizures", "3"),
        ("provisional_seizures", "2"),
        ("auction_commencements", "4"),
        ("trust_registrations", "5"),
        ("lease_registrations", "3"),
    ],
)
def test_어떤_종류도_말소_미결을_뚫지_못한다(field, rank):
    """종류가 15개로 늘면 "이 종류만 예외"가 한 줄씩 늘어나기 쉽다. 전 종류를 한 번에 훑는다."""
    kwargs = {field: [entry(rank_number=rank, claim_amount=50_000_000,
                            deposit_amount=120_000_000, is_canceled=False)]}
    result = highlight.build_highlights(extract_with(**kwargs), as_result(unbound_cancel_page()))
    assert result.highlights == [], f"{field}가 말소 미결 상태를 뚫었다"


def test_문서_스칼라는_말소와_무관하므로_계속_보인다():
    """주소·서류 종류·뗀 날은 표 항목이 아니다 — 말소 개념이 없다.
    여기까지 막으면 "사진에 아무것도 없다"가 되어 사용자가 앱이 고장 났다고 읽는다."""
    base = unbound_cancel_page()
    words = list(base.words) + [w for r in [
        [W("[집합건물]", 33, 10, 74), W("서울특별시서초구서초동123-4", 116, 10, 220)]
    ] for w in r]
    page = OcrPage(name="p.jpg", index=0, words=words, lines=group_lines(words),
                   width=PAGE_W, height=PAGE_H)
    extract = extract_with(address="서울특별시 서초구 서초동 123-4")
    result = highlight.build_highlights(extract, as_result(page))
    assert "address" in kinds_of(result)


def test_말소된_항목은_상한_계산에도_들어가지_않는다():
    """상한(5건)을 채우느라 말소된 것이 상위 5건에 끼어들면 유효한 것이 밀려난다."""
    rows = [section_row("을구", 40), header_row(90)]
    for i in range(1, 8):
        y = 150 + (i - 1) * 60
        rows.append([
            W(str(i), 66, y, 11), W("근저당권설정", 117, y, 91),
            W("2020년1월1일", 269, y, 95), W("설정계약", 391, y, 60),
            W("채권최고액", 515, y, 74), W(f"금{i}0,000,000원", 606, y, 105),
        ])
    page = make_page(0, rows)
    # IE가 큰 금액 2건을 말소로 본다 → 남는 5건이 전부 칠해져야 한다
    extract = extract_with(mortgages=[
        MoneyEntry(rank_number=str(i), amount=i * 10_000_000, is_canceled=(i >= 6))
        for i in range(1, 8)
    ])
    result = highlight.build_highlights(extract, as_result(page))
    titles = " ".join(h.title for h in marks(result, "mortgage"))
    assert len(marks(result, "mortgage")) == 5
    assert "6,000만원" not in titles and "7,000만원" not in titles  # 말소분은 빠진다
    assert "1,000만원" in titles  # 그래서 작은 것까지 자리가 난다


# ══════════════════════════════════════════════════════════════════════════════
# 문구 규율 — 카드에 보이는 것은 `body`의 **첫 문장**뿐이다
# ══════════════════════════════════════════════════════════════════════════════

# 2026-07-27 이전에 이미 리뷰를 거친 문구 2종. 이번 규율의 소급 대상이 아니다
# (바꾸려면 별도 결정이 필요하다 — 기록된 문구를 조용히 갈아치우지 않는다).
_LEGACY_BODIES = {"mortgage", "jeonse"}


@pytest.mark.parametrize(
    "kind", sorted(k for k, s in highlight._SPECS.items() if s.body and k not in _LEGACY_BODIES)
)
def test_첫_문장이_행동으로_끝난다(kind: str):
    """카드 캐러셀은 `body`의 **첫 문장만** 요약으로 보여준다(`analysis_report.dart`).

    상황 설명이 먼저 오면 카드에는 무서운 사실만 남고 할 일은 시트를 열어야 보인다 —
    "심장이 내려앉았는데 뭘 하라는 말이 없어요"(2026-07-28 지수).
    """
    line = highlight._SPECS[kind].body.split("\n")[0]
    # 한 줄에 두 문장이 올 수 있다. **첫 문장**이 행동이어야 한다.
    first = line.split(". ")[0].rstrip()
    assert first.endswith(("하세요", "마세요", "보세요", "안 돼요", "하세요.", "마세요.", "보세요.", "안 돼요.")), (
        f"{kind}의 첫 문장이 행동이 아니다: {first[:50]}"
    )


@pytest.mark.parametrize("kind", sorted(highlight._SPECS))
def test_화면에_없는_이름으로_안내하지_않는다(kind: str):
    """리포트의 그 목록은 화면에서 **'근거 살펴보기'** 라고 불린다.
    "근거 카드"라고 쓰면 사용자가 어디인지 못 찾는다(2026-07-28 지수)."""
    assert "근거 카드" not in highlight._SPECS[kind].body


def test_안내_문장에도_같은_규율이_적용된다():
    from app.services import cross_check

    extract = extract_with(current_owners=[Owner(name="홍길동")])
    notes = " ".join(highlight.build_highlights(extract, as_result(gap_gu_claims_page())).checked_notes)
    assert "근거 카드" not in notes
    joined = " ".join(cross_check.to_notes(cross_check.compare(extract, extract)))
    assert "근거 카드" not in joined


def test_압류가_있는데_위치를_못_짚으면_그_사실이_화면에_나간다():
    """앱은 `kUnmarkedNoteMarkers`가 든 문장만 화면에 그린다. 압류·가처분이 있는데
    위치를 못 짚으면 표시가 0건이 되는데, 이 경고까지 필터에 걸리면 **화면이 통째로 빈다.**

    가처분(`provisional_dispositions`)은 아직 매칭 규칙이 없어 **항상** 이 경로다
    (2026-07-28 gap-checker 지적).
    """
    extract = extract_with(
        provisional_dispositions=[entry(rank_number="3", is_canceled=False)]
    )
    result = highlight.build_highlights(extract, as_result(gap_gu_claims_page()))
    assert result.highlights == []  # 가처분은 칠할 규칙이 없다
    joined = " ".join(result.checked_notes)
    assert "1건 있어요" in joined
    assert "표시하지 않았어요" in joined, "앱 필터를 통과하지 못해 화면이 빈다"
