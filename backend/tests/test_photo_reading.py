"""사진으로 찍은 등기부를 더 잘 읽기 (2026-10-31 — 시연 샘플 스캔본 사고 + 실촬영 대비).

**API 호출 없이** 좌표 로직만 본다(목은 HTTP 경계에만 — `test_analyze_smoke.py` 방식).

1. **꼬리말 쪽 번호를 띄어 써도 읽는다** — 시연 샘플은 꼬리말이 `2 / 3`(띄어 씀)이었고, OCR이 어떤 쪽은
   `2/3` 한 낱말로, 2쪽은 `2`·`/`·`3` 세 낱말로 줬다. 예전엔 한 낱말만 봐서 2쪽이 '아래가 잘림' + '빠진 쪽'이
   됐고 → 빚 형광펜이 전부 숨고('3쪽 중 2쪽만 확인됐어요') 모든 카드가 '양호' 금지로 '확인 필요'가 됐다.
2. **비스듬히 찍은 사진도 같은 줄을 같은 줄로 묶는다** — 순위번호와 금액이 한 줄이어야 형광펜이 칠해진다.
   예전엔 2°만 기울어도 줄이 쪼개져 빚 형광펜이 사라졌다. 원근(폰을 비스듬히 듦)으로 아래로 갈수록 칸이
   옆으로 밀려 순위번호를 놓치던 것도 함께 막는다.
3. **시세 조회 주소** — IE 주소에 호수가 없으면(표제부 소재지는 지번까지만 오는 일이 많다) 쪽 머리 주소로.

⚠ 표시·읽기 전용이다. 위험 등급의 규칙·임계값은 하나도 바뀌지 않는다(판정 재료는 여전히 IE).
"""

from __future__ import annotations

import math

import pytest

from app.schemas.contract import CaptureCheck
from app.schemas.internal import MoneyEntry
from app.services import capture_check, highlight, price_lookup
from app.services import report_builder as rb
from app.services.ocr_layout import (
    DocumentCheck,
    OcrPage,
    Word,
    _line_page_marker,
    _page_footer_facts,
    build_items,
    check_document,
    estimate_skew,
    group_lines,
)

from tests.test_analyze_smoke import (  # noqa: F401 — pytest 픽스처 재사용
    blank_image,
    client,
    no_network,
    post_analyze,
    raw_ocr_json,
    registry_raw,
)
from tests.test_highlight import (
    PAGE_H,
    PAGE_W,
    W,
    address_row,
    as_result,
    eul_gu_page,
    extract_with,
    gap_gu_page,
    header_row,
    section_row,
)


# ══════════════════════════════════════════════════════════════════════════════
# 재료
# ══════════════════════════════════════════════════════════════════════════════


def footer_words(tokens: list[str], *, y: float = 1150, x: float = 560, gap: float = 6) -> list[Word]:
    """꼬리말 낱말들을 왼→오로 붙여 놓는다(낱말 사이 `gap`px) — OCR이 쪼갠 모양 그대로."""
    out: list[Word] = []
    cur = x
    for t in tokens:
        width = 9 * len(t) + 4
        out.append(W(t, cur, y, width))
        cur += width + gap
    return out


def page_of(index: int, words: list[Word]) -> OcrPage:
    return OcrPage(name=f"page_{index + 1}.jpg", index=index, words=words,
                   lines=group_lines(words), width=PAGE_W, height=PAGE_H)


def warp(words: list[Word], f) -> list[Word]:
    """낱말 상자 네 모서리를 `f`로 옮기고 그걸 감싼 상자로 — 비스듬히 찍힌 사진의 OCR 좌표 모양."""
    out = []
    for w in words:
        pts = [f(x, y) for x, y in ((w.x0, w.y0), (w.x1, w.y0), (w.x1, w.y1), (w.x0, w.y1))]
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        out.append(Word(w.text, w.confidence, min(xs), min(ys), max(xs), max(ys)))
    return out


_CX, _CY = PAGE_W / 2, PAGE_H / 2


def roll(degrees: float):
    """종이를 돌려 찍음(사진 평면 안의 회전)."""
    th = math.radians(degrees)
    c, s = math.cos(th), math.sin(th)
    return lambda x, y: (_CX + (x - _CX) * c - (y - _CY) * s, _CY + (x - _CX) * s + (y - _CY) * c)


