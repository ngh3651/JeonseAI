"""촬영 품질 검사 — 사진이 **읽을 수 있게 찍혔는가** (2026-10-22, P1-1).

왜 있나: 같은 사진을 여러 번 넣으면 IE 결과는 거의 같다(7/28 실측). 결과가 매번 다른 원인은
**사진이 매번 달라서**(흔들림·어두움·잘림)다. 그런데 서버는 사진 품질을 전혀 보지 않고 IE·OCR을
불렀다 — 흔들린 사진에 크레딧을 쓰고, 틀릴 수 있는 결과를 내놓았다.

두 번 본다:
1. **IE·OCR을 부르기 전** (`precheck`) — 사진 바이트만 본다(Pillow + numpy, AI 아님).
   흐림 · 너무 어두움 · 빛 번짐(글자가 하얗게 날아감) · 글자 없음 · 해상도 부족.
   **심한 문제가 하나라도 있으면 분석하지 않고 거절**한다(크레딧 0원 — 라우터가 400으로 돌려준다).
2. **OCR 뒤** (`add_ocr_findings`) — 맨 아래 쪽 번호(`1/5`)가 안 보이면 **잘림 의심**, 글자를 하나도
   못 읽었으면 **글자 없음**. 분석은 이미 끝났으므로 거절하지 않고 알리기만 한다.

⚠ **판정과 무관하다.** 여기 수치는 위험 등급의 임계값이 아니라 **사진 품질 기준**이다.
  등급·근거 카드·하이라이트를 하나도 바꾸지 않는다. 수치의 근거(합성 등기부를 일부러 흐리게·어둡게
  만든 사본으로 잰 값)는 `docs/decisions.md` [2026-10-22] 촬영 품질 검사에 있다.
⚠ 종이 촬영본으로는 아직 검증하지 않았다. 현장에서 멀쩡한 사진이 거절되면 서버 변수
  `CAPTURE_CHECK=warn`(거절하지 않고 알리기만) 또는 `off`(검사 끔)로 바로 바꿀 수 있다.
⚠ 알려진 한계: 흐림 지표(blur effect)는 초점 나감·부드러운 흔들림은 잘 잡지만, **한 방향으로 곧게
  끌린 흔들림**(글자가 두 겹으로 겹쳐 보이는 것)은 덜 잡는다 — 겹친 글자도 테두리는 날카롭기 때문이다.
"""

from __future__ import annotations

import io
import logging
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass

import numpy as np
from PIL import Image, ImageFilter

from .. import settings
from ..schemas.contract import CaptureCheck, CapturePageIssue
from .ocr_layout import _page_footer_facts

_log = logging.getLogger("jeonseai")

# ══════════════════════════════════════════════════════════════════════════════
# 기준값 — 사진 품질 기준 (위험 임계값 아님). 근거: decisions.md [2026-10-22] 촬영 품질 검사
# ══════════════════════════════════════════════════════════════════════════════

#: 재는 크기 — 긴 변을 이만큼으로 줄여서 잰다. 앱이 보내는 촬영본(약 1920×2560)에서 등기부 본문 글자가
#: 20px 안팎이 되는 크기다. 크기를 맞춰야 같은 흐림이 같은 값으로 나온다.
ANALYSIS_LONG_SIDE = 1600

#: 흐림 — blur effect(0~1, 클수록 흐림). 선명한 합성 등기부 0.09~0.13.
#: 글자 높이의 9%만큼 번지면 0.50 안팎(읽히지만 무르다), 13%면 0.67~0.69(읽기 어렵다).
BLUR_MILD = 0.45
BLUR_SEVERE = 0.65

#: 종이 밝기 = 사진 밝기의 95번째 백분위(0~255). 흰 종이를 정상 노출로 찍으면 170~255.
PAPER_DARK_MILD = 100
PAPER_DARK_SEVERE = 60

#: 글자와 종이의 밝기 차 = 종이 밝기 − 가장 어두운 0.1% (0~255). 선명한 합성 등기부 170~220.
#: 0.1%로 잡는 이유: 마지막 쪽처럼 글자가 몇 줄뿐인 쪽도 글자 픽셀이 0.1%는 넘는다(한 줄 ≈ 0.2%).
CONTRAST_LOW_MILD = 40
CONTRAST_SEVERE = 15
_INK_PERCENTILE = 0.1
#: 이 밝기 이상이면 대비 부족의 원인을 '빛 번짐'으로 본다(종이가 하얗게 날아감).
PAPER_GLARE = 235
#: 사진 전체가 거의 한 색이다 — 글자가 아예 없다(벽·천장·빈 종이·렌즈 가림).
CONTRAST_BLANK = 4

