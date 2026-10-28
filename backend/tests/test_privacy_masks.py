"""사진 속 실명·주민번호 **자리** — '사진 속 이름 가리기'가 켜지면 화면에 실명 0건 (P0-2b, 2026-10-22).

PR #4의 스위치는 집주인 이름 칸만 덮었다. 이 파일은 서버가 **나머지 이름 칸**의 위치를 빠짐없이
내려주는지 본다: 이전 소유자·공유자, 채무자, 개인 근저당권자, 전세권자, 임차권자, 개인 가압류 채권자,
주민·법인등록번호. 은행·회사·관공서 이름은 **덮지 않는다**(공개된 이름 + 빚 형광펜 대조가 살아야 한다).

검사 방법: 합성 등기부(실명 대신 가짜 이름)를 만들고, **이름 글자의 상자가 가림 상자 안에 들어가는지**
좌표로 확인한다. 픽셀이 아니라 상자로 보는 이유 — 서버는 좌표만 보내고, 그리는 쪽(앱)은 위젯 테스트가 본다.

⚠ 표시 전용이다. 여기 어떤 테스트도 등급을 다루지 않는다(판정 불변은 `test_verdict_regression.py`).
"""

from __future__ import annotations

import logging

import pytest

from app.schemas.internal import MoneyEntry, Owner, RegistryEntry, RegistryExtract
from app.services import privacy_masks
from app.services.ocr import OcrResult
from app.services.ocr_layout import OcrPage, Word, group_lines

from tests.test_highlight import PAGE_H, PAGE_W, W, eul_gu_page, gap_gu_page, header_row, section_row

PEOPLE = ("홍길동", "김영희", "이전수", "박사채", "최전세", "정임차", "강채권", "윤채무")


def _page(index: int, rows: list[list[Word]], *, width: int = PAGE_W, height: int = PAGE_H) -> OcrPage:
    words = [w for row in rows for w in row]
    return OcrPage(name=f"page_{index + 1}.jpg", index=index, words=words,
                   lines=group_lines(words), width=width, height=height)


def gap_gu_full(index: int = 0) -> OcrPage:
    """갑구 — 옛 소유자(이전수) → 공유자 2명(홍길동·김영희) + 개인 가압류(강채권) + 관공서 압류."""
    rows = [section_row("갑구", 40), header_row(90)]
    rows.append([W("1", 66, 150, 11), W("소유권보존", 117, 150, 75), W("2001년3월2일", 269, 150, 98),
                 W("소유자", 516, 150, 44), W("이전수", 566, 150, 44), W("600101-*******", 616, 150, 107)])
    rows.append([W("2", 66, 210, 11), W("소유권이전", 117, 210, 75), W("2006년6월23일", 269, 210, 98),
                 W("2006년2월15일", 391, 210, 100), W("공유자", 516, 210, 44)])
    rows.append([W("제50495호", 271, 250, 67), W("매매", 394, 250, 28),
                 W("홍길동", 531, 250, 44), W("900101-*******", 589, 250, 107)])
    rows.append([W("지분", 531, 290, 29), W("2분의", 566, 290, 38), W("1", 612, 290, 8)])
    rows.append([W("김영희", 531, 330, 43), W("920202-*******", 589, 330, 107)])
    # 개인 가압류 — 채권자는 사람(이름 + 번호)
    rows.append([W("3", 66, 390, 11), W("가압류", 117, 390, 48), W("2024년1월5일", 269, 390, 98),
                 W("청구금액", 516, 390, 60), W("금10,000,000원", 590, 390, 110)])
    rows.append([W("채권자", 516, 430, 44), W("강채권", 566, 430, 44), W("750505-*******", 616, 430, 107)])
    # 관공서 압류 — 권리자 국 / 처분청 양천세무서 (가리지 않는다)
    rows.append([W("4", 66, 490, 11), W("압류", 117, 490, 30), W("2024년3월1일", 269, 490, 98),
                 W("권리자", 516, 490, 44), W("국", 566, 490, 14)])
    rows.append([W("처분청", 516, 530, 44), W("양천세무서", 566, 530, 74)])
    return _page(index, rows)


