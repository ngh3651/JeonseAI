"""Upstage **Document Parse** — 표 구조를 제품에게 맡기는 대체 레이아웃 경로.

⚠ **좌표는 여기서 오지 않는다.** DP의 `coordinates`는 **요소 단위, 그것도 표 하나당
  사각형 하나**다(실측: 표 bbox가 페이지의 20~61%). 낱말 좌표(`words`)는 아예 없다.
  이름 하이라이트는 낱말 하나를 43px로 감싸야 하므로 DP 좌표로는 불가능하고,
  권리자 칸을 통째로 칠하면 **등록번호까지 형광펜에 들어간다.**
  → 좌표는 앞으로도 전적으로 `ocr_layout.py`(Document OCR)에서 온다.
  자세한 실측은 `docs/document-parse-probe-2026-07-28.md`.

그럼 DP는 무엇에 쓰나: **LLM 구조화 경로(경로 ③)의 입력 텍스트**다.
표 재조립을 우리가 손으로 하지 않아도 되므로 그 텍스트가 훨씬 깨끗하다.

실측으로 확인된 DP의 강점 (2026-07-28):
- 등기목적 칸의 **두 줄 접힘이 한 셀에** 담긴다 (`1번근저당권설정등 기말소`).
  공백만 지우면 복원된다 — `ocr_layout`의 컬럼 밴드 알고리즘이 통째로 불필요해진다.
- **순위번호 칸이 깨끗하다.** 지분 분수(`2분의`/`1`)가 섞이지 않는다.
- 구역 머리(`【 갑 구 】`)가 표 첫 칸에, 꼬리말이 `footer` 카테고리로 온다.

약점(그래서 전면 교체가 아니다):
- 낱말 좌표 없음(위 참고) · 면적 단위 `㎡` 소실 · 장당 3.6~4.2초로 OCR보다 느림
- **페이지를 걸쳐 이어지는 항목**은 여전히 우리가 이어야 한다(DP는 쪽 단위 파싱).
"""

from __future__ import annotations

import io
import logging
import mimetypes
import re
import time
from dataclasses import dataclass, field

import requests

from . import artifacts
from .extraction import _USER_FACING_STATUS, ExtractionError, _load_api_key

_log = logging.getLogger("jeonseai")

DP_URL = "https://api.upstage.ai/v1/document-digitization"
DP_MODEL = "document-parse"
REQUEST_TIMEOUT_SECONDS = 120  # 실측 장당 3.6~4.2초 — 넉넉한 상한

# 사용자 눈에 보일 일이 없는 구조 텍스트라 그대로 쓴다.
_TAG = re.compile(r"<[^>]+>")
_WS = re.compile(r"[ \t]+")


class DocumentParseError(ExtractionError):
    """DP 호출 실패 — extraction.py의 에러 계약을 그대로 따른다."""


@dataclass
class ParsedPage:
    """DP가 본 한 쪽. 좌표는 담지 않는다 — 쓰지 않기 때문이다."""

    index: int
    name: str
    elements: list[dict] = field(default_factory=list)

    @property
    def categories(self) -> list[str]:
        return [e.get("category", "?") for e in self.elements]


@dataclass
class ParseResult:
    pages: list[ParsedPage] = field(default_factory=list)
    elapsed: float = 0.0
    errors: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return bool(self.pages)


