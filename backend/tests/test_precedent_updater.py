"""판례 자동 업데이트(2026-10-24) — 새 것만 받기 · 창고 다시 만들기 · 기록 · 간격 · 실패해도 그대로."""

from __future__ import annotations

import json
from datetime import datetime

import pytest
from fastapi.testclient import TestClient

from app.services.precedent import ingest, updater


@pytest.fixture()
def data_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("PRECEDENT_INDEX_DIR", str(tmp_path / "index"))
    return tmp_path


def _detail(pid: str, case_no: str) -> dict:
    return {
        "판례정보일련번호": pid,
        "사건번호": case_no,
        "사건명": "임대차보증금반환",
        "법원명": "대법원",
        "선고일자": "20261001",
        "판결요지": "<br/>임차인은 경매에서 보증금을 배당받지 못하였다",
        "판례내용": "본문",
    }


def test_collect_new_skips_known_and_maps_raw():
    items = {"임대차보증금": [{"판례일련번호": "1"}, {"판례일련번호": "2"}]}
    got = updater.collect_new(
        "test",
        {"1"},
        search=lambda oc, q: items.get(q, []),
        fetch=lambda pid: {"PrecService": _detail(pid, "2026다2")},
    )
    assert [r["prec_id"] for r in got] == ["2"]
    assert got[0]["holding_summary"] == "임차인은 경매에서 보증금을 배당받지 못하였다"
    assert got[0]["source_url"].startswith("https://www.law.go.kr/")


def test_run_update_saves_new_raw_rebuilds_and_records(data_dir):
    rebuilt = []
    st = updater.run_update(
        collect=lambda known: [updater._to_raw(_detail("999001", "2026다999"))],
        rebuild=lambda: rebuilt.append(1) or 41,
        now=datetime(2026, 10, 24, 4, 0, tzinfo=updater.KST),
    )
    assert rebuilt == [1]
    assert st["lastSuccessAt"] == "2026-10-24" and st["added"] == 1 and st["docCount"] == 41
    assert (ingest.extra_raw_dir() / "prec-999001.json").exists()
    # 다음 적재 때 원문 목록에 들어간다(레포 원문 + 자동으로 받은 것)
    assert any(d.get("prec_id") == "999001" for d in ingest.load_raw_docs())
    assert json.loads(updater.status_path().read_text(encoding="utf-8"))["added"] == 1


def test_run_update_without_new_does_not_rebuild(data_dir):
    st = updater.run_update(
        collect=lambda known: [],
        rebuild=lambda: pytest.fail("새 판례가 없으면 창고를 다시 만들지 않는다"),
        now=datetime(2026, 10, 24, tzinfo=updater.KST),
    )
    assert st["lastSuccessAt"] == "2026-10-24" and st["added"] == 0


def test_failure_keeps_last_success_date(data_dir):
    updater.run_update(collect=lambda k: [], now=datetime(2026, 10, 17, tzinfo=updater.KST))

    def boom(_):
        raise RuntimeError("법제처 막힘")

    st = updater.run_update(collect=boom, now=datetime(2026, 10, 24, tzinfo=updater.KST))
    assert st["lastSuccessAt"] == "2026-10-17"  # 실패한 날로 덮지 않는다
    assert st["lastCheckAt"] == "2026-10-24"
    assert "법제처 막힘" in st["error"]


def test_is_due_every_7_days(data_dir, monkeypatch):
    assert updater.is_due()  # 기록이 없으면 바로
    updater.run_update(collect=lambda k: [], now=datetime(2026, 10, 24, tzinfo=updater.KST))
    assert not updater.is_due(datetime(2026, 10, 30, tzinfo=updater.KST))
    assert updater.is_due(datetime(2026, 10, 31, tzinfo=updater.KST))
    monkeypatch.setenv("PRECEDENT_UPDATE_DAYS", "0")
    assert not updater.is_due(datetime(2027, 1, 1, tzinfo=updater.KST))