def eul_gu_full(index: int = 1) -> OcrPage:
    """을구 — 은행 근저당(채무자 홍길동, 번호 없음) · 개인 근저당(박사채) · 전세권(최전세) · 임차권(정임차)."""
    rows = [section_row("을구", 40), header_row(90)]
    rows.append([W("1", 66, 150, 11), W("근저당권설정", 117, 150, 91), W("2004년6월25일", 269, 150, 98),
                 W("채권최고액", 515, 150, 74), W("금36,000,000원", 606, 150, 105)])
    rows.append([W("채무자", 515, 190, 44), W("홍길동", 565, 190, 44)])
    rows.append([W("근저당권자", 515, 230, 74), W("주식회사하나은행", 595, 230, 120),
                 W("110111-0015671", 720, 230, 107)])
    rows.append([W("2", 66, 290, 11), W("근저당권설정", 117, 290, 91), W("2025년3월2일", 269, 290, 98),
                 W("채권최고액", 515, 290, 74), W("금20,000,000원", 606, 290, 105)])
    rows.append([W("채무자", 515, 330, 44), W("윤채무", 565, 330, 44)])
    rows.append([W("근저당권자", 515, 370, 74), W("박사채", 595, 370, 44), W("750101-*******", 645, 370, 107)])
    rows.append([W("3", 66, 430, 11), W("전세권설정", 117, 430, 75), W("2025년5월1일", 269, 430, 98),
                 W("전세금", 515, 430, 44), W("금150,000,000원", 566, 430, 116)])
    rows.append([W("전세권자", 515, 470, 60), W("최전세", 580, 470, 44), W("880808-*******", 630, 470, 107)])
    rows.append([W("4", 66, 530, 11), W("주택임차권", 117, 530, 75), W("2025년8월1일", 269, 530, 98),
                 W("임차보증금", 515, 530, 74), W("금90,000,000원", 595, 530, 105)])
    rows.append([W("임차권자", 515, 570, 60), W("정임차", 580, 570, 44), W("950909-*******", 630, 570, 107)])
    return _page(index, rows)


def extract_full() -> RegistryExtract:
    return RegistryExtract(
        current_owners=[Owner(name="홍길동", share="2분의 1"), Owner(name="김영희", share="2분의 1")],
        ownership_changes=[RegistryEntry(holder="이전수"), RegistryEntry(holder="홍길동, 김영희")],
        provisional_seizures=[RegistryEntry(rank_number="3", claimant="강채권")],
        seizures=[RegistryEntry(rank_number="4", claimant="국")],
        mortgages=[
            MoneyEntry(rank_number="1", amount=36_000_000, debtor="홍길동", mortgagee="주식회사하나은행"),
            MoneyEntry(rank_number="2", amount=20_000_000, debtor="윤채무", mortgagee="박사채"),
        ],
        jeonse_rights=[MoneyEntry(rank_number="3", amount=150_000_000, holder="최전세")],
        lease_registrations=[RegistryEntry(rank_number="4", holder="정임차")],
    )


def _covered(word: Word, page: OcrPage, masks) -> bool:
    """이 낱말의 상자(중심 + 네 귀퉁이 안쪽)가 같은 쪽의 가림 상자 하나 안에 들어가는가."""
    x0, y0, x1, y1 = word.x0 / page.width, word.y0 / page.height, word.x1 / page.width, word.y1 / page.height
    eps = 1e-6
    for m in masks:
        if m.page != page.index:
            continue
        if m.x - eps <= x0 and m.y - eps <= y0 and x1 <= m.x + m.w + eps and y1 <= m.y + m.h + eps:
            return True
    return False


def _words_with(page: OcrPage, text: str) -> list[Word]:
    return [w for w in page.words if text in w.text]


def _run(*pages: OcrPage, extract: RegistryExtract | None = None):
    return privacy_masks.build_privacy_masks(OcrResult(pages=list(pages)), extract, page_count=len(pages))


# ══════════════════════════════════════════════════════════════════════════════
# ① 사람 이름 — 전부 덮는다
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.parametrize("with_extract", [True, False])
def test_사람_이름과_주민번호는_전부_덮는다(with_extract):
    """추출 결과가 없어도(①등록번호 ②역할어만으로) 모든 사람 이름이 덮여야 한다."""
    gap, eul = gap_gu_full(0), eul_gu_full(1)
    result = _run(gap, eul, extract=extract_full() if with_extract else None)
    for page in (gap, eul):
        for name in PEOPLE:
            for word in _words_with(page, name):
                assert _covered(word, page, result.masks), f"{page.name}의 '{name}'이 안 덮였다"
        for word in page.words:
            if "-*******" in word.text:
                assert _covered(word, page, result.masks), f"{page.name}의 주민번호가 안 덮였다"


