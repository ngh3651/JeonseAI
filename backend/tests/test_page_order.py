"""사진 순서 자동 정렬 — **여기서 틀리면 남의 사진에 형광펜이 간다.**

이 기능의 위험은 둘이다:
1. 순서를 **잘못 세우면** 항목이 엉뚱하게 이어져 말소 판정이 깨진다
   → 말소된 근저당에 형광펜이 간다(이 기능 최악의 오류).
2. 정렬은 맞게 했는데 **좌표를 되돌리지 않으면** 3쪽의 표시가 1쪽 사진 위에 그려진다
   → 사용자는 전혀 다른 줄을 "여기 보세요"라고 읽는다.

그래서 테스트를 두껍게 깐다. 절반은 "정렬하면 안 되는 상황"이고,
나머지 절반은 "정렬한 뒤 좌표가 원래 사진으로 돌아오는가"다.
"""

from __future__ import annotations

import pytest

from app.schemas.internal import MoneyEntry, Owner
from app.services import highlight
from app.services.ocr_layout import OcrPage, check_document, group_lines

from tests.test_highlight import (
    PAGE_H,
    PAGE_W,
    W,
    address_row,
    as_result,
    eul_gu_page,
    extract_with,
    footer_row,
    gap_gu_page,
    make_page,
    section_row,
    header_row,
)


def paged(index: int, *, page_no: int, total: int, rows=None, marker: bool = True) -> OcrPage:
    """꼬리말 표식이 있는(또는 없는) 페이지 1장."""
    base_rows = rows if rows is not None else [
        section_row("갑구", 40),
        header_row(90),
        [W(str(page_no), 66, 150, 11), W("소유권이전", 117, 150, 75)],
    ]
    words = [w for r in base_rows for w in r] + address_row(10, "행복아파트")
    if marker:
        words += footer_row(950, page_no=page_no, total=total, issue="ABCD-EFGH-0000")
    return OcrPage(name=f"page_{index + 1}.jpg", index=index, words=words,
                   lines=group_lines(words), width=PAGE_W, height=PAGE_H)


# ══════════════════════════════════════════════════════════════════════════════
# 정렬해도 되는가 — 조건 넷
# ══════════════════════════════════════════════════════════════════════════════


def test_표식이_전부_읽히고_1부터_M까지_채워지면_정렬한다():
    check = check_document([paged(0, page_no=4, total=4), paged(1, page_no=2, total=4),
                            paged(2, page_no=1, total=4), paged(3, page_no=3, total=4)])
    assert check.page_order == [2, 1, 3, 0]
    assert check.ok_to_highlight_any is True
    assert check.ok_to_highlight_money is True


def test_한_장이라도_표식을_못_읽으면_정렬하지_않는다():
    """`?/?`가 하나라도 있으면 그 사진이 몇 쪽인지 모른다 — 세울 수 없는 순서다."""
    check = check_document([paged(0, page_no=3, total=3), paged(1, page_no=1, total=3),
                            paged(2, page_no=0, total=3, marker=False)])
    assert check.page_order is None
    assert check.ok_to_highlight_any is False
    assert check.notice and "순서" in check.notice


def test_같은_쪽_번호가_두_번_나오면_정렬하지_않는다():
    """같은 쪽을 두 번 찍었거나 다른 등기부가 섞였다 — 어느 쪽이든 세울 수 없다.

    2026-07-28: 중복 감지를 **순서 점검보다 앞**으로 옮겼다. 그래야 진단이 정확해진다 —
    예전에는 "순서가 달라요"라고 안내했지만 실제 원인은 중복이고, 사용자가 할 일도 다르다
    (다시 정렬해 올리는 게 아니라 **한 장을 빼야** 한다).
    이름·주소 같은 대조 항목은 계속 보여준다(`any=True`) — 중복이 그것까지 망치지는 않는다.
    """
    check = check_document([paged(0, page_no=2, total=3), paged(1, page_no=1, total=3),
                            paged(2, page_no=1, total=3)])
    assert check.page_order is None
    assert check.ok_to_highlight_money is False
    assert check.notice and "같은 쪽 사진" in check.notice


def test_총_쪽수가_서로_다르면_정렬하지_않는다():
    check = check_document([paged(0, page_no=2, total=3), paged(1, page_no=1, total=5)])
    assert check.page_order is None
    assert check.ok_to_highlight_any is False


def test_1부터_M이_다_채워지지_않으면_정렬하지_않는다():
    """3쪽짜리인데 1·3쪽만 있으면, 2쪽이 어디 갔는지 모른 채 이어 붙이게 된다."""
    check = check_document([paged(0, page_no=3, total=3), paged(1, page_no=1, total=3)])
    assert check.page_order is None
    assert check.ok_to_highlight_any is False


def test_순서가_이미_맞으면_정렬하지_않는다():
    """할 일이 없을 때 조용해야 한다 — 안내 문구가 괜히 뜨면 사용자가 불안해진다."""
    check = check_document([paged(0, page_no=1, total=3), paged(1, page_no=2, total=3),
                            paged(2, page_no=3, total=3)])
    assert check.page_order is None
    assert check.ok_to_highlight_any is True
    assert check.notice is None


