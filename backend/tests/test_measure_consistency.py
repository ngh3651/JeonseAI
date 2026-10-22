"""일관성 측정 도구 (`scripts/measure_consistency.py`) — **키 없이** `--dry-run`으로만 돈다 (P1-1, 2026-10-22).

실제 측정은 종이 등기부를 여러 번 찍은 묶음 + Upstage 키가 필요하다(NOW.md 할 일). 여기서는
⑴ 합성 픽스처로 끝까지 도는지 ⑵ 집계(판정 일치율·거절·'안내 없이 다른 판정')가 맞는지 ⑶ 결과 표에 실명이 없는지 본다.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "measure_consistency.py"


@pytest.fixture(scope="module")
def tool():
    spec = importlib.util.spec_from_file_location("measure_consistency", _SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["measure_consistency"] = module
    spec.loader.exec_module(module)
    return module


def test_dry_run이_끝까지_돌고_표를_쓴다(tool, tmp_path, monkeypatch):
    import requests

    monkeypatch.setattr(requests, "post", requests.post)  # 도구가 바꿔 끼운 가짜를 테스트 뒤에 되돌린다
    for name in ("DATA_DIR", "ANALYSIS_CACHE_HOURS", "UPSTAGE_API_KEY", "MOLIT_API_KEY",
                 "LLM_STRUCTURE_PROVIDER", "SAVE_RAW_RESPONSES"):
        monkeypatch.setenv(name, "")  # 도구가 os.environ을 바꾼다 — monkeypatch가 되돌린다

    assert tool.main(["--dry-run", "--out", str(tmp_path)]) == 0
    md = next(tmp_path.glob("consistency_*_dryrun.md"))
    js = next(tmp_path.glob("consistency_*_dryrun.json"))
    text = md.read_text(encoding="utf-8")
    assert "합성 픽스처(--dry-run)" in text
    assert "| 합성등기부 | 4 | 3 | 1 | 0 | **3/3 (100%)** | 확인 필요 |" in text
    assert "근저당권" in text  # 필드 이름은 쉬운 한국어로
    data = json.loads(js.read_text(encoding="utf-8"))
    summary = data["summaries"][0]
    assert summary["rejected"] == 1 and summary["silent_miss"] == 0
    # 실명·주소 원문이 없다 (합성 IE의 집주인 '가나다', 주소 '○○동 1-1')
    for secret in ("가나다", "○○동 1-1"):
        assert secret not in text and secret not in js.read_text(encoding="utf-8")


def test_집계_안내_없이_다른_판정을_센다(tool):
    Shot, Registry = tool.Shot, tool.Registry
    shots = [Shot(name=f"{i:02d}", pages=3, seconds=20.0 + i, outcome="analyzed", grade="위험",
                  fields={"주소": "aaaaaa"}) for i in range(8)]
    shots.append(Shot(name="09", pages=3, seconds=25, outcome="analyzed", grade="확인 필요",
                      fields={"주소": "aaaaaa"}, capture_issues=["2쪽 cut_off"]))  # 다르지만 안내가 붙음
    shots.append(Shot(name="10", pages=3, seconds=26, outcome="analyzed", grade="양호",
                      fields={"주소": "bbbbbb"}))  # 다르고 안내도 없음 = 놓친 것
    shots.append(Shot(name="11", pages=3, seconds=0.5, outcome="rejected", capture_issues=["1쪽 blurry"]))
    s = tool.summarize(Registry("A", shots))
    assert s["analyzed"] == 10 and s["rejected"] == 1
    assert s["top_grade"] == "위험" and s["grade_agree"] == 8
    assert s["flagged"] == 1 and s["silent_miss"] == 1
    assert s["field_agree"]["주소"] == pytest.approx(0.9)
    assert s["all_fields_same"] == 9


def test_폴더_없이_부르면_안내하고_끝낸다(tool, capsys):
    with pytest.raises(SystemExit):
        tool.main([])
    assert "--dry-run" in capsys.readouterr().err
