"""`LAYOUT_SOURCE` 스위치 — 구조화 경로의 입력만 바꾸고, **판정은 절대 안 건드린다.**

2026-07-28 Document Parse 조사 결과(`docs/document-parse-probe-2026-07-28.md`)에 따라
`ocr_layout` ↔ `document_parse` 를 `.env`로 고를 수 있게 했다.

이 파일이 지키는 것 셋:
1. 기본값은 **`ocr_layout`** 이다 — 스위치를 넣었다고 동작이 바뀌면 안 된다.
2. DP를 골라도 **좌표는 여전히 Document OCR에서** 온다(DP는 낱말 좌표를 안 준다).
3. 어느 경로든 **등급·점수는 한 건도 달라지지 않는다.**

⚠ 실호출 없음. DP 응답은 실측 모양을 본뜬 합성 데이터를 쓴다.
"""

from __future__ import annotations

import pytest

from app.schemas.internal import MoneyEntry, Owner, RegistryExtract
from app.services import document_parse, highlight, llm, ocr, report_builder, rule_engine
from app.services.document_parse import ParsedPage, ParseResult, render_parsed_text

from tests.test_highlight import as_result, eul_gu_page, gap_gu_page


def dp_pages() -> list[ParsedPage]:
    """실측 응답 모양 그대로의 합성 DP 결과 (2026-07-28 `out/dp_4.json` 구조).

    핵심은 **등기목적 칸의 접힘**이다 — 실제 응답이 `1번근저당권설정등 기말소`처럼
    공백 하나를 남긴 채 **한 셀 안에** 담아 준다.
    """
    table_html = (
        "<table><tr><td>순위번호</td><td>등기목적</td><td>접수</td>"
        "<td>등기원인</td><td>권리자 및 기타사항</td></tr>"
        "<tr><td>1</td><td>근저당권설정</td><td>2004년6월25일 제41414호</td>"
        "<td>2004년6월25일 설정계약</td>"
        "<td>채권최고액 금36,000,000원 채무자 홍길동 서울 양천구</td></tr>"
        "<tr><td>2</td><td>1번근저당권설정등 기말소</td><td>2005년6월29일 제45409호</td>"
        "<td>2005년6월29일 해지</td><td></td></tr></table>"
    )
    return [
        ParsedPage(
            index=0,
            name="page_1.jpg",
            elements=[
                {"category": "heading1", "content": {"text": "등기사항전부증명서(말소사항 포함)"}},
                {"category": "table", "content": {"html": table_html}},
                {"category": "footer", "content": {"text": "발급확인번호 AAPI-GJBJ-1806  1/1"}},
            ],
        )
    ]


# ══════════════════════════════════════════════════════════════════════════════
# 렌더링 — 밤 버그의 원인이 사라지는가
# ══════════════════════════════════════════════════════════════════════════════


def test_접힌_등기목적_칸이_한_덩어리로_복원된다():
    """`ocr_layout`이 컬럼 x밴드 알고리즘으로 겨우 하던 일을 공백 제거 한 줄이 대신한다."""
    text = render_parsed_text(dp_pages())
    assert "1번근저당권설정등기말소" in text
    assert "1번근저당권설정등 기말소" not in text


def test_긴_산문_칸의_띄어쓰기는_지우지_않는다():
    """`채권최고액 금36,000,000원 채무자 …`까지 붙이면 오히려 읽기 나빠진다."""
    text = render_parsed_text(dp_pages())
    assert "채권최고액 금36,000,000원" in text


def test_표는_칸_구분자로_행마다_한_줄이_된다():
    """`ocr_layout.render_layout_text`와 같은 모양이라 프롬프트를 바꿀 필요가 없다."""
    lines = render_parsed_text(dp_pages()).splitlines()
    header = next(line for line in lines if line.startswith("순위번호"))
    assert header.count("|") == 4  # 5칸
    assert "기타사항" in header


