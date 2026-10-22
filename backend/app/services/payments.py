"""요금제 + 토스페이먼츠 **테스트** 결제 승인 (2026-10-22, P2-1).

흐름: 앱의 토스 결제위젯이 결제를 마치면 `paymentKey·orderId·amount`를 돌려준다 →
앱이 `POST /api/payments/confirm`으로 넘긴다 → 서버가 **요금제 가격으로 금액을 검사**하고
토스 승인 API(`/v1/payments/confirm`)를 부른다 → 승인되면 그 주인의 패스를 기록한다.

지키는 것:
- **금액은 서버가 정한다.** 앱이 보낸 금액이 `data/pricing.json`의 가격과 다르면 토스를 부르지도
  않고 거절한다. 토스에도 앱 금액이 아니라 **요금제 가격**을 보낸다(토스가 실제 결제 금액과 한 번 더 맞춘다).
- **테스트 키만** 쓴다. `test_`로 시작하지 않는 키(실제 키 `live_…`)가 들어오면 승인하지 않는다.
- 토스 응답에서 **필요한 것만** 남긴다(주문번호·금액·결제수단·승인 시각). 카드 번호·영수증 주소는 버린다.
- 토스 호출은 이 파일의 `_post`/`_get` 두 곳뿐이다 — 테스트는 이 둘을 바꿔 끼운다(실제 호출 0회).
"""

from __future__ import annotations

import base64
import json
import logging
from dataclasses import dataclass
from pathlib import Path

import requests

from .. import settings
from ..schemas.contract import GuardianPass, Pricing, PricingPlan

_log = logging.getLogger("jeonseai")

PRICING_PATH = Path(__file__).resolve().parents[2] / "data" / "pricing.json"

TOSS_API_BASE = "https://api.tosspayments.com"
_CONFIRM_PATH = "/v1/payments/confirm"
#: 토스 결제 승인은 카드사 응답을 기다린다 — 문서 권장대로 넉넉히 기다린다.
_TIMEOUT_SECONDS = 30

TEST_NOTICE = "테스트 결제 — 실제 청구 없음"


# ── 요금제 ────────────────────────────────────────────────────────────────────


def load_pricing() -> Pricing:
    """`data/pricing.json` → 요금제. 파일이 깨지면 예외(서버 시작 후 첫 호출에서 바로 보인다)."""
    raw = json.loads(PRICING_PATH.read_text(encoding="utf-8"))
    return Pricing(
        label=raw["label"],
        currency=raw.get("currency", "KRW"),
        testMode=True,
        testNotice=TEST_NOTICE,
        plans=[PricingPlan(**plan) for plan in raw["plans"]],
    )


def plan_by_id(plan_id: str) -> PricingPlan | None:
    return next((p for p in load_pricing().plans if p.id == plan_id), None)


# ── 키 ──────────────────────────────────────────────────────────────────────


def is_test_key(key: str) -> bool:
    """토스 테스트 키인가 — `test_`로 시작해야 한다(`test_sk_…` · `test_gsk_…`). 실제 키는 `live_…`."""
    return key.startswith("test_")


def _auth_header(secret_key: str) -> str:
    # 토스 API는 시크릿 키를 사용자 이름으로, 비밀번호는 비워서(`키:`) Basic 인증한다.
    token = base64.b64encode(f"{secret_key}:".encode("utf-8")).decode("ascii")
    return f"Basic {token}"


# ── 토스 호출 (테스트는 이 두 함수를 바꿔 끼운다) ─────────────────────────────


def _post(path: str, body: dict, secret_key: str) -> requests.Response:
    return requests.post(
        f"{TOSS_API_BASE}{path}",
        json=body,
        headers={"Authorization": _auth_header(secret_key), "Content-Type": "application/json"},
        timeout=_TIMEOUT_SECONDS,
    )


def _get(path: str, secret_key: str) -> requests.Response:
    return requests.get(
        f"{TOSS_API_BASE}{path}",
        headers={"Authorization": _auth_header(secret_key)},
        timeout=_TIMEOUT_SECONDS,
    )


# ── 승인 ────────────────────────────────────────────────────────────────────