#: **다크 모드 화면 캡처**(검은 바탕에 흰 글자 — 폰을 다크 모드로 두고 등기부 화면을 캡처)는 밝기를 뒤집어 잰다.
#: 그대로 재면 검은 바탕이 '종이'로 잡혀 '너무 어두움', 글자가 적은 쪽은 '글자 없음'으로 **멀쩡한 캡처를 거절**한다
#: (2026-10-22 PR 검토 실측: 글자 여섯 줄 쪽 대비 0 → 거절). 가려내는 법 — 가운데 밝기(중앙값)가 어둡고(< 100),
#: 가장 밝은 끝(글자)까지는 멀고(≥ 100) 가장 어두운 끝까지보다 3배 넘게 멀다.
#: 정상 노출 종이(가운데 150~250)와 어두운 데서 찍은 종이(글자가 종이보다 **어두워** 밝은 끝이 가깝다)는 해당 없다.
#: 흐림 값은 뒤집어도 같다(밝기 차의 크기만 본다).
DARK_MODE_SPAN = 100
_DARK_MODE_TAIL_RATIO = 3

#: 부분 빛 번짐 — 글자 영역 안에서 **하얗게 타 버린**(평균 248 이상) 32px 칸의 비율. 일부만 날아간 것이라
#: **알리기만** 한다(거절 안 함). 종이가 원래 회색 기운일 때(글자 영역 안 빈칸의 가운데 밝기 < 235 —
#: 카메라 사진)만 잰다. 화면 캡처나 이미 하얗게 찍힌 종이(250)는 하얀 칸이 반사가 아니라 종이다.
GLARE_SPOT_RATIO = 0.03
_GLARE_TILE_MEAN = 248
_CAMERA_PAPER_MAX = 235

#: 사진의 짧은 변(px). 등기부 한 쪽이 폭에 꽉 차면 본문 글자 높이 ≈ 짧은 변 × 0.02.
#: 700px → 약 14px, 400px → 약 8px(OCR이 읽기 어려운 크기).
SHORT_SIDE_MILD = 700
SHORT_SIDE_SEVERE = 400

#: 글자가 있는 칸으로 볼 32px 타일의 표준편차(대비를 0~1로 늘인 뒤). 흐림은 이 타일들에서만 잰다 —
#: 빈 여백·책상의 잡티가 값을 흔들지 않게.
_TILE = 32
_TILE_STD_CONTENT = 0.08
_BLUR_FILTER = 11  # blur effect 원 논문(Crété-Roffet 외, 2007)과 scikit-image 기본값

# ── 문제 종류 → 화면 말 ────────────────────────────────────────────────────────
# (거절 문장 틀 — {page}에 'N쪽', 이유, 다시 찍는 법). 앱은 `tip`(이유 + 다시 찍는 법)을 그대로 보여 준다.
_TEXT: dict[str, tuple[str, str, str]] = {
    "no_text": (
        "{page}에서 글자를 찾지 못했어요",
        "사진에서 글자를 찾지 못했어요",
        "등기부 종이가 화면에 꽉 차게 나오도록 다시 찍어 주세요.",
    ),
    "too_dark": (
        "{page}이 너무 어두워요",
        "종이가 회색으로 보일 만큼 어두워요",
        "불을 켜거나 밝은 곳에서, 휴대폰 그림자가 종이에 지지 않게 찍어 주세요.",
    ),
    "too_bright": (
        "{page}이 빛에 번졌어요",
        "빛이 반사돼 글자가 하얗게 날아갔어요",
        "조명이 종이에 비치지 않게 각도를 조금 바꿔 찍어 주세요. 플래시는 꺼 주세요.",
    ),
    "blurry": (
        "{page}이 흐려요",
        "글자 테두리가 번져 있어요",
        "휴대폰을 종이와 나란히 들고, 화면의 글자를 한 번 눌러 초점을 맞춘 뒤 움직이지 말고 찍어 주세요.",
    ),
    "low_contrast": (
        "{page} 글자가 흐릿해요",
        "글자와 종이의 색 차이가 너무 적어요",
        "밝은 곳에서 종이를 평평하게 펴고 다시 찍어 주세요.",
    ),
    "low_resolution": (
        "{page} 사진이 너무 작아요",
        "글자가 너무 작게 찍혔어요",
        "등기부 한 쪽이 화면에 꽉 차게 가까이 찍어 주세요.",
    ),
    "amount_unread": (
        "{page} 빚 금액을 못 읽었어요",
        "빚 금액(채권최고액) 칸의 글자를 읽지 못했어요",
        "그 쪽이 화면에 꽉 차게, 글자가 또렷하게 나오도록 다시 찍어 주세요.",
    ),
    "cut_off": (
        "{page} 아래쪽이 잘렸을 수 있어요",
        "맨 아래 쪽 번호(예: 1/5)가 보이지 않아요",
        "종이 네 모서리와 맨 아래 줄(쪽 번호)이 모두 나오게 찍어 주세요.",
    ),
}

