"""OCR 하이라이트 매칭 테스트 — **API 호출 없이** 좌표 로직만 검증한다.

두 갈래로 나눠 둔다.
1. **합성 페이지** (항상 실행): 손으로 만든 표 좌표로 매칭 규칙을 검증한다.
   등기부 실명이 들어가지 않으므로 저장소에 그대로 둘 수 있다.
2. **실제 OCR 응답** (`backend/out/ocr_*.json` 이 있을 때만 실행): 진짜 등기부에서
   뽑은 좌표로 검증한다. `out/`은 소유자 실명이 있어 커밋하지 않으므로, 파일이
   없으면 skip 한다. 다시 만들려면:
       cd backend
       .\\.venv\\Scripts\\python.exe scripts\\test_ocr_coords.py test_samples\\3.png ... (실호출 1회)

⚠ 이 기능은 **표시 전용**이다. 여기 어떤 테스트도 위험 등급·점수를 다루지 않는다.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.schemas.internal import MoneyEntry, Owner, RegistryExtract
from app.services import highlight
from app.services.ocr import OcrResult
from app.services.ocr_layout import OcrPage, Word, build_items, group_lines, parse_words

_BACKEND_ROOT = Path(__file__).resolve().parents[1]
_OUT_DIR = _BACKEND_ROOT / "out"

PAGE_W, PAGE_H = 880, 1200


# ══════════════════════════════════════════════════════════════════════════════
# 합성 페이지 만들기 — 실측 좌표(3.png)를 본떠 만든 표
# ══════════════════════════════════════════════════════════════════════════════


def W(text: str, x0: float, y: float, w: float, h: float = 16) -> Word:
    return Word(text=text, confidence=0.99, x0=x0, y0=y, x1=x0 + w, y1=y + h)


def header_row(y: float) -> list[Word]:
    """`순위번호 | 등 기 목 적 | 접 수 | 등 기 원 인 | 권리자 및 기타사항` (3.png L2 실측 기준)."""
    return [
        W("순위번호", 40, y, 60),
        W("등", 145, y, 15), W("기", 167, y, 14), W("목", 190, y, 15), W("적", 212, y, 14),
        W("접", 302, y, 13), W("수", 331, y, 15),
        W("등", 405, y, 15), W("기", 428, y, 13), W("원", 451, y, 14), W("인", 473, y, 14),
        W("권리자", 616, y, 46), W("및", 669, y, 14), W("기타사항", 692, y, 60),
    ]


def section_row(name: str, y: float) -> list[Word]:
    a, b = name[0], name[1]
    return [W("【", 84, y, 10), W(a, 114, y, 20), W(b, 198, y, 19), W("】", 238, y, 9)]


def make_page(index: int, rows: list[list[Word]]) -> OcrPage:
    words = [w for row in rows for w in row]
    return OcrPage(
        name=f"page_{index + 1}.jpg",
        index=index,
        words=words,
        lines=group_lines(words),
        width=PAGE_W,
        height=PAGE_H,
    )


def eul_gu_page(*, amount_on_rank_line: bool = True, with_cancel_row: bool = True) -> OcrPage:
    """을구 1장 — 순위1 근저당(3,600만원) + (옵션) 순위2 말소 근거 행."""
    rows = [section_row("을구", 40), header_row(90)]
    # 순위1 근저당권설정
    rank_line = [
        W("1", 66, 150, 11),
        W("근저당권설정", 117, 150, 91),
        W("2004년6월25일", 269, 150, 98),
        W("2004년6월25일", 391, 150, 100),
        W("채권최고액", 515, 150, 74),
    ]
    money = W("금36,000,000원", 606, 150 if amount_on_rank_line else 190, 105)
    rank_line.append(money) if amount_on_rank_line else None
    rows.append(rank_line)
    rows.append(
        [W("제41414호", 270, 190, 68), W("설정계약", 393, 190, 60)]
        + ([] if amount_on_rank_line else [money])
    )
    if with_cancel_row:
        # 순위2 = '1번근저당권설정등기말소' — 등기목적 칸이 두 줄로 접힌 실제 모양 그대로
        rows.append(
            [
                W("2", 66, 250, 11),
                W("1번근저당권설정등", 117, 250, 124),
                W("2005년6월29일", 269, 250, 98),
                W("2005년6월29일", 391, 250, 100),
            ]
        )
        rows.append([W("기말소", 117, 290, 44), W("제45409호", 270, 290, 68), W("해지", 393, 290, 28)])
    return make_page(0, rows)


def gap_gu_page(index: int = 0) -> OcrPage:
    """갑구 1장 — 공유자 2명(소유자D·소유자E)."""
    rows = [section_row("갑구", 40), header_row(90)]
    rows.append(
        [
            W("1", 66, 150, 11),
            W("소유권이전", 117, 150, 75),
            W("2006년6월23일", 269, 150, 98),
            W("2006년2월15일", 391, 150, 100),
            W("공유자", 516, 150, 44),
        ]
    )
    rows.append([W("제50495호", 271, 190, 67), W("매매", 394, 190, 28),
                 W("소유자D", 531, 190, 44), W("○○○○○○-○******", 589, 190, 107)])
    rows.append([W("지분", 531, 230, 29), W("2분의", 566, 230, 38), W("1", 612, 230, 8)])
    rows.append([W("소유자E", 531, 270, 43), W("○○○○○○-○******", 589, 270, 107)])
    return make_page(index, rows)


def as_result(*pages: OcrPage) -> OcrResult:
    return OcrResult(pages=list(pages), elapsed=1.0)


def extract_with(**kwargs) -> RegistryExtract:
    return RegistryExtract(**kwargs)


def _run(extract: RegistryExtract, ocr: OcrResult) -> list:
    """build_highlights의 하이라이트 목록만 꺼낸다 (안내 문구는 별도 테스트에서 본다)."""
    return highlight.build_highlights(extract, ocr).highlights


# ══════════════════════════════════════════════════════════════════════════════
# 말소 — 가장 중요한 방어선
# ══════════════════════════════════════════════════════════════════════════════


def test_말소_행이_두_줄로_접혀_있어도_해당_항목을_말소로_잡는다():
    """등기목적 칸 안에서 '…설정등' / '기말소' 로 갈라지고 그 사이에 날짜가 낀다.
    줄 단위로 이어붙이면 못 찾고, 등기목적 컬럼 word만 이어붙여야 찾는다."""
    items = build_items([eul_gu_page()])
    by_rank = {it.rank: it for it in items if it.section == "을구"}
    assert by_rank["1"].canceled is True
    assert by_rank["1"].cancel_evidence and "1번근저당권설정등기말소" in by_rank["1"].cancel_evidence
    assert by_rank["2"].is_cancel_record is True
    assert by_rank["2"].canceled is False  # 말소를 기록한 행 자체는 유효한 기록이다


def test_말소된_근저당에는_좌표를_내보내지_않는다():
    """이 기능 최악의 오류 — '이미 없어진 빚'을 현재 위험으로 오해하게 만드는 것."""
    extract = extract_with(
        mortgages=[MoneyEntry(rank_number="1", amount=36_000_000, is_canceled=False)]
    )
    result = _run(extract, as_result(eul_gu_page()))
    assert result == []


def test_IE가_말소로_보면_애초에_대상이_아니다():
    extract = extract_with(
        mortgages=[MoneyEntry(rank_number="1", amount=36_000_000, is_canceled=True)]
    )
    result = _run(
        extract, as_result(eul_gu_page(with_cancel_row=False))
    )
    assert result == []


# ══════════════════════════════════════════════════════════════════════════════
# 앵커 매칭 — 부분 매칭 금지
# ══════════════════════════════════════════════════════════════════════════════


def test_순위번호와_금액이_같은_줄이면_좌표를_준다():
    extract = extract_with(
        mortgages=[MoneyEntry(rank_number="1", amount=36_000_000, is_canceled=False)]
    )
    result = _run(
        extract, as_result(eul_gu_page(with_cancel_row=False))
    )
    assert len(result) == 1
    h = result[0]
    assert h.kind == "mortgage" and h.page == 0 and h.badge == 1
    assert "3,600만원" in h.title  # 앱 표기와 동일한 한글 금액
    # 순위번호(x=66)부터 금액 오른쪽 끝(x=711)까지를 감싼다
    assert h.box.x < 66 / PAGE_W + 0.01
    assert h.box.x + h.box.w > 700 / PAGE_W


def test_금액이_순위번호와_다른_줄이면_좌표를_주지_않는다():
    """부분 매칭 금지 — 틀린 위치에 칠하는 것보다 안 칠하는 것이 낫다."""
    extract = extract_with(
        mortgages=[MoneyEntry(rank_number="1", amount=36_000_000, is_canceled=False)]
    )
    result = _run(
        extract, as_result(eul_gu_page(amount_on_rank_line=False, with_cancel_row=False))
    )
    assert result == []


def test_순위번호가_없으면_좌표를_주지_않는다():
    """같은 금액이 여러 곳에 나오므로 금액만으로는 항목을 지목할 수 없다."""
    extract = extract_with(mortgages=[MoneyEntry(amount=36_000_000, is_canceled=False)])
    result = _run(
        extract, as_result(eul_gu_page(with_cancel_row=False))
    )
    assert result == []


def test_금액_미상이면_좌표를_주지_않는다():
    extract = extract_with(
        mortgages=[MoneyEntry(rank_number="1", amount=None, amount_unknown=True, is_canceled=False)]
    )
    result = _run(
        extract, as_result(eul_gu_page(with_cancel_row=False))
    )
    assert result == []


def test_IE_금액이_사진과_다르면_좌표를_주지_않는다():
    """OCR이 읽은 금액과 IE가 뽑은 금액이 어긋나면 칠하지 않는다(교차 확인이 아니라 표시 보류)."""
    extract = extract_with(
        mortgages=[MoneyEntry(rank_number="1", amount=99_000_000, is_canceled=False)]
    )
    result = _run(
        extract, as_result(eul_gu_page(with_cancel_row=False))
    )
    assert result == []


# ══════════════════════════════════════════════════════════════════════════════
# 소유자 이름
# ══════════════════════════════════════════════════════════════════════════════


def test_현재_소유자_이름에_좌표가_붙는다():
    extract = extract_with(current_owners=[Owner(name="소유자D"), Owner(name="소유자E")])
    result = _run(extract, as_result(gap_gu_page()))
    assert len(result) == 2
    assert [h.kind for h in result] == ["owner", "owner"]
    assert [h.badge for h in result] == [1, 2]
    assert all("계약서에 적힌 집주인(임대인) 이름" in h.body for h in result)
    assert all("대리인이 나왔다면" in h.body for h in result)  # 위임장 케이스 누락 방지
    # 공동명의는 전원 동의가 필요하다는 안내가 붙어야 한다
    assert all(h.caution and "2명이 함께 가진 집" in h.caution for h in result)


def test_단독_소유면_공동명의_안내가_붙지_않는다():
    extract = extract_with(current_owners=[Owner(name="소유자D")])
    result = _run(extract, as_result(gap_gu_page()))
    assert len(result) == 1
    assert result[0].caution is None


def test_IE에_없는_옛_소유자는_칠하지_않는다():
    """사진에 이름이 보여도 IE의 current_owners에 없으면 대상이 아니다.
    지분을 넘긴 옛 소유자를 칠하면 사용자가 그 사람을 임대인으로 오인한다."""
    extract = extract_with(current_owners=[Owner(name="소유자E")])
    result = _run(extract, as_result(gap_gu_page()))
    assert [h.title for h in result] == ["집주인 이름 · 소유자E"]


def test_사진에_없는_이름은_좌표_없이_넘어간다():
    extract = extract_with(current_owners=[Owner(name="홍길동")])
    assert _run(extract, as_result(gap_gu_page())) == []


# ══════════════════════════════════════════════════════════════════════════════
# 좌표 정규화 · 실패 내성 · 개인정보
# ══════════════════════════════════════════════════════════════════════════════


def test_좌표는_0과_1_사이로_정규화된다():
    extract = extract_with(current_owners=[Owner(name="소유자D")])
    box = _run(extract, as_result(gap_gu_page()))[0].box
    for value in (box.x, box.y, box.w, box.h):
        assert 0.0 <= value <= 1.0
    assert 0.0 <= box.x + box.w <= 1.0
    assert 0.0 <= box.y + box.h <= 1.0


def test_OCR이_통째로_실패하면_빈_목록을_돌려준다():
    extract = extract_with(current_owners=[Owner(name="소유자D")])
    assert _run(extract, OcrResult(errors=["timeout"])) == []


def test_원본_크기를_모르면_좌표를_주지_않는다():
    """정규화 기준이 없으면 앱에서 좌표가 통째로 밀린다 — 차라리 안 준다."""
    page = gap_gu_page()
    page.width = 0
    page.height = 0
    extract = extract_with(current_owners=[Owner(name="소유자D")])
    assert _run(extract, as_result(page)) == []


def test_페이지_인덱스가_그대로_전달된다():
    """사진 순서가 그대로 유지돼야 앱이 맞는 사진에 그린다."""
    extract = extract_with(current_owners=[Owner(name="소유자D")])
    result = _run(extract, as_result(gap_gu_page(index=2)))
    assert result[0].page == 2


@pytest.mark.parametrize(
    "name,masked",
    [("소유자D", "김○○"), ("주식회사하나은행", "주○○○○○○○"), ("김", "김"), ("", "(이름없음)")],
)
def test_로그용_이름_마스킹(name, masked):
    assert highlight.mask_name(name) == masked


# ══════════════════════════════════════════════════════════════════════════════
# 실제 OCR 응답 (out/ 이 있을 때만)
# ══════════════════════════════════════════════════════════════════════════════

_REAL_STEMS = ("3", "4")
_real_available = all((_OUT_DIR / f"ocr_{s}.json").is_file() for s in _REAL_STEMS)
requires_real = pytest.mark.skipif(
    not _real_available,
    reason="backend/out/ocr_*.json 없음 (실명 포함이라 커밋하지 않음 — 재생성: scripts/test_ocr_coords.py)",
)


# 실측 원본 크기 (Pillow) — 정규화 기준. 운영에서는 ocr.py가 전송 바이트에서 직접 읽는다.
_REAL_SIZES = {"3": (878, 1030), "4": (878, 1014)}


def real_pages() -> list[OcrPage]:
    pages = []
    for i, stem in enumerate(_REAL_STEMS):
        raw = json.loads((_OUT_DIR / f"ocr_{stem}.json").read_text(encoding="utf-8"))
        words = parse_words(raw)
        width, height = _REAL_SIZES[stem]
        pages.append(
            OcrPage(name=f"{stem}.png", index=i, words=words, lines=group_lines(words),
                    width=width, height=height)
        )
    return pages


@requires_real
def test_실제_등기부_갑구_이름_5명이_전부_잡힌다():
    items = build_items(real_pages())
    names = [hit.name for it in items if it.section == "갑구" for hit in it.names]
    assert names == ["소유자A", "소유자B", "소유자C", "소유자D", "소유자E"]


@requires_real
def test_실제_등기부_을구_근저당_2건이_말소로_잡힌다():
    items = build_items(real_pages())
    eul = {it.rank: it for it in items if it.section == "을구"}
    assert eul["1"].canceled and eul["2"].canceled
    assert "1번근저당권설정등기말소" in (eul["1"].cancel_evidence or "")
    assert "2번근저당권설정등기말소" in (eul["2"].cancel_evidence or "")


@requires_real
def test_실제_등기부_을구_1번은_페이지를_걸쳐_이어진다():
    """금액은 3.png, 근저당권자(하나은행)는 4.png — 항목은 페이지 경계에서 닫히면 안 된다."""
    items = build_items(real_pages())
    item = next(it for it in items if it.section == "을구" and it.rank == "1")
    assert item.page_indexes == [0, 1]
    assert [n.name for n in item.names] == ["주식회사하나은행"]


@requires_real
def test_실제_등기부에서_말소된_근저당은_칠해지지_않는다():
    """이 샘플의 유효 근저당은 0건이다 — 그래서 근저당 형광펜도 0건이어야 한다."""
    extract = extract_with(
        mortgages=[
            MoneyEntry(rank_number="1", amount=36_000_000, is_canceled=False),
            MoneyEntry(rank_number="2", amount=75_600_000, is_canceled=False),
        ]
    )
    result = _run(extract, OcrResult(pages=real_pages()))
    assert [h for h in result if h.kind == "mortgage"] == []


@requires_real
def test_실제_등기부에서_현재_소유자_이름에_좌표가_붙는다():
    extract = extract_with(current_owners=[Owner(name="소유자D"), Owner(name="소유자E")])
    result = _run(extract, OcrResult(pages=real_pages()))
    assert len(result) == 2
    assert all(h.page == 0 for h in result)  # 둘 다 3.png(첫 페이지)
    for h in result:
        assert 0.0 < h.box.x < 1.0 and 0.0 < h.box.y < 1.0
        assert h.box.w < 0.15  # 이름 word 하나 크기 (과거 버그는 옆 칸까지 번졌다)


# ══════════════════════════════════════════════════════════════════════════════
# 라운드 4 방어 — 페이지 누락 · 순서 · 다른 등기부 섞임 · 말소 미결
# ══════════════════════════════════════════════════════════════════════════════


def footer_row(y: float, *, page_no: int, total: int, issue: str, addr: str = "행복아파트") -> list[Word]:
    """실측 꼬리말 — `발급확인번호 AAPI-GJBJ-1806 …` + 우측 하단 `1/5`."""
    return [
        W("발급확인번호", 300, y, 80),
        W(issue, 400, y, 90),
        W(f"{page_no}/{total}", 800, y + 30, 24),
    ]


def address_row(y: float, addr: str) -> list[Word]:
    return [W("[집합건물]", 33, y, 74), W(addr, 116, y, 120)]


def page_with_footer(index: int, *, page_no: int, total: int, issue: str,
                     addr: str = "행복아파트", cancel: bool = True) -> OcrPage:
    base = eul_gu_page(with_cancel_row=cancel)
    rows = [address_row(10, addr)]
    rows.append(footer_row(950, page_no=page_no, total=total, issue=issue))
    words = list(base.words) + [w for r in rows for w in r]
    return OcrPage(name=f"page_{index + 1}.jpg", index=index, words=words,
                   lines=group_lines(words), width=PAGE_W, height=PAGE_H)


def test_페이지_표식으로_쪽수를_읽는다():
    from app.services.ocr_layout import check_document

    check = check_document([page_with_footer(0, page_no=1, total=1, issue="AAPI-GJBJ-1806")])
    assert check.ok_to_highlight_any is True
    assert check.ok_to_highlight_money is True
    assert check.notice is None


def test_쪽이_빠지면_금액_표시를_보류한다():
    """말소 근거 행이 안 올린 쪽에 있을 수 있다 — 이 경우 빚에 형광펜을 칠하면 안 된다."""
    from app.services.ocr_layout import check_document

    check = check_document([page_with_footer(0, page_no=1, total=5, issue="AAPI-GJBJ-1806")])
    assert check.ok_to_highlight_any is True  # 이름은 계속 보여준다
    assert check.ok_to_highlight_money is False
    assert check.notice and "5쪽 중 1쪽" in check.notice


def test_쪽이_빠지면_근저당_하이라이트가_실제로_사라진다():
    extract = extract_with(
        mortgages=[MoneyEntry(rank_number="1", amount=36_000_000, is_canceled=False)]
    )
    page = page_with_footer(0, page_no=1, total=5, issue="AAPI-GJBJ-1806", cancel=False)
    result = highlight.build_highlights(extract, as_result(page))
    assert result.highlights == []
    assert result.notice and "5쪽 중 1쪽" in result.notice


def test_다른_등기부가_섞이면_아무것도_표시하지_않는다():
    from app.services.ocr_layout import check_document

    check = check_document([
        page_with_footer(0, page_no=1, total=2, issue="AAPI-GJBJ-1806"),
        page_with_footer(1, page_no=2, total=2, issue="BBPI-XXXX-9999"),
    ])
    assert check.ok_to_highlight_any is False
    assert check.notice and "서로 다른 등기부" in check.notice


def test_발급확인번호가_없으면_상단_주소_줄로_섞임을_본다():
    from app.services.ocr_layout import check_document

    a = eul_gu_page(with_cancel_row=False)
    b = gap_gu_page(index=1)
    a_words = list(a.words) + address_row(10, "행복아파트")
    b_words = list(b.words) + address_row(10, "전혀다른아파트")
    pages = [
        OcrPage(name="a", index=0, words=a_words, lines=group_lines(a_words),
                width=PAGE_W, height=PAGE_H),
        OcrPage(name="b", index=1, words=b_words, lines=group_lines(b_words),
                width=PAGE_W, height=PAGE_H),
    ]
    check = check_document(pages)
    assert check.ok_to_highlight_any is False
    assert check.notice and "주소가 서로 달라요" in check.notice


def test_사진_순서가_뒤바뀌면_아무것도_표시하지_않는다():
    """항목이 페이지를 걸쳐 이어지므로, 순서가 틀리면 말소 판정 자체가 깨진다."""
    from app.services.ocr_layout import check_document

    check = check_document([
        page_with_footer(0, page_no=3, total=3, issue="AAPI-GJBJ-1806"),
        page_with_footer(1, page_no=1, total=3, issue="AAPI-GJBJ-1806"),
        page_with_footer(2, page_no=2, total=3, issue="AAPI-GJBJ-1806"),
    ])
    assert check.ok_to_highlight_any is False
    assert check.notice and "순서" in check.notice


def test_페이지_표식이_없으면_판별_불가로_두고_진행한다():
    """사진이 잘려 꼬리말이 없을 수 있다. 확인 못 한다고 기능을 끄면 정상 사진도 안 보인다."""
    from app.services.ocr_layout import check_document

    check = check_document([eul_gu_page(with_cancel_row=False)])
    assert check.ok_to_highlight_any is True
    assert check.ok_to_highlight_money is True
    assert any("표식" in r for r in check.reasons)


def test_말소_대상을_못_찾으면_금액_표시를_전부_보류한다():
    """'무언가 말소됐는데 무엇인지 모른다' 상태에서 칠하면 말소분을 칠할 수 있다."""
    rows = [
        section_row("을구", 40),
        header_row(90),
        [W("1", 66, 150, 11), W("근저당권설정", 117, 150, 91),
         W("2004년6월25일", 269, 150, 98), W("2004년6월25일", 391, 150, 100),
         W("채권최고액", 515, 150, 74), W("금36,000,000원", 606, 150, 105)],
        # 존재하지 않는 순위 9번을 말소한다는 행 → 대상 항목을 못 찾는다
        [W("2", 66, 250, 11), W("9번근저당권설정등", 117, 250, 124),
         W("2005년6월29일", 269, 250, 98)],
        [W("기말소", 117, 290, 44), W("제45409호", 270, 290, 68)],
    ]
    page = make_page(0, rows)
    extract = extract_with(
        mortgages=[MoneyEntry(rank_number="1", amount=36_000_000, is_canceled=False)]
    )
    result = highlight.build_highlights(extract, as_result(page))
    assert result.highlights == []
    assert result.notice and "말소" in result.notice


def test_구역을_모를_때도_말소를_놓치지_않는다():
    """중간 장부터 올려 구역 머리(【을 구】)가 없으면 구역이 '미상'이 된다.
    엄격히 비교하면 말소 근거 행과 대상이 갈려 **말소된 근저당이 칠해진다**."""
    base = eul_gu_page()
    # 구역 머리 줄(y=40)을 제거해 '미상' 상태를 만든다
    words = [w for w in base.words if w.y0 > 60]
    page = OcrPage(name="mid.jpg", index=0, words=words, lines=group_lines(words),
                   width=PAGE_W, height=PAGE_H)
    items = build_items([page])
    target = next(it for it in items if it.rank == "1")
    assert target.section == "미상"
    assert target.canceled is True  # 구역이 달라도 말소를 잡아야 한다

    extract = extract_with(
        mortgages=[MoneyEntry(rank_number="1", amount=36_000_000, is_canceled=False)]
    )
    assert _run(extract, as_result(page)) == []


# ══════════════════════════════════════════════════════════════════════════════
# "무엇을 찾아봤는지" 요약 — 침묵이 신뢰를 깎는다는 리뷰 3인 공통 지적 반영
# ══════════════════════════════════════════════════════════════════════════════


def test_말소된_근저당은_왜_안_칠했는지_사용자에게_말해준다():
    """이 한 줄이 없으면 사용자는 '이 앱이 을구를 안 봤다'로 읽는다 (페르소나 2인 공통)."""
    extract = extract_with(
        current_owners=[Owner(name="소유자D")],
        mortgages=[MoneyEntry(rank_number="1", amount=36_000_000, is_canceled=True)],
    )
    result = highlight.build_highlights(extract, as_result(eul_gu_page(), gap_gu_page(index=1)))
    joined = " ".join(result.checked_notes)
    assert "말소된 것으로 확인" in joined
    assert "못 읽었다는 뜻이 아니에요" in joined


def test_표시가_하나도_없어도_찾아본_항목을_알려준다():
    extract = extract_with(current_owners=[Owner(name="홍길동")])
    result = highlight.build_highlights(extract, as_result(gap_gu_page()))
    assert result.highlights == []
    assert result.checked_notes  # 침묵하지 않는다
    assert any("찾지 못했어요" in n for n in result.checked_notes)


def test_유효한_근저당을_못_찾으면_리포트로_안내한다():
    """말소돼서 안 칠한 것과, 유효한데 위치를 못 찾은 것이 화면에서 같아 보이면 안 된다."""
    extract = extract_with(
        current_owners=[Owner(name="소유자D")],
        mortgages=[MoneyEntry(rank_number="7", amount=99_000_000, is_canceled=False)],
    )
    result = highlight.build_highlights(extract, as_result(gap_gu_page()))
    assert any("리포트의 근거 카드에서 확인" in n for n in result.checked_notes)


def test_시트_문장에_출처가_붙는다():
    extract = extract_with(current_owners=[Owner(name="소유자D")])
    result = highlight.build_highlights(extract, as_result(gap_gu_page()))
    assert result.highlights[0].source and "갑구" in result.highlights[0].source


def test_공동명의_안내는_단정이_아니라_권고형이다():
    """'전원 동의가 필요합니다'는 권위 출처 없는 법적 단정 — 앱 신뢰를 흔든다(서연 지적)."""
    extract = extract_with(current_owners=[Owner(name="소유자D"), Owner(name="소유자E")])
    caution = highlight.build_highlights(extract, as_result(gap_gu_page())).highlights[0].caution
    assert caution and "가장 안전합니다" in caution
    assert "필요합니다" not in caution