class PaymentRejected(Exception):
    """토스가 승인을 거절했다(카드 한도·취소·만료 등). [message]는 토스의 한국어 문구."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class PaymentUnavailable(Exception):
    """토스에 닿지 못했거나 응답이 이상하다 — 잠시 뒤 다시 시도할 일."""


@dataclass(frozen=True)
class Approved:
    """승인된 결제에서 남기는 것만."""

    order_id: str
    payment_key: str
    amount: int
    method: str | None
    approved_at: str | None


def _approved_from(body: dict, *, order_id: str, amount: int) -> Approved:
    """토스 결제 객체 → 남길 값. 상태·주문번호·금액이 우리가 보낸 것과 다르면 승인으로 치지 않는다."""
    status = body.get("status")
    total = body.get("totalAmount")
    if status != "DONE" or body.get("orderId") != order_id or total != amount:
        _log.error(
            f"[결제] ⚠ 토스 응답이 요청과 맞지 않아 승인으로 치지 않음 (상태 {status}, 금액 일치 {total == amount})"
        )
        raise PaymentUnavailable("결제 확인 결과가 요청과 맞지 않아요")
    return Approved(
        order_id=order_id,
        payment_key=str(body.get("paymentKey") or ""),
        amount=int(total),
        method=body.get("method"),
        approved_at=body.get("approvedAt"),
    )


def _error_of(resp: requests.Response) -> tuple[str, str]:
    try:
        data = resp.json()
        return str(data.get("code") or "UNKNOWN"), str(data.get("message") or "")
    except ValueError:
        return "UNKNOWN", ""


def confirm(*, payment_key: str, order_id: str, amount: int, secret_key: str) -> Approved:
    """토스 승인 API를 부른다. [amount]는 **요금제 가격**(앱 금액이 아니다).

    - 토스가 4xx로 거절 → [PaymentRejected] (토스의 한국어 문구 그대로)
    - 이미 승인된 결제(`ALREADY_PROCESSED_PAYMENT`) → 결제를 조회해 같은 주문·금액이면 승인으로 본다
      (승인 직후 응답이 끊겨 앱이 다시 보낸 경우 — 패스를 잃지 않게)
    - 네트워크 오류·5xx → [PaymentUnavailable]
    """
    if not is_test_key(secret_key):
        # 라우터가 먼저 막지만, 여기서도 한 번 더 — 실제 결제 키로는 토스를 부르지 않는다.
        raise PaymentUnavailable("테스트 결제 키가 아니에요")
    try:
        resp = _post(
            _CONFIRM_PATH,
            {"paymentKey": payment_key, "orderId": order_id, "amount": amount},
            secret_key,
        )
    except requests.RequestException as e:
        _log.error(f"[결제] ⚠ 토스 승인 API에 닿지 못함 ({type(e).__name__})")
        raise PaymentUnavailable("결제사에 연결하지 못했어요") from e

    if resp.status_code == 200:
        return _approved_from(resp.json(), order_id=order_id, amount=amount)

    code, message = _error_of(resp)
    if code == "ALREADY_PROCESSED_PAYMENT":
        try:
            again = _get(f"/v1/payments/{payment_key}", secret_key)
        except requests.RequestException as e:
            raise PaymentUnavailable("결제사에 연결하지 못했어요") from e
        if again.status_code == 200:
            return _approved_from(again.json(), order_id=order_id, amount=amount)
    if 400 <= resp.status_code < 500:
        _log.info(f"[결제] 토스가 승인을 거절함 — {code}")
        raise PaymentRejected(code, message or "결제를 승인하지 못했어요")
    _log.error(f"[결제] ⚠ 토스 승인 API 오류 {resp.status_code} — {code}")
    raise PaymentUnavailable("결제사 응답이 올바르지 않아요")


# ── 패스(결제 기록) → 응답 모양 ─────────────────────────────────────────────────


def to_guardian_pass(record: dict) -> GuardianPass:
    plan = plan_by_id(record["plan_id"])
    return GuardianPass(
        planId=record["plan_id"],
        planName=plan.name if plan else record["plan_id"],
        orderId=record["order_id"],
        amount=record["amount"],
        method=record.get("method"),
        approvedAt=record.get("approved_at"),
        testMode=bool(record.get("test_mode", True)),
    )