#: 한 장에 문제가 여럿이면 이 순서로 하나를 대표로 말한다(가장 먼저 고칠 것).
_PRIORITY = (
    "no_text", "too_dark", "too_bright", "blurry", "low_contrast", "low_resolution", "amount_unread", "cut_off",
)


# ══════════════════════════════════════════════════════════════════════════════
# 재기
# ══════════════════════════════════════════════════════════════════════════════


@dataclass(frozen=True)
class PageMetrics:
    """사진 한 장의 측정값 — 로그·보정용. 글자 내용은 담지 않는다."""

    width: int  # 원본 픽셀
    height: int
    blur: float  # 0~1, 클수록 흐림 (글자 칸이 없으면 0)
    paper: float  # 0~255
    contrast: float  # 0~255
    content_ratio: float  # 글자가 있는 타일 비율 0~1
    glare_ratio: float = 0.0  # 하얗게 타 버린 칸의 비율 0~1 (카메라 사진일 때만 잰다)
    inverted: bool = False  # 다크 모드 화면(어두운 바탕·밝은 글자)이라 밝기를 뒤집어 쟀다


def _load_gray(data: bytes) -> tuple[np.ndarray, int, int] | None:
    """바이트 → (재는 크기의 회색 배열, 원본 폭, 원본 높이). 사진으로 못 읽으면 None."""
    try:
        with Image.open(io.BytesIO(data)) as im:
            width, height = im.size
            if width <= 0 or height <= 0:
                return None
            # JPEG는 줄여 읽기(draft)로 큰 사진을 빠르게 연다 — 요청한 크기보다 작아지지는 않는다.
            im.draft("L", (ANALYSIS_LONG_SIDE, ANALYSIS_LONG_SIDE))
            gray = im.convert("L")
            scale = ANALYSIS_LONG_SIDE / max(gray.size)
            if scale < 1:
                gray = gray.resize(
                    (max(1, round(gray.width * scale)), max(1, round(gray.height * scale))),
                    Image.Resampling.BILINEAR,
                )
            # 3×3 중앙값 — 어두운 데서 찍은 사진의 **자글자글한 잡티(센서 노이즈)**를 걷어낸다.
            # 안 걷으면 잡티의 날카로운 점들이 '선명함'으로 잡혀, 흐리고 어두운 사진이 선명하게 나온다
            # (보정 실측: 노이즈 σ7·흐림 σ3.9에서 0.41 → 0.57). 선명한 사진 값은 거의 그대로다(0.11 → 0.13).
            gray = gray.filter(ImageFilter.MedianFilter(3))
            return np.asarray(gray, dtype=np.float32), width, height
    except Exception:  # noqa: BLE001 — 못 읽는 사진은 검사하지 않는다(뒤 단계가 원래대로 처리한다)
        return None


def _uniform(a: np.ndarray, size: int, axis: int) -> np.ndarray:
    """1차원 평균 필터(가장자리는 거울 반사) — numpy 누적합으로 O(N)."""
    pad = size // 2
    widths = [(0, 0)] * a.ndim
    widths[axis] = (pad, size - 1 - pad)
    padded = np.pad(a, widths, mode="reflect")
    csum = np.cumsum(padded, axis=axis, dtype=np.float64)
    zero = np.zeros_like(np.take(csum, [0], axis=axis))
    csum = np.concatenate([zero, csum], axis=axis)
    n = a.shape[axis]
    hi = np.take(csum, np.arange(size, size + n), axis=axis)
    lo = np.take(csum, np.arange(0, n), axis=axis)
    return ((hi - lo) / size).astype(np.float32)