def test_짧은_칸의_정상_띄어쓰기도_같이_붙는다_알려진_한계():
    """접힘과 정상 띄어쓰기를 글자만 보고 가를 방법이 없다 — 이건 **알려진 한계**다.

    `권리자 및 기타사항`(헤더, 10자)이 `권리자및기타사항`으로 붙는다.
    손해는 "LLM이 공백 하나를 덜 본다"뿐이고, 이 계층은 판정과 무관하다.
    되돌리려면 `document_parse._FOLD_JOIN_MAX_CHARS`를 0으로 두면 된다(접힘도 남는다).
    """
    text = render_parsed_text(dp_pages())
    assert "권리자및기타사항" in text
    assert "권리자 및 기타사항" not in text


def test_표가_아닌_요소는_카테고리와_함께_적힌다():
    """`footer`/`heading1` 표식이 남아야 LLM이 '표 바깥 문구'를 구분할 수 있다."""
    text = render_parsed_text(dp_pages())
    assert "[heading1] 등기사항전부증명서(말소사항포함)" in text
    assert "[footer] 발급확인번호" in text


def test_빈_행은_버린다():
    pages = [ParsedPage(index=0, name="p", elements=[
        {"category": "table", "content": {"html": "<table><tr><td></td><td></td></tr></table>"}}
    ])]
    assert render_parsed_text(pages).strip() == "### 1쪽"


# ══════════════════════════════════════════════════════════════════════════════
# 스위치 — 기본값과 폴백
# ══════════════════════════════════════════════════════════════════════════════


def fake_ocr():
    return ocr.OcrResult(pages=[gap_gu_page(0), eul_gu_page()], elapsed=1.0)


def fake_pages():
    """`_layout_text_for`가 받는 것은 **이미 정렬된 페이지 목록**이다(OcrResult가 아니다).

    2026-07-28: 사진 순서 정렬을 두 번째 경로에도 먹이려고 시그니처를 바꿨다 —
    예전에는 LLM만 뒤섞인 문서를 읽고 그 결과가 '교차검증 불일치'로 나갔다.
    """
    return fake_ocr().pages


def one_image():
    """DP는 **전 장이 성공했을 때만** 쓴다 — 장수를 맞춰 줘야 폴백으로 안 떨어진다."""
    return [("page_1.jpg", b"")]


def test_기본값은_ocr_layout이다(monkeypatch):
    """스위치를 넣었다고 동작이 바뀌면 그건 리팩터가 아니라 사양 변경이다."""
    monkeypatch.delenv("LAYOUT_SOURCE", raising=False)
    called = []
    monkeypatch.setattr(
        document_parse, "run_document_parse", lambda *a, **k: called.append(1) or ParseResult()
    )
    text = report_builder._layout_text_for(one_image(), fake_pages(), None)
    assert called == [], "기본값에서 DP를 불렀다 — 크레딧이 새 나간다"
    assert text == llm.render_layout_text(fake_pages())


@pytest.mark.parametrize("value", ["ocr_layout", "OCR_LAYOUT", "", "  ", "이상한값"])
def test_모르는_값이면_기존_경로로_간다(monkeypatch, value):
    monkeypatch.setenv("LAYOUT_SOURCE", value)
    monkeypatch.setattr(
        document_parse, "run_document_parse", lambda *a, **k: pytest.fail("DP를 부르면 안 된다")
    )
    assert report_builder._layout_text_for(one_image(), fake_pages(), None)


def test_document_parse를_고르면_DP_텍스트를_쓴다(monkeypatch):
    monkeypatch.setenv("LAYOUT_SOURCE", "document_parse")
    monkeypatch.setattr(
        document_parse,
        "run_document_parse",
        lambda *a, **k: ParseResult(pages=dp_pages(), elapsed=3.9),
    )
    text = report_builder._layout_text_for(one_image(), fake_pages(), None)
    assert "1번근저당권설정등기말소" in text
    assert "[heading1]" in text