def pitch(p: float):
    """폰 위쪽이 종이에서 멂 — 위가 좁고 아래가 넓다(가로줄은 수평, 세로 칸이 아래로 갈수록 벌어진다)."""
    return lambda x, y: (_CX + (x - _CX) / (1 - p * y), y / (1 - p * y))


def yaw(q: float):
    """폰을 옆으로 비스듬히 듦 — 오른쪽이 크다(가로줄이 위·아래에서 다르게 기운다)."""
    return lambda x, y: (x / (1 - q * x), _CY + (y - _CY) / (1 - q * x))


def tall_eul_gu(count: int = 8) -> list[Word]:
    """을구 한 쪽에 근저당 `count`건 — 쪽 아래까지 순위번호가 이어진다(원근에서 칸이 밀리는지 보려고)."""
    rows = [section_row("을구", 40), header_row(90)]
    for k in range(count):
        y = 150 + k * 120
        rows.append([W(str(k + 1), 66, y, 11), W("근저당권설정", 117, y, 91), W("2004년6월25일", 269, y, 98),
                     W("2004년6월25일", 391, y, 100), W("채권최고액", 515, y, 74),
                     W(f"금{(k + 1) * 10},000,000원", 606, y, 105)])
        rows.append([W("제41414호", 270, y + 40, 68), W("설정계약", 393, y + 40, 60),
                     W("근저당권자", 515, y + 40, 74), W("주식회사가나은행", 606, y + 40, 120)])
    return [w for r in rows for w in r]


def mortgage_marks(words: list[Word], ranks: int, amounts: list[int] | None = None) -> list:
    """근저당 형광펜만 — IE가 순위 1..ranks를 찾았다고 치고(금액은 `amounts`, 없으면 1천만 원씩 늘림)."""
    page = page_of(0, words)
    amounts = amounts or [(k + 1) * 10_000_000 for k in range(ranks)]
    extract = extract_with(mortgages=[MoneyEntry(rank_number=str(k + 1), amount=amounts[k]) for k in range(ranks)])
    return [h for h in highlight.build_highlights(extract, as_result(page)).highlights if h.kind == "mortgage"]


#: `eul_gu_page`의 순위1 근저당 금액
EUL_GU_AMOUNT = [36_000_000]


# ══════════════════════════════════════════════════════════════════════════════
# ① 꼬리말 쪽 번호
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.parametrize(
    "tokens, expected",
    [
        (["1/3"], (1, 3)),  # 실제 등기부 모양
        (["2", "/", "3"], (2, 3)),  # 띄어 쓴 '2 / 3'을 OCR이 세 낱말로 (2026-10-31 사고)
        (["아닙니다.", "2", "/", "3"], (2, 3)),  # 시연 샘플 꼬리말 그대로
        (["아닙니다.2/3"], (2, 3)),  # 앞 문장에 붙여 한 낱말로
        (["아닙니다.2", "/", "3"], (2, 3)),
        (["2/", "3"], (2, 3)),
        (["2", "/3"], (2, 3)),
        (["2／3"], (2, 3)),  # 전각 빗금
        (["12", "/", "15"], (12, 15)),
    ],
)
def test_꼬리말_쪽_번호를_여러_모양으로_읽는다(tokens, expected):
    line = group_lines(footer_words(tokens))[0]
    assert _line_page_marker(line) == expected


@pytest.mark.parametrize(
    "tokens",
    [
        ["2분의", "1"],  # 지분 표기
        ["312.5분의", "38.42"],  # 대지권 비율
        ["38.42/5"],  # 소수 뒤 숫자를 쪽 번호로 잘라 읽지 않는다
        ["2022/3"],  # 네 자리 숫자의 끝자리를 잘라 읽지 않는다
        ["4", "/", "3"],  # 쪽 번호가 전체 쪽수보다 크다
        ["0/3"],
    ],
)
def test_쪽_번호가_아닌_것은_쪽_번호로_읽지_않는다(tokens):
    line = group_lines(footer_words(tokens))[0]
    assert _line_page_marker(line) is None


