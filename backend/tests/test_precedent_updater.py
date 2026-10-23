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