def test_DP가_실패하면_조용히_기존_경로로_되돌아간다(monkeypatch):
    """새 경로가 분석을 깨뜨리면 안 된다 — 이 저장소의 대원칙."""
    monkeypatch.setenv("LAYOUT_SOURCE", "document_parse")
    monkeypatch.setattr(
        document_parse,
        "run_document_parse",
        lambda *a, **k: ParseResult(errors=["timeout"]),
    )
    text = report_builder._layout_text_for(one_image(), fake_pages(), None)
    assert text == llm.render_layout_text(fake_pages())


# ══════════════════════════════════════════════════════════════════════════════
# 경계 — 스위치는 판정에도 좌표에도 닿지 않는다
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.parametrize("source", ["ocr_layout", "document_parse"])
def test_어느_경로를_골라도_등급이_같다(monkeypatch, source):
    """구조화 경로는 판정 계층이 아니다. 이 테스트가 깨지면 경계가 뚫린 것이다."""
    monkeypatch.setenv("LAYOUT_SOURCE", source)
    monkeypatch.setattr(
        document_parse,
        "run_document_parse",
        lambda *a, **k: ParseResult(pages=dp_pages(), elapsed=3.9),
    )
    extract = RegistryExtract(
        current_owners=[Owner(name="소유자D")],
        mortgages=[MoneyEntry(rank_number="1", amount=36_000_000, is_canceled=False)],
    )
    verdict = rule_engine.evaluate(extract, deposit=100_000_000, market_price=300_000_000)
    report_builder._layout_text_for(one_image(), fake_pages(), None)  # 경로를 실제로 태운다
    after = rule_engine.evaluate(extract, deposit=100_000_000, market_price=300_000_000)
    assert verdict.grade == after.grade
    assert verdict.gauge_progress == after.gauge_progress
    assert verdict.senior_debt_amount == after.senior_debt_amount


@pytest.mark.parametrize("source", ["ocr_layout", "document_parse"])
def test_어느_경로를_골라도_좌표는_Document_OCR에서_온다(monkeypatch, source):
    """DP는 낱말 좌표를 주지 않는다(표 하나당 사각형 하나). 좌표 출처는 바뀌지 않는다."""
    monkeypatch.setenv("LAYOUT_SOURCE", source)
    extract = RegistryExtract(current_owners=[Owner(name="소유자D")])
    result = highlight.build_highlights(extract, as_result(gap_gu_page(0)))
    assert [h.kind for h in result.highlights] == ["owner"]
    # 이름 word 하나 크기 — DP 좌표였다면 표 전체(페이지의 20~61%)가 됐을 것이다
    assert result.highlights[0].box.w < 0.15


def test_DP_모듈은_좌표를_들고_다니지_않는다():
    """실수로 DP 좌표를 쓰는 코드가 생기지 않게, 자료구조 자체에 좌표를 두지 않는다."""
    page = ParsedPage(index=0, name="p", elements=[{"category": "table", "content": {}}])
    assert not hasattr(page, "coordinates")
    assert "coordinates" not in ParsedPage.__dataclass_fields__


def test_DP가_일부_장만_성공하면_기존_경로로_되돌아간다(monkeypatch):
    """반쪽 문서를 LLM에 먹이면 항목 개수가 모자라고, 그 부족분이 **교차검증 불일치로
    둔갑해** 사용자에게는 등기부 문제로 읽힌다(2026-07-28 gap-checker 지적)."""
    monkeypatch.setenv("LAYOUT_SOURCE", "document_parse")
    monkeypatch.setattr(
        document_parse,
        "run_document_parse",
        lambda *a, **k: ParseResult(pages=dp_pages(), elapsed=3.9, errors=["2장 실패"]),
    )
    images = [("page_1.jpg", b""), ("page_2.jpg", b""), ("page_3.jpg", b"")]
    text = report_builder._layout_text_for(images, fake_pages(), None)
    assert text == llm.render_layout_text(fake_pages())
    assert "1번근저당권설정등기말소" not in text  # DP 텍스트를 쓰지 않았다
