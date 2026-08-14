"""말소 확인분을 판정 계산에서 빼는 계층 (2026-08-14 D10).

이 파일이 지키는 것은 **"뺐다"가 아니라 "함부로 빼지 않는다"** 쪽이다.
잘못 빼면 있는 위험이 화면에서 사라진다 — 이 앱에서 가장 나쁜 실수다.
그래서 정상 제외 1건마다 보류 조건 테스트가 여러 건 붙는다.
"""

from __future__ import annotations

from app.schemas.internal import Grade, RegistryExtract
from app.services import cancellation, rule_engine
from app.services.ocr_layout import OcrPage, check_document, group_lines

from tests.test_highlight import (
    PAGE_W,
    PAGE_H,
    W,
    address_row,
    as_result,
    eul_gu_page,
    footer_row,
    header_row,
    make_page,
    section_row,
)

# 합성 을구는 순위1 근저당 3,600만원 + 순위2 '1번근저당권설정등기말소'다.
CANCELED_AMOUNT = 36_000_000


def _extract(mortgages=None, **kwargs) -> RegistryExtract:
    """IE가 '말소인 줄 모르고' 준 상태를 만든다 — `is_canceled`가 False다.

    ⚠ 배열 키를 **하나도 빠뜨리지 않고** 채운다. 하나라도 없으면 `doc_incomplete`가
      켜져 문서 신뢰도 게이트가 모든 '양호'를 '확인 필요'로 내린다 — 그러면 등급 변화를
      보는 테스트가 말소 제외가 아니라 게이트를 측정하게 된다.
    """
    raw = {key: [] for key in RegistryExtract.LIST_KEYS}
    raw.update(
        {
            # ⚠ 호수까지 적는다. 호수가 없으면 단독·다가구로 보여 전세가율 카드가
            #   '확인 필요'로 보류되고, 종합 등급이 그 보류에 붙들려 움직이지 않는다.
            "address": "서울특별시 샘플구 샘플동 1-1 샘플빌라 제101호",
            "exclusive_area_sqm": 59.9,
            "current_owners": [{"name": "홍길동"}],
            "mortgages": mortgages
            if mortgages is not None
            else [
                {"rank_number": "1", "max_claim_amount": "금36,000,000원", "is_canceled": False},
            ],
        }
    )
    raw.update(kwargs)
    return RegistryExtract.from_raw(raw)


def _pages(*pages: OcrPage):
    """(OcrResult, DocumentCheck) — 실사용과 같은 순서로 만든다."""
    result = as_result(*pages)
    return result, check_document(list(pages))


def _apply(extract: RegistryExtract, *pages: OcrPage):
    ocr_result, check = _pages(*pages)
    return cancellation.apply_confirmed_cancellations(extract, ocr_result, check=check)


# ══════════════════════════════════════════════════════════════════════════════
# ① 근거가 결합된 말소는 계산에서 빠진다
# ══════════════════════════════════════════════════════════════════════════════


def test_말소_근거가_결합된_근저당은_선순위채권_합계에서_빠진다():
    """이 테스트가 D10의 발단이다.

    앱은 `1번근저당권설정등기말소` 행을 근거로 이 근저당을 **하이라이트에서는 이미
    빼고 있었다.** 그런데 선순위채권 합계에는 그대로 넣고 있었다 — 말소된 줄 알면서
    없는 빚을 세고 있었다는 뜻이다. 이제는 합계에서도 빠진다.
    """
    extract = _extract()
    assert cancellation.senior_debt_total(extract) == CANCELED_AMOUNT

    result = _apply(extract, eul_gu_page())

    assert result.applied is True
    assert result.count == 1
    assert result.senior_before == CANCELED_AMOUNT
    assert result.senior_after == 0
    assert cancellation.senior_debt_total(extract) == 0
    assert extract.mortgages[0].is_canceled is True


def test_제외한_근거를_사람이_읽을_수_있게_남긴다():
    """근거 없이 위험을 지우지 않는다 — 어느 페이지 어느 줄의 어떤 문구인지 남는다."""
    result = _apply(_extract(), eul_gu_page())

    (excluded,) = result.excluded
    assert excluded.section == "을구"
    assert excluded.rank == "1"
    assert excluded.label == "근저당"
    assert excluded.amount == CANCELED_AMOUNT
    assert "1번근저당권설정등기말소" in excluded.evidence
    assert "page_1.jpg" in excluded.evidence
    # 제안서에 캡처할 로그 한 줄의 모양
    assert excluded.describe().startswith("을구 순위1 근저당 3,600만원 (근거: ")


