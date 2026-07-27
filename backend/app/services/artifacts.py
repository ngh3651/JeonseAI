"""진단용 원응답 저장 — **보관 상한을 절차가 아니라 코드로 박는다.**

왜 이 파일이 생겼나 (2026-07-28):
`backend/out/`에는 등기부 소유자 **실명·주소**가 담긴 IE·OCR 원응답이 분석할 때마다 쌓인다.
지금까지의 방어는 `.gitignore`(= 커밋 금지)와 **"시연 전에 비운다"는 절차**뿐이었다.
절차는 잊힌다. 무제한 키로 실험을 늘릴수록 이 폴더는 빠르게 커지고, 그 안에 남는 것은
전부 남의 개인정보다. 앱이 사진을 최근 5건만 들고 있는 것(`RegistryPhotoStore`)과
**같은 규율을 서버에도 적용한다.**

무엇이 보장되나:
1. **운영 모드에서는 애초에 저장하지 않는다** — `DEV_MODE_AUTH` 하나에 묶여 있다.
2. 저장하더라도 **최근 `MAX_KEPT_RUNS`회분만** 남고 오래된 회차는 자동으로 지워진다.
3. 분석 1회 = 폴더 1개다. 회차 단위로 지우므로 "IE는 남았는데 OCR만 지워진" 상태가 없다.

부수 효과 — 예전 구조의 버그도 함께 사라진다:
앱은 사진을 항상 `page_N.jpg`로 보내므로 `out/ocr_page_N.json`이 **분석할 때마다
덮어써졌다.** 실제로 22:44 분석분이 23:06 분석분에 덮여, 나중에 원인을 조사할 때
"5장 중 1장이 다른 사진"인 이상한 묶음이 만들어졌다(night-log 2026-07-28 참고).
회차 폴더로 나누면 덮어쓰기 자체가 일어나지 않는다.
"""

from __future__ import annotations

import json
import logging
import shutil
import time
from pathlib import Path

from ..dependencies import DEV_MODE_AUTH

_log = logging.getLogger("jeonseai")

_BACKEND_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = _BACKEND_ROOT / "out"
RUNS_DIR = OUT_DIR / "runs"

#: 남길 분석 회차 수. 앱의 `RegistryPhotoStore`(최근 5건)와 같은 값으로 맞춘다 —
#: 두 곳의 보관 정책이 다르면 "앱에는 있는데 서버에는 없는" 상태를 설명하기 어렵다.
MAX_KEPT_RUNS = 5

#: 운영 전환(`DEV_MODE_AUTH=False`) 시 **저장 자체가 일어나지 않는다.**
#: 스위치가 하나여야 "어디선가 아직 저장하고 있었다"가 생기지 않는다.
SAVE_RAW = DEV_MODE_AUTH


def new_run_id() -> str:
    """분석 1회를 가리키는 폴더 이름. 밀리초까지 붙여 같은 초의 충돌을 원천 차단한다."""
    return time.strftime("%Y%m%d_%H%M%S") + f"_{int(time.time() * 1000) % 1000:03d}"


def run_dir(run_id: str | None) -> Path | None:
    """저장할 회차 폴더. 저장이 꺼져 있으면 **None**(호출부는 조용히 건너뛴다)."""
    if not SAVE_RAW:
        return None
    path = RUNS_DIR / (run_id or "adhoc")
    try:
        path.mkdir(parents=True, exist_ok=True)
    except OSError as e:  # 저장 실패는 분석을 막지 못한다
        _log.info(f"[진단저장] 폴더 생성 실패 — 무시하고 계속 ({type(e).__name__})")
        return None
    return path


def save_json(run_id: str | None, filename: str, payload: dict) -> Path | None:
    """원응답 1건 저장. **실패는 전부 삼킨다** — 진단 산출물이 분석을 깨뜨려선 안 된다.

    ⚠ 등기부 실명·주소 포함 → `out/`은 `.gitignore` 대상, 절대 커밋 금지.
    """
    target = run_dir(run_id)
    if target is None:
        return None
    try:
        path = target / filename
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        return path
    except (OSError, TypeError, ValueError) as e:
        _log.info(f"[진단저장] {filename} 저장 실패 — 무시하고 계속 ({type(e).__name__})")
        return None


def prune_runs(keep: int = MAX_KEPT_RUNS) -> list[str]:
    """오래된 회차 폴더를 지운다. 지운 폴더 이름 목록을 돌려준다.

    이름이 타임스탬프라 **이름 정렬 = 시간 정렬**이다(파일시스템 mtime을 믿지 않는다 —
    복사·동기화로 쉽게 흐트러진다).
    """
    if not RUNS_DIR.is_dir():
        return []
    runs = sorted((p for p in RUNS_DIR.iterdir() if p.is_dir()), key=lambda p: p.name)
    doomed = runs[:-keep] if keep > 0 else runs
    removed: list[str] = []
    for path in doomed:
        try:
            shutil.rmtree(path)
            removed.append(path.name)
        except OSError as e:
            _log.info(f"[진단저장] 오래된 회차 삭제 실패 {path.name} ({type(e).__name__})")
    if removed:
        _log.info(
            f"[진단저장] 오래된 분석 원응답 {len(removed)}회분 삭제 (최근 {keep}회분만 보관)"
            " — 등기부 실명이 담긴 파일입니다"
        )
    return removed


def prune_legacy_flat_files(keep: int = MAX_KEPT_RUNS) -> list[str]:
    """회차 폴더 도입 **이전**에 `out/` 바닥에 쌓인 `ie_*.json`을 정리한다.

    이 함수는 과거 파일을 위한 것이다. 새 저장 경로는 전부 회차 폴더로 간다.
    """
    if not OUT_DIR.is_dir():
        return []
    files = sorted(OUT_DIR.glob("ie_*.json"), key=lambda p: p.name)
    removed: list[str] = []
    for path in files[:-keep] if keep > 0 else files:
        try:
            path.unlink()
            removed.append(path.name)
        except OSError:
            pass
    if removed:
        _log.info(f"[진단저장] 옛 위치의 IE 원응답 {len(removed)}건 삭제 (최근 {keep}건만 보관)")
    return removed


def latest_run() -> Path | None:
    """가장 최근 회차 폴더 — 비교 하네스·재현 스크립트가 입력을 찾을 때 쓴다."""
    if not RUNS_DIR.is_dir():
        return None
    runs = sorted((p for p in RUNS_DIR.iterdir() if p.is_dir()), key=lambda p: p.name)
    return runs[-1] if runs else None
