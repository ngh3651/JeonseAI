"""서버 문 — 기기 id · 기기별 기록 · 앱 키 · 속도 제한 (2026-10-21 배포 준비).

예전에는 `DEV_MODE_AUTH = True` 하나가 인증 우회와 실명 원응답 저장을 같이 켰고,
`GET /api/reports`는 **모든 사람의 기록**을 돌려줬다. 이 파일이 지키는 것:

1. 호출자 = `X-Device-Id` 헤더(형식 검사). 없으면 공용 `legacy-device`(옛 앱 호환),
   `REQUIRE_DEVICE_ID=1`이면 400.
2. 기록은 기기별 — 다른 기기의 리포트는 404. 예시 리포트는 누구나 보되 못 지운다(403).
3. `APP_KEY`가 있으면 `/api/*`는 `X-App-Key`가 맞아야 한다(401). 헬스·문서는 열려 있다.
4. 분석·대조는 기기×IP별 1시간 상한(429).
"""

from __future__ import annotations

import pytest
from fastapi import HTTPException

from app import dependencies, settings


# ══════════════════════════════════════════════════════════════════════════════
# ① 기기 id
# ══════════════════════════════════════════════════════════════════════════════


def test_헤더가_없으면_공용_기기_id다(monkeypatch):
    monkeypatch.delenv("REQUIRE_DEVICE_ID", raising=False)
    assert dependencies.get_current_user(None) == settings.LEGACY_DEVICE_ID == "legacy-device"


def test_헤더_필수로_켜면_헤더_없이는_400이다(monkeypatch):
    monkeypatch.setenv("REQUIRE_DEVICE_ID", "1")
    with pytest.raises(HTTPException) as e:
        dependencies.get_current_user(None)
    assert e.value.status_code == 400
    assert "기기" in e.value.detail  # 한국어 안내


@pytest.mark.parametrize(
    "device_id",
    ["3f2b8c1e-9a4d-4e7b-b1c2-0d9e8f7a6b5c", "abcdEFGH", "a" * 64, "device-0001"],
)
def test_올바른_기기_id는_그대로_쓴다(device_id):
    assert dependencies.get_current_user(device_id) == device_id


@pytest.mark.parametrize(
    "device_id",
    ["short", "a" * 65, "has space here", "slash/not/ok", "한글기기아이디입니다", "semi;colon00"],
)
def test_형식이_틀린_기기_id는_400이다(device_id):
    with pytest.raises(HTTPException) as e:
        dependencies.get_current_user(device_id)
    assert e.value.status_code == 400


def test_공용_통로_이름을_직접_보내면_400이다():
    """헤더로 `legacy-device`를 보내 공용 기록에 들어가는 길을 막는다."""
    with pytest.raises(HTTPException) as e:
        dependencies.get_current_user("legacy-device")
    assert e.value.status_code == 400


# ══════════════════════════════════════════════════════════════════════════════
# ② 기기별 기록 + 영구 저장 (엔드포인트 관통, 크레딧 0원)
# ══════════════════════════════════════════════════════════════════════════════

from tests.test_analyze_smoke import (  # noqa: E402,F401 — pytest 픽스처 재사용
    blank_image,
    client,
    no_network,
    raw_ocr_json,
    registry_raw,
)
from tests.test_highlight import PAGE_H, PAGE_W, gap_gu_page  # noqa: E402

PHONE_A = {"X-Device-Id": "phone-aaaa-0001"}
PHONE_B = {"X-Device-Id": "phone-bbbb-0002"}


def _analyze(client, headers: dict | None = None):
    files = [("files", ("page_1.jpg", blank_image(PAGE_W, PAGE_H), "image/jpeg"))]
    return client.post(
        "/api/analyze", files=files, data={"deposit": "120000000"}, headers=headers or {}
    )


def _ids(client, headers: dict | None = None) -> list[str]:
    resp = client.get("/api/reports", headers=headers or {})
    assert resp.status_code == 200, resp.text
    return [r["id"] for r in resp.json()]