def test_말소_행이_없으면_아무것도_빼지_않는다():
    extract = _extract()
    result = _apply(extract, eul_gu_page(with_cancel_row=False))

    assert result.applied is True
    assert result.count == 0
    assert cancellation.senior_debt_total(extract) == CANCELED_AMOUNT


# ══════════════════════════════════════════════════════════════════════════════
# ② 보류 조건 — 애매하면 종전대로 센다
# ══════════════════════════════════════════════════════════════════════════════


def _unbound_cancel_page() -> OcrPage:
    """말소 근거 행은 있는데 **대상 순위를 못 읽은** 을구.

    `N번…말소`의 `N번`이 빠져 있어 어느 항목이 말소됐는지 알 수 없다.
    무언가 말소된 것은 사실이므로, 이 구역에서는 아무것도 빼면 안 된다.
    """
    rows = [section_row("을구", 40), header_row(90)]
    rows.append(
        [
            W("1", 66, 150, 11),
            W("근저당권설정", 117, 150, 91),
            W("2004년6월25일", 269, 150, 98),
            W("채권최고액", 515, 150, 74),
            W("금36,000,000원", 606, 150, 105),
        ]
    )
    rows.append(
        [
            W("2", 66, 250, 11),
            W("근저당권설정등기말소", 117, 250, 150),  # 대상 순위(`N번`)가 없다
            W("2005년6월29일", 269, 250, 98),
        ]
    )
    return make_page(0, rows)


def test_미결_말소가_있으면_그_구역에서는_아무것도_빼지_않는다():
    """무언가 말소됐는데 무엇인지 모르는 상태 — 여기서 빼면 살아 있는 권리를 뺄 수 있다."""
    extract = _extract()
    result = _apply(extract, _unbound_cancel_page())

    assert "을구" in result.blocked_sections
    assert result.count == 0
    assert cancellation.senior_debt_total(extract) == CANCELED_AMOUNT
    assert extract.mortgages[0].is_canceled is False


def test_사진이_누락되면_제외를_적용하지_않는다():
    """5쪽짜리인데 1장만 올렸다 — 못 본 쪽에 무엇이 있는지 모른다.

    말소 판정 자체를 믿을 수 없는 상태이므로(빠진 쪽에 또 다른 말소·설정이 있을 수
    있다) 종전대로 센다.
    """
    base = eul_gu_page()
    words = list(base.words) + [
        *address_row(10, "행복아파트"),
        *footer_row(950, page_no=1, total=5, issue="ABCD-EFGH-0000"),
    ]
    page = OcrPage(
        name="page_1.jpg", index=0, words=words, lines=group_lines(words),
        width=PAGE_W, height=PAGE_H,
    )

    extract = _extract()
    result = _apply(extract, page)

    assert result.applied is False
    assert result.skipped_reason and "사진 묶음 점검 미통과" in result.skipped_reason
    assert cancellation.senior_debt_total(extract) == CANCELED_AMOUNT


def test_OCR이_없으면_제외를_적용하지_않는다():
    extract = _extract()
    result = cancellation.apply_confirmed_cancellations(extract, as_result(), check=None)

    assert result.applied is False
    assert cancellation.senior_debt_total(extract) == CANCELED_AMOUNT


def test_같은_금액이_유효분에도_있으면_빼지_않는다():
    """실측 사례 — 을구 3번과 4번이 둘 다 5억이었다.

    금액으로 이으므로, 같은 금액이 살아 있는 쪽에도 있으면 **어느 쪽이 말소분인지
    가릴 수 없다.** 이때 빼면 절반의 확률로 살아 있는 근저당을 지운다.
    """
    rows = [section_row("을구", 40), header_row(90)]
    rows.append(
        [W("1", 66, 150, 11), W("근저당권설정", 117, 150, 91),
         W("채권최고액", 515, 150, 74), W("금36,000,000원", 606, 150, 105)]
    )
    rows.append(
        [W("2", 66, 250, 11), W("1번근저당권설정등기말소", 117, 250, 165),
         W("2005년6월29일", 269, 250, 98)]
    )
    rows.append(  # 순위3 — 말소분과 **같은 금액**의 유효 근저당
        [W("3", 66, 350, 11), W("근저당권설정", 117, 350, 91),
         W("채권최고액", 515, 350, 74), W("금36,000,000원", 606, 350, 105)]
    )
    page = make_page(0, rows)

    extract = _extract(
        mortgages=[
            {"rank_number": "1", "max_claim_amount": "금36,000,000원", "is_canceled": False},
            {"rank_number": "3", "max_claim_amount": "금36,000,000원", "is_canceled": False},
        ]
    )
    result = _apply(extract, page)

    assert result.count == 0, "같은 금액이 둘이면 어느 쪽이 말소분인지 가릴 수 없다"
    assert cancellation.senior_debt_total(extract) == CANCELED_AMOUNT * 2


