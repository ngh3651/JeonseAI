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

from ..dependencies import DEV_MODE_AUTH
from ..schemas.internal import RegistryExtract
from ..schemas.registry_schema import build_response_format
from . import artifacts

_log = logging.getLogger("jeonseai")

UPSTAGE_URL = "https://api.upstage.ai/v1/information-extraction"
MODEL = "information-extract"
REQUEST_TIMEOUT_SECONDS = 300  # test_extract.py에서 검증한 상한 (IE는 수십 초 걸릴 수 있음)

_BACKEND_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = _BACKEND_ROOT / "out"

# [개발 모드 전용] IE 추출 결과를 `out/runs/<회차>/ie.json` 으로 남긴다.
#
# 왜 필요한가 (2026-07-27):
# 리포트 근거 카드("유효 채권최고액 등 합계 27억 8,000만원 · 근저당 4건")와 뷰어
# 하이라이트(근저당 3건 · 14억원)가 어긋났을 때, **IE가 각 항목의 `is_canceled`를
# 무엇으로 줬는지 확인할 방법이 전혀 없었다.** OCR 쪽은 `SAVE_OCR_RAW` 덕분에
# out/ocr_page_*.json 으로 크레딧 0원 재현이 됐지만, IE 쪽은 다시 호출해야만
# — 즉 크레딧을 또 태워야만 — 알 수 있었다. 같은 질문이 반복될 것이므로 대칭으로 남긴다.
#
# `ocr.py`의 `SAVE_OCR_RAW`와 같은 방식으로 `DEV_MODE_AUTH`에 묶는다 —
# 운영 전환(=False) 시 함께 꺼져 **운영 경로에서는 저장하지 않는다**(스위치 하나로 보장).
# ⚠ out/ 에는 등기부 소유자 실명·주소가 담긴다 → .gitignore 대상, 절대 커밋 금지.
SAVE_IE_RAW = DEV_MODE_AUTH

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


# ── 요약본 거부 (decisions.md 2026-07-07) ────────────────────────────────────
# '주요 등기사항 요약(참고용)'에는 말소 이력이 없어 유효/말소 구분이 불가능하다.
# 그대로 분석하면 '깨끗한 집'으로 오판(미탐)할 수 있으므로 분석을 중단한다.
_SUMMARY_KEYWORDS = ("주요 등기사항 요약", "참고용")
SUMMARY_REJECT_DETAIL = (
    "요약본은 판단에 부족해요. '말소사항 포함 등기사항전부증명서'로 다시 올려주세요"
)


def reject_summary_document(raw: dict) -> None:
    """요약본 문서가 감지되면 ExtractionError(400)를 던진다.

    document_title 필드가 1차 신호이지만, 제목 추출이 실패할 수 있어
    추출 JSON 전체 문자열에서 키워드를 이중 검사한다(한계는 decisions.md 기록).
    """
    haystack = json.dumps(raw, ensure_ascii=False)
    if any(keyword in haystack for keyword in _SUMMARY_KEYWORDS):
        raise ExtractionError(400, SUMMARY_REJECT_DETAIL)


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


def call_information_extract(
    images: list[tuple[str, bytes]], *, run_id: str | None = None
) -> dict:
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
    if SAVE_IE_RAW:  # 개발 모드에서만 (요약본 거부보다 **앞**에 둔다 — 거부된 문서도 봐야 한다)
        _save_raw_ie(run_id, raw)
    reject_summary_document(raw)  # 요약본이면 여기서 분석 중단 (400)
    return raw


def _save_raw_ie(run_id: str | None, raw: dict) -> None:
    """[개발 모드 전용] IE 추출 결과를 `out/runs/<회차>/ie.json` 으로 남긴다.

    남기는 것은 **모델이 실제로 돌려준 스키마 형태의 추출 결과**(`choices[0].message.content`)다.
    HTTP 봉투(usage 등)는 판정과 무관해 버린다. 이 파일 하나면
    `is_canceled`·`rank_number`·`amount`가 항목마다 무엇이었는지 크레딧 0원으로 다시 볼 수 있다.

    2026-07-28: 회차 폴더로 옮겨 **같은 분석의 OCR 응답과 나란히** 남게 했다.
    예전에는 IE만 타임스탬프 이름이고 OCR은 사진 이름이라, 어느 IE 응답이 어느 OCR 응답과
    같은 분석인지 파일만 보고는 알 수 없었다(실제로 그 때문에 조사가 한참 헤맸다).
    보관 상한도 `artifacts.py`가 회차 단위로 건다.

    저장 실패는 삼킨다 — 진단 산출물이 분석을 깨뜨려선 안 된다(ocr.py `_save_raw_ocr`과 동일).
    ⚠ 등기부 실명·주소 포함 → 커밋 금지(.gitignore).
    """
    path = artifacts.save_json(run_id, "ie.json", raw)
    if path is not None:
        _log.info(f"[Upstage] IE 원응답 저장(개발 모드): out/runs/{path.parent.name}/{path.name}")


def extract_registry(
    images: list[tuple[str, bytes]], *, run_id: str | None = None
) -> RegistryExtract:
    """이미지들 → 정형화된 등기부 추출 결과 (누락 플래그 포함)."""
    return RegistryExtract.from_raw(call_information_extract(images, run_id=run_id))