def _tile_sums(values: np.ndarray, rows: int, cols: int) -> np.ndarray:
    """(rows·T, cols·T) 배열 → 타일별 합 (rows, cols)."""
    return values[: rows * _TILE, : cols * _TILE].reshape(rows, _TILE, cols, _TILE).sum(axis=(1, 3))


def _glare_ratio(g: np.ndarray, content: np.ndarray, rows: int, cols: int) -> float:
    """글자 영역(글자 칸들을 감싸는 사각형) 안에서 하얗게 탄 칸의 비율. 종이가 원래 하야면 0."""
    ys, xs = np.nonzero(content)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    tile_mean = g[: rows * _TILE, : cols * _TILE].reshape(rows, _TILE, cols, _TILE).mean(axis=(1, 3))
    area = tile_mean[y0:y1, x0:x1]
    blank = area[~content[y0:y1, x0:x1]]
    if blank.size == 0 or float(np.median(blank)) >= _CAMERA_PAPER_MAX:
        return 0.0  # 화면 캡처·하얗게 찍힌 종이 — 하얀 칸은 반사가 아니라 종이다
    return float((area >= _GLARE_TILE_MEAN).mean())


def _light_text_on_dark(g: np.ndarray) -> bool:
    """어두운 바탕에 밝은 글자인가 — 다크 모드 화면 캡처 (`DARK_MODE_SPAN` 설명)."""
    darkest, middle, brightest = (
        float(v) for v in np.percentile(g, [_INK_PERCENTILE, 50, 100 - _INK_PERCENTILE])
    )
    bright_tail = brightest - middle
    return (
        middle < PAPER_DARK_MILD
        and bright_tail >= DARK_MODE_SPAN
        and bright_tail > _DARK_MODE_TAIL_RATIO * (middle - darkest)
    )


def measure(data: bytes) -> PageMetrics | None:
    """사진 한 장을 잰다. 사진으로 읽히지 않으면 None (검사하지 않고 넘어간다)."""
    loaded = _load_gray(data)
    if loaded is None:
        return None
    g, width, height = loaded
    inverted = _light_text_on_dark(g)
    if inverted:
        g = 255.0 - g  # 다크 모드 화면 — 뒤집으면 흰 바탕에 검은 글자와 같다
    ink, paper, top = (float(v) for v in np.percentile(g, [_INK_PERCENTILE, 95, 99.5]))
    contrast = paper - ink

    rows, cols = g.shape[0] // _TILE, g.shape[1] // _TILE
    if rows == 0 or cols == 0:
        return PageMetrics(width, height, 0.0, paper, contrast, 0.0, inverted=inverted)

    # 글자가 있는 타일 고르기 — 대비를 0~1로 늘인 뒤 표준편차로 본다(어두운 사진에서도 같은 기준).
    norm = np.clip((g - ink) / max(top - ink, 1.0), 0.0, 1.0)
    crop = norm[: rows * _TILE, : cols * _TILE].reshape(rows, _TILE, cols, _TILE)
    content = crop.std(axis=(1, 3)) > _TILE_STD_CONTENT
    content_ratio = float(content.mean())
    if not content.any():
        return PageMetrics(width, height, 0.0, paper, contrast, content_ratio, inverted=inverted)
    glare_ratio = _glare_ratio(g, content, rows, cols)

    # 흐림 — blur effect (Crété-Roffet 외, 2007): 한 번 더 흐리게 했을 때 글자 테두리의 밝기 변화가
    # 얼마나 **안** 줄어드는가. 이미 흐린 사진은 더 흐려져도 변화가 적다(→ 1에 가깝다).
    # 가로·세로 중 더 흐린 쪽을 쓴다(흔들림은 한 방향으로 생긴다).
    blurs = []
    for axis in (0, 1):
        smooth = _uniform(g, _BLUR_FILTER, axis)
        d_img = np.abs(np.diff(g, axis=axis))
        lost = np.maximum(0.0, d_img - np.abs(np.diff(smooth, axis=axis)))
        # diff로 한 칸 줄었으니 원래 크기로 맞춘다(끝 줄은 0) — 그래야 타일 마스크를 씌울 수 있다
        pad = [(0, 1), (0, 0)] if axis == 0 else [(0, 0), (0, 1)]
        s_img = float(_tile_sums(np.pad(d_img, pad), rows, cols)[content].sum())
        s_lost = float(_tile_sums(np.pad(lost, pad), rows, cols)[content].sum())
        blurs.append((s_img - s_lost) / s_img if s_img > 0 else 1.0)
    return PageMetrics(width, height, max(blurs), paper, contrast, content_ratio, glare_ratio, inverted)


