"""진단용 원응답 보관 — **절차가 아니라 코드가 지운다**는 것을 못 박는다.

`backend/out/`에는 등기부 소유자 **실명·주소**가 담긴 원응답이 쌓인다.
지금까지의 방어는 `.gitignore`와 "시연 전에 비운다"는 절차뿐이었고, 절차는 잊힌다.
이 파일이 지키는 두 가지:

1. **운영 모드에서는 애초에 저장하지 않는다** (`DEV_MODE_AUTH` 하나에 묶여 있다)
2. 저장하더라도 **최근 N회분만** 남는다
"""

from __future__ import annotations

import json

import pytest

from app.services import artifacts


@pytest.fixture
def sandbox(tmp_path, monkeypatch):
    """`out/`을 임시 폴더로 갈아끼운다 — 진짜 out/을 건드리지 않는다."""
    monkeypatch.setattr(artifacts, "OUT_DIR", tmp_path)
    monkeypatch.setattr(artifacts, "RUNS_DIR", tmp_path / "runs")
    monkeypatch.setattr(artifacts, "SAVE_RAW", True)
    return tmp_path


# ══════════════════════════════════════════════════════════════════════════════
# 운영 모드에서는 저장 자체가 없다
# ══════════════════════════════════════════════════════════════════════════════


def test_개발_모드가_꺼지면_저장하지_않는다(tmp_path, monkeypatch):
    """운영 전환 시 스위치 **하나**로 저장이 멈춰야 한다.

    스위치가 여럿이면 "어디선가 아직 저장하고 있었다"가 반드시 생긴다.
    """
    monkeypatch.setattr(artifacts, "OUT_DIR", tmp_path)
    monkeypatch.setattr(artifacts, "RUNS_DIR", tmp_path / "runs")
    monkeypatch.setattr(artifacts, "SAVE_RAW", False)

    assert artifacts.run_dir("20260728_000000_000") is None
    assert artifacts.save_json("20260728_000000_000", "ie.json", {"a": 1}) is None
    assert not (tmp_path / "runs").exists()


def test_저장_스위치는_DEV_MODE_AUTH를_그대로_따른다():
    """`SAVE_RAW`가 다른 값에서 파생되면 운영 전환 때 한쪽만 남는다."""
    from app.dependencies import DEV_MODE_AUTH

    assert artifacts.SAVE_RAW is DEV_MODE_AUTH
    # 원응답을 남기는 두 모듈도 같은 스위치를 봐야 한다
    from app.services import extraction, ocr

    assert ocr.SAVE_OCR_RAW is DEV_MODE_AUTH
    assert extraction.SAVE_IE_RAW is DEV_MODE_AUTH


# ══════════════════════════════════════════════════════════════════════════════
# 보관 상한
# ══════════════════════════════════════════════════════════════════════════════


def test_회차별로_폴더가_나뉜다(sandbox):
    """예전에는 앱이 항상 `page_N.jpg`로 보내는 탓에 원응답이 **덮어써졌다**.

    실제로 22:44 분석분이 23:06 분석분에 덮여, 나중에 조사할 때 '5장 중 1장이 다른 사진'인
    이상한 묶음이 만들어졌다(night-log 2026-07-28). 회차 폴더면 덮어쓰기가 일어나지 않는다.
    """
    artifacts.save_json("run_a", "ocr_page_1.json", {"who": "a"})
    artifacts.save_json("run_b", "ocr_page_1.json", {"who": "b"})
    a = json.loads((sandbox / "runs" / "run_a" / "ocr_page_1.json").read_text(encoding="utf-8"))
    b = json.loads((sandbox / "runs" / "run_b" / "ocr_page_1.json").read_text(encoding="utf-8"))
    assert a["who"] == "a" and b["who"] == "b"


def test_같은_회차의_IE와_OCR이_한_폴더에_모인다(sandbox):
    """어느 IE 응답이 어느 OCR 응답과 짝인지 **파일만 보고** 알 수 있어야 한다."""
    artifacts.save_json("run_a", "ie.json", {"k": 1})
    artifacts.save_json("run_a", "ocr_page_1.json", {"k": 2})
    names = sorted(p.name for p in (sandbox / "runs" / "run_a").iterdir())
    assert names == ["ie.json", "ocr_page_1.json"]


def test_최근_N회분만_남기고_지운다(sandbox):
    for i in range(9):
        artifacts.save_json(f"2026072{i}_000000_000", "ie.json", {"i": i})
    removed = artifacts.prune_runs(keep=5)
    left = sorted(p.name for p in (sandbox / "runs").iterdir())
    assert len(left) == 5
    assert len(removed) == 4
    # 이름이 타임스탬프라 이름 정렬 = 시간 정렬. 오래된 쪽이 지워져야 한다.
    assert left[0] == "20260724_000000_000"
    assert "20260720_000000_000" in removed


def test_상한이_기본값이면_5회분이다(sandbox):
    """앱의 `RegistryPhotoStore`(최근 5건)와 같은 값이어야 설명이 어긋나지 않는다."""
    assert artifacts.MAX_KEPT_RUNS == 5
    for i in range(7):
        artifacts.save_json(f"2026072{i}_000000_000", "ie.json", {"i": i})
    artifacts.prune_runs()
    assert len(list((sandbox / "runs").iterdir())) == 5


def test_옛_위치의_IE_파일도_정리한다(sandbox):
    """회차 폴더 도입 전에 `out/` 바닥에 쌓인 파일이 그대로 남으면 상한이 무의미하다."""
    for i in range(8):
        (sandbox / f"ie_2026072{i}_000000_000.json").write_text("{}", encoding="utf-8")
    removed = artifacts.prune_legacy_flat_files(keep=3)
    left = sorted(p.name for p in sandbox.glob("ie_*.json"))
    assert len(left) == 3 and len(removed) == 5


def test_지울_것이_없으면_아무_일도_없다(sandbox):
    artifacts.save_json("run_a", "ie.json", {})
    assert artifacts.prune_runs(keep=5) == []
    assert artifacts.prune_legacy_flat_files(keep=5) == []


def test_저장_실패는_삼킨다(sandbox, monkeypatch):
    """진단 산출물이 분석을 깨뜨려선 안 된다 — 이 모듈의 대원칙."""

    def boom(*a, **k):
        raise OSError("disk full")

    monkeypatch.setattr("pathlib.Path.write_text", boom)
    assert artifacts.save_json("run_a", "ie.json", {"k": 1}) is None  # 예외가 새지 않는다


def test_가장_최근_회차를_찾을_수_있다(sandbox):
    for name in ("20260726_000000_000", "20260728_000000_000", "20260727_000000_000"):
        artifacts.save_json(name, "ie.json", {})
    assert artifacts.latest_run().name == "20260728_000000_000"


def test_회차가_없으면_None이다(sandbox):
    assert artifacts.latest_run() is None