def test_멀리_떨어진_숫자끼리는_이어_붙이지_않는다():
    words = [W("2", 100, 1150, 10), W("/", 400, 1150, 6), W("3", 700, 1150, 10)]
    assert _line_page_marker(group_lines(words)[0]) is None


def _sample_like_pages() -> list[OcrPage]:
    """시연 샘플 모양 — 1·3쪽만 머리 주소, 꼬리말은 '…아닙니다. N / 3', 2쪽 꼬리말만 세 낱말로 쪼개짐."""
    header = address_row(10, "서울특별시 ○○구 ○○동 123-4 제3층 제301호")
    p1 = header + list(gap_gu_page(0).words) + footer_words(["아닙니다.", "1/3"])
    p2 = list(eul_gu_page(with_cancel_row=False).words) + footer_words(["아닙니다.", "2", "/", "3"])
    p3 = header + footer_words(["아닙니다.", "3/3"])
    return [page_of(0, p1), page_of(1, p2), page_of(2, p3)]


def test_띄어_쓴_꼬리말이_있어도_빠진_쪽이_없다():
    """2026-10-31 사고 재현 — 예전엔 2쪽 표식을 못 읽어 '3쪽 중 2쪽만 확인됐어요'로 빚 표시를 숨겼다."""
    pages = _sample_like_pages()
    assert _page_footer_facts(pages[1])[0] == (2, 3)
    check = check_document(pages)
    assert check.page_numbers == [1, 2, 3]
    assert check.missing_pages == []
    assert check.ok_to_highlight_money is True
    assert check.notice is None


def test_띄어_쓴_꼬리말은_아래가_잘림이_아니다():
    after = capture_check.add_ocr_findings(CaptureCheck(), _sample_like_pages(), 3)
    assert after is not None and after.ok is True and after.pages == []


def test_띄어_쓴_꼬리말이어도_근저당에_형광펜이_칠해진다():
    extract = extract_with(mortgages=[MoneyEntry(rank_number="1", amount=36_000_000)])
    result = highlight.build_highlights(extract, as_result(*_sample_like_pages()))
    assert [h.page for h in result.highlights if h.kind == "mortgage"] == [1]


# ══════════════════════════════════════════════════════════════════════════════
# ② 비스듬히 찍은 사진
# ══════════════════════════════════════════════════════════════════════════════


def test_바로_선_사진은_예전과_똑같이_묶는다():
    """보정은 0.25° 넘게 기울었을 때만 — 바로 선 사진(스캔·화면 캡처)은 한 글자도 다르게 묶지 않는다."""
    words = list(eul_gu_page().words) + list(footer_words(["1/1"]))
    assert estimate_skew(words) is None
    auto = [[w.text for w in line.words] for line in group_lines(words)]
    plain = [[w.text for w in line.words] for line in group_lines(words, skew=None)]
    assert auto == plain


@pytest.mark.parametrize("degrees", [2, 3, -4, 8, 12])
def test_돌려_찍은_사진도_빚_형광펜이_칠해진다(degrees):
    words = warp(list(eul_gu_page(with_cancel_row=False).words), roll(degrees))
    skew = estimate_skew(words)
    assert skew is not None and abs(skew.degrees - degrees) < 0.3
    assert len(mortgage_marks(words, 1, EUL_GU_AMOUNT)) == 1


def test_보정하지_않으면_2도만_기울어도_형광펜이_사라졌다():
    """왜 이 기능이 있나 — 예전 묶기(보정 없음)로는 같은 사진에서 순위번호와 금액이 다른 줄이 된다."""
    words = warp(list(eul_gu_page(with_cancel_row=False).words), roll(2))
    page = OcrPage(name="p.jpg", index=0, words=words, lines=group_lines(words, skew=None),
                   width=PAGE_W, height=PAGE_H)
    extract = extract_with(mortgages=[MoneyEntry(rank_number="1", amount=36_000_000)])
    assert [h for h in highlight.build_highlights(extract, as_result(page)).highlights if h.kind == "mortgage"] == []


