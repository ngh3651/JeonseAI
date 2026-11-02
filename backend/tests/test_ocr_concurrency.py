"""OCR 장별 동시 호출 (2026-11-03) — 순서·결과는 그대로, 시간만 줄어든다."""

from __future__ import annotations

import threading
import time

from app.services import extraction, ocr


def _raw(text: str) -> dict:
    return {
        "words": [
            {"text": text, "confidence": 0.99,
             "boundingBox": {"vertices": [{"x": 10, "y": 10}, {"x": 60, "y": 10}, {"x": 60, "y": 30}, {"x": 10, "y": 30}]}}
        ],
    }


def _jpeg() -> bytes:
    import io

    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (100, 100), "white").save(buf, "JPEG")
    return buf.getvalue()


def test_동시에_불러도_올린_순서대로_쌓이고_시간이_줄어든다(monkeypatch):
    monkeypatch.setenv("OCR_CONCURRENCY", "2")
    monkeypatch.setenv("UPSTAGE_API_KEY", "test")
    monkeypatch.setattr(ocr, "_OCR_STAGGER_SECONDS", 0.0)
    live = {"now": 0, "max": 0}
    lock = threading.Lock()

    def fake(api_key, filename, data):
        with lock:
            live["now"] += 1
            live["max"] = max(live["max"], live["now"])
        time.sleep(0.2 if filename == "page_1.jpg" else 0.05)  # 1쪽이 가장 늦게 온다
        with lock:
            live["now"] -= 1
        return _raw(filename)

    monkeypatch.setattr(ocr, "call_document_ocr", fake)
    images = [(f"page_{i}.jpg", _jpeg()) for i in range(1, 5)]
    t0 = time.perf_counter()
    result = ocr.run_ocr(images)
    took = time.perf_counter() - t0
    assert [p.name for p in result.pages] == ["page_1.jpg", "page_2.jpg", "page_3.jpg", "page_4.jpg"]
    assert [p.index for p in result.pages] == [0, 1, 2, 3]
    assert [p.words[0].text for p in result.pages] == [f"page_{i}.jpg" for i in range(1, 5)]
    assert live["max"] == 2, "동시에 2장까지만"
    assert took < 0.2 + 0.05 * 3, f"순차보다 빨라야 한다({took:.2f}초)"


def test_요청_제한이면_한_번_더_부르고_한_장이_끝내_실패해도_나머지는_살린다(monkeypatch):
    monkeypatch.setenv("OCR_CONCURRENCY", "2")
    monkeypatch.setenv("UPSTAGE_API_KEY", "test")
    monkeypatch.setattr(ocr, "_OCR_STAGGER_SECONDS", 0.0)
    monkeypatch.setattr(ocr, "_OCR_RETRY_WAIT_SECONDS", 0.0)
    calls: dict[str, int] = {}

    def fake(api_key, filename, data):
        calls[filename] = calls.get(filename, 0) + 1
        if filename == "page_1.jpg" and calls[filename] == 1:
            raise ocr.OcrError(429, "잠시 뒤")
        if filename == "page_3.jpg":
            raise ocr.OcrError(400, "못 읽음")  # 4xx(429 아님)는 다시 부르지 않는다
        return _raw(filename)

    monkeypatch.setattr(ocr, "call_document_ocr", fake)
    images = [(f"page_{i}.jpg", _jpeg()) for i in range(1, 4)]
    result = ocr.run_ocr(images)
    assert calls == {"page_1.jpg": 2, "page_2.jpg": 1, "page_3.jpg": 1}
    assert [p.name for p in result.pages] == ["page_1.jpg", "page_2.jpg"]
    assert result.errors and "page_3.jpg" in result.errors[0]


def test_동시_호출_수는_1에서_4_사이(monkeypatch):
    for raw, want in [("", ocr.OCR_CONCURRENCY_DEFAULT), ("1", 1), ("9", 4), ("0", 1), ("x", ocr.OCR_CONCURRENCY_DEFAULT)]:
        monkeypatch.setenv("OCR_CONCURRENCY", raw)
        assert ocr.ocr_concurrency() == want
    assert extraction  # import 확인