def test_status_endpoint(data_dir):
    from app.main import app

    index = data_dir / "index"
    index.mkdir()
    (index / "meta.json").write_text(json.dumps({"doc_count": 40, "ingested_at": "2026-08-12T10:00:00"}))
    client = TestClient(app)
    r = client.get("/api/precedents/status", headers={"X-Device-Id": "dev-test-1"})
    assert r.status_code == 200
    assert r.json() == {"docCount": 40, "updatedAt": "2026-08-12"}  # 업데이트 전이면 창고 만든 날

    updater.run_update(collect=lambda k: [], now=datetime(2026, 10, 24, tzinfo=updater.KST))
    r = client.get("/api/precedents/status", headers={"X-Device-Id": "dev-test-1"})
    assert r.json() == {"docCount": 40, "updatedAt": "2026-10-24"}


def test_rebuild_swaps_index_folder(data_dir):
    live = data_dir / "index"
    live.mkdir()
    (live / "meta.json").write_text(json.dumps({"doc_count": 40}))

    def fake_ingest(building):
        building.mkdir(parents=True)
        (building / "meta.json").write_text(json.dumps({"doc_count": 45}))
        return {"doc_count": 45}

    assert updater._rebuild_index(fake_ingest) == 45
    assert updater.index_doc_count() == 45
    assert not (data_dir / "index.building").exists() and not (data_dir / "index.old").exists()


def test_health_summary_plain_words(data_dir):
    from fastapi.testclient import TestClient
    from app.main import app

    assert TestClient(app).get("/").json()["precedentUpdate"]["ok"] is False  # 아직 한 번도 안 돎

    def blocked(_):
        raise RuntimeError("법제처 API 사용자 검증 실패 — LAW_API_OC·서버 IP 등록 확인 필요")

    updater.run_update(collect=blocked, now=datetime(2026, 10, 24, tzinfo=updater.KST))
    pu = TestClient(app).get("/").json()["precedentUpdate"]
    assert {k: pu[k] for k in ("lastCheckAt", "lastSuccessAt", "added", "ok", "error")} == {
        "lastCheckAt": "2026-10-24", "lastSuccessAt": None, "added": None,
        "ok": False, "error": "법제처 인증 실패(OC·서버 IP 등록)",
    }
    assert pu["running"] is None and pu["backfillDone"] is False and pu["extraRaw"] == 0
    updater.run_update(collect=lambda k: [], now=datetime(2026, 10, 25, tzinfo=updater.KST))
    pu = TestClient(app).get("/").json()["precedentUpdate"]
    assert pu["ok"] is True and pu["error"] is None and pu["added"] == 0


def test_backfill_pages_through_and_marks_done(data_dir):
    """몰아 받기: 검색어마다 여러 쪽을 훑고, 끝나면 표시를 남긴다(다음엔 매주 업데이트만)."""
    calls = []

    def search(oc, q, page=1, display=100):
        calls.append((q, page))
        if q != "임대차보증금" or page > 2:
            return []
        return [{"판례일련번호": f"{page}{i:03d}"} for i in range(100 if page == 1 else 3)]

    got = updater.collect_new(
        "test", set(), search=search, fetch=lambda pid: _detail(pid, f"2026다{pid}"), backfill=True
    )
    assert len(got) == 103
    assert ("임대차보증금", 2) in calls and ("임대차보증금", 3) not in calls  # 마지막 쪽에서 멈춤
    assert len({q for q, _ in calls}) == len(updater.BACKFILL_QUERIES)

    assert not updater.backfill_done()
    updater.run_update(collect=lambda k: [], backfill=True, now=datetime(2026, 10, 24, tzinfo=updater.KST))
    assert updater.backfill_done()


def test_failed_backfill_is_retried(data_dir):
    def boom(_):
        raise RuntimeError("법제처 막힘")

    updater.run_update(collect=boom, backfill=True, now=datetime(2026, 10, 24, tzinfo=updater.KST))
    assert not updater.backfill_done()  # 실패하면 표시를 남기지 않아 다음에 다시 한다