def test_형광펜은_사진의_원래_자리에_그린다():
    """보정 좌표는 줄 묶기에만 쓴다 — 상자는 사진 속 낱말을 그대로 감싼다(앱이 원본 사진 위에 그린다)."""
    words = warp(list(eul_gu_page(with_cancel_row=False).words), roll(3))
    rank = next(w for w in words if w.text == "1")
    money = next(w for w in words if w.text == "금36,000,000원")
    (mark,) = mortgage_marks(words, 1, EUL_GU_AMOUNT)
    box = mark.box
    x0, y0, x1, y1 = box.x * PAGE_W, box.y * PAGE_H, (box.x + box.w) * PAGE_W, (box.y + box.h) * PAGE_H
    for w in (rank, money):
        assert x0 - 0.5 <= w.x0 and w.x1 <= x1 + 0.5 and y0 - 0.5 <= w.y0 and w.y1 <= y1 + 0.5


@pytest.mark.parametrize("distort", [yaw(0.0001), yaw(0.00015), pitch(0.0002)], ids=["yaw1", "yaw15", "pitch2"])
def test_원근으로_찍힌_사진도_빚_형광펜이_칠해진다(distort):
    words = warp(tall_eul_gu(), distort)
    assert len(mortgage_marks(words, 4)) == 4


def test_아래로_갈수록_칸이_밀려도_순위번호를_놓치지_않는다():
    """원근(위가 좁고 아래가 넓음) — 표 머리에서 정한 순위번호 칸 밖으로 아래쪽 순위번호가 밀려난다."""
    words = warp(tall_eul_gu(8), pitch(0.0002))
    ranks = [it.rank for it in build_items([page_of(0, words)]) if it.rank]
    assert ranks == [str(k) for k in range(1, 9)]


def test_기울기를_재지_못할_만큼_글자가_적으면_보정하지_않는다():
    words = warp(footer_words(["1/3"]) + [W("근저당권설정", 117, 150, 91)], roll(5))
    assert estimate_skew(words) is None


# ══════════════════════════════════════════════════════════════════════════════
# ③ 시세 조회 주소
# ══════════════════════════════════════════════════════════════════════════════


def _doc(header: str | None, kind: str | None = "집합건물") -> DocumentCheck:
    return DocumentCheck(header_address=header, header_kind=kind)


def test_IE_주소에_호수가_없으면_쪽_머리_주소로_시세를_찾는다():
    got = rb.price_address("서울특별시 영등포구 신길동 274-1", _doc("서울특별시 영등포구 신길동 274-1 제3층 제301호"))
    assert got == "[집합건물] 서울특별시 영등포구 신길동 274-1 제3층 제301호"


def test_IE_주소에_호수가_있으면_그대로다():
    ie = "서울특별시 영등포구 신길동 274-1 제3층 제301호"
    assert rb.price_address(ie, _doc("서울특별시 영등포구 신길동 274-1 제3층 제302호")) == ie


@pytest.mark.parametrize("doc", [None, _doc(None), _doc("서울특별시 영등포구 신길동 274-1")])
def test_쪽_머리에도_호수가_없으면_IE_주소_그대로다(doc):
    assert rb.price_address("서울특별시 영등포구 신길동 274-1", doc) == "서울특별시 영등포구 신길동 274-1"


def test_IE가_주소를_못_읽어도_쪽_머리_주소로_찾는다():
    assert rb.price_address(None, _doc("서울특별시 ○○구 ○○동 1 제101호")) == "[집합건물] 서울특별시 ○○구 ○○동 1 제101호"


def test_통건물_머리표는_그대로_넘긴다():
    """'[건물]'이면 시세 조회가 통건물로 보고 전세가율을 보류한다 — 머리표를 지우면 집합건물로 오인한다."""
    got = rb.price_address("서울특별시 ○○구 ○○동 1", _doc("서울특별시 ○○구 ○○동 1 101호", kind="건물"))
    assert got == "[건물] 서울특별시 ○○구 ○○동 1 101호"


def test_머리표를_전각_괄호로_읽어도_머리_주소다():
    page = page_of(0, [W("［집합건물］", 33, 10, 74), W("서울특별시", 116, 10, 70), W("제301호", 200, 10, 50)]
                   + footer_words(["1/1"]))
    check = check_document([page])
    assert check.header_kind == "집합건물"
    assert check.header_address == "서울특별시 제301호"


