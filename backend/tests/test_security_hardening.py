"""보안 다지기 (2026-10-30) — DB가 새거나, 큰 파일을 보내거나, 상한을 다 써 버리려는 시도를 막는다.

1. 저장 데이터 잠금: `DATA_SECRET`이 있으면 리포트·대조 기준·재료·표시 이름이 DB에 **잠긴 채**(`enc1:`) 쓰인다.
   DB 파일 어디에도 주소·기기 id 원문이 없다. 옛 평문 행도 읽고, 켜질 때 잠근다. 열쇠가 없으면 그 행만 건너뛴다.
2. 기기 id 가리기: 주인 칸에 기기 id 대신 HMAC 값(`dv-…`). 옛 원문 주인의 기록은 처음 부를 때 옮긴다.
3. 업로드 문지기: 너무 큰 본문은 다 받기 전에 413 · 장당 10MB · 압축 폭탄(화소 수)은 디코딩 전에 400 · 별칭 40자.
4. 서버 전체 상한은 크레딧을 실제로 쓸 때만 센다 — 촬영 거절(0원)로 하루 상한을 다 써 버릴 수 없다.
5. 보안 헤더 · CORS 없음 · 예기치 못한 오류는 안쪽 내용 없이 500 · 로그에 오류 문장(실명이 섞일 수 있음)을 남기지 않는다.
"""

from __future__ import annotations

import asyncio
import io
import logging
import sys

import pytest
from PIL import Image

from app import dependencies, main, settings
from app.services import accounts, sealing, store
from tests.test_analyze_smoke import (  # noqa: F401 — pytest 픽스처 재사용
    blank_image,
    client,
    no_network,
    raw_ocr_json,
    registry_raw,
)
from tests.test_highlight import PAGE_H, PAGE_W, gap_gu_page

SECRET = "jeonseai-test-secret-0123456789abcdef"
RAW_DEVICE = "secure-test-device-0001"
DEVICE = {"X-Device-Id": RAW_DEVICE}


@pytest.fixture
def sealed(monkeypatch):
    monkeypatch.setenv("DATA_SECRET", SECRET)
    sealing.reset_for_test()
    accounts.reset_adopted_for_test()
    yield
    sealing.reset_for_test()
    accounts.reset_adopted_for_test()


def _db_bytes() -> bytes:
    """DB 파일과 WAL 조각까지 — 새어 나간다면 통째로 새어 나갈 모든 바이트."""
    path = store.db_path()
    out = b""
    for suffix in ("", "-wal", "-shm"):
        p = path.with_name(path.name + suffix)
        if p.exists():
            out += p.read_bytes()
    return out


def _analyze(client, *, alias: str | None = None):
    files = [("files", ("page_1.jpg", blank_image(PAGE_W, PAGE_H), "image/jpeg"))]
    data = {"deposit": "120000000"}
    if alias is not None:
        data["alias"] = alias
    return client.post("/api/analyze", files=files, data=data, headers=DEVICE)


def _jpeg(im: Image.Image) -> bytes:
    buf = io.BytesIO()
    im.convert("RGB").save(buf, format="JPEG", quality=85)
    return buf.getvalue()


# ══════════════════════════════════════════════════════════════════════════════
# ① 저장 데이터 잠금 · ② 기기 id 가리기
# ══════════════════════════════════════════════════════════════════════════════


def test_열쇠가_있으면_DB에_주소도_기기_id도_원문으로_남지_않는다(client, no_network, sealed):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    resp = _analyze(client, alias="역삼동 오피스텔")
    assert resp.status_code == 200, resp.text
    report = resp.json()
    assert report["address"] == "서울특별시 ○○구 ○○동 123-4"

    raw = _db_bytes()
    assert "123-4".encode() not in raw, "주소가 DB 파일에 평문으로 남았다"
    assert "역삼동 오피스텔".encode() not in raw, "별칭이 DB 파일에 평문으로 남았다"
    assert RAW_DEVICE.encode() not in raw, "기기 id 원문이 DB 주인 칸에 남았다"
    for table, column in store.SEALED_COLUMNS:
        values = store._db().execute(f"SELECT {column} FROM {table}")
        assert values, f"{table}가 비었다"
        assert all(v[0].startswith(sealing.PREFIX) for v in values), f"{table}.{column}이 잠기지 않았다"

    # 앱에서는 그대로 보인다 — 같은 기기 id로 목록·단건
    listed = client.get("/api/reports", headers=DEVICE).json()
    assert [r["id"] for r in listed] == [report["id"]]
    assert client.get(f"/api/reports/{report['id']}", headers=DEVICE).json()["address"] == report["address"]