def test_법인등록번호도_덮는다():
    eul = eul_gu_full(0)
    result = _run(eul)
    corp_id = next(w for w in eul.words if w.text == "110111-0015671")
    assert _covered(corp_id, eul, result.masks)


@pytest.mark.parametrize(
    "institution", ["주식회사하나은행", "양천세무서", "국"],
)
def test_은행_회사_관공서_이름은_덮지_않는다(institution):
    """공개된 이름이다 — 덮으면 '어느 은행 빚인가'를 사진과 대조할 수 없다."""
    gap, eul = gap_gu_full(0), eul_gu_full(1)
    result = _run(gap, eul, extract=extract_full())
    for page in (gap, eul):
        for word in page.words:
            if word.text == institution:
                assert not _covered(word, page, result.masks), f"기관 '{institution}'까지 덮었다"


def test_빚_금액과_순위번호는_덮지_않는다():
    """가림은 이름 칸에만 — 빚 형광펜(순위번호~금액)이 읽혀야 대조할 수 있다."""
    eul = eul_gu_full(0)
    result = _run(eul, extract=extract_full())
    for word in eul.words:
        if word.text.startswith("금") and "," in word.text:
            assert not _covered(word, eul, result.masks), f"금액 '{word.text}'까지 덮었다"
        if word.text in {"1", "2", "3", "4"} and word.x0 < 100:
            assert not _covered(word, eul, result.masks), "순위번호까지 덮었다"


def test_표_머리의_권리자_및_기타사항은_이름이_아니다():
    gap = gap_gu_full(0)
    result = _run(gap)
    for word in gap.words:
        if word.text in {"및", "기타사항"}:
            assert not _covered(word, gap, result.masks)


# ══════════════════════════════════════════════════════════════════════════════
# ② OCR이 낱말을 이상하게 자른 경우
# ══════════════════════════════════════════════════════════════════════════════


def test_이름과_번호가_한_낱말로_붙어_와도_덮는다():
    page = _page(0, [section_row("갑구", 40), header_row(90),
                     [W("1", 66, 150, 11), W("소유권이전", 117, 150, 75),
                      W("소유자", 516, 150, 44), W("홍길동900101-*******", 566, 150, 150)]])
    result = _run(page)
    word = next(w for w in page.words if w.text.startswith("홍길동"))
    # 낱말 전체(이름 + 번호)가 덮인다
    assert _covered(word, page, result.masks)


def test_번호가_두_낱말로_쪼개져도_덮는다():
    """`900101-` / `*******` — OCR이 줄표에서 끊는 일이 있다."""
    page = _page(0, [section_row("갑구", 40), header_row(90),
                     [W("1", 66, 150, 11), W("소유권이전", 117, 150, 75), W("소유자", 516, 150, 44),
                      W("홍길동", 566, 150, 44), W("900101-", 616, 150, 52), W("*******", 672, 150, 50)]])
    result = _run(page)
    for text in ("홍길동", "900101-", "*******"):
        word = next(w for w in page.words if w.text == text)
        assert _covered(word, page, result.masks), text


def test_역할어에_이름이_붙어_와도_덮는다():
    page = _page(0, [section_row("을구", 40), header_row(90),
                     [W("1", 66, 150, 11), W("근저당권설정", 117, 150, 91),
                      W("채권최고액", 515, 150, 74), W("금36,000,000원", 606, 150, 105)],
                     [W("채무자홍길동", 515, 190, 90)]])
    result = _run(page)
    word = next(w for w in page.words if w.text == "채무자홍길동")
    # 이름 부분(오른쪽 절반)은 반드시 덮인다 — 낱말 안을 글자 폭으로 어림해 자른다
    name_part = Word(text="홍길동", confidence=1, x0=word.x0 + 40, y0=word.y0, x1=word.x1, y1=word.y1)
    assert _covered(name_part, page, result.masks)


def test_추출에만_있는_이름도_사진에서_찾아_덮는다():
    """등록번호도 역할어도 없는 줄 — IE가 읽은 이름과 대조하는 길(③)이 잡는다."""
    page = _page(0, [section_row("갑구", 40), header_row(90),
                     [W("1-1", 66, 150, 22), W("1번등기명의인표시변경", 117, 150, 150),
                      W("홍길동의", 516, 150, 58), W("주소", 580, 150, 30)]])
    extract = RegistryExtract(current_owners=[Owner(name="홍길동")])
    result = _run(page, extract=extract)
    word = next(w for w in page.words if w.text == "홍길동의")
    name_part = Word(text="홍길동", confidence=1, x0=word.x0, y0=word.y0, x1=word.x0 + 40, y1=word.y1)
    assert _covered(name_part, page, result.masks)