# ══════════════════════════════════════════════════════════════════════════════
# ④ 끝에서 끝까지 — 시연 샘플 모양 + 2쪽은 3° 기울여 찍음
# ══════════════════════════════════════════════════════════════════════════════


def test_시연_샘플_모양_사진이_끝까지_관통한다(client, no_network, monkeypatch):
    pages = _sample_like_pages()
    tilted = warp(pages[1].words, roll(3))
    pages[1] = page_of(1, tilted)
    no_network(registry_raw(), [raw_ocr_json(p) for p in pages])  # IE 주소엔 호수가 없다('… 123-4')
    seen: list[str | None] = []
    real_collect = price_lookup.collect

    def spy(**kwargs):
        seen.append(kwargs.get("address"))
        return real_collect(**kwargs)

    monkeypatch.setattr(price_lookup, "collect", spy)

    resp = post_analyze(client, [blank_image(PAGE_W, PAGE_H) for _ in pages])

    assert resp.status_code == 200, resp.text
    report = resp.json()
    assert report["pageNumbers"] == [1, 2, 3]
    assert report["missingPages"] == []
    issues = [i for p in (report.get("captureCheck") or {}).get("pages", []) for i in p["issues"]]
    assert "cut_off" not in issues, report.get("captureCheck")
    assert [h["page"] for h in report["highlights"] if h["kind"] == "mortgage"] == [1]
    assert seen and seen[0] == "[집합건물] 서울특별시 ○○구 ○○동 123-4 제3층 제301호"

    # 보증금만 고쳐 다시 판정해도 **같은 주소**로 시세를 찾는다 — 고쳤더니 시세가 사라지면 안 된다
    resp = client.patch(f"/api/reports/{report['id']}", json={"deposit": 150_000_000})
    assert resp.status_code == 200, resp.text
    assert seen[-1] == "[집합건물] 서울특별시 ○○구 ○○동 123-4 제3층 제301호"


# ══════════════════════════════════════════════════════════════════════════════
# ⑤ 건물 용도 — 등기부 표제부 건물내역에서 (2026-10-31)
# ══════════════════════════════════════════════════════════════════════════════

from app.schemas.contract import CapturePageIssue, Highlight, HighlightBox, Report  # noqa: E402
from app.services import loss_estimate  # noqa: E402
from app.services.ocr_layout import building_use  # noqa: E402


def pyojebu_page(index: int, *, use_text: list[str], name: str = "서울특별시 영등포구 신길동 274-1") -> OcrPage:
    """표제부(1동의 건물의 표시) — 건물내역 칸이 두 줄로 접힌 실제 모양('… 지붕 4' / '층 다세대주택')."""
    rows = [
        section_row("표제부", 40),
        [W("표시번호", 40, 90, 60), W("접", 150, 90, 13), W("수", 170, 90, 13),
         W("소재지번,", 250, 90, 60), W("건물명칭", 316, 90, 60), W("및", 382, 90, 14), W("번호", 402, 90, 30),
         W("건", 560, 90, 14), W("물", 580, 90, 14), W("내", 600, 90, 14), W("역", 620, 90, 14)],
        [W("1", 66, 150, 11), W("2019년11월05일", 117, 150, 98), W(name, 250, 150, 230)]
        + [W(t, 560 + 70 * k, 150, 64) for k, t in enumerate(use_text[:1])],
    ]
    rows += [[W(t, 560, 190 + 40 * k, 64)] for k, t in enumerate(use_text[1:])]
    rows.append(section_row("갑구", 500))
    rows.append([W("1", 66, 560, 11), W("소유권보존", 117, 560, 75), W("서울특별시", 516, 560, 70),
                 W("○○아파트", 590, 560, 70), W("101동", 664, 560, 40)])  # 소유자 주소 속 '아파트'는 갑구라 안 본다
    return page_of(index, [w for r in rows for w in r])