def test_rebuild_is_retried_after_failure(data_dir):
    """원문은 받았는데 창고 만들기가 실패하면, 다음 번에 새 원문이 없어도 다시 만든다."""
    def fail():
        raise RuntimeError("임베딩 끊김")

    raw = [updater._to_raw(_detail("777", "2026다777"))]
    updater.run_update(collect=lambda k: raw, rebuild=fail, now=datetime(2026, 10, 24, tzinfo=updater.KST))
    rebuilt = []
    st = updater.run_update(
        collect=lambda k: [], rebuild=lambda: rebuilt.append(1) or 41,
        now=datetime(2026, 10, 25, tzinfo=updater.KST),
    )
    assert rebuilt == [1] and st["needsRebuild"] is False and st["docCount"] == 41


def test_backfill_keeps_each_raw_even_if_server_stops_midway(data_dir, monkeypatch):
    """받는 도중 서버가 꺼져도(배포) 받은 원문은 남고, 다시 켜지면 창고부터 만든다 (2026-10-24 실측 사고)."""
    monkeypatch.setattr(updater, "REQUEST_INTERVAL_SECONDS", 0)
    calls = {"n": 0}

    def search(oc, q, page=1, display=100):
        return [{"판례일련번호": str(500 + i)} for i in range(5)] if q == "임대차보증금" and page == 1 else []

    def fetch(pid):
        calls["n"] += 1
        if calls["n"] == 4:
            raise KeyboardInterrupt  # 서버가 꺼지는 것 흉내 (Exception이 아니라 잡히지 않는다)
        return {"PrecService": _detail(pid, f"2026다{pid}")}

    monkeypatch.setattr(updater, "_search_latest", search)
    monkeypatch.setattr(updater, "_get_json", lambda url, params: fetch(params["ID"]))
    with pytest.raises(KeyboardInterrupt):
        updater.run_update(backfill=True, rebuild=lambda: 0, now=datetime(2026, 10, 24, tzinfo=updater.KST))
    assert updater._extra_raw_count() == 3
    st = updater.read_status()
    assert st["needsRebuild"] is True and st["running"]

    # 다시 켜짐 — 남은 것만 받고 창고를 만든다
    calls["n"] = 100
    rebuilt = []
    st = updater.run_update(
        backfill=True, rebuild=lambda: rebuilt.append(1) or 45, now=datetime(2026, 10, 24, tzinfo=updater.KST)
    )
    assert rebuilt == [1] and updater._extra_raw_count() == 5 and st["running"] is None
    assert updater.backfill_done()


def test_backfill_cap_counts_already_saved(data_dir, monkeypatch):
    """이어 받을 때 상한은 '지금까지 받은 것 포함' — 다시 켜질 때마다 600건씩 늘지 않게."""
    out = ingest.extra_raw_dir()
    out.mkdir(parents=True)
    for i in range(updater.BACKFILL_MAX_NEW):
        (out / f"prec-x{i}.json").write_text("{}", encoding="utf-8")
    seen = {}

    def fake_collect(oc, known, *, backfill, limit, on_new):
        seen["limit"] = limit
        return []

    monkeypatch.setattr(updater, "collect_new", fake_collect)
    monkeypatch.setattr(ingest, "load_raw_docs", lambda: [])
    updater.run_update(backfill=True, rebuild=lambda: 0, now=datetime(2026, 10, 24, tzinfo=updater.KST))
    assert seen["limit"] == 0


def test_rebuild_forgets_cached_chroma_connections(data_dir, monkeypatch):
    """바꿔 끼운 뒤 같은 경로로 다시 열 때 옛 파일 연결을 쓰지 않게 Chroma 기억을 지운다."""
    calls = []
    monkeypatch.setattr(updater, "_forget_chroma_clients", lambda: calls.append(1))

    def fake_ingest(building):
        building.mkdir(parents=True)
        (building / "meta.json").write_text(json.dumps({"doc_count": 3}))
        return {"doc_count": 3}

    updater._rebuild_index(fake_ingest)
    assert len(calls) == 2