def test_IE가_이미_말소로_준_항목은_다시_세지_않는다():
    """원래부터 계산 밖이던 항목이 '제외 1건'으로 잡히면 로그가 거짓말이 된다."""
    extract = _extract(
        mortgages=[
            {"rank_number": "1", "max_claim_amount": "금36,000,000원", "is_canceled": True},
        ]
    )
    result = _apply(extract, eul_gu_page())

    assert result.count == 0
    assert result.senior_before == 0 and result.senior_after == 0


# ══════════════════════════════════════════════════════════════════════════════
# ③ 등급이 뒤집히는 경우 — **의도된 동작이다**
# ══════════════════════════════════════════════════════════════════════════════


def test_말소_제외로_등급이_위험에서_양호로_뒤집힐_수_있다():
    """**이 뒤집힘은 버그가 아니라 이 작업의 목적이다.**

    2026-07-27 결정 ③은 "OCR 말소 판정으로 등급을 바꾸지 않는다"였다. 2026-08-14에
    그 결정을 뒤집었다(decisions.md) — 말소된 권리를 현재 채권으로 세는 것은 보수적
    편향이 아니라 **사실 오류**이기 때문이다. 말소분 하나를 빼면 선순위채권 비율이
    기준 아래로 내려가고, 그 결과 등급이 '위험'에서 벗어나는 입력이 존재한다.

    바꿔 말하면 이 테스트가 깨지는 방향은 둘 중 하나다 —
    ⑴ 제외가 동작하지 않게 됐거나, ⑵ 누군가 결정을 다시 뒤집었거나.
    어느 쪽이든 decisions.md를 먼저 읽어야 한다.
    """
    # 시세 2억 · 보증금 5,000만원. 말소분(3,600만원)까지 세면 선순위 1억 3,600만원(68%)이라
    # 기준 60%를 넘어 '위험', 빼면 1억(50%)이라 기준 아래다.
    market, deposit = 200_000_000, 50_000_000
    mortgages = [
        {"rank_number": "1", "max_claim_amount": "금36,000,000원", "is_canceled": False},
        {"rank_number": "3", "max_claim_amount": "금100,000,000원", "is_canceled": False},
    ]
    rows = [section_row("을구", 40), header_row(90)]
    rows.append(
        [W("1", 66, 150, 11), W("근저당권설정", 117, 150, 91),
         W("채권최고액", 515, 150, 74), W("금36,000,000원", 606, 150, 105)]
    )
    rows.append(
        [W("2", 66, 250, 11), W("1번근저당권설정등기말소", 117, 250, 165),
         W("2005년6월29일", 269, 250, 98)]
    )
    rows.append(
        [W("3", 66, 350, 11), W("근저당권설정", 117, 350, 91),
         W("채권최고액", 515, 350, 74), W("금100,000,000원", 606, 350, 110)]
    )
    page = make_page(0, rows)

    before = _extract(mortgages=mortgages)
    v_before = rule_engine.evaluate(
        before, deposit=deposit, market_price=market, blacklist_entries=[{"name": "x"}]
    )
    assert v_before.grade is Grade.DANGER, "말소분까지 세면 기준 초과 — 종전 동작"

    after = _extract(mortgages=mortgages)
    result = _apply(after, page)
    v_after = rule_engine.evaluate(
        after, deposit=deposit, market_price=market, blacklist_entries=[{"name": "x"}]
    )

    assert result.count == 1
    assert v_after.grade is Grade.GOOD, "말소분을 빼면 기준 아래 — 바뀐 동작(의도된 것)"
    assert v_after.senior_debt_amount == 100_000_000


# ══════════════════════════════════════════════════════════════════════════════
# ④ 규칙은 바뀌지 않는다 — 사실만 바뀐다
# ══════════════════════════════════════════════════════════════════════════════


def test_제외해도_규칙_임계값은_그대로다():
    """이 계층은 `rule_engine`에 손대지 않는다. 같은 입력이면 같은 판정이 나와야 한다."""
    hand_marked = _extract(
        mortgages=[
            {"rank_number": "1", "max_claim_amount": "금36,000,000원", "is_canceled": True},
        ]
    )
    auto_marked = _extract()
    _apply(auto_marked, eul_gu_page())

    kw = dict(deposit=50_000_000, market_price=200_000_000, blacklist_entries=[{"name": "x"}])
    a = rule_engine.evaluate(hand_marked, **kw)
    b = rule_engine.evaluate(auto_marked, **kw)

    assert a.grade == b.grade
    assert a.senior_debt_amount == b.senior_debt_amount
    assert [e.grade for e in a.evidences] == [e.grade for e in b.evidences]