@pytest.mark.parametrize(
    "use_text, expected",
    [
        (["(철근)콘크리트지붕 4", "층 다세대주택"], "연립다세대"),  # 시연 샘플 그대로(두 줄로 접힘)
        (["콘크리트지붕 15층", "아파트"], "아파트"),
        (["콘크리트지붕 3층", "연립주택"], "연립다세대"),
        (["콘크리트지붕 20층", "업무시설(오피스텔)"], "오피스텔"),
        (["콘크리트지붕 5층", "공동주택(아파트)"], "아파트"),
        (["콘크리트지붕 4층", "제2종근린생활시설및다세대주택"], "연립다세대"),
    ],
)
def test_표제부_건물내역에서_용도를_읽는다(use_text, expected):
    assert building_use([pyojebu_page(0, use_text=use_text)]) == expected


def test_건물_이름에만_용도가_있으면_그것을_쓴다():
    page = pyojebu_page(0, use_text=["철근콘크리트조"], name="서울특별시 ○○구 ○○동 1 행복아파트")
    assert building_use([page]) == "아파트"


def test_건물내역이_건물_이름보다_먼저다():
    """건물 이름이 '○○아파트'여도 건물내역이 '다세대주택'이면 다세대다(옛 빌라 이름에 흔하다)."""
    page = pyojebu_page(0, use_text=["콘크리트지붕 4층", "다세대주택"], name="서울특별시 ○○구 ○○동 1 행복아파트")
    assert building_use([page]) == "연립다세대"


def test_표제부가_없으면_용도를_정하지_않는다():
    assert building_use([eul_gu_page()]) is None


def test_등기부_용도가_있으면_한_가지로_계산한다():
    public = price_lookup.R.PriceCandidate(price_won=1, source=price_lookup.R.SOURCE_OFFICIAL_PRICE, source_name="",
                                           as_of="", house_types=("apt", "row_house"))
    address = "[집합건물] 서울특별시 영등포구 신길동 274-1 제3층 제301호"
    assert loss_estimate.house_types_from([public], address) == ["아파트", "연립다세대"]
    assert loss_estimate.house_types_from([public], address, registry_use="연립다세대") == ["연립다세대"]
    # 통건물 등기는 등기부 용도와 상관없이 단독·다가구
    assert loss_estimate.house_types_from([], "[건물] 서울특별시 ○○구 ○○동 1", registry_use="아파트") == ["단독·다가구"]


def _report_with_address_mark(**kw) -> Report:
    mark = Highlight(id="m1", page=0, kind="address", badge=1, box=HighlightBox(x=0, y=0, w=0.1, h=0.1),
                     title="이 서류가 가리키는 집 (주소·동호수)", body="")
    return Report(
        id="r1", alias="a", analyzedAt="2026-10-31", address="서울특별시 영등포구 신길동 274-1",
        deposit=200_000_000, grade="위험", gaugeProgress=0.2, headline="h", nextAction="n", topRiskSummary="t",
        seniorDebtAmount=0, evidences=[], highlights=[mark], **kw,
    )


def test_주소_표시는_읽은_주소부터_보여_주고_확실하지_않다고_하지_않는다():
    report = _report_with_address_mark(
        propertyAddress="서울특별시 영등포구 신길동 274-1 제3층 제301호", houseTypes=["아파트", "연립다세대", "오피스텔"]
    )
    rb._add_house_type_to_address_mark(report)
    facts = report.highlights[0].facts
    assert facts[0] == "신길동 274-1 제3층 제301호"
    assert not any("확실하지" in f for f in facts)
    assert facts[1].startswith("서울 ") and facts[1].endswith("로 계산")
    assert facts[1] == f"서울 {loss_estimate.chosen_use(report)}로 계산"


def test_주소_표시는_등기부_용도_그대로_말한다():
    report = _report_with_address_mark(
        propertyAddress="서울특별시 영등포구 신길동 274-1 제3층 제301호", houseTypes=["연립다세대"]
    )
    rb._add_house_type_to_address_mark(report)
    assert report.highlights[0].facts == ["신길동 274-1 제3층 제301호", "서울 연립다세대로 계산"]


# ══════════════════════════════════════════════════════════════════════════════
# ⑥ 쪽 번호만 잘린 사진 — 앞뒤 쪽으로 몇 쪽인지 정한다 (다시 찍기 줄이기)
# ══════════════════════════════════════════════════════════════════════════════


