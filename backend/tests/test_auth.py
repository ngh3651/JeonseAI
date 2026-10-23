"""카카오 로그인 — 세션 · 기록 옮기기 · 사칭 차단 · 회원 탈퇴 · 회원번호 원문 0 (2026-10-22, P2-1).

이 파일이 지키는 것:
1. 서버에 `KAKAO_APP_ID`·`ACCOUNT_HASH_SECRET`이 없으면 로그인은 503 "아직 준비되지 않았어요"(둘러보기는 그대로).
2. 카카오 토큰 정보의 `app_id`가 **우리 앱과 같을 때만** 통과 — 다른 앱의 토큰·만료 토큰은 401, 카카오 장애는 502.
3. 세션: 무작위 토큰 → DB엔 SHA-256만. `Authorization: Bearer`가 살아 있으면 주인 = 계정(`acct-…`),
   틀리거나 만료면 401 "다시 로그인해 주세요". 로그아웃하면 그 세션은 끝.
4. 로그인하는 순간 그 기기의 기록(리포트·대조 기준·캐시 쪽지·패스)이 계정으로 옮겨진다. 공용 통로는 안 옮긴다.
5. 기기 id로 `acct-…`를 보내면 400(남의 계정 기록 사칭 차단).
6. 회원 탈퇴 = 그 계정의 기록·세션·패스 전부 삭제 → 0건.
7. 회원번호 원문은 DB 파일 바이트·로그·응답 어디에도 없다.

카카오 호출은 전부 가짜다(`accounts._get`을 바꿔 끼운다) — 실제 호출 0회.
"""

from __future__ import annotations

import logging
from datetime import timedelta

import pytest
from fastapi import HTTPException

from app import dependencies
from app.services import accounts, analysis_cache, payments, store

# 다른 테스트 파일의 픽스처를 그대로 쓴다 (분석 한 바퀴 — 크레딧 0원)
from tests.test_analyze_smoke import (  # noqa: F401 — pytest 픽스처 재사용
    blank_image,
    client,
    no_network,
    raw_ocr_json,
    registry_raw,
)
from tests.test_highlight import PAGE_H, PAGE_W, gap_gu_page

APP_ID = "1234567"
OTHER_APP_ID = 7654321
#: 눈에 띄는 회원번호 — DB·로그·응답에서 이 숫자를 찾는다.
MEMBER_ID = 4098765432123
OTHER_MEMBER_ID = 4012345678901
SECRET = "test-account-hash-secret-0123456789-abcdef"  # 32자 이상
KAKAO_TOKEN = "kakao-access-token-for-test-ZYXW9876"

PHONE_A = {"X-Device-Id": "phone-aaaa-0001"}
PHONE_B = {"X-Device-Id": "phone-bbbb-0002"}


class _FakeResponse:
    def __init__(self, status_code: int, body: object) -> None:
        self.status_code = status_code
        self._body = body

    def json(self) -> object:
        if isinstance(self._body, Exception):
            raise self._body
        return self._body


@pytest.fixture
def kakao(monkeypatch):
    """카카오 토큰 정보 API 대신 — 받은 토큰을 기록하고, 정해 둔 회원번호·앱 ID를 돌려준다."""

    class _Kakao:
        def __init__(self) -> None:
            self.calls: list[tuple[str, str]] = []
            self.member_id: int = MEMBER_ID
            self.app_id: object = int(APP_ID)
            self.reply: _FakeResponse | None = None
            self.raise_error: Exception | None = None

        def get(self, path: str, access_token: str):
            self.calls.append((path, access_token))
            if self.raise_error is not None:
                raise self.raise_error
            if self.reply is not None:
                return self.reply
            return _FakeResponse(
                200, {"id": self.member_id, "expires_in": 7199, "app_id": self.app_id}
            )

    fake = _Kakao()
    monkeypatch.setattr(accounts, "_get", fake.get)

    def _no_real_call(*_a, **_k):  # 혹시 다른 길로 새도 실제 호출은 0회
        raise AssertionError("테스트에서 실제 카카오 API를 부르면 안 된다")

    monkeypatch.setattr(accounts.requests, "get", _no_real_call)
    return fake


