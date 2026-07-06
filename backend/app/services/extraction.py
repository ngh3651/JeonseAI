"""Upstage Information Extract 호출 서비스 — scripts/test_extract.py의 승격판 (E-1c).

흐름: 이미지 바이트들 → (1장 원본 / 여러 장 img2pdf 병합 PDF) → base64 data URL
     → Information Extract 1회 호출 → 응답 파싱 → RegistryExtract 정형화.

- 에러는 `ExtractionError(status_code, 한국어 detail)`로 올린다 — 라우터가 그대로
  HTTPException으로 변환한다(계약 §1.3 에러 형식).
- 금액 해석 실패를 여기서 0으로 메꾸지 않는다 — `RegistryExtract.from_raw`가
  None + '미상' 플래그로 규칙 엔진까지 전달한다(0 치환 금지, decisions.md 2026-07-06).
- Upstage 사양(엔드포인트·모델·멀티페이지 PDF 병합)은 decisions.md 2026-07-01 검증값.
"""

from __future__ import annotations

import base64
import json
import logging
import mimetypes
import os
import time
from pathlib import Path

import img2pdf
import requests
from dotenv import load_dotenv

from ..schemas.internal import RegistryExtract
from ..schemas.registry_schema import build_response_format

_log = logging.getLogger("jeonseai")

UPSTAGE_URL = "https://api.upstage.ai/v1/information-extraction"
MODEL = "information-extract"
REQUEST_TIMEOUT_SECONDS = 300  # test_extract.py에서 검증한 상한 (IE는 수십 초 걸릴 수 있음)

_BACKEND_ROOT = Path(__file__).resolve().parents[2]

# 사용자에게 보여줄 상태코드별 한국어 안내 (test_extract.py 안내문 이식).
# 401/403(우리 키 문제)은 앱의 인증 의미(계약 §1.3)와 겹치지 않게 502로 감싼다.
_USER_FACING_STATUS = {
    400: "문서를 처리하지 못했어요. 등기부 사진(JPEG/PNG)인지 확인해 주세요",
    402: "분석 크레딧이 소진됐어요. 관리자에게 문의해 주세요 (Upstage Console > Dashboard에서 잔여 크레딧 확인)",
    413: "사진 용량이 너무 커요. 장수를 줄이거나 더 작은 사진으로 다시 시도해 주세요",
    415: "지원하지 않는 파일 형식이에요. JPEG/PNG 사진으로 다시 시도해 주세요",
    429: "요청이 몰려 잠시 제한됐어요. 잠시 후 다시 시도해 주세요",
}


class ExtractionError(Exception):
    """추출 실패 — 상태코드 + 사용자용 한국어 메시지."""

    def __init__(self, status_code: int, detail: str):
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


def _load_api_key() -> str:
    """backend/.env의 UPSTAGE_API_KEY를 읽는다 (하드코딩 금지 — api-design 규칙)."""
    load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")
    key = os.environ.get("UPSTAGE_API_KEY", "").strip()
    if not key:
        raise ExtractionError(500, "서버에 분석 API 키가 설정되지 않았어요 (backend/.env)")
    return key


def _build_document(images: list[tuple[str, bytes]]) -> tuple[bytes, str]:
    """이미지들을 전송용 문서 하나로 만든다 — 1장은 원본, 여러 장은 멀티페이지 PDF."""
    if len(images) == 1:
        filename, data = images[0]
        mime = mimetypes.guess_type(filename)[0] or "image/jpeg"  # 앱은 항상 JPEG 전송
        return data, mime
    try:
        pdf_bytes = img2pdf.convert([data for _, data in images])
    except Exception as e:  # noqa: BLE001 — 병합 실패 원인을 사용자 문구로 감싼다
        raise ExtractionError(
            400, "사진들을 하나의 문서로 합치지 못했어요. 각 사진이 정상 이미지인지 확인해 주세요"
        ) from e
    return pdf_bytes, "application/pdf"


def call_information_extract(images: list[tuple[str, bytes]]) -> dict:
    """(파일명, 바이트) 목록 → Upstage IE 호출 → 추출 원본(raw) JSON."""
    if not images:
        raise ExtractionError(400, "등기부 사진을 1장 이상 올려 주세요")

    api_key = _load_api_key()
    doc_bytes, mime = _build_document(images)
    data_url = f"data:{mime};base64,{base64.b64encode(doc_bytes).decode('ascii')}"

    payload = {
        "model": MODEL,
        "messages": [
            {"role": "user", "content": [{"type": "image_url", "image_url": {"url": data_url}}]}
        ],
        "response_format": build_response_format(),
    }
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}

    _log.info(
        f"[Upstage] Information Extract 호출 — 사진 {len(images)}장, 전송 {len(doc_bytes) / 1024:.0f}KB (⚠ 크레딧 소모)"
    )
    t0 = time.perf_counter()
    try:
        resp = requests.post(
            UPSTAGE_URL, headers=headers, json=payload, timeout=REQUEST_TIMEOUT_SECONDS
        )
    except requests.exceptions.Timeout as e:
        _log.info(f"[Upstage] 시간 초과 ({time.perf_counter() - t0:.1f}초)")
        raise ExtractionError(504, "분석 서버 응답이 너무 늦어요. 잠시 후 다시 시도해 주세요") from e
    except requests.exceptions.RequestException as e:
        _log.info("[Upstage] 연결 실패")
        raise ExtractionError(502, "분석 서버에 연결하지 못했어요. 잠시 후 다시 시도해 주세요") from e
    _log.info(f"[Upstage] 응답 HTTP {resp.status_code} ({time.perf_counter() - t0:.1f}초)")

    if resp.status_code != 200:
        detail = _USER_FACING_STATUS.get(
            resp.status_code, "분석 서버에 문제가 생겼어요. 잠시 후 다시 시도해 주세요"
        )
        status = resp.status_code if resp.status_code in _USER_FACING_STATUS else 502
        raise ExtractionError(status, detail)

    try:
        content = resp.json()["choices"][0]["message"]["content"]
        raw = content if isinstance(content, dict) else json.loads(content)
    except (KeyError, IndexError, TypeError, ValueError) as e:
        raise ExtractionError(502, "추출 결과를 해석하지 못했어요. 다시 시도해 주세요") from e
    if not isinstance(raw, dict):
        raise ExtractionError(502, "추출 결과를 해석하지 못했어요. 다시 시도해 주세요")
    return raw


def extract_registry(images: list[tuple[str, bytes]]) -> RegistryExtract:
    """이미지들 → 정형화된 등기부 추출 결과 (누락 플래그 포함)."""
    return RegistryExtract.from_raw(call_information_extract(images))