# ══════════════════════════════════════════════════════════════════════════════
# 판단
# ══════════════════════════════════════════════════════════════════════════════


def assess(m: PageMetrics) -> tuple[list[str], bool]:
    """측정값 → (문제 목록, 심한가). 심하면 그 장은 분석하지 않는다(거절)."""
    if m.contrast < CONTRAST_BLANK:
        return ["no_text"], True  # 한 색 사진 — 나머지는 잴 것도 없다

    issues: list[str] = []
    severe = False
    if m.paper < PAPER_DARK_MILD:
        issues.append("too_dark")
        severe |= m.paper < PAPER_DARK_SEVERE
    elif m.contrast < CONTRAST_LOW_MILD:
        issues.append("too_bright" if m.paper >= PAPER_GLARE else "low_contrast")
        severe |= m.contrast < CONTRAST_SEVERE
    elif m.glare_ratio >= GLARE_SPOT_RATIO:
        issues.append("too_bright")  # 일부만 하얗게 날아갔다 — 알리기만 한다

    if m.content_ratio > 0 and m.blur >= BLUR_MILD:
        issues.append("blurry")
        severe |= m.blur >= BLUR_SEVERE

    short = min(m.width, m.height)
    if short < SHORT_SIDE_MILD:
        issues.append("low_resolution")
        severe |= short < SHORT_SIDE_SEVERE
    return issues, severe


def _lead(issues: list[str]) -> str:
    known = [i for i in issues if i in _TEXT]
    return min(known, key=_PRIORITY.index) if known else "blurry"


def tip_for(issues: list[str]) -> str:
    """장 하나의 안내 — 이유 + 다시 찍는 법 (대표 문제 하나만)."""
    _, why, how = _TEXT[_lead(issues)]
    return f"{why}. {how}"


def mode() -> str:
    """`CAPTURE_CHECK` — `on`(기본: 심하면 거절) · `warn`(거절하지 않고 알리기만) · `off`(검사 안 함)."""
    value = settings.env_str("CAPTURE_CHECK", "on").lower()
    return value if value in {"on", "warn", "off"} else "on"


def precheck(images: list[tuple[str, bytes]]) -> CaptureCheck | None:
    """IE·OCR **전** 검사. 꺼져 있으면 None. 예외를 밖으로 던지지 않는다(검사 실패 = 검사 없이 진행).

    장당 0.15~0.4초(1080~4000px, 실측) — 분석 20~30초에 비하면 작지만, 여러 장은 나란히 잰다
    (Pillow·numpy가 계산 중에는 GIL을 놓아 스레드로도 빨라진다).
    """
    if mode() == "off":
        return None
    pages: list[CapturePageIssue] = []
    t0 = time.perf_counter()
    try:
        with ThreadPoolExecutor(max_workers=min(4, max(1, len(images))), thread_name_prefix="capture") as pool:
            measured = list(pool.map(measure, [data for _, data in images]))
        for index, m in enumerate(measured):
            if m is None:
                _log.info(f"[촬영검사] {index + 1}쪽 — 사진으로 읽지 못해 검사 건너뜀")
                continue
            issues, severe = assess(m)
            _log.info(
                f"[촬영검사] {index + 1}쪽 {m.width}x{m.height} 흐림 {m.blur:.2f} · 종이 {m.paper:.0f}"
                f" · 대비 {m.contrast:.0f} · 글자칸 {m.content_ratio:.0%}"
                f"{' · 다크 모드(뒤집어 잼)' if m.inverted else ''}"
                f" → {', '.join(issues) if issues else '문제 없음'}{' (심함)' if severe else ''}"
            )
            if issues:
                pages.append(CapturePageIssue(index=index, issues=issues, severe=severe, tip=tip_for(issues)))
    except Exception:  # noqa: BLE001 — 검사가 분석을 막으면 안 된다
        _log.error("[촬영검사] ⚠ 검사 중 예외 — 검사 없이 진행합니다", exc_info=True)
        return None
    _log.info(f"[촬영검사] 사진 {len(images)}장 검사 {time.perf_counter() - t0:.2f}초 — 문제 {len(pages)}장")
    return CaptureCheck(ok=not pages, pages=pages)


