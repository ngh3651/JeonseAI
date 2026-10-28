"""등기부가 아닌 사진 거르기 (2026-10-24) — '못 읽은 등기부'와 '등기부 아님'을 가른다."""

from __future__ import annotations

import pytest

from app.schemas.internal import RegistryExtract
from app.services import document_gate, extraction, ocr, report_builder, store
from app.services.ocr_layout import OcrPage, Word


def _page(*texts: str) -> OcrPage:
    words = [Word(text=t, confidence=0.9, x0=0, y0=0, x1=10, y1=10) for t in texts]
    return OcrPage(name="p1", index=0, words=words, lines=[], width=100, height=100)


EMPTY = RegistryExtract.from_raw({})
REAL = RegistryExtract.from_raw({"address": "서울특별시 서초구 서초동 1557-8", "current_owners": [{"name": "홍길동"}]})


def test_keyboard_photo_is_not_registry():
    assert document_gate.looks_not_registry(EMPTY, [_page("Claude는", "AI이므로", "Enter", "Shift")])


def test_ocr_failed_and_ie_empty_is_not_registry():
    assert document_gate.looks_not_registry(EMPTY, [])


def test_badly_read_registry_is_not_rejected():
    """IE가 아무것도 못 읽어도, OCR에 등기부 낱말이 보이면 '못 읽은 등기부' → 분석 계속(확인 필요)."""
    assert not document_gate.looks_not_registry(EMPTY, [_page("【", "을", "구", "】", "순위번호", "등기목적", "접 수")])


def test_ie_found_content_is_never_rejected():
    assert not document_gate.looks_not_registry(REAL, [])


def test_marker_count_ignores_spaces():
    assert document_gate.ocr_marker_count([_page("갑", "구", "표 제 부")]) == 2


def test_analyze_rejects_non_registry_without_saving(monkeypatch, tmp_path):
    """분석 단계에서 400으로 멈추고, 기록(최근 분석)에 아무것도 남기지 않는다."""
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    store.reset()
    monkeypatch.setattr(extraction, "extract_registry", lambda images, run_id=None: EMPTY)
    monkeypatch.setattr(
        report_builder,
        "_ocr_then_second_opinion",
        lambda images, run_id=None, stop=None: report_builder.OcrPath(ocr=ocr.OcrResult(pages=[_page("Enter", "Shift")])),
    )
    before = len(store.list_reports(device_id="dev-gate"))
    with pytest.raises(extraction.ExtractionError) as e:
        report_builder.analyze([("a.jpg", b"x")], deposit=1, market_price=None, alias="아", device_id="dev-gate")
    assert e.value.status_code == 400
    assert "등기부등본이 아닌 사진" in e.value.detail
    assert len(store.list_reports(device_id="dev-gate")) == before
    store.reset()