def call_document_parse(api_key: str, filename: str, data: bytes) -> dict:
    """이미지 1장 → DP 원응답 (multipart)."""
    mime = mimetypes.guess_type(filename)[0] or "image/jpeg"
    try:
        resp = requests.post(
            DP_URL,
            headers={"Authorization": f"Bearer {api_key}"},
            data={
                "model": DP_MODEL,
                "ocr": "force",  # 사진이라 내장 텍스트가 없다
                "coordinates": "false",  # 안 쓴다 — 응답만 커진다
                "output_formats": '["html", "text"]',
                "base64_encoding": "[]",
            },
            files={"document": (filename, io.BytesIO(data), mime)},
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
    except requests.exceptions.Timeout as e:
        raise DocumentParseError(504, "문서 구조 인식이 너무 오래 걸렸어요") from e
    except requests.exceptions.RequestException as e:
        raise DocumentParseError(502, "문서 구조 인식 서버에 연결하지 못했어요") from e

    if resp.status_code != 200:
        detail = _USER_FACING_STATUS.get(resp.status_code, "문서 구조 인식에 실패했어요")
        raise DocumentParseError(resp.status_code, detail)
    try:
        return resp.json()
    except ValueError as e:
        raise DocumentParseError(502, "문서 구조 인식 결과를 해석하지 못했어요") from e


def run_document_parse(
    images: list[tuple[str, bytes]], *, run_id: str | None = None
) -> ParseResult:
    """사진들 → 장별 DP. **예외를 밖으로 던지지 않는다** (OCR과 같은 계약).

    한 장이 실패해도 나머지는 살린다. 전부 실패하면 pages가 빈 채로 돌아가고,
    호출부는 `ocr_layout` 텍스트로 조용히 되돌아간다.
    """
    result = ParseResult()
    if not images:
        return result

    t0 = time.perf_counter()
    try:
        api_key = _load_api_key()
    except ExtractionError as e:
        _log.info(f"[DP] 건너뜀 — {e.detail}")
        result.errors.append(e.detail)
        return result

    total = len(images)
    _log.info(f"[DP] 호출 시작 — 사진 {total}장 (⚠ 크레딧 소모)")
    for i, (filename, data) in enumerate(images):
        t1 = time.perf_counter()
        try:
            raw = call_document_parse(api_key, filename, data)
        except ExtractionError as e:
            _log.info(f"[DP] {i + 1}/{total} {filename} → 실패 HTTP {e.status_code}")
            result.errors.append(f"{filename}: {e.detail}")
            continue
        except Exception as e:  # noqa: BLE001 — DP는 어떤 이유로도 분석을 막지 못한다
            _log.info(f"[DP] {i + 1}/{total} {filename} → 예기치 못한 실패 {type(e).__name__}")
            result.errors.append(f"{filename}: {type(e).__name__}")
            continue

        artifacts.save_json(run_id, f"dp_{filename.rsplit('.', 1)[0]}.json", raw)
        elements = raw.get("elements") or []
        _log.info(
            f"[DP] {i + 1}/{total} {filename} → HTTP 200 ({time.perf_counter() - t1:.1f}초)"
            f" 요소 {len(elements)}개"
            f" (표 {sum(1 for e in elements if e.get('category') == 'table')}개)"
        )
        result.pages.append(ParsedPage(index=i, name=filename, elements=elements))

    result.elapsed = time.perf_counter() - t0
    return result


# ══════════════════════════════════════════════════════════════════════════════
# LLM에 넘길 텍스트 만들기
# ══════════════════════════════════════════════════════════════════════════════


# 접힘 복원을 적용할 셀 길이 상한 (레이아웃 휴리스틱 — 판정 임계값 아님).
#
# 왜 길이로 가르나: 셀 안 줄바꿈(접힘)은 **좁은 칸**에서만 일어난다. 등기부에서 좁은 칸은
# 순위번호·등기목적이고, 그 칸의 값은 원래 띄어쓰기가 없는 한 덩어리다
# (`근저당권설정`, `1번근저당권설정등기말소`, `소유권이전`).
# 반대로 `권리자 및 기타사항` 칸은 산문이라 띄어쓰기가 의미를 갖는다
# (`채권최고액 금36,000,000원 채무자 …`). 여기까지 붙이면 오히려 읽기 나빠진다.
# 실측 등기목적 셀은 최대 12자, 권리자 셀은 40자 이상이라 30자로 가르면 깨끗하게 나뉜다.
_FOLD_JOIN_MAX_CHARS = 30


def _cell_text(cell_html: str) -> str:
    """셀 HTML → 텍스트. **좁은 칸의 접힘 공백만** 지운다 — 이게 DP를 쓰는 이유다.

    `1번근저당권설정등 기말소` → `1번근저당권설정등기말소`
    줄이 접힌 자리에 공백 하나가 남을 뿐이라, 지우면 원래 문구가 정확히 복원된다.
    (`ocr_layout`은 같은 일을 하려고 컬럼 x밴드 계산 알고리즘을 통째로 들고 있다.)

    ⚠ 긴 산문 칸에는 손대지 않는다 — `_FOLD_JOIN_MAX_CHARS` 주석 참고.
      **이건 휴리스틱이다.** 등기목적이 30자를 넘는 등기부를 만나면 접힘이 남는데,
      그때도 손해는 "LLM이 공백 하나를 더 본다"뿐이다(판정과 무관한 계층).
    """
    text = _TAG.sub(" ", cell_html or "")
    text = _WS.sub(" ", text).replace("\n", " ").strip()
    if len(text) <= _FOLD_JOIN_MAX_CHARS:
        # 한글 + 공백 + 한글 → 붙인다 (셀 안 줄바꿈 흔적). 숫자·기호 주변은 남긴다.
        text = re.sub(r"(?<=[가-힣])\s+(?=[가-힣])", "", text)
    return text


def render_parsed_text(pages: list[ParsedPage]) -> str:
    """DP 결과 → LLM 프롬프트용 텍스트.

    표는 `칸 | 칸 | 칸` 로, 그 외 요소는 `[category] 내용` 으로 적는다.
    `ocr_layout.render_layout_text`와 **같은 모양**이라 프롬프트를 바꾸지 않아도 된다.

    ⚠ 우리가 내린 해석(말소 여부·항목 묶음)은 넣지 않는다 — 넣으면 LLM이 베끼게 되어
      '독립된 두 번째 경로'라는 성질이 사라진다.
    """
    out: list[str] = []
    for page in sorted(pages, key=lambda p: p.index):
        out.append(f"### {page.index + 1}쪽")
        for element in page.elements:
            category = element.get("category", "?")
            content = element.get("content") or {}
            if category == "table":
                html = content.get("html") or ""
                for row in re.findall(r"<tr[^>]*>(.*?)</tr>", html, re.S):
                    cells = [
                        _cell_text(c)
                        for c in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", row, re.S)
                    ]
                    if any(cells):
                        out.append(" | ".join(cells))
            else:
                text = _cell_text(content.get("text") or content.get("html") or "")
                if text:
                    out.append(f"[{category}] {text}")
    return "\n".join(out)