def test_이전이라는_글자로_시작하는_이름도_대조에서_빠지지_않는다():
    """'이전'은 등기원인어(소유권 이전)라 접두어로 떼면 `이전수`가 `수`로 잘려 사라진다."""
    names = privacy_masks.person_names(RegistryExtract(ownership_changes=[RegistryEntry(holder="이전수")]))
    assert "이전수" in names


def test_채권자가_구청_이름이어도_주소_줄은_가리지_않는다():
    """`서울특별시 양천구`가 채권자면 `양천구`가 이름처럼 남는다 — 주소에 든 낱말은 대조에서 뺀다."""
    extract = RegistryExtract(
        address="서울특별시 양천구 목동 123-4",
        seizures=[RegistryEntry(rank_number="4", claimant="서울특별시 양천구")],
    )
    assert privacy_masks.person_names(extract) == []
    page = _page(0, [[W("[집합건물]", 33, 10, 74), W("서울특별시", 116, 10, 76), W("양천구", 198, 10, 46)]])
    result = _run(page, extract=extract)
    addr = next(w for w in page.words if w.text == "양천구")
    assert not _covered(addr, page, result.masks)


def test_추출_이름_목록에서_기관과_꼬리표는_빠진다():
    names = privacy_masks.person_names(extract_full())
    assert set(names) >= {"홍길동", "김영희", "이전수", "박사채", "최전세", "정임차", "강채권", "윤채무"}
    assert "주식회사하나은행" not in names and "국" not in names


# ══════════════════════════════════════════════════════════════════════════════
# ③ 못 찾아본 쪽 — 통째로 덮는다 (마지막 방어선)
# ══════════════════════════════════════════════════════════════════════════════


def test_OCR이_실패한_쪽은_통째로_덮는다():
    gap = gap_gu_full(0)
    # 3장을 올렸는데 OCR은 1쪽만 돌려줬다(2·3쪽 실패)
    result = privacy_masks.build_privacy_masks(OcrResult(pages=[gap]), None, page_count=3)
    full = [m for m in result.masks if (m.x, m.y, m.w, m.h) == privacy_masks.FULL_PAGE]
    assert sorted(m.page for m in full) == [1, 2]
    assert result.checked_pages == [0] and result.unchecked_pages == [1, 2]


def test_글자를_하나도_못_읽은_쪽도_통째로_덮는다():
    blank = OcrPage(name="blank.jpg", index=0, words=[], lines=[], width=PAGE_W, height=PAGE_H)
    result = _run(blank)
    assert [(m.page, m.x, m.y, m.w, m.h) for m in result.masks] == [(0, 0.0, 0.0, 1.0, 1.0)]


def test_OCR_쪽_번호가_장수보다_커도_빠뜨리지_않는다():
    """방어 — 장수(page_count)가 모자라게 와도 OCR이 돌려준 쪽은 모두 찾아본다."""
    eul = eul_gu_full(1)
    result = privacy_masks.build_privacy_masks(OcrResult(pages=[eul]), None, page_count=1)
    assert result.checked_pages == [1] and result.unchecked_pages == [0]
    corp_id = next(w for w in eul.words if w.text == "110111-0015671")
    assert _covered(corp_id, eul, result.masks)


def test_원본_크기를_모르면_그_쪽은_통째로_덮는다():
    gap = gap_gu_full(0)
    sizeless = OcrPage(name=gap.name, index=0, words=gap.words, lines=gap.lines, width=0, height=0)
    result = _run(sizeless)
    assert result.unchecked_pages == [0]
    assert len(result.masks) == 1 and result.masks[0].w == 1.0


def test_좌표는_0과_1_사이이고_쪽은_업로드_순서다():
    gap, eul = gap_gu_full(0), eul_gu_full(1)
    result = _run(gap, eul, extract=extract_full())
    assert result.masks
    assert {m.page for m in result.masks} == {0, 1}
    for m in result.masks:
        assert 0 <= m.x <= 1 and 0 <= m.y <= 1 and 0 < m.w <= 1 and 0 < m.h <= 1
        assert m.x + m.w <= 1.000001 and m.y + m.h <= 1.000001


def test_같은_이름을_여러_길로_찾아도_상자는_하나로_합친다():
    page = gap_gu_page(0)
    result = _run(page, extract=RegistryExtract(current_owners=[Owner(name="홍길동")]))
    hong = next(w for w in page.words if w.text == "홍길동")
    hits = [m for m in result.masks if _covered(hong, page, [m])]
    assert len(hits) == 1