def test_주인_칸은_가린_값이고_다른_기기_id로는_보이지_않는다(client, no_network, sealed):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    assert _analyze(client).status_code == 200
    owners = {row[0] for row in store._db().execute("SELECT device_id FROM reports")}
    assert owners == {sealing.device_owner(RAW_DEVICE)}
    assert next(iter(owners)).startswith(sealing.DEVICE_OWNER_PREFIX)
    # DB에서 본 주인 값을 기기 id로 보내도 남의 기록에 들어가지 못한다 — 형식부터 400(옛 기록 옮기기로 끌어오지 못하게)
    stolen = next(iter(owners))
    assert client.get("/api/reports", headers={"X-Device-Id": stolen}).status_code == 400
    assert client.get("/api/reports", headers={"X-Device-Id": stolen.upper()}).status_code == 400
    assert store._db().execute("SELECT DISTINCT device_id FROM reports") == [(stolen,)], "기록이 그대로 그 자리에 있다"


def test_옛_평문_기록도_읽고_켜질_때_잠그며_옛_주인_값은_처음_부를_때_옮긴다(client, no_network, monkeypatch):
    # 열쇠 없이(이 기능 전처럼) 분석 — 평문 · 기기 id 원문 주인
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    report_id = _analyze(client).json()["id"]
    assert store._db().execute("SELECT device_id FROM reports") == [(RAW_DEVICE,)]
    assert "123-4".encode() in _db_bytes()

    # 열쇠를 넣고 서버를 다시 켠 것처럼
    monkeypatch.setenv("DATA_SECRET", SECRET)
    sealing.reset_for_test()
    accounts.reset_adopted_for_test()
    try:
        sealed_count = store.seal_existing()
        assert sealed_count >= 2  # 리포트 + 대조 기준 (+ 재료)
        assert store.seal_existing() == 0, "두 번째는 할 일이 없다"
        # 같은 앱이 다시 부르면 기록이 그대로 보이고, 주인 칸이 가린 값으로 바뀐다
        assert [r["id"] for r in client.get("/api/reports", headers=DEVICE).json()] == [report_id]
        owners = {row[0] for row in store._db().execute("SELECT device_id FROM reports")}
        assert owners == {sealing.device_owner(RAW_DEVICE)}
        raw = _db_bytes()
        assert "123-4".encode() not in raw, "VACUUM 뒤에도 옛 평문 조각이 남았다"
        assert RAW_DEVICE.encode() not in raw
    finally:
        sealing.reset_for_test()
        accounts.reset_adopted_for_test()


def test_열쇠가_없거나_틀리면_잠긴_기록만_건너뛰고_서버는_멀쩡하다(client, no_network, sealed, monkeypatch):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    assert _analyze(client).status_code == 200
    owner = sealing.device_owner(RAW_DEVICE)
    monkeypatch.setenv("DATA_SECRET", "another-secret-another-secret-0000")
    sealing.reset_for_test()
    assert store.list_reports(device_id=owner) == []  # 500이 아니라 빈 목록
    monkeypatch.setenv("DATA_SECRET", "")
    sealing.reset_for_test()
    assert store.list_reports(device_id=owner) == []


def test_짧은_열쇠는_쓰지_않는다(monkeypatch):
    monkeypatch.setenv("DATA_SECRET", "too-short")
    sealing.reset_for_test()
    try:
        assert sealing.enabled() is False
        assert sealing.seal("{}") == "{}"
        assert sealing.device_owner(RAW_DEVICE) == RAW_DEVICE
    finally:
        sealing.reset_for_test()


def test_표시_이름도_잠겨서_저장된다(sealed):
    owner = accounts.ACCOUNT_PREFIX + "0" * 32
    assert accounts.set_display_name(owner, "동크크") == "동크크"
    stored = accounts._execute("SELECT display_name FROM profiles WHERE owner = ?", (owner,))[0][0]
    assert stored.startswith(sealing.PREFIX) and "동크크" not in stored
    assert accounts.display_name(owner) == "동크크"


def test_로그인하면_가린_기기_주인의_기록이_계정으로_옮겨진다(client, no_network, sealed):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    report_id = _analyze(client).json()["id"]
    account = accounts.ACCOUNT_PREFIX + "1" * 32
    moved = accounts.claim_device_records(accounts.device_owner(RAW_DEVICE), account)
    assert moved == 1
    assert [r.id for r in store.list_reports(device_id=account)] == [report_id]


# ══════════════════════════════════════════════════════════════════════════════
# ③ 업로드 문지기
# ══════════════════════════════════════════════════════════════════════════════


def test_본문이_너무_크면_다_받기_전에_413():
    sent: list[dict] = []
    reached = []

    async def inner(scope, receive, send):  # 여기까지 오면 안 된다
        reached.append(True)

    async def send(message):
        sent.append(message)

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    guard = main.LimitRequestBody(inner, max_bytes=100)
    scope = {"type": "http", "headers": [(b"content-length", b"5000")]}
    asyncio.run(guard(scope, receive, send))
    assert not reached
    assert sent[0]["status"] == 413