@pytest.fixture
def ready(monkeypatch):
    """서버에 카카오 로그인 변수를 넣는다(Railway Variables에 넣은 것과 같다)."""
    monkeypatch.setenv("KAKAO_APP_ID", APP_ID)
    monkeypatch.setenv("ACCOUNT_HASH_SECRET", SECRET)


@pytest.fixture
def server_logs():
    """`jeonseai` 로거는 propagate=False라 caplog가 못 본다 → 직접 붙인다."""

    class _Collect(logging.Handler):
        def __init__(self) -> None:
            super().__init__(level=logging.DEBUG)
            self.lines: list[str] = []

        def emit(self, record: logging.LogRecord) -> None:
            self.lines.append(self.format(record))

    logger = logging.getLogger("jeonseai")
    handler = _Collect()
    handler.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(handler)
    old_level = logger.level
    logger.setLevel(logging.DEBUG)
    yield handler.lines
    logger.removeHandler(handler)
    logger.setLevel(old_level)


def _login(client, headers: dict | None = None, token: str = KAKAO_TOKEN):
    return client.post("/api/auth/kakao", json={"accessToken": token}, headers=headers or {})


def _session_headers(session_token: str, device: dict | None = None) -> dict:
    return {**(device or {}), "Authorization": f"Bearer {session_token}"}


def _analyze(client, headers: dict):
    files = [("files", ("page_1.jpg", blank_image(PAGE_W, PAGE_H), "image/jpeg"))]
    return client.post("/api/analyze", files=files, data={"deposit": "120000000"}, headers=headers)


def _ids(client, headers: dict) -> list[str]:
    resp = client.get("/api/reports", headers=headers)
    assert resp.status_code == 200, resp.text
    return [r["id"] for r in resp.json() if r["id"] not in store.EXAMPLE_IDS]


def _owner(member_id: int = MEMBER_ID) -> str:
    return accounts.owner_for(accounts.account_key(member_id, secret=SECRET))


# ══════════════════════════════════════════════════════════════════════════════
# ① 준비 안 됨 → 503 (둘러보기는 그대로)
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.parametrize(
    "app_id, secret",
    [("", ""), (APP_ID, ""), ("", SECRET), (APP_ID, "too-short-secret")],
)
def test_변수가_없거나_비밀이_짧으면_로그인은_503이고_카카오를_부르지_않는다(
    client, kakao, monkeypatch, app_id, secret
):
    monkeypatch.setenv("KAKAO_APP_ID", app_id)
    monkeypatch.setenv("ACCOUNT_HASH_SECRET", secret)
    resp = _login(client, PHONE_A)
    assert resp.status_code == 503, resp.text
    assert resp.json()["detail"] == "카카오 로그인이 아직 준비되지 않았어요"
    assert kakao.calls == []
    # 로그인 없이 둘러보기(기기 id)는 그대로 된다
    assert client.get("/api/reports", headers=PHONE_A).status_code == 200
    assert client.get("/api/me", headers=PHONE_A).json() == {
        "loggedIn": False,
        "provider": None,
        "customerKey": None,
    }


# ══════════════════════════════════════════════════════════════════════════════
# ② 카카오 토큰 확인 — 우리 앱의 토큰만
# ══════════════════════════════════════════════════════════════════════════════


def test_카카오_토큰_정보로_확인하고_세션을_준다(client, kakao, ready):
    resp = _login(client, PHONE_A)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert set(body) == {"sessionToken", "expiresAt", "customerKey"}
    assert len(body["sessionToken"]) >= 40
    assert body["customerKey"].startswith("acct_") and 2 <= len(body["customerKey"]) <= 50
    # 카카오에는 토큰 정보 API 하나만 물었다(사용자 정보 /v2/user/me는 부르지 않는다 — 이름·이메일 안 받음)
    assert kakao.calls == [(accounts.TOKEN_INFO_PATH, KAKAO_TOKEN)]
    assert accounts.TOKEN_INFO_PATH == "/v1/user/access_token_info"
    assert accounts.KAKAO_API_BASE == "https://kapi.kakao.com"


@pytest.mark.parametrize("app_id", [OTHER_APP_ID, None, "1234567x"])
def test_다른_앱의_토큰이면_401이고_세션을_만들지_않는다(client, kakao, ready, app_id):
    kakao.app_id = app_id
    resp = _login(client, PHONE_A)
    assert resp.status_code == 401, resp.text
    assert "다시 로그인" in resp.json()["detail"]
    assert accounts.sessions_for_test() == []


