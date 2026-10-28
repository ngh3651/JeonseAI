"""분석 중 [중단] = 결과 버리기 (2026-10-29, 규혁 결정 — 크레딧 아끼는 쪽).

앱이 분석 중에 [중단]을 누르면 진행 중인 HTTP 요청을 끊는다. 서버는 그걸 알아채고:

1. **아직 시작 안 한** 비싼 단계(Upstage IE·OCR·Solar)를 부르지 않는다.
2. 끊긴 요청의 리포트를 **기록에 남기지 않는다**(저장 직후에 끊겼으면 거둔다).
3. `replaces`로 옛 리포트를 **지우지 않는다** — 다시 올리다 중단해도 원래 리포트는 그대로다.
4. 같은 사진 캐시에 남기지 않는다 — 같은 사진을 다시 보내면 처음부터 분석한다.

⚠ 이미 보낸 호출(IE 한 번·그 장의 OCR)은 멈출 수 없다 — 그 크레딧은 쓰인다(이 파일은 그 뒤 단계만 본다).
진짜 연결 끊김은 TestClient로 흉내 내기 어려워 `reports._client_gone`을 바꿔 끼운다.
"""

from __future__ import annotations

import threading

import pytest
import requests

from app.routers import reports as reports_router
from app.services import analysis_cache, ocr, store

from tests.test_analyze_smoke import (  # noqa: F401 — pytest 픽스처 재사용
    _IE_URL,
    _OCR_URL,
    blank_image,
    client,
    no_network,
    raw_ocr_json,
    registry_raw,
)
from tests.test_highlight import PAGE_H, PAGE_W, gap_gu_page

DEVICE = {"X-Device-Id": "phone-cancel-0001"}


def _post(client, *, deposit: int, replaces: str | None = None):
    files = [("files", ("page_1.jpg", blank_image(PAGE_W, PAGE_H), "image/jpeg"))]
    data = {"deposit": str(deposit)}
    if replaces:
        data["replaces"] = replaces
    return client.post("/api/analyze", files=files, data=data, headers=DEVICE)


def _ids() -> list[str]:
    return [r.id for r in store.list_reports(device_id=DEVICE["X-Device-Id"])]


def _cache_rows() -> int:
    return analysis_cache._execute(
        "SELECT COUNT(*) FROM analysis_cache WHERE device_id = ?", (DEVICE["X-Device-Id"],)
    )[0][0]


@pytest.fixture
def gone(monkeypatch):
    """앱이 끊었나 — `state["gone"]`을 켜면 그때부터 끊긴 것으로 보인다."""
    state = {"gone": False}
    monkeypatch.setattr(reports_router, "_client_gone", lambda request: state["gone"])
    return state


def test_끊긴_채_도착한_요청은_Upstage를_한_번도_부르지_않는다(client, no_network, gone):
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    gone["gone"] = True

    resp = _post(client, deposit=120_000_000)

    assert resp.status_code == reports_router.CLIENT_CLOSED_STATUS
    assert calls == [], "IE·OCR·Solar 어느 것도 부르지 않는다(크레딧 0원)"
    assert _ids() == [] and _cache_rows() == 0


def test_IE_도중_끊기면_설명_Solar를_부르지_않고_저장도_replaces도_안_한다(client, no_network, gone, monkeypatch):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0)), raw_ocr_json(gap_gu_page(0))])
    first = _post(client, deposit=120_000_000)
    assert first.status_code == 200, first.text
    old_id = first.json()["id"]
    cache_before = _cache_rows()

    # IE 호출이 돌아오는 순간 사용자가 [중단]을 눌렀다 (IE는 이미 보낸 호출이라 멈출 수 없다)
    seen: list[str] = []
    inner = requests.post

    def post(url, *args, **kwargs):
        seen.append(url)
        resp = inner(url, *args, **kwargs)
        if url == _IE_URL:
            gone["gone"] = True
        return resp

    monkeypatch.setattr(requests, "post", post)

    resp = _post(client, deposit=130_000_000, replaces=old_id)

    assert resp.status_code == reports_router.CLIENT_CLOSED_STATUS
    assert _IE_URL in seen
    assert not [u for u in seen if u.endswith("/chat/completions")], "설명(Solar)을 부르지 않는다"
    assert _ids() == [old_id], "새 리포트는 남지 않고, 옛 리포트는 replaces로 지워지지 않는다"
    assert _cache_rows() == cache_before, "같은 사진 캐시에 끊긴 결과가 남지 않는다"


def test_저장_직후_끊기면_새_리포트를_거두고_옛_리포트는_그대로다(client, no_network, gone, monkeypatch):
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))] * 3)
    first = _post(client, deposit=120_000_000)
    old_id = first.json()["id"]
    cache_before = _cache_rows()

    # 설명까지 다 쓰고 기록에 넣은 바로 뒤에 끊겼다
    real_add = store.add

    def add_then_gone(report, *, device_id):
        real_add(report, device_id=device_id)
        gone["gone"] = True

    monkeypatch.setattr(store, "add", add_then_gone)
    resp = _post(client, deposit=130_000_000, replaces=old_id)
    monkeypatch.setattr(store, "add", real_add)

    assert resp.status_code == reports_router.CLIENT_CLOSED_STATUS
    assert _ids() == [old_id]
    assert _cache_rows() == cache_before

    # 같은 사진·같은 보증금을 다시 보내면 캐시가 아니라 처음부터 분석한다
    gone["gone"] = False
    ie_before = calls.count(_IE_URL)
    again = _post(client, deposit=130_000_000, replaces=old_id)
    assert again.status_code == 200, again.text
    assert calls.count(_IE_URL) == ie_before + 1
    assert _ids() == [again.json()["id"]], "중단하지 않으면 replaces가 원래대로 옛 리포트를 대신한다"


def test_안_끊기면_지금과_똑같다(client, no_network, gone):
    """대조군 — 끊김 확인이 정상 분석을 건드리지 않는다."""
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    resp = _post(client, deposit=120_000_000)
    assert resp.status_code == 200, resp.text
    assert _ids() == [resp.json()["id"]]
    assert _cache_rows() == 1


def test_OCR은_중단_신호가_켜지면_남은_장을_부르지_않는다(no_network):
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))] * 3)
    stop = threading.Event()
    stop.set()

    result = ocr.run_ocr([(f"page_{i}.jpg", blank_image(PAGE_W, PAGE_H)) for i in range(3)], stop=stop)

    assert result.pages == []
    assert _OCR_URL not in calls


def test_끊김을_확인하지_못하면_안_끊긴_것으로_본다():
    """이벤트 루프 밖(직접 부른 경우)에서는 물을 곳이 없다 — 분석을 멈추지 않는다."""
    assert reports_router._client_gone(object()) is False  # type: ignore[arg-type]
