"""요금제 + 토스페이먼츠 **테스트** 결제 (2026-10-22, P2-1) — 돈이 걸린 곳이라 못 박는다.

1. 요금제: 가격 옆에는 늘 '예시' 표시(`label`), 무료 · 계약 지킴이 패스 · 기관용(문의).
2. **금액은 서버가 정한다** — 앱이 보낸 금액이 요금제 가격과 다르면 토스를 부르지도 않는다.
   토스에도 앱 금액이 아니라 요금제 가격을 보낸다.
3. **테스트 키만** — 실제 키(`live_…`)면 승인하지 않는다(503).
4. 승인되면 그 주인(지금은 기기)의 패스가 생기고 `GET /api/me/pass`가 참. 다른 기기에는 없다.
5. 같은 주문을 다시 보내면 토스를 다시 부르지 않고 같은 패스. 토스 거절은 토스 문구 그대로 400.
6. 남기는 것은 주문번호·금액·결제수단·승인 시각뿐 — 카드 번호·영수증 주소는 버린다.

토스 호출은 전부 가짜다(`payments._post`/`_get`을 바꿔 끼운다) — 실제 호출 0회.
"""

from __future__ import annotations

import json

import pytest

from app import dependencies, settings
from app.services import payments, store

PHONE_A = {"X-Device-Id": "phone-aaaa-0001"}
PHONE_B = {"X-Device-Id": "phone-bbbb-0002"}

PASS_PRICE = 9900  # data/pricing.json 의 guardian_pass (예시 가격)


class _FakeResponse:
    def __init__(self, status_code: int, body: dict) -> None:
        self.status_code = status_code
        self._body = body

    def json(self) -> dict:
        return self._body


def _toss_done(order_id: str, amount: int, payment_key: str = "pk_test_0001") -> dict:
    """토스 결제 승인 응답(필요한 칸 + 버려야 할 칸)."""
    return {
        "paymentKey": payment_key,
        "orderId": order_id,
        "orderName": "계약 지킴이 패스",
        "status": "DONE",
        "totalAmount": amount,
        "method": "카드",
        "approvedAt": "2026-10-22T21:00:00+09:00",
        # ↓ 저장·응답하면 안 되는 것들
        "card": {"number": "43301234****123*", "issuerCode": "71"},
        "receipt": {"url": "https://dashboard.tosspayments.com/receipt/xxxx"},
    }


@pytest.fixture
def client():
    from fastapi.testclient import TestClient

    from app.main import app

    return TestClient(app)


@pytest.fixture
def toss(monkeypatch):
    """토스 API 대신 — 받은 요청을 기록하고, 정해 둔 응답을 돌려준다."""

    class _Toss:
        def __init__(self) -> None:
            self.posts: list[tuple[str, dict, str]] = []
            self.gets: list[str] = []
            self.reply: _FakeResponse | None = None
            self.get_reply: _FakeResponse | None = None

        def post(self, path: str, body: dict, secret_key: str):
            self.posts.append((path, body, secret_key))
            if self.reply is not None:
                return self.reply
            return _FakeResponse(200, _toss_done(body["orderId"], body["amount"], body["paymentKey"]))

        def get(self, path: str, secret_key: str):
            self.gets.append(path)
            return self.get_reply or _FakeResponse(404, {"code": "NOT_FOUND_PAYMENT", "message": "없음"})

    fake = _Toss()
    monkeypatch.setattr(payments, "_post", fake.post)
    monkeypatch.setattr(payments, "_get", fake.get)

    def _no_real_call(*_a, **_k):  # 혹시 다른 길로 새도 실제 호출은 0회
        raise AssertionError("테스트에서 실제 토스 API를 부르면 안 된다")

    monkeypatch.setattr(payments.requests, "post", _no_real_call)
    monkeypatch.setattr(payments.requests, "get", _no_real_call)
    return fake


def _confirm(client, *, order_id="jsp-order-0001", amount=PASS_PRICE, plan="guardian_pass", headers=None):
    return client.post(
        "/api/payments/confirm",
        json={"planId": plan, "orderId": order_id, "paymentKey": "pk_test_0001", "amount": amount},
        headers=headers if headers is not None else PHONE_A,
    )