def _pages_with_footers(footers: list[list[str] | None]) -> list[OcrPage]:
    """쪽마다 을구 표 + 꼬리말(None이면 꼬리말이 화면 밖으로 잘림)."""
    out = []
    for i, f in enumerate(footers):
        words = list(eul_gu_page(with_cancel_row=False).words) + (footer_words(f) if f else [])
        out.append(page_of(i, words))
    return out


def test_가운데_쪽_번호가_잘려도_몇_쪽인지_안다():
    pages = _pages_with_footers([["1/3"], None, ["3/3"]])
    check = check_document(pages)
    assert check.page_numbers == [1, 2, 3]
    assert check.inferred_pages == [1]
    assert check.missing_pages == []
    assert check.ok_to_highlight_money is True


@pytest.mark.parametrize(
    "footers, expected",
    [
        ([None, ["2/3"], ["3/3"]], [1, 2, 3]),  # 첫 쪽
        ([["1/3"], ["2/3"], None], [1, 2, 3]),  # 마지막 쪽
        ([None, ["2/4"], None, ["4/4"]], [1, 2, 3, 4]),  # 두 장
        ([["1/4"], None, None, ["4/4"]], [1, 2, 3, 4]),  # 이어진 두 장
    ],
)
def test_잘린_쪽이_어디든_한_가지로_정해지면_채운다(footers, expected):
    assert check_document(_pages_with_footers(footers)).page_numbers == expected


@pytest.mark.parametrize(
    "footers",
    [
        [["1/4"], None, ["3/4"]],  # 4쪽인데 3장 — 빠진 쪽이 있다
        [["3/3"], None, ["1/3"]],  # 순서가 뒤바뀌었다 — 어디에 끼웠는지 모른다
        [["1/3"], ["2/3"], ["3/3"], None],  # 쪽 수보다 사진이 많다 — 다른 서류가 섞였을 수 있다
        [["1/3"], None, ["2/3"]],  # 1쪽과 2쪽 사이엔 들어갈 쪽이 없다
        [None, None, None],  # 쪽 번호를 하나도 못 읽었다 — 전체 쪽수를 모른다
    ],
)
def test_한_가지로_정해지지_않으면_채우지_않는다(footers):
    check = check_document(_pages_with_footers(footers))
    assert check.inferred_pages == []
    assert None in check.page_numbers


def test_등기부로_보이지_않는_사진은_쪽을_채우지_않는다():
    """[2026-07-28] 사고 방어 — 무관한 사진 한 장이 빠진 쪽 자리를 채우면 빠진 쪽(말소 줄)을 놓친다."""
    pages = _pages_with_footers([["1/3"], None, ["3/3"]])
    pages[1] = page_of(1, [W("키보드", 100, 100, 60), W("화면", 200, 100, 40)])
    check = check_document(pages)
    assert check.inferred_pages == []
    assert check.page_numbers == [1, None, 3]


def test_쪽을_정한_사진은_아래가_잘림으로_보지_않는다():
    pages = _pages_with_footers([["1/3"], None, ["3/3"]])
    check = check_document(pages)
    numbered = {p.index for p, n in zip(pages, check.page_numbers) if n is not None}
    after = capture_check.add_ocr_findings(CaptureCheck(), pages, 3, numbered=numbered)
    assert after is not None and after.pages == []


# ══════════════════════════════════════════════════════════════════════════════
# ⑦ 조금 흐려도 글자를 잘 읽었으면 다시 찍으라고 하지 않는다
# ══════════════════════════════════════════════════════════════════════════════


def test_글자를_잘_읽은_장은_흐림_안내를_뺀다():
    pages = _pages_with_footers([["1/2"], ["2/2"]])
    before = CaptureCheck(ok=False, pages=[
        CapturePageIssue(index=0, issues=["blurry"], tip="x"),
        CapturePageIssue(index=1, issues=["too_dark", "low_contrast"], tip="x"),
    ])
    after = capture_check.forgive_read_well(before, pages, {0, 1})
    assert after is not None and after.ok is True and after.pages == []