def test_다른_기기의_기록은_목록에_안_보이고_열면_404다(client, no_network):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    resp = _analyze(client, PHONE_A)
    assert resp.status_code == 200, resp.text
    rid = resp.json()["id"]

    assert rid in _ids(client, PHONE_A)
    assert rid not in _ids(client, PHONE_B)
    assert rid not in _ids(client)  # 헤더 없는 옛 앱(공용 기기)에도 안 보인다

    for path in (
        f"/api/reports/{rid}",
        f"/api/reports/{rid}/questions",
        f"/api/reports/{rid}/cases",
    ):
        assert client.get(path, headers=PHONE_B).status_code == 404, path
    assert client.delete(f"/api/reports/{rid}", headers=PHONE_B).status_code == 404
    assert client.post(f"/api/reports/{rid}/compare", headers=PHONE_B).status_code == 404

    # 주인 기기에서는 그대로 보인다 (남이 지우려던 시도로 사라지지 않았다)
    assert client.get(f"/api/reports/{rid}", headers=PHONE_A).status_code == 200


def test_예시_리포트는_모든_기기에_보이고_지울_수_없다(client):
    for headers in (PHONE_A, PHONE_B, {}):
        assert "dummy-example" in _ids(client, headers)
        assert client.get("/api/reports/dummy-example", headers=headers).status_code == 200
        assert client.delete("/api/reports/dummy-example", headers=headers).status_code == 403


def test_내_기록은_내가_지울_수_있다(client, no_network):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    rid = _analyze(client, PHONE_A).json()["id"]

    assert client.delete(f"/api/reports/{rid}", headers=PHONE_A).status_code == 204
    assert rid not in _ids(client, PHONE_A)
    assert client.get(f"/api/reports/{rid}", headers=PHONE_A).status_code == 404


def test_서버를_다시_켜도_기록과_대조_기준이_남는다(client, no_network):
    """재시작 = 저장소를 다시 만든다(`store.reset()` — 파일은 그대로). 대조도 '기준 없음'이 아니어야 한다."""
    from app.services import store

    page = gap_gu_page(0)
    no_network(registry_raw(), [raw_ocr_json(page)])
    base = _analyze(client, PHONE_A).json()
    assert base["comparable"] is True

    store.reset()  # ← 서버 재시작

    assert base["id"] in _ids(client, PHONE_A)
    again = client.get(f"/api/reports/{base['id']}", headers=PHONE_A).json()
    assert again["grade"] == base["grade"] and again["comparable"] is True

    # 같은 서류를 다시 떼어 대조 → 집주인이 '그대로'여야 한다 (이름 해시 소금도 DB에 남아서)
    no_network(registry_raw(), [raw_ocr_json(page)])
    files = [("files", ("page_1.jpg", blank_image(PAGE_W, PAGE_H), "image/jpeg"))]
    resp = client.post(f"/api/reports/{base['id']}/compare", files=files, headers=PHONE_A)
    assert resp.status_code == 200, resp.text
    result = resp.json()
    assert result["result"] != "no_baseline", "재시작 뒤 대조 기준이 사라졌다"
    owner_rows = [r for r in result["rows"] if r["title"].startswith("집주인")]
    assert owner_rows and owner_rows[0]["kind"] == "same", owner_rows


def test_기록_DB는_DATA_DIR_아래_app_db다(client, no_network, tmp_path, monkeypatch):
    from app.services import store

    monkeypatch.setenv("DATA_DIR", str(tmp_path / "vol"))
    store.reset()
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    assert _analyze(client, PHONE_A).status_code == 200
    assert (tmp_path / "vol" / "app.db").is_file()
    assert store.db_path() == tmp_path / "vol" / "app.db"


def test_스냅샷은_JSON으로_오가도_똑같다():
    """튜플이 리스트로 바뀌면 `owner_keys` 비교가 늘 '다르다'가 된다 — 되읽기를 못 박는다."""
    from app.schemas.internal import RegistryExtract
    from app.services import compare, store
    from tests.test_compare import _report

    extract = RegistryExtract.from_raw(registry_raw())
    snap = compare.build_snapshot(
        extract, report=_report("r1"), page_count=1, manual_market_price=None, name_salt=b"s" * 16
    )
    back = store.snapshot_from_json(store.snapshot_to_json(snap))
    assert back == snap