def test_길이를_밝히지_않고_흘려보내도_상한에서_끊는다():
    sent: list[dict] = []
    chunks = [b"x" * 60, b"x" * 60]

    async def inner(scope, receive, send):
        while True:
            message = await receive()
            if not message.get("more_body"):
                break
        await send({"type": "http.response.start", "status": 200, "headers": []})

    async def receive():
        body = chunks.pop(0)
        return {"type": "http.request", "body": body, "more_body": bool(chunks)}

    async def send(message):
        sent.append(message)

    guard = main.LimitRequestBody(inner, max_bytes=100)
    asyncio.run(guard({"type": "http", "headers": []}, receive, send))
    assert sent[0]["status"] == 413


def test_서버의_본문_상한은_앱이_보내는_최대보다_넉넉하다():
    # 앱은 한 번에 최대 10장 × 장당 3MB 안팎 — 시연이 막히면 안 된다
    assert settings.MAX_REQUEST_BYTES >= 10 * 3 * 1024 * 1024 * 2


def test_장당_10MB를_넘으면_413이고_외부_호출이_없다(client, no_network):
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    big = b"\xff\xd8" + b"0" * (settings.MAX_UPLOAD_BYTES + 10)
    resp = client.post(
        "/api/analyze",
        files=[("files", ("page_1.jpg", big, "image/jpeg"))],
        data={"deposit": "120000000"},
        headers=DEVICE,
    )
    assert resp.status_code == 413
    assert calls == []


@pytest.mark.parametrize("side", [7100, 9500])  # 5천만 화소(경고 구간) · 9천만 화소(Pillow가 거절하는 구간)
def test_압축_폭탄_사진은_풀기_전에_400(client, no_network, side):
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    buf = io.BytesIO()
    Image.new("1", (side, side), 1).save(buf, format="PNG")  # 수십 KB짜리 파일 · 화소는 수천만
    assert len(buf.getvalue()) < 2 * 1024 * 1024
    resp = client.post(
        "/api/analyze",
        files=[("files", ("page_1.png", buf.getvalue(), "image/png"))],
        data={"deposit": "120000000"},
        headers=DEVICE,
    )
    assert resp.status_code == 400
    assert "사진이 너무 커요" in resp.json()["detail"]
    assert calls == []


def test_별칭은_40자까지(client, no_network):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    assert _analyze(client, alias="가" * 41).status_code == 422


# ══════════════════════════════════════════════════════════════════════════════
# ④ 서버 전체 상한은 크레딧을 쓸 때만
# ══════════════════════════════════════════════════════════════════════════════


def test_촬영_거절은_서버_하루_상한을_깎지_않는다(client, no_network, monkeypatch):
    monkeypatch.setenv("RATE_LIMIT_GLOBAL_PER_DAY", "1")
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    white = _jpeg(Image.new("L", (880, 1200), 255))  # 글자 없음 → 분석 전 거절(0원)
    for _ in range(3):
        resp = client.post(
            "/api/analyze",
            files=[("files", ("page_1.jpg", white, "image/jpeg"))],
            data={"deposit": "120000000"},
            headers=DEVICE,
        )
        assert resp.status_code == 400
    assert calls == []
    assert len(dependencies._hits.get(dependencies._GLOBAL_DAY, ())) == 0
    # 진짜 분석은 그대로 된다 — 거절 세 번이 하루 상한(1)을 먹지 않았다
    assert _analyze(client).status_code == 200
    assert len(dependencies._hits[dependencies._GLOBAL_DAY]) == 1


# ══════════════════════════════════════════════════════════════════════════════
# ⑤ 보안 헤더 · CORS · 안전한 오류
# ══════════════════════════════════════════════════════════════════════════════


def test_보안_헤더가_붙고_CORS는_없다(client):
    resp = client.get("/", headers={"Origin": "https://evil.example"})
    assert resp.headers["x-content-type-options"] == "nosniff"
    assert resp.headers["x-frame-options"] == "DENY"
    assert resp.headers["referrer-policy"] == "no-referrer"
    assert "access-control-allow-origin" not in resp.headers
    api = client.get("/api/reports", headers=DEVICE)
    assert api.headers["cache-control"] == "no-store"
    assert resp.json()["deviceIdRequired"] in (True, False)
    assert "dataSealed" in resp.json()


def test_예기치_못한_오류는_내용_없이_한국어_500(client, monkeypatch):
    def boom(*_args, **_kwargs):
        raise ValueError("집주인 홍길동 600101-1234567 을 읽다 실패")

    monkeypatch.setattr(store, "list_reports", boom)
    resp = client.get("/api/reports", headers=DEVICE)
    assert resp.status_code == 500
    assert "홍길동" not in resp.text and "600101" not in resp.text
    assert resp.json()["detail"]


def test_로그에는_오류_문장_대신_종류와_위치만():
    try:
        raise ValueError("집주인 홍길동 600101-1234567")
    except ValueError:
        record = logging.LogRecord("jeonseai", logging.ERROR, __file__, 1, "실패", None, sys.exc_info())
    text = main._SafeFormatter("%(message)s").format(record)
    assert "홍길동" not in text and "600101" not in text
    assert "ValueError" in text
    assert "test_security_hardening.py" in text