def should_reject(check: CaptureCheck | None) -> bool:
    """심한 장이 있고, 거절 모드(`on`)인가."""
    return check is not None and mode() == "on" and any(p.severe for p in check.pages)


def rejection_message(check: CaptureCheck) -> str:
    """거절 문구 — `2쪽이 흐려요 — 다시 찍어 주세요 (글자 테두리가 번져 있어요)`.

    여러 장이면 장마다 한 마디씩(최대 3장) 잇는다. 장마다의 자세한 안내는 `captureCheck`에 있다.
    """
    severe = [p for p in check.pages if p.severe]
    if not severe:
        return "사진을 다시 찍어 주세요"
    leads = [_lead(p.issues) for p in severe]
    if len(set(leads)) == 1:
        pages = "·".join(f"{p.index + 1}" for p in severe[:3]) + "쪽" + (" 등" if len(severe) > 3 else "")
        head, why, _ = _TEXT[leads[0]]
        return f"{head.format(page=pages)} — 다시 찍어 주세요 ({why})"
    parts = [_TEXT[lead][0].format(page=f"{p.index + 1}쪽") for p, lead in zip(severe[:3], leads)]
    more = f" 외 {len(severe) - 3}장" if len(severe) > 3 else ""
    return f"{' · '.join(parts)}{more} — 그 장만 다시 찍어 주세요"


def add_ocr_findings(check: CaptureCheck | None, ocr_pages: list, image_count: int) -> CaptureCheck | None:
    """OCR 뒤 — 쪽 번호가 안 보이는 장(잘림 의심)과 글자를 못 읽은 장을 더한다. 분석은 이미 끝났다(거절 없음).

    `ocr_pages`에는 OCR이 **성공한** 장만 있다 — OCR 호출 자체가 실패한 장은 사진 탓이 아닐 수 있어 말하지 않는다.
    """
    if check is None:
        return None
    by_index = {p.index: p.model_copy(deep=True) for p in check.pages}
    for page in ocr_pages:
        if not 0 <= page.index < image_count:
            continue
        found: list[str] = []
        if not page.words:
            found.append("no_text")
        else:
            marker, _, _, _ = _page_footer_facts(page)
            if marker is None:
                found.append("cut_off")
        if not found:
            continue
        entry = by_index.setdefault(page.index, CapturePageIssue(index=page.index))
        for issue in found:
            if issue not in entry.issues:
                entry.issues.append(issue)
        entry.tip = tip_for(entry.issues)
    pages = sorted(by_index.values(), key=lambda p: p.index)
    if pages != check.pages:
        _log.info(
            "[촬영검사] OCR 뒤: "
            + ", ".join(f"{p.index + 1}쪽 {'/'.join(p.issues)}" for p in pages)
        )
    return CaptureCheck(ok=not pages, pages=pages)


def add_unread_amount_pages(
    check: CaptureCheck | None, upload_indexes: list[int], image_count: int
) -> CaptureCheck:
    """빚 금액을 끝내 못 읽은 쪽 → '다시 찍기' 대상(`amount_unread`)으로 더한다 (2026-10-29 QA).

    촬영 검사가 꺼져 있어도(check=None) 만든다 — 이 안내는 사진 품질 검사가 아니라 **판정 재료가 빈** 경우라서.
    """
    by_index = {p.index: p.model_copy(deep=True) for p in (check.pages if check else [])}
    for i in upload_indexes:
        if not 0 <= i < image_count:
            continue
        entry = by_index.setdefault(i, CapturePageIssue(index=i))
        if "amount_unread" not in entry.issues:
            entry.issues.append("amount_unread")
        entry.tip = tip_for(entry.issues)
    pages = sorted(by_index.values(), key=lambda p: p.index)
    if pages:
        _log.info("[촬영검사] 빚 금액 못 읽음: " + ", ".join(f"{i + 1}번째 사진" for i in upload_indexes))
    return CaptureCheck(ok=not pages, pages=pages)
