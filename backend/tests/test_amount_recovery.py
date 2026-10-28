"""못 읽은 빚 금액 없애기 (2026-10-29 QA — 규혁 결정: 1순위 다 읽기, 2순위 그 쪽 다시 찍기).

① IE가 금액을 비운 살아 있는 근저당 → 같은 사진의 같은 순위 항목 글자(OCR)에서 다시 읽는다.
② 금액 후보가 둘 이상이거나 항목을 못 찾으면 채우지 않는다(지어내지 않는다) → 그 쪽을 다시 찍기 대상으로.
③ 다시 찍기 안내는 다른 카드를 '확인 필요'로 올리지 않는다(빚 카드만 금액 미상으로 확인 필요).
"""

from __future__ import annotations

from app.schemas.contract import CaptureCheck
from app.schemas.internal import RegistryExtract
from app.services import amount_recovery, capture_check
from app.services.ocr_layout import group_lines, OcrPage

from tests.test_highlight import PAGE_H, PAGE_W, W, eul_gu_page, header_row, section_row


def extract_with(amount):
    return RegistryExtract.from_raw(
        {
            "address": "서울특별시 ○○구 ○○동 1-1 제101호",
            "current_owners": [{"name": "최미상"}],
            "mortgages": [{"rank_number": "1", "max_claim_amount": amount, "is_canceled": False}],
        }
    )


def test_ie_blank_amount_is_read_from_same_ocr_row():
    extract = extract_with(None)
    assert extract.mortgages[0].amount_unknown
    result = amount_recovery.recover_missing_amounts(extract, [eul_gu_page(with_cancel_row=False)], check=None)
    assert result.filled == 1 and result.still_unknown == 0
    assert extract.mortgages[0].amount == 36_000_000
    assert not extract.mortgages[0].amount_unknown
    assert "3,600만원" in result.notes[0]


def test_amount_on_next_line_of_same_item_is_still_found():
    extract = extract_with(None)
    page = eul_gu_page(amount_on_rank_line=False, with_cancel_row=False)
    result = amount_recovery.recover_missing_amounts(extract, [page], check=None)
    assert extract.mortgages[0].amount == 36_000_000 and result.filled == 1


def test_korean_numeral_amount_in_ocr():
    rows = [section_row("을구", 40), header_row(90)]
    rows.append([W("1", 66, 150, 11), W("근저당권설정", 117, 150, 91), W("채권최고액", 515, 150, 74),
                 W("금일억이천만원정", 606, 150, 120)])
    words = [w for r in rows for w in r]
    page = OcrPage(name="p.jpg", index=0, words=words, lines=group_lines(words), width=PAGE_W, height=PAGE_H)
    extract = extract_with(None)
    amount_recovery.recover_missing_amounts(extract, [page], check=None)
    assert extract.mortgages[0].amount == 120_000_000


def test_two_different_amounts_are_not_guessed():
    rows = [section_row("을구", 40), header_row(90)]
    rows.append([W("1", 66, 150, 11), W("근저당권설정", 117, 150, 91), W("채권최고액", 515, 150, 74),
                 W("금36,000,000원", 606, 150, 105)])
    rows.append([W("금48,000,000원", 606, 190, 105)])
    words = [w for r in rows for w in r]
    page = OcrPage(name="p.jpg", index=0, words=words, lines=group_lines(words), width=PAGE_W, height=PAGE_H)
    extract = extract_with(None)
    result = amount_recovery.recover_missing_amounts(extract, [page], check=None)
    assert extract.mortgages[0].amount is None  # 어느 것인지 모르면 채우지 않는다
    assert result.still_unknown == 1 and result.unread_pages == [0]


def test_rank_not_found_points_to_eul_gu_pages_for_retake():
    extract = RegistryExtract.from_raw(
        {"mortgages": [{"rank_number": "7", "max_claim_amount": None, "is_canceled": False}]}
    )
    result = amount_recovery.recover_missing_amounts(extract, [eul_gu_page(with_cancel_row=False)], check=None)
    assert result.filled == 0 and result.still_unknown == 1
    assert result.unread_pages == [0]


def test_known_amounts_are_untouched():
    extract = extract_with(50_000_000)
    result = amount_recovery.recover_missing_amounts(extract, [eul_gu_page(with_cancel_row=False)], check=None)
    assert extract.mortgages[0].amount == 50_000_000 and result.filled == 0


def test_unread_amount_becomes_retake_pill_even_without_capture_check():
    out = capture_check.add_unread_amount_pages(None, [1], image_count=3)
    assert out.pages[0].index == 1 and out.pages[0].issues == ["amount_unread"]
    assert "빚 금액" in out.pages[0].tip
    merged = capture_check.add_unread_amount_pages(
        CaptureCheck(ok=False, pages=[{"index": 1, "issues": ["blurry"]}]), [1], image_count=3
    )
    assert merged.pages[0].issues == ["blurry", "amount_unread"]