# ══════════════════════════════════════════════════════════════════════════════
# ① 요금제
# ══════════════════════════════════════════════════════════════════════════════


def test_요금제는_세_가지이고_가격은_예시로_표시된다(client):
    resp = client.get("/api/pricing")
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["label"] == "예시 (팀 확정 전)"
    assert body["testMode"] is True
    assert body["testNotice"] == "테스트 결제 — 실제 청구 없음"
    plans = {p["id"]: p for p in body["plans"]}
    assert list(plans) == ["free", "guardian_pass", "institution"]
    assert plans["free"]["price"] == 0 and not plans["free"]["purchasable"]
    assert plans["guardian_pass"]["purchasable"] and plans["guardian_pass"]["price"] == PASS_PRICE
    # 기관용은 가격 대신 "문의" — 결제 버튼 없음
    assert plans["institution"]["price"] is None
    assert plans["institution"]["priceText"] == "문의" and plans["institution"]["contact"]
    assert not plans["institution"]["purchasable"]


def test_요금제_파일의_가격과_표시_글자가_같다():
    """`price`(검사 기준)와 `priceText`(화면)가 어긋나면 화면 가격과 청구 금액이 달라진다."""
    raw = json.loads(payments.PRICING_PATH.read_text(encoding="utf-8"))
    for plan in raw["plans"]:
        if plan["price"] is None:
            continue
        assert plan["priceText"] == f"{plan['price']:,}원", plan["id"]


# ══════════════════════════════════════════════════════════════════════════════
# ② 금액·키 검사 (토스를 부르기 전에 막는다)
# ══════════════════════════════════════════════════════════════════════════════


def test_앱이_보낸_금액이_요금제와_다르면_토스를_부르지_않고_거절한다(client, toss):
    resp = _confirm(client, amount=100)
    assert resp.status_code == 400
    assert "금액" in resp.json()["detail"]
    assert toss.posts == []
    assert client.get("/api/me/pass", headers=PHONE_A).json()["active"] is False


@pytest.mark.parametrize("plan", ["free", "institution", "없는-요금제"])
def test_결제할_수_없는_요금제는_거절한다(client, toss, plan):
    resp = _confirm(client, plan=plan, amount=0)
    assert resp.status_code == 400
    assert toss.posts == []


def test_실제_결제_키가_들어오면_승인하지_않는다(client, toss, monkeypatch):
    monkeypatch.setenv("TOSS_SECRET_KEY", "live_gsk_aaaaaaaaaaaaaaaaaaaaaaaa")
    resp = _confirm(client)
    assert resp.status_code == 503
    assert "테스트 결제만" in resp.json()["detail"]
    assert toss.posts == []


def test_키를_비우면_문서_공개_테스트_키를_쓴다(monkeypatch):
    monkeypatch.setenv("TOSS_SECRET_KEY", "")
    assert settings.toss_secret_key() == settings.TOSS_DOCS_TEST_SECRET_KEY
    assert payments.is_test_key(settings.toss_secret_key())
    assert not payments.is_test_key("live_sk_aaaa")


def test_서비스도_실제_키로는_토스를_부르지_않는다(toss):
    with pytest.raises(payments.PaymentUnavailable):
        payments.confirm(payment_key="pk", order_id="jsp-order-0001", amount=PASS_PRICE, secret_key="live_sk_x")
    assert toss.posts == []


@pytest.mark.parametrize("order_id", ["short", "한글주문번호입니다", "has space 0001", "a" * 65])
def test_주문번호_형식이_틀리면_422(client, toss, order_id):
    assert _confirm(client, order_id=order_id).status_code == 422
    assert toss.posts == []


# ══════════════════════════════════════════════════════════════════════════════
# ③ 승인 → 패스
# ══════════════════════════════════════════════════════════════════════════════