def test_카카오_앱_ID는_숫자와_문자열을_같게_본다(client, kakao, ready):
    kakao.app_id = APP_ID  # 문자열로 와도
    assert _login(client, PHONE_A).status_code == 200


@pytest.mark.parametrize(
    "reply",
    [
        _FakeResponse(401, {"msg": "this access token does not exist", "code": -401}),
        _FakeResponse(400, {"msg": "invalid token", "code": -2}),
        _FakeResponse(200, {"expires_in": 100, "app_id": int(APP_ID)}),  # 회원번호 없음
        _FakeResponse(200, {"id": "4098765432123", "app_id": int(APP_ID)}),  # 숫자가 아님
        _FakeResponse(200, {"id": True, "app_id": int(APP_ID)}),
    ],
)
def test_카카오가_토큰을_받지_않거나_회원번호가_없으면_401(client, kakao, ready, reply):
    kakao.reply = reply
    resp = _login(client, PHONE_A)
    assert resp.status_code == 401, resp.text
    assert accounts.sessions_for_test() == []


def test_카카오에_닿지_못하면_502(client, kakao, ready):
    import requests

    kakao.raise_error = requests.ConnectionError("down")
    assert _login(client, PHONE_A).status_code == 502
    kakao.raise_error = None
    kakao.reply = _FakeResponse(500, {"code": -1})
    assert _login(client, PHONE_A).status_code == 502
    kakao.reply = _FakeResponse(200, ValueError("not json"))
    assert _login(client, PHONE_A).status_code == 502
    assert accounts.sessions_for_test() == []


def test_빈_토큰은_카카오에_묻기_전에_422(client, kakao, ready):
    assert _login(client, PHONE_A, token="").status_code == 422
    assert kakao.calls == []


# ══════════════════════════════════════════════════════════════════════════════
# ③ 세션 — Authorization: Bearer
# ══════════════════════════════════════════════════════════════════════════════


def test_세션이_있으면_주인은_계정이고_다른_폰에서도_같은_계정이다(client, kakao, ready, no_network):
    token_a = _login(client, PHONE_A).json()["sessionToken"]
    me = client.get("/api/me", headers=_session_headers(token_a, PHONE_A))
    assert me.status_code == 200
    assert me.json()["loggedIn"] is True and me.json()["provider"] == "kakao"

    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    rid = _analyze(client, _session_headers(token_a, PHONE_A)).json()["id"]

    # 같은 카카오 계정으로 다른 폰에서 로그인 → 같은 기록
    token_b = _login(client, PHONE_B).json()["sessionToken"]
    assert token_b != token_a
    assert rid in _ids(client, _session_headers(token_b, PHONE_B))
    # 로그인 없이 둘러보는 폰 B(기기 id)에는 안 보인다
    assert rid not in _ids(client, PHONE_B)
    # 직접 부르면 계정 주인이 나온다
    assert dependencies.get_current_user("phone-bbbb-0002", f"Bearer {token_b}") == _owner()


@pytest.mark.parametrize(
    "authorization",
    ["Bearer not-a-real-session", "Bearer ", "Basic abc", "bearer " + "x" * 300],
)
def test_틀린_세션은_401_다시_로그인(client, authorization):
    resp = client.get("/api/reports", headers={**PHONE_A, "Authorization": authorization})
    assert resp.status_code == 401, resp.text
    assert resp.json()["detail"] == "로그인이 끝났어요. 다시 로그인해 주세요"
    # 앱이 '세션 문제'임을 알아보는 표시 (RFC 6750) — 앱 키 401과 가른다
    assert 'error="invalid_token"' in resp.headers.get("www-authenticate", "")


def test_빈_Authorization_헤더는_로그인하지_않은_것과_같다(client):
    resp = client.get("/api/reports", headers={**PHONE_A, "Authorization": "  "})
    assert resp.status_code == 200