# ══════════════════════════════════════════════════════════════════════════════
# ④ 개인정보 — 상자에도 로그에도 글자가 없다
# ══════════════════════════════════════════════════════════════════════════════


class _Collect(logging.Handler):
    def __init__(self) -> None:
        super().__init__(level=logging.DEBUG)
        self.lines: list[str] = []

    def emit(self, record: logging.LogRecord) -> None:
        self.lines.append(record.getMessage())


def test_가림_상자와_로그에_이름이_없다():
    logger = logging.getLogger("jeonseai")
    handler = _Collect()
    logger.addHandler(handler)
    old = logger.level
    logger.setLevel(logging.DEBUG)
    try:
        result = _run(gap_gu_full(0), eul_gu_full(1), extract=extract_full())
    finally:
        logger.removeHandler(handler)
        logger.setLevel(old)
    dumped = "".join(m.model_dump_json() for m in result.masks)
    assert set(result.masks[0].model_dump()) == {"page", "x", "y", "w", "h"}
    joined = "\n".join(handler.lines)
    assert "[가리기]" in joined
    for name in PEOPLE:
        assert name not in dumped and name not in joined


def test_가리기는_말소된_줄의_이름도_덮는다():
    """말소 = 빚이 없어졌다는 뜻이지 이름이 공개됐다는 뜻이 아니다 (하이라이트와 반대 규칙)."""
    page = eul_gu_page(with_cancel_row=True)
    words = list(page.words) + [W("채무자", 515, 190, 44), W("홍길동", 565, 190, 44)]
    page = OcrPage(name="p.jpg", index=0, words=words, lines=group_lines(words), width=PAGE_W, height=PAGE_H)
    result = _run(page)
    hong = next(w for w in page.words if w.text == "홍길동")
    assert _covered(hong, page, result.masks)


# ══════════════════════════════════════════════════════════════════════════════
# ④-b 하이라이트가 '이름'으로 읽은 칸은 하나도 빠짐없이 가린다 (기존 OCR 픽스처)
# ══════════════════════════════════════════════════════════════════════════════

from app.services.ocr_layout import build_items  # noqa: E402

from tests.test_highlight import corp_gap_gu_page, real_pages, requires_real  # noqa: E402


def _assert_every_name_hit_covered(pages: list[OcrPage]) -> int:
    """`ocr_layout`(하이라이트)이 등록번호 앞에서 찾은 이름(개인) 낱말이 전부 가림 상자 안에 있는가.

    ⚠ 하이라이트 쪽이 **꼬리표(`소유자`)를 이름으로** 집는 경우는 뺀다 — 이름이 등기원인어로 시작하면
      (`이전수` → '이전'을 떼면 `수` 한 글자) 그 이름을 버리고 한 칸 앞의 `소유자`를 집는다(기존 동작, 집주인
      하이라이트가 빠질 뿐 엉뚱한 곳을 칠하지는 않는다). 꼬리표는 실명이 아니고, 진짜 이름 `이전수`는
      `test_사람_이름과_주민번호는_전부_덮는다`가 덮이는 것을 확인한다.
    """
    result = privacy_masks.build_privacy_masks(OcrResult(pages=pages), None, page_count=len(pages))
    by_index = {p.index: p for p in pages}
    checked = 0
    for item in build_items(pages):
        for hit in item.names:
            if hit.kind != "개인":
                continue
            page = by_index[hit.page_index]
            line = next(ln for ln in page.lines if ln.index == hit.line_index)
            word = line.words[hit.word_index]
            if privacy_masks._is_label(word.text.strip()):
                continue
            assert _covered(word, page, result.masks), f"{page.name} L{hit.line_index}의 이름 낱말이 안 덮였다"
            checked += 1
    return checked


def test_하이라이트가_찾은_이름은_전부_덮인다_합성_픽스처():
    pages = [gap_gu_page(0), gap_gu_full(1), eul_gu_full(2)]
    assert _assert_every_name_hit_covered(pages) >= 6


def test_법인_소유자_등기부도_돈다():
    """법인 소유자 이름은 공개된 이름이라 덮지 않아도 되지만, 그 등록번호는 덮는다."""
    page = corp_gap_gu_page(0)
    result = _run(page)
    corp_id = next(w for w in page.words if w.text == "110111-0000000")
    assert _covered(corp_id, page, result.masks)
    corp_name = next(w for w in page.words if w.text == "주식회사가나다")
    assert not _covered(corp_name, page, result.masks)


