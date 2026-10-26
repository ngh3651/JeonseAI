"""사진 방향 바로 세우기 — 가로로·거꾸로 찍은 등기부를 **글자가 바로 선 방향**으로 (2026-10-26 규혁 요청).

왜: 사진이 옆으로 누웠거나 뒤집히면 ① OCR이 글자를 잘 못 읽어 형광펜이 안 붙고,
② '내 등기부등본 보기'에서 글자가 누운 채로 보여 대조하기 어렵다.

어떻게 (AI 판단 없음 — OCR 결과의 **모양**만 본다):
1. 먼저 받은 사진 그대로 OCR한다(지금과 같다 — 바로 찍은 사진은 추가 호출 0회).
2. 그 결과가 '바로 선 등기부'처럼 보이면 끝. 기준(셋 다):
   - 등기부 표지 낱말(표제부·갑구·순위번호 …)이 2개 이상 읽혔다
   - 세 글자 이상 낱말 상자가 대부분 **가로로 길다**(누운 글자는 상자가 세로로 길다)
   - 낱말의 읽는 방향(OCR 꼭짓점 순서)이 대부분 **왼→오**다(뒤집힌 글자는 오→왼)
3. 아니면 90°·180°·270°로 돌린 사진을 차례로 OCR해, **처음으로 기준을 넘는 방향**을 쓴다.
   어느 방향도 넘지 못하면 원래 사진 그대로 둔다(지금과 같다 — 더 나빠지지 않는다).

돌린 경우: OCR 좌표는 **돌린 사진 기준**이 되고, 리포트의 `pageRotations`에 '시계 방향으로 몇 도 돌렸는지'를
적는다. 앱은 폰에 남긴 원본 사진을 그만큼 돌려 그리므로 형광펜 좌표가 그대로 맞는다.

⚠ 판정 규칙이 아니다 — 표시·읽기 재료의 방향만 고친다. 크레딧: 바로 찍은 사진 0회 추가,
  방향이 틀린 사진만 장당 최대 3회 추가(분석 1회당 상한 [MAX_EXTRA_CALLS]).
"""

from __future__ import annotations

import io
import os
from dataclasses import dataclass

import numpy as np
from PIL import Image

from .document_gate import MIN_MARKERS, REGISTRY_MARKERS

#: 분석 1회에 방향을 찾느라 더 부르는 OCR 횟수 상한 — 등기부가 아닌 사진이 섞여도 비용이 새지 않게
MAX_EXTRA_CALLS = 6

#: '대부분'의 기준 — 세 글자 이상 낱말 중 이 비율 이상이 가로로 길고, 왼→오로 읽혀야 바로 선 것
UPRIGHT_RATIO = 0.6

#: 가로·읽는 방향을 셀 만큼 낱말이 있어야 판단한다(그보다 적으면 표지 낱말만 본다)
MIN_SHAPE_WORDS = 8


def enabled() -> bool:
    """`AUTO_ROTATE=off`면 끈다(지금까지처럼 받은 그대로만 읽는다)."""
    return (os.environ.get("AUTO_ROTATE", "") or "on").strip().lower() not in ("off", "0", "false")


def rotate_jpeg(data: bytes, degrees_cw: int) -> bytes:
    """사진을 시계 방향으로 90·180·270도 돌린 JPEG. 0이면 그대로.

    `transpose`는 픽셀을 그대로 옮긴다(보간 없음) — 크기는 90·270도면 가로세로가 바뀐다.
    """
    turn = degrees_cw % 360
    if turn == 0:
        return data
    method = {
        90: Image.Transpose.ROTATE_270,  # PIL의 ROTATE_n은 반시계 방향
        180: Image.Transpose.ROTATE_180,
        270: Image.Transpose.ROTATE_90,
    }[turn]
    with Image.open(io.BytesIO(data)) as im:
        rotated = im.convert("RGB").transpose(method)
        out = io.BytesIO()
        rotated.save(out, format="JPEG", quality=92)
        return out.getvalue()


@dataclass
class Reading:
    """OCR 결과의 모양 — 방향이 맞았는지 가늠하는 숫자들."""

    markers: int  # 등기부 표지 낱말 수
    shape_words: int  # 가로·방향을 센 낱말 수(세 글자 이상)
    horizontal: float  # 그중 가로로 긴 비율
    left_to_right: float  # 그중 왼→오로 읽힌 비율(꼭짓점 순서)

    @property
    def upright(self) -> bool:
        if self.markers < MIN_MARKERS:
            return False
        if self.shape_words < MIN_SHAPE_WORDS:
            return True  # 낱말이 적으면 표지 낱말만으로 판단
        return self.horizontal >= UPRIGHT_RATIO and self.left_to_right >= UPRIGHT_RATIO


def read_shape(raw: dict) -> Reading:
    """OCR 원응답 → [Reading]. `pages[].words[]`·최상위 `words[]` 둘 다 받는다."""
    containers = raw.get("pages") or []
    if not containers and raw.get("words"):
        containers = [raw]
    texts: list[str] = []
    counted = horizontal = ltr = 0
    for page in containers:
        for w in page.get("words") or []:
            text = str(w.get("text", "") or "")
            texts.append(text)
            verts = (w.get("boundingBox") or {}).get("vertices") or []
            if len("".join(text.split())) < 3 or len(verts) < 4:
                continue
            xs = [float(v.get("x", 0)) for v in verts]
            ys = [float(v.get("y", 0)) for v in verts]
            counted += 1
            if max(xs) - min(xs) > max(ys) - min(ys):
                horizontal += 1
            # 꼭짓점은 읽는 순서(왼위 → 오위 → …)로 온다 — 첫 변이 왼→오면 바로 선 글자
            dx = xs[1] - xs[0]
            dy = ys[1] - ys[0]
            if dx > abs(dy):
                ltr += 1
    joined = "".join("".join(texts).split())
    markers = sum(1 for m in REGISTRY_MARKERS if m in joined)
    return Reading(
        markers=markers,
        shape_words=counted,
        horizontal=horizontal / counted if counted else 0.0,
        left_to_right=ltr / counted if counted else 0.0,
    )


def candidate_turns(data: bytes) -> list[int]:
    """돌려 볼 순서 — 누운 사진이면 90·270을 먼저, 아니면 180을 먼저(맞히면 호출이 준다).

    글줄이 가로면 행(row)마다 잉크 양이 크게 오르내리고, 누우면 열(column)이 그렇다.
    순서만 정할 뿐이라 틀려도 결과는 같다(호출 수만 는다).
    """
    try:
        with Image.open(io.BytesIO(data)) as im:
            g = im.convert("L")
            g.thumbnail((600, 600))
            a = np.asarray(g, dtype=np.float32)
        ink = a < (a.mean() - a.std() * 0.5)
        rows = ink.mean(axis=1)
        cols = ink.mean(axis=0)
        sideways = float(np.std(np.diff(cols))) > float(np.std(np.diff(rows))) * 1.15
    except Exception:  # noqa: BLE001 — 순서 힌트일 뿐이다
        sideways = False
    return [90, 270, 180] if sideways else [180, 90, 270]
