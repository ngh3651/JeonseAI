"""Upstage Document OCR 호출 서비스 — **하이라이트 좌표 전용**.

왜 IE 말고 이걸 또 부르나:
Information Extract는 필드를 구조화해주지만 **좌표를 주지 않는다**. "채권최고액 3,600만원"이
사진의 어디에 있는지 알 수 없어 표시할 수 없다. Document OCR은 단어 단위 좌표를 준다.

⚠ 이 서비스는 **판정에 개입하지 않는다.** 위험 등급·점수·근거 카드는 전부 IE + 규칙 엔진
  경로 그대로다. OCR 결과는 "사진 위 어디에 표시할지"만 정한다.
⚠ **OCR 실패는 분석을 실패시키지 않는다.** 좌표 없이 리포트가 지금과 똑같이 완성돼야 한다
  (`run_ocr`는 예외를 밖으로 던지지 않는다).

호출·키 로딩·에러 처리·로깅은 `extraction.py`의 패턴을 그대로 따른다. 다만 전송 방식이
다르다 — IE는 JSON + base64 data URL, OCR은 **multipart/form-data**다.

⚠ 이미지를 병합하지 않는다. 장별 원본을 개별 호출해야 좌표가 원본 사진과 1:1로 맞는다
  (PDF로 합치면 좌표계가 합본 기준이 되어 앱이 그릴 수 없다).
"""

from __future__ import annotations

import io
import logging
import mimetypes
import time
from dataclasses import dataclass, field

import requests
from PIL import Image

from .extraction import _USER_FACING_STATUS, ExtractionError, _load_api_key
from .ocr_layout import OcrPage, group_lines, parse_words

_log = logging.getLogger("jeonseai")

OCR_URL = "https://api.upstage.ai/v1/document-digitization"
OCR_MODEL = "ocr"
REQUEST_TIMEOUT_SECONDS = 120  # IE(300초)보다 짧게 — 장당 1.6~3.1초가 실측치라 넉넉하다


class OcrError(ExtractionError):
    """OCR 호출 실패 — extraction.py의 에러 계약을 그대로 따른다."""


@dataclass
class OcrResult:
    """OCR 호출 결과 묶음. 실패해도 이 객체는 항상 만들어진다(pages가 빌 뿐)."""

    pages: list[OcrPage] = field(default_factory=list)
    elapsed: float = 0.0
    errors: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return bool(self.pages)


def _image_size(data: bytes) -> tuple[int, int]:
    """원본 픽셀 크기를 **Pillow로 직접** 읽는다.

    OCR 응답의 페이지 크기를 믿지 않는다 — 정규화 기준이 실제 이미지와 1px이라도
    어긋나면 앱에서 좌표가 통째로 밀린다. 전송한 바이트에서 직접 재는 것이 유일한 진실이다.
    """
    with Image.open(io.BytesIO(data)) as im:
        return im.width, im.height


def call_document_ocr(api_key: str, filename: str, data: bytes) -> dict:
    """이미지 1장 → OCR 원본 JSON (multipart 전송)."""
    mime = mimetypes.guess_type(filename)[0] or "image/jpeg"
    try:
        resp = requests.post(
            OCR_URL,
            headers={"Authorization": f"Bearer {api_key}"},
            data={"model": OCR_MODEL},
            files={"document": (filename, io.BytesIO(data), mime)},
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
    except requests.exceptions.Timeout as e:
        raise OcrError(504, "사진 위치 인식이 너무 오래 걸렸어요") from e
    except requests.exceptions.RequestException as e:
        raise OcrError(502, "사진 위치 인식 서버에 연결하지 못했어요") from e

    if resp.status_code != 200:
        detail = _USER_FACING_STATUS.get(resp.status_code, "사진 위치 인식에 실패했어요")
        raise OcrError(resp.status_code, detail)
    try:
        return resp.json()
    except ValueError as e:
        raise OcrError(502, "사진 위치 인식 결과를 해석하지 못했어요") from e


def run_ocr(images: list[tuple[str, bytes]]) -> OcrResult:
    """사진들 → 장별 OCR → OcrPage 목록. **예외를 밖으로 던지지 않는다.**

    한 장이 실패해도 나머지 장은 살린다 — 3장 중 1장만 실패하면 나머지 2장에는
    형광펜을 칠할 수 있다. 전부 실패하면 pages가 빈 채로 돌아가고, 리포트는
    좌표 없이 지금과 똑같이 완성된다.

    장별 호출은 **순차**로 한다. 실측 장당 1.6~3.1초이고 IE가 30초 이상 걸리므로,
    OCR을 더 병렬화해도 전체 시간이 줄지 않는다. 대신 동시 요청을 늘리면 429(요청 제한)
    위험만 커진다.
    """
    result = OcrResult()
    if not images:
        return result

    t0 = time.perf_counter()
    try:
        api_key = _load_api_key()
    except ExtractionError as e:
        _log.info(f"[OCR] 건너뜀 — {e.detail}")
        result.errors.append(e.detail)
        return result

    total = len(images)
    _log.info(f"[OCR] 호출 시작 — 사진 {total}장, 장별 개별 호출 (⚠ 크레딧 소모)")
    for i, (filename, data) in enumerate(images):
        t1 = time.perf_counter()
        try:
            raw = call_document_ocr(api_key, filename, data)
        except ExtractionError as e:
            _log.info(f"[OCR] {i + 1}/{total} {filename} → 실패 HTTP {e.status_code} — {e.detail}")
            result.errors.append(f"{filename}: {e.detail}")
            continue
        except Exception as e:  # noqa: BLE001 — OCR은 어떤 이유로도 분석을 막지 못한다
            _log.info(f"[OCR] {i + 1}/{total} {filename} → 예기치 못한 실패 {type(e).__name__}: {e}")
            result.errors.append(f"{filename}: {type(e).__name__}")
            continue

        words = parse_words(raw)
        try:
            width, height = _image_size(data)
        except Exception as e:  # noqa: BLE001 — 크기를 못 읽으면 정규화가 불가능하다
            _log.info(f"[OCR] {i + 1}/{total} {filename} → 이미지 크기를 읽지 못함 ({type(e).__name__})")
            result.errors.append(f"{filename}: 이미지 크기 확인 실패")
            continue

        _log.info(
            f"[OCR] {i + 1}/{total} {filename} → HTTP 200 ({time.perf_counter() - t1:.1f}초)"
            f" 단어 {len(words)}개, 원본 {width}x{height}px"
        )
        result.pages.append(
            OcrPage(
                name=filename,
                index=i,
                words=words,
                lines=group_lines(words),
                width=width,
                height=height,
            )
        )

    result.elapsed = time.perf_counter() - t0
    return result