@requires_real
def test_실제_등기부에서_이름_낱말이_전부_덮인다():
    """`backend/out/ocr_*.json`(실명 포함, 커밋 안 함)이 있을 때만 — 실제 OCR 배치에서도 빠짐없는가."""
    assert _assert_every_name_hit_covered(real_pages()) >= 5


# ══════════════════════════════════════════════════════════════════════════════
# ⑤ 분석 응답 — 끝에서 끝까지 (크레딧 0원)
# ══════════════════════════════════════════════════════════════════════════════

from tests.test_analyze_smoke import (  # noqa: E402,F401 — pytest 픽스처 재사용
    blank_image,
    client,
    no_network,
    raw_ocr_json,
)


def _registry_raw_full() -> dict:
    return {
        "address": "서울특별시 ○○구 ○○동 123-4",
        "exclusive_area_sqm": 44.2,
        "current_owners": [{"name": "홍길동", "share": "2분의 1"}, {"name": "김영희", "share": "2분의 1"}],
        "ownership_changes": [{"holder": "이전수"}, {"holder": "홍길동, 김영희"}],
        "provisional_seizures": [{"rank_number": "3", "claimant": "강채권", "is_canceled": False}],
        "provisional_dispositions": [],
        "seizures": [{"rank_number": "4", "claimant": "국", "is_canceled": False}],
        "auction_commencements": [],
        "trust_registrations": [],
        "mortgages": [
            {"rank_number": 1, "max_claim_amount": 36000000, "debtor": "홍길동",
             "mortgagee": "주식회사하나은행", "is_canceled": False},
            {"rank_number": 2, "max_claim_amount": 20000000, "debtor": "윤채무",
             "mortgagee": "박사채", "is_canceled": False},
        ],
        "jeonse_rights": [{"rank_number": "3", "deposit_amount": 150000000, "holder": "최전세",
                           "is_canceled": False}],
        "lease_registrations": [{"rank_number": "4", "holder": "정임차", "is_canceled": False}],
    }


def test_분석_응답에_가림_상자가_실리고_상자에는_글자가_없다(client, no_network):
    gap, eul = gap_gu_full(0), eul_gu_full(1)
    no_network(_registry_raw_full(), [raw_ocr_json(gap), raw_ocr_json(eul)])
    files = [("files", (f"page_{i + 1}.jpg", blank_image(PAGE_W, PAGE_H), "image/jpeg")) for i in range(2)]
    resp = client.post("/api/analyze", files=files, data={"deposit": "120000000"},
                       headers={"X-Device-Id": "mask-test-device-01"})
    assert resp.status_code == 200, resp.text
    report = resp.json()
    assert report["privacyMasksReady"] is True
    masks = report["privacyMasks"]
    assert masks and {m["page"] for m in masks} == {0, 1}
    # 상자에는 **위치만** — 글자는 하나도 없다. (2026-10-22부터 분석 응답 자체는 실명이다 — 화면엔 실명,
    # 서버 기록엔 가린 사본. 그쪽은 test_pii_persistence가 본다.)
    assert all(set(m) == {"page", "x", "y", "w", "h"} for m in masks)
    assert all(isinstance(m[k], (int, float)) for m in masks for k in ("x", "y", "w", "h"))
    for name in PEOPLE:
        assert name not in repr(masks), f"가림 상자에 실명 '{name}'"

    # 응답의 상자로도 모든 이름이 덮인다 (서버 → JSON → 다시 읽어도 같은 결과)
    from app.schemas.contract import PrivacyMask

    parsed = [PrivacyMask(**m) for m in masks]
    for page in (gap, eul):
        for name in PEOPLE:
            for word in _words_with(page, name):
                assert _covered(word, page, parsed), f"응답 상자로 '{name}'이 안 덮였다"


def test_가림_상자를_만들다_터져도_리포트는_나가고_준비_안_됨으로_표시된다(client, no_network, monkeypatch):
    def boom(*_a, **_k):
        raise RuntimeError("일부러 터뜨림")

    monkeypatch.setattr(privacy_masks, "build_privacy_masks", boom)
    no_network(_registry_raw_full(), [raw_ocr_json(gap_gu_full(0))])
    files = [("files", ("page_1.jpg", blank_image(PAGE_W, PAGE_H), "image/jpeg"))]
    resp = client.post("/api/analyze", files=files, data={"deposit": "120000000"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["privacyMasksReady"] is False
    assert resp.json()["privacyMasks"] == []
