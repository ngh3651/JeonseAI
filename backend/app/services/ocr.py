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
import json
import logging
import mimetypes
import time
from dataclasses import dataclass, field
from pathlib import Path

import requests
from PIL import Image

from ..dependencies import DEV_MODE_AUTH
from . import artifacts
from .extraction import _USER_FACING_STATUS, ExtractionError, _load_api_key
from .ocr_layout import OcrPage, group_lines, parse_words

_log = logging.getLogger("jeonseai")

OCR_URL = "https://api.upstage.ai/v1/document-digitization"
OCR_MODEL = "ocr"
REQUEST_TIMEOUT_SECONDS = 120  # IE(300초)보다 짧게 — 장당 1.6~3.1초가 실측치라 넉넉하다

_BACKEND_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = _BACKEND_ROOT / "out"

# [개발 모드 전용] OCR 원응답(JSON)을 `out/runs/<회차>/ocr_<파일stem>.json` 으로 남긴다.
# 목적: 레이아웃 임계값(_GAP_RATIO=1.8 / _RANK_BAND_MARGIN=0.15 / _NAME_GAP_RATIO=2.5,
#   ocr_layout.py)은 밤 샘플 1건 실측값이다. 다른 해상도·다른 등기부에서 그 값이 버티는지
#   **크레딧을 더 쓰지 않고** 다시 재려면 실호출 응답을 파일로 남겨 두어야 한다.
#   파일명 규칙은 scripts/test_ocr_coords.py 와 동일하므로, 그 스크립트에
#   `--from-json out/runs/<회차>` 를 주면 API 호출 0회로 재분석이 된다.
# 이 저장소의 '개발 모드' 단일 스위치인 dependencies.DEV_MODE_AUTH 에 묶는다 —
#   운영 전환(=False) 시 함께 꺼져 **운영 경로에서는 저장하지 않는다**(스위치 하나로 보장).
#   실제 보관·삭제는 `artifacts.py`가 담당한다(최근 N회분만 유지).
# ⚠ out/ 에는 등기부 소유자 실명이 담긴다 → .gitignore 대상, 절대 커밋 금지.
SAVE_OCR_RAW = DEV_MODE_AUTH


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


def _image_size(data: bytes, filename: str = "") -> tuple[int, int]:
    """원본 픽셀 크기를 **Pillow로 직접** 읽는다.

    OCR 응답의 페이지 크기를 믿지 않는다 — 정규화 기준이 실제 이미지와 1px이라도
    어긋나면 앱에서 좌표가 통째로 밀린다. 전송한 바이트에서 직접 재는 것이 유일한 진실이다.

    ⚠ EXIF 방향 태그가 남아 있으면 위험하다. Pillow는 **저장된 그대로**의 크기를 주는데
      Flutter 디코더는 EXIF 회전을 **적용해서** 그린다 → 한쪽만 돌아가 좌표가 통째로
      어긋난다. 앱이 `keepExif: false`로 태그를 지워 보내므로 정상이면 안 걸리지만,
      다른 경로로 들어온 사진을 잡기 위해 경고를 남긴다.
    """
    with Image.open(io.BytesIO(data)) as im:
        try:
            orientation = (im.getexif() or {}).get(274)  # 274 = EXIF Orientation
        except Exception:  # noqa: BLE001 — EXIF 파싱 실패는 무시하고 진행
            orientation = None
        if orientation not in (None, 0, 1):
            _log.info(
                f"[OCR] ⚠ {filename} 에 EXIF 회전 태그({orientation})가 남아 있습니다 —"
                " 앱 표시 크기와 서버 측정 크기가 달라져 좌표가 어긋날 수 있습니다"
            )
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


def _save_raw_ocr(run_id: str | None, filename: str, index: int, raw: dict) -> None:
    """[개발 모드 전용] OCR 원응답을 `out/runs/<회차>/ocr_<stem>.json` 으로 남긴다.

    2026-07-28: 저장 위치를 **회차 폴더**로 옮겼다. 예전에는 `out/ocr_<stem>.json` 이라
    앱이 늘 `page_N.jpg`로 보내는 탓에 **분석할 때마다 이전 회차가 덮어써졌다**
    (실측 사고: 22:44 분석분이 23:06 분석분에 덮여, 나중에 조사할 때 '5장 중 1장이
    다른 사진'인 이상한 묶음이 만들어졌다). 보관 상한도 여기서 함께 걸린다.

    저장 실패는 삼킨다 — 진단 산출물이 분석을 깨뜨려선 안 된다(이 모듈의 대원칙).
    ⚠ 등기부 실명 포함 → 커밋 금지(.gitignore).
    """
    stem = Path(filename).stem or f"page_{index}"
    path = artifacts.save_json(run_id, f"ocr_{stem}.json", raw)
    if path is not None:
        _log.info(f"[OCR] 원응답 저장(개발 모드): out/runs/{path.parent.name}/{path.name}")


def run_ocr(images: list[tuple[str, bytes]], *, run_id: str | None = None) -> OcrResult:
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

        if SAVE_OCR_RAW:  # 개발 모드에서만 원응답을 남긴다 (운영 경로에서는 저장 안 함)
            _save_raw_ocr(run_id, filename, i, raw)

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