def test_쪽_번호를_모르는_장은_흐림_안내를_그대로_둔다():
    pages = _pages_with_footers([["1/2"], None])
    before = CaptureCheck(ok=False, pages=[CapturePageIssue(index=1, issues=["blurry", "cut_off"], tip="x")])
    after = capture_check.forgive_read_well(before, pages, {0})
    assert after is not None and [(p.index, p.issues) for p in after.pages] == [(1, ["blurry", "cut_off"])]


def test_빚_금액을_못_읽은_것은_그대로_다시_찍기다():
    pages = _pages_with_footers([["1/1"]])
    before = CaptureCheck(ok=False, pages=[CapturePageIssue(index=0, issues=["blurry", "amount_unread"], tip="x")])
    after = capture_check.forgive_read_well(before, pages, {0})
    assert after is not None and [p.issues for p in after.pages] == [["amount_unread"]]
    assert "빚 금액" in after.pages[0].tip


def test_글자가_거의_없는_장은_흐림_안내를_그대로_둔다():
    page = page_of(0, footer_words(["1/1"]) + [W("등기목적", 100, 100, 60)])
    before = CaptureCheck(ok=False, pages=[CapturePageIssue(index=0, issues=["blurry"], tip="x")])
    after = capture_check.forgive_read_well(before, [page], {0})
    assert after is not None and [p.issues for p in after.pages] == [["blurry"]]


def test_꼬리말이_잘리고_조금_흐려도_끝까지_관통하면_다시_찍기가_없다(client, no_network, monkeypatch):
    """실촬영에서 가장 흔한 두 가지(맨 아래 잘림 + 손 떨림)를 한 번에 — 다시 찍기 카드도, '양호' 금지도 없어야 한다."""
    header = address_row(10, "서울특별시 ○○구 ○○동 123-4 제3층 제301호")
    p1 = page_of(0, header + list(pyojebu_page(0, use_text=["콘크리트지붕 4층", "다세대주택"]).words)
                 + footer_words(["1/3"]))
    p2 = page_of(1, list(eul_gu_page(with_cancel_row=False).words))  # 꼬리말 잘림
    p3 = page_of(2, header + list(eul_gu_page(with_cancel_row=False).words)[:-8] + footer_words(["3/3"]))
    no_network(registry_raw(), [raw_ocr_json(p) for p in (p1, p2, p3)])
    real_precheck = capture_check.precheck

    def mildly_blurry(images):
        got = real_precheck(images)
        mild = CapturePageIssue(index=2, issues=["blurry"], severe=False, tip=capture_check.tip_for(["blurry"]))
        return CaptureCheck(ok=False, pages=[*(got.pages if got else []), mild])

    monkeypatch.setattr(capture_check, "precheck", mildly_blurry)
    from app.routers import reports as reports_router  # 라우터가 모듈 이름으로 부르는지와 상관없이 막는다

    if hasattr(reports_router, "capture_check"):
        monkeypatch.setattr(reports_router.capture_check, "precheck", mildly_blurry)

    resp = post_analyze(client, [blank_image(PAGE_W, PAGE_H) for _ in range(3)])

    assert resp.status_code == 200, resp.text
    report = resp.json()
    assert report["pageNumbers"] == [1, 2, 3]
    assert report["missingPages"] == []
    assert (report.get("captureCheck") or {}).get("pages", []) == []
    assert report["houseTypes"] == ["연립다세대"]


def test_쪽마다_머리표_모양이_달라도_같은_등기부다():
    """'[집합건물]'과 '［집합 건물］'로 읽혀도 '주소가 서로 달라요'(빚 표시 전부 숨김)가 되지 않는다."""
    a = page_of(0, [W("[집합건물]", 33, 10, 74), W("서울특별시", 116, 10, 70), W("제301호", 200, 10, 50)]
                + list(eul_gu_page(with_cancel_row=False).words) + footer_words(["1/2"]))
    b = page_of(1, [W("［집합", 33, 10, 40), W("건물］", 76, 10, 40), W("서울특별시", 116, 10, 70), W("제301호", 200, 10, 50)]
                + footer_words(["2/2"]))
    check = check_document([a, b])
    assert check.notice is None and check.ok_to_highlight_money is True
