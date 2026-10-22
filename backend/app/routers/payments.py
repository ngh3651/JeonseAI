"""요금제·테스트 결제·내 패스 라우터 (계약 §3.12~§3.14 — 2026-10-22, P2-1).

- GET  /api/pricing            요금제 (가격은 **예시** — `label`)
- POST /api/payments/confirm   토스 결제위젯 결과 → 금액 검사 → 토스 승인(테스트 키만) → 패스 기록
- GET  /api/me/pass            이 주인의 패스가 있는가

주인 키는 `dependencies.get_pass_owner` 한 곳에서만 정한다(지금은 기기 id).
⚠ 동기(def) 핸들러다 — 토스 승인 호출이 몇 초 걸릴 수 있어 스레드풀에서 돌게 한다.
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException

from .. import settings
from ..dependencies import get_pass_owner
from ..schemas.contract import PassStatus, PaymentConfirmRequest, PaymentConfirmResponse, Pricing
from ..services import payments, store

_log = logging.getLogger("jeonseai")

router = APIRouter(prefix="/api", tags=["payments"])


@router.get("/pricing", response_model=Pricing)
def pricing() -> Pricing:
    """요금제 3가지(무료 · 계약 지킴이 패스 · 기관용). 가격은 팀 확정 전 **예시**다."""
    return payments.load_pricing()


@router.post("/payments/confirm", response_model=PaymentConfirmResponse, response_model_by_alias=True)
def confirm_payment(
    body: PaymentConfirmRequest, owner: str = Depends(get_pass_owner)
) -> PaymentConfirmResponse:
    """결제위젯 성공 값 → 승인 → 패스. **앱이 보낸 금액은 검사에만 쓴다.**"""
    plan = payments.plan_by_id(body.planId)
    if plan is None or not plan.purchasable or plan.price is None:
        raise HTTPException(status_code=400, detail="결제할 수 없는 요금제예요")
    if body.amount != plan.price:
        # 금액이 다르면 토스를 부르지도 않는다 — 앱이나 중간에서 금액을 바꾼 결제를 승인하지 않는다.
        _log.info(f"[결제] 금액이 요금제 가격과 달라 승인하지 않음 (요금제 {plan.id})")
        raise HTTPException(status_code=400, detail="결제 금액이 요금제 가격과 달라요. 결제를 승인하지 않았어요")

    # 같은 주문을 다시 보내면(응답이 끊겨 앱이 재시도) 토스를 다시 부르지 않고 같은 패스를 돌려준다.
    existing = store.pass_by_order(body.orderId)
    if existing is not None:
        if existing["owner_key"] != owner:
            raise HTTPException(status_code=409, detail="이미 다른 곳에서 쓴 주문번호예요")
        return PaymentConfirmResponse(guardianPass=payments.to_guardian_pass(existing))

    secret_key = settings.toss_secret_key()
    if not payments.is_test_key(secret_key):
        _log.error("[결제] ⚠ TOSS_SECRET_KEY가 테스트 키가 아니라 승인을 막음 — 결선은 테스트 결제만")
        raise HTTPException(
            status_code=503,
            detail="지금은 테스트 결제만 받아요. 실제 결제 키로는 승인하지 않아요",
        )

    try:
        approved = payments.confirm(
            payment_key=body.paymentKey,
            order_id=body.orderId,
            amount=plan.price,
            secret_key=secret_key,
        )
    except payments.PaymentRejected as e:
        raise HTTPException(status_code=400, detail=e.message) from e
    except payments.PaymentUnavailable as e:
        raise HTTPException(
            status_code=502, detail="결제를 확인하지 못했어요. 잠시 후 다시 시도해 주세요"
        ) from e

    store.add_pass(
        owner_key=owner,
        order_id=approved.order_id,
        plan_id=plan.id,
        payment_key=approved.payment_key or body.paymentKey,
        amount=approved.amount,
        method=approved.method,
        approved_at=approved.approved_at,
        test_mode=True,
    )
    record = store.pass_by_order(approved.order_id)
    _log.info(f"[결제] 테스트 결제 승인 — {plan.name} {approved.amount:,}원 (실제 청구 없음)")
    return PaymentConfirmResponse(guardianPass=payments.to_guardian_pass(record))


@router.get("/me/pass", response_model=PassStatus, response_model_by_alias=True)
def my_pass(owner: str = Depends(get_pass_owner)) -> PassStatus:
    """이 주인의 가장 최근 패스. 없으면 `active=false`. 패스가 없어도 기능은 막지 않는다(표시만)."""
    record = store.latest_pass(owner)
    if record is None:
        return PassStatus(active=False)
    return PassStatus(active=True, guardianPass=payments.to_guardian_pass(record))