def test_승인되면_패스가_생기고_요금제_가격으로_승인을_부른다(client, toss):
    resp = _confirm(client)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["testMode"] is True
    assert body["notice"] == "테스트 결제 — 실제 청구 없음"
    assert body["pass"]["planId"] == "guardian_pass"
    assert body["pass"]["planName"] == "계약 지킴이 패스"
    assert body["pass"]["amount"] == PASS_PRICE
    assert body["pass"]["method"] == "카드"

    # 토스에는 요금제 가격 + 테스트 키
    (path, sent, key), = toss.posts
    assert path == "/v1/payments/confirm"
    assert sent == {"paymentKey": "pk_test_0001", "orderId": "jsp-order-0001", "amount": PASS_PRICE}
    assert key.startswith("test_")

    mine = client.get("/api/me/pass", headers=PHONE_A).json()
    assert mine["active"] is True
    assert mine["pass"]["orderId"] == "jsp-order-0001"
    assert mine["notice"] == "테스트 결제 — 실제 청구 없음"


def test_다른_기기에는_패스가_없다(client, toss):
    assert _confirm(client).status_code == 200
    other = client.get("/api/me/pass", headers=PHONE_B).json()
    assert other == {"active": False, "testMode": True, "notice": "테스트 결제 — 실제 청구 없음", "pass": None}


def test_카드_번호와_영수증_주소는_어디에도_남기지_않는다(client, toss):
    resp = _confirm(client)
    text = resp.text + client.get("/api/me/pass", headers=PHONE_A).text
    assert "4330" not in text and "receipt" not in text
    rows = store._db().execute("SELECT * FROM passes")
    assert "4330" not in repr(rows) and "dashboard.tosspayments.com" not in repr(rows)


def test_같은_주문을_다시_보내면_토스를_다시_부르지_않는다(client, toss):
    first = _confirm(client)
    again = _confirm(client)
    assert first.status_code == again.status_code == 200
    assert again.json()["pass"] == first.json()["pass"]
    assert len(toss.posts) == 1


def test_남의_주문번호로는_패스를_가져갈_수_없다(client, toss):
    assert _confirm(client, headers=PHONE_A).status_code == 200
    stolen = _confirm(client, headers=PHONE_B)
    assert stolen.status_code == 409
    assert client.get("/api/me/pass", headers=PHONE_B).json()["active"] is False


def test_토스가_거절하면_토스_문구_그대로_400_패스는_없다(client, toss):
    toss.reply = _FakeResponse(
        400, {"code": "REJECT_CARD_PAYMENT", "message": "한도초과 혹은 잔액부족으로 결제에 실패했습니다."}
    )
    resp = _confirm(client)
    assert resp.status_code == 400
    assert resp.json()["detail"] == "한도초과 혹은 잔액부족으로 결제에 실패했습니다."
    assert client.get("/api/me/pass", headers=PHONE_A).json()["active"] is False


def test_토스_응답이_요청과_다르면_승인으로_치지_않는다(client, toss):
    toss.reply = _FakeResponse(200, _toss_done("jsp-order-0001", 100))  # 금액이 다르다
    resp = _confirm(client)
    assert resp.status_code == 502
    assert client.get("/api/me/pass", headers=PHONE_A).json()["active"] is False


def test_토스에_닿지_못하면_502(client, toss, monkeypatch):
    import requests

    def _down(*_a, **_k):
        raise requests.ConnectionError("끊김")

    monkeypatch.setattr(payments, "_post", _down)
    resp = _confirm(client)
    assert resp.status_code == 502
    assert "다시 시도" in resp.json()["detail"]


def test_이미_승인된_결제면_조회해서_같은_주문이면_패스를_되살린다(client, toss):
    """승인 직후 응답이 끊겨 앱이 다시 보냈는데 우리 기록이 없는 경우 — 패스를 잃지 않는다."""
    toss.reply = _FakeResponse(400, {"code": "ALREADY_PROCESSED_PAYMENT", "message": "이미 처리된 결제 입니다."})
    toss.get_reply = _FakeResponse(200, _toss_done("jsp-order-0001", PASS_PRICE))
    resp = _confirm(client)
    assert resp.status_code == 200, resp.text
    assert toss.gets == ["/v1/payments/pk_test_0001"]
    assert client.get("/api/me/pass", headers=PHONE_A).json()["active"] is True


# ══════════════════════════════════════════════════════════════════════════════
# ④ 주인 키 — 한 곳에서만
# ══════════════════════════════════════════════════════════════════════════════


def test_패스의_주인_키는_기기_id에서_나온다():
    assert dependencies.get_pass_owner("phone-aaaa-0001") == "device:phone-aaaa-0001"
    assert store.latest_pass("device:phone-aaaa-0001") is None
