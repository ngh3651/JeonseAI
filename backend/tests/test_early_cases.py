"""판례를 설명과 동시에 찾아 둔다 (2026-11-03 속도).

예전엔 리포트가 나온 뒤 앱이 판례를 따로 불러 9~14초를 더 기다렸다(로딩 '1초 남았어요'에서 멈춰 보이던 까닭).
이제 분석이 설명을 쓰는 동안 같은 재료(저장될 가린 사본과 같은 값)로 판례를 먼저 찾고, 앱이 부르면 그 결과를 준다.
"""

from __future__ import annotations

import threading
import time
from types import SimpleNamespace

from app.routers import reports as reports_router
from app.services import store

from tests.test_analyze_smoke import blank_image, client, no_network, post_analyze, raw_ocr_json, registry_raw  # noqa: F401
from tests.test_highlight import PAGE_H, PAGE_W, gap_gu_page


def _fake_service(calls: list, *, delay: float = 0.0):
    def match_for_report(report, *, explain=False):
        calls.append(report.id)
        # 앱이 읽는 것과 같은 **가린 사본**이어야 한다 — 저장 사본처럼 사람 이름 목록이 있다
        assert report.personNames is not None
        time.sleep(delay)
        return SimpleNamespace(cases=[])

    return lambda: SimpleNamespace(match_for_report=match_for_report)


def test_분석이_판례를_먼저_찾고_앱이_부르면_다시_찾지_않는다(client, no_network, monkeypatch):
    calls: list = []
    monkeypatch.setattr(reports_router.precedent_service, "get_service", _fake_service(calls, delay=0.2))
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    resp = post_analyze(client, [blank_image(PAGE_W, PAGE_H)])
    assert resp.status_code == 200, resp.text
    report_id = resp.json()["id"]
    got = client.get(f"/api/reports/{report_id}/cases")
    assert got.status_code == 200 and got.json() == []
    assert calls == [report_id], f"판례 찾기는 한 번만(분석 중에) — {calls}"


def test_미리_찾던_중_지워지면_낡은_결과를_남기지_않는다():
    started, release = threading.Event(), threading.Event()

    def compute():
        started.set()
        release.wait(2)
        return ["낡은 결과"]

    store.start_cases("r-1", compute, device_id="dv-x")
    assert started.wait(2)
    store.clear_cases("r-1", device_id="dv-x")  # 보증금 고치기 등으로 판례를 다시 찾아야 함
    release.set()
    time.sleep(0.1)
    assert store.get_cases("r-1", device_id="dv-x") is None
    assert store.wait_cases("r-1", device_id="dv-x", timeout=0.1) is None


def test_미리_찾기가_실패하면_캐시하지_않고_앱이_부를_때_다시_찾는다():
    def compute():
        raise RuntimeError("크레딧 소진")

    store.start_cases("r-2", compute, device_id="dv-x")
    assert store.wait_cases("r-2", device_id="dv-x", timeout=1) is None
    assert store.get_cases("r-2", device_id="dv-x") is None