def test_만료된_세션은_401이고_지워진다(client, kakao, ready, monkeypatch):
    monkeypatch.setenv("SESSION_DAYS", "30")
    token = _login(client, PHONE_A).json()["sessionToken"]
    headers = _session_headers(token, PHONE_A)
    assert client.get("/api/me", headers=headers).status_code == 200

    later = accounts._now() + timedelta(days=30, seconds=1)
    monkeypatch.setattr(accounts, "_now", lambda: later)
    assert client.get("/api/me", headers=headers).status_code == 401
    assert accounts.sessions_for_test() == []


def test_세션_기간은_SESSION_DAYS를_따른다(client, kakao, ready, monkeypatch):
    from datetime import datetime

    monkeypatch.setenv("SESSION_DAYS", "7")
    body = _login(client, PHONE_A).json()
    left = datetime.fromisoformat(body["expiresAt"]) - accounts._now()
    assert timedelta(days=6, hours=23) < left <= timedelta(days=7)


def test_로그아웃하면_그_세션은_끝나고_다른_폰은_그대로(client, kakao, ready):
    token_a = _login(client, PHONE_A).json()["sessionToken"]
    token_b = _login(client, PHONE_B).json()["sessionToken"]
    assert client.post("/api/auth/logout", headers=_session_headers(token_a)).status_code == 204
    assert client.get("/api/me", headers=_session_headers(token_a)).status_code == 401
    assert client.get("/api/me", headers=_session_headers(token_b)).json()["loggedIn"] is True
    # 몇 번을 불러도, 로그인하지 않았어도 204
    assert client.post("/api/auth/logout", headers=_session_headers(token_a)).status_code == 204
    assert client.post("/api/auth/logout", headers=PHONE_A).status_code == 204


def test_세션_토큰_원문은_DB에_없고_SHA256만_있다(client, kakao, ready):
    import hashlib

    token = _login(client, PHONE_A).json()["sessionToken"]
    rows = accounts.sessions_for_test()
    assert len(rows) == 1
    assert token not in repr(rows)
    assert hashlib.sha256(token.encode()).hexdigest() in repr(rows)


# ══════════════════════════════════════════════════════════════════════════════
# ④ 로그인하는 순간 그 기기의 기록을 계정으로
# ══════════════════════════════════════════════════════════════════════════════


def test_로그인하면_이_기기의_리포트_대조기준_캐시_패스가_계정으로_옮겨진다(
    client, kakao, ready, no_network
):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    guest = _analyze(client, PHONE_A)
    assert guest.status_code == 200, guest.text
    rid = guest.json()["id"]
    assert store.get_snapshot(rid, device_id=PHONE_A["X-Device-Id"]) is not None
    payments.add_pass(
        owner_key="device:phone-aaaa-0001",
        order_id="jsp-order-claim-01",
        plan_id="guardian_pass",
        payment_key="pk_test_claim",
        amount=9900,
        method="카드",
        approved_at=None,
        test_mode=True,
    )
    cache_rows = analysis_cache._execute("SELECT device_id FROM analysis_cache")
    assert cache_rows == [("phone-aaaa-0001",)], cache_rows

    token = _login(client, PHONE_A).json()["sessionToken"]
    owner = _owner()
    account = _session_headers(token, PHONE_A)

    # 리포트·대조 기준·쪽지·패스 — 전부 계정 쪽에 있다
    assert rid in _ids(client, account)
    assert client.get(f"/api/reports/{rid}", headers=account).status_code == 200
    assert store.get_snapshot(rid, device_id=owner) is not None
    assert analysis_cache._execute("SELECT device_id FROM analysis_cache") == [(owner,)]
    my_pass = client.get("/api/me/pass", headers=account).json()
    assert my_pass["active"] is True and my_pass["pass"]["orderId"] == "jsp-order-claim-01"

    # 그 기기로 로그인 없이 둘러보면 옮긴 기록은 없다(이제 계정의 것)
    assert rid not in _ids(client, PHONE_A)
    assert client.get("/api/me/pass", headers=PHONE_A).json()["active"] is False

    # 다시 로그인해도(두 번째) 그대로 — 옮길 것이 없다
    assert accounts.claim_device_records("phone-aaaa-0001", owner) == 0
    assert rid in _ids(client, account)