# ══════════════════════════════════════════════════════════════════════════════
# 좌표를 원래 사진으로 되돌리는가 — 여기서 틀리면 남의 사진에 칠한다
# ══════════════════════════════════════════════════════════════════════════════


def shuffled_pair() -> list[OcrPage]:
    """을구(1쪽)와 갑구(2쪽)를 **거꾸로** 올린 상태.

    업로드 0 = 2쪽(갑구, 이름) / 업로드 1 = 1쪽(을구, 근저당)
    """
    gap = gap_gu_page(index=0)
    eul = eul_gu_page(with_cancel_row=False)
    gap_words = list(gap.words) + address_row(10, "행복아파트") + footer_row(
        950, page_no=2, total=2, issue="ABCD-EFGH-0000"
    )
    eul_words = list(eul.words) + address_row(10, "행복아파트") + footer_row(
        950, page_no=1, total=2, issue="ABCD-EFGH-0000"
    )
    return [
        OcrPage(name="a.jpg", index=0, words=gap_words, lines=group_lines(gap_words),
                width=PAGE_W, height=PAGE_H),
        OcrPage(name="b.jpg", index=1, words=eul_words, lines=group_lines(eul_words),
                width=PAGE_W, height=PAGE_H),
    ]


def test_정렬해도_좌표는_원래_업로드_인덱스로_돌아온다():
    """뷰어는 업로드 순서로 사진을 보여준다. 표시의 `page`가 문서 순서로 나가면
    **1쪽 사진 위에 2쪽의 형광펜**이 그려진다."""
    pages = shuffled_pair()
    extract = extract_with(
        current_owners=[Owner(name="홍길동")],
        mortgages=[MoneyEntry(rank_number="1", amount=36_000_000, is_canceled=False)],
    )
    result = highlight.build_highlights(extract, as_result(*pages))
    by_kind = {h.kind: h for h in result.highlights}
    assert "owner" in by_kind and "mortgage" in by_kind
    # 이름은 갑구 = 업로드 0번 사진에 있다
    assert by_kind["owner"].page == 0
    # 근저당은 을구 = 업로드 1번 사진에 있다
    assert by_kind["mortgage"].page == 1


def test_정렬하면_사용자에게_한_줄로_알린다():
    """조용히 고치면 '내가 순서대로 올렸는데 왜?'를 사용자가 영영 알 수 없다."""
    result = highlight.build_highlights(
        extract_with(current_owners=[Owner(name="홍길동")]), as_result(*shuffled_pair())
    )
    assert any("자동으로 맞췄어요" in n for n in result.checked_notes)


def test_정렬하지_않았으면_그_문구가_없다():
    extract = extract_with(current_owners=[Owner(name="홍길동")])
    result = highlight.build_highlights(extract, as_result(gap_gu_page(0)))
    assert not any("자동으로 맞췄어요" in n for n in result.checked_notes)


def test_정렬_결과가_말소_판정을_바로_세운다():
    """을구 1쪽에 근저당, 2쪽에 '1번근저당권설정등기말소'가 있는데 거꾸로 올린 경우.

    정렬하지 않으면 말소 근거 행이 **먼저** 읽혀 대상 항목을 못 찾고, 미결 말소로
    금액 표시가 통째로 보류된다. 정렬하면 말소가 제대로 잡혀 좌표가 나가지 않는다
    (둘 다 '안 칠한다'지만, 이유가 다르고 사용자 문구가 다르다).
    """
    rows_page1 = [
        section_row("을구", 40), header_row(90),
        [W("1", 66, 150, 11), W("근저당권설정", 117, 150, 91),
         W("2004년6월25일", 269, 150, 98), W("2004년6월25일", 391, 150, 100),
         W("채권최고액", 515, 150, 74), W("금36,000,000원", 606, 150, 105)],
    ]
    rows_page2 = [
        [W("2", 66, 250, 11), W("1번근저당권설정등", 117, 250, 124),
         W("2005년6월29일", 269, 250, 98)],
        [W("기말소", 117, 290, 44), W("제45409호", 270, 290, 68)],
    ]
    w1 = [w for r in rows_page1 for w in r] + address_row(10, "신정동") + footer_row(
        950, page_no=1, total=2, issue="ABCD-EFGH-0000")
    w2 = [w for r in rows_page2 for w in r] + address_row(10, "신정동") + footer_row(
        950, page_no=2, total=2, issue="ABCD-EFGH-0000")
    # 거꾸로 업로드: 0번 = 2쪽(말소 행), 1번 = 1쪽(근저당)
    pages = [
        OcrPage(name="a.jpg", index=0, words=w2, lines=group_lines(w2), width=PAGE_W, height=PAGE_H),
        OcrPage(name="b.jpg", index=1, words=w1, lines=group_lines(w1), width=PAGE_W, height=PAGE_H),
    ]
    check = check_document(pages)
    assert check.page_order == [1, 0]

    extract = extract_with(
        mortgages=[MoneyEntry(rank_number="1", amount=36_000_000, is_canceled=False)]
    )
    result = highlight.build_highlights(extract, as_result(*pages))
    assert [h for h in result.highlights if h.kind == "mortgage"] == []
    # 미결 말소가 아니라 **말소로 확인돼서** 안 칠한 것이다
    assert any("말소된 것으로 확인" in n for n in result.checked_notes)