def test_같은_사진은_로그인_뒤에도_캐시에서_나온다(client, kakao, ready, no_network):
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    first = _analyze(client, PHONE_A).json()
    token = _login(client, PHONE_A).json()["sessionToken"]
    before = len(calls) if calls is not None else None
    again = _analyze(client, _session_headers(token, PHONE_A))
    assert again.status_code == 200, again.text
    assert again.json()["id"] == first["id"]  # 옮긴 쪽지가 옮긴 리포트를 가리킨다
    if before is not None:
        assert len(calls) == before  # 외부 호출 0회


def test_헤더_없는_옛_앱의_공용_칸은_옮기지_않는다(client, kakao, ready, no_network):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    shared = _analyze(client, {}).json()["id"]  # legacy-device
    token = _login(client, {}).json()["sessionToken"]  # 기기 id 없이 로그인
    assert shared not in _ids(client, _session_headers(token))
    assert shared in _ids(client, {})
    assert accounts.claim_device_records("legacy-device", _owner()) == 0


def test_다른_카카오_계정의_기록은_섞이지_않는다(client, kakao, ready, no_network):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    token_1 = _login(client, PHONE_A).json()["sessionToken"]
    rid = _analyze(client, _session_headers(token_1, PHONE_A)).json()["id"]

    kakao.member_id = OTHER_MEMBER_ID
    token_2 = _login(client, PHONE_B).json()["sessionToken"]
    assert rid not in _ids(client, _session_headers(token_2, PHONE_B))
    assert client.get(f"/api/reports/{rid}", headers=_session_headers(token_2)).status_code == 404


# ══════════════════════════════════════════════════════════════════════════════
# ⑤ 사칭 차단 — 기기 id로 acct-… 를 보내면 400
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.parametrize("device_id", ["acct-0123456789abcdef0123456789abcdef", "ACCT-0123456789abcdef", "Acct-xyz12345"])
def test_기기_id로_계정_주인을_보내면_400이다(client, device_id):
    with pytest.raises(HTTPException) as e:
        dependencies.get_current_user(device_id)
    assert e.value.status_code == 400
    for path in ("/api/reports", "/api/me", "/api/me/pass"):
        assert client.get(path, headers={"X-Device-Id": device_id}).status_code == 400, path


def test_계정_주인_값을_그대로_기기_id로_넣어도_그_계정_기록이_안_열린다(client, kakao, ready, no_network):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    token = _login(client, PHONE_A).json()["sessionToken"]
    rid = _analyze(client, _session_headers(token, PHONE_A)).json()["id"]
    stolen = {"X-Device-Id": _owner()}
    assert client.get("/api/reports", headers=stolen).status_code == 400
    assert client.get(f"/api/reports/{rid}", headers=stolen).status_code == 400
    assert _login(client, {"X-Device-Id": _owner()}).status_code == 400


def test_패스_주인_키_모양은_한_함수가_정한다():
    assert accounts.pass_owner_key("phone-aaaa-0001") == "device:phone-aaaa-0001"
    assert accounts.pass_owner_key(_owner()) == f"account:{_owner()}"
    assert dependencies.get_pass_owner("phone-aaaa-0001") == "device:phone-aaaa-0001"
    assert dependencies.get_pass_owner(_owner()) == f"account:{_owner()}"


# ══════════════════════════════════════════════════════════════════════════════
# ⑥ 회원 탈퇴 — 그 계정의 기록·세션·패스 전부 삭제
# ══════════════════════════════════════════════════════════════════════════════