# ══════════════════════════════════════════════════════════════════════════════
# 쪽 누락 판정 버그 — 무관한 사진이 장수를 채우는 경로 (2026-07-28 실측 발견)
# ══════════════════════════════════════════════════════════════════════════════


def test_등기부가_아닌_사진이_장수를_채워도_누락을_잡는다():
    """실측 버그: 표식 2/5·3/5·4/5·5/5 네 장 + 무관한 사진 한 장 = 5장이라
    `len(pages) < total`이 False가 되어 **'누락 없음'으로 통과**했다.
    정작 빠진 1쪽에는 표제부·표지가 있었고, 말소 근거 행이 거기 있었다면 그대로 새어 나간다.

    → 장수가 아니라 **실제로 읽힌 쪽 번호**로 판단해야 한다.
    """
    pages = [paged(i, page_no=n, total=5) for i, n in enumerate([2, 3, 4, 5])]
    stray = paged(4, page_no=0, total=0, marker=False, rows=[[W("아무거나", 100, 300, 60)]])
    check = check_document(pages + [stray])
    assert check.ok_to_highlight_money is False
    assert check.notice and "5쪽 중 4쪽" in check.notice
    assert any("안 읽힌 쪽 [1]" in r for r in check.reasons)


def test_쪽_번호가_다_나와도_표식_없는_사진이_섞이면_금액을_보류한다():
    """같은 등기부라면 **모든 쪽 꼬리말에 표식이 찍힌다.** 표식 없는 사진이 섞였다는 건
    다른 서류가 들어왔다는 신호다 — 그 서류에 무엇이 적혀 있는지 우리는 모른다."""
    pages = [paged(0, page_no=1, total=2), paged(1, page_no=2, total=2)]
    stray = paged(2, page_no=0, total=0, marker=False, rows=[[W("아무거나", 100, 300, 60)]])
    check = check_document(pages + [stray])
    assert check.ok_to_highlight_money is False
    assert check.ok_to_highlight_any is True  # 이름 같은 대조 항목은 계속 보여준다
    assert check.notice and "쪽 번호" in check.notice


def test_모든_쪽이_다_있으면_금액을_보류하지_않는다():
    check = check_document([paged(0, page_no=1, total=2), paged(1, page_no=2, total=2)])
    assert check.ok_to_highlight_money is True
    assert check.notice is None


@pytest.mark.parametrize("order", [[0, 1, 2], [2, 1, 0], [1, 0, 2], [0, 2, 1]])
def test_어떤_업로드_순서로_넣어도_같은_표시가_나온다(order):
    """정렬이 제 역할을 하면, 사용자가 어떤 순서로 올렸든 **같은 결론**이 나와야 한다.
    (좌표가 붙는 사진 번호만 달라진다.)"""
    base = [paged(i, page_no=i + 1, total=3) for i in range(3)]
    shuffled = [
        OcrPage(name=base[src].name, index=dst, words=base[src].words,
                lines=base[src].lines, width=PAGE_W, height=PAGE_H)
        for dst, src in enumerate(order)
    ]
    extract = extract_with(address="서울특별시 양천구 행복아파트")
    result = highlight.build_highlights(extract, as_result(*shuffled))
    check = check_document(shuffled)
    assert check.ok_to_highlight_any is True
    # 표시 종류·개수는 순서와 무관해야 한다
    assert sorted(h.kind for h in result.highlights) == ["address"]
    # 주소는 **문서 1쪽**에 있고, 그 쪽을 몇 번째로 올렸든 그 사진에 붙어야 한다
    assert result.highlights[0].page == order.index(0)


def test_같은_쪽_사진이_두_장이면_금액_표시를_보류한다():
    """표식이 `[1,2,3,3,4,5]`면 **정렬돼 있어** 순서 점검을 건너뛰고, 1..5가 다 채워져
    누락 점검도 통과한다. 그런데 같은 쪽을 두 번 파싱해 항목이 중복되고, 소유자 표시는
    "가장 마지막 등기" 규칙 때문에 **사본 쪽**으로 간다(2026-07-28 gap-checker 지적).
    """
    pages = [paged(i, page_no=n, total=5) for i, n in enumerate([1, 2, 3, 3, 4, 5])]
    check = check_document(pages)
    assert check.ok_to_highlight_money is False
    assert check.ok_to_highlight_any is True  # 이름·주소 같은 대조 항목은 계속 보여준다
    assert check.notice and "같은 쪽 사진" in check.notice
    assert any("쪽 번호 중복" in r for r in check.reasons)


def test_중복이_없으면_그대로_통과한다():
    pages = [paged(i, page_no=i + 1, total=3) for i in range(3)]
    check = check_document(pages)
    assert check.ok_to_highlight_money is True
    assert check.notice is None