def test_탈퇴하면_그_계정의_기록_세션_패스가_0건이다(client, kakao, ready, no_network):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0)) for _ in range(3)])  # 주인 셋 → 분석 세 번
    token = _login(client, PHONE_A).json()["sessionToken"]
    other_phone_token = _login(client, PHONE_B).json()["sessionToken"]
    account = _session_headers(token, PHONE_A)
    rid = _analyze(client, account).json()["id"]
    owner = _owner()
    payments.add_pass(
        owner_key=f"account:{owner}",
        order_id="jsp-order-bye-0001",
        plan_id="guardian_pass",
        payment_key="pk_test_bye",
        amount=9900,
        method="카드",
        approved_at=None,
        test_mode=True,
    )
    # 다른 사람(다른 계정·둘러보기 기기)의 기록은 그대로 남아야 한다
    kakao.member_id = OTHER_MEMBER_ID
    other_token = _login(client, {}).json()["sessionToken"]
    other_rid = _analyze(client, _session_headers(other_token)).json()["id"]
    guest_rid = _analyze(client, {"X-Device-Id": "phone-cccc-0003"}).json()["id"]

    assert client.delete("/api/me", headers=account).status_code == 204

    # 그 계정: 리포트·대조 기준·쪽지·패스·세션 0건
    assert [r.id for r in store.list_reports(device_id=owner) if r.id not in store.EXAMPLE_IDS] == []
    assert store.get_snapshot(rid, device_id=owner) is None
    assert analysis_cache._execute("SELECT COUNT(*) FROM analysis_cache WHERE device_id = ?", (owner,)) == [(0,)]
    assert payments.latest_pass(f"account:{owner}") is None
    assert [r for r in accounts.sessions_for_test() if r[1] == owner] == []
    # 이 폰의 세션도, 다른 폰의 같은 계정 세션도 끝났다
    assert client.get("/api/me", headers=account).status_code == 401
    assert client.get("/api/me", headers=_session_headers(other_phone_token)).status_code == 401
    # 다른 사람 것은 그대로
    assert other_rid in _ids(client, _session_headers(other_token))
    assert guest_rid in _ids(client, {"X-Device-Id": "phone-cccc-0003"})

    # 같은 카카오 계정으로 다시 로그인하면 빈 계정이다
    kakao.member_id = MEMBER_ID
    again = _login(client, {}).json()["sessionToken"]
    assert _ids(client, _session_headers(again)) == []
    assert client.get("/api/me/pass", headers=_session_headers(again)).json()["active"] is False


def test_로그인하지_않고_탈퇴하면_401(client):
    resp = client.delete("/api/me", headers=PHONE_A)
    assert resp.status_code == 401
    assert "로그인" in resp.json()["detail"]


# ══════════════════════════════════════════════════════════════════════════════
# ⑦ 회원번호 원문 0 — DB 파일 바이트 · 로그 · 응답
# ══════════════════════════════════════════════════════════════════════════════


def test_회원번호와_카카오_토큰_원문은_DB_파일_로그_응답_어디에도_없다(
    client, kakao, ready, no_network, server_logs
):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0)) for _ in range(2)])
    _analyze(client, PHONE_A)  # 둘러보기 기록 → 로그인 때 옮겨진다
    login = _login(client, PHONE_A)
    assert login.status_code == 200, login.text
    token = login.json()["sessionToken"]
    account = _session_headers(token, PHONE_A)
    bodies = [
        login.text,
        client.get("/api/me", headers=account).text,
        client.get("/api/reports", headers=account).text,
        _analyze(client, account).text,
        client.get("/api/me/pass", headers=account).text,
    ]
    client.post("/api/auth/logout", headers=account)

    secrets_to_hide = [str(MEMBER_ID), KAKAO_TOKEN, token]
    db_dir = store.db_path().parent
    db_files = [p for p in db_dir.iterdir() if p.is_file() and p.name.startswith("app.db")]
    assert any(p.name == "app.db" for p in db_files), db_files
    for path in db_files:
        blob = path.read_bytes()
        for value in secrets_to_hide:
            assert value.encode() not in blob, f"{path.name}에 '{value[:6]}…' 원문"
    assert server_logs, "로그를 하나도 못 잡았다 — 로거 연결이 틀렸다"
    joined = "\n".join(server_logs)
    for value in secrets_to_hide:
        assert value not in joined, f"로그에 '{value[:6]}…' 원문"
    for body in bodies:
        assert str(MEMBER_ID) not in body
        assert KAKAO_TOKEN not in body


def test_계정_키는_비밀이_다르면_달라지고_같은_회원번호면_같다():
    a = accounts.account_key(MEMBER_ID, secret=SECRET)
    assert a == accounts.account_key(MEMBER_ID, secret=SECRET)
    assert a != accounts.account_key(MEMBER_ID, secret=SECRET + "x")
    assert a != accounts.account_key(OTHER_MEMBER_ID, secret=SECRET)
    assert len(a) == 64 and str(MEMBER_ID) not in a
    owner = accounts.owner_for(a)
    assert owner == "acct-" + a[:32]
    assert accounts.is_account_owner(owner)
