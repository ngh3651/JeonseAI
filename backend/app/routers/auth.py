"""로그인 라우터 (계약 §3.15~§3.18 — 2026-10-22, P2-1 카카오 로그인).

- POST   /api/auth/kakao    카카오 액세스 토큰 → 확인(우리 앱의 토큰인가) → 세션 + **이 기기의 기록을 계정으로**
- POST   /api/auth/logout   이 세션만 끝낸다 (다른 폰의 로그인은 그대로)
- GET    /api/me            로그인 상태 `{loggedIn, provider, customerKey}`
- DELETE /api/me            **회원 탈퇴** — 그 계정의 기록·세션·패스를 전부 지운다

"로그인 없이 둘러보기"(기기 id)는 그대로 남는다 — 부스에서 카카오가 막혀도 분석은 돼야 한다.
⚠ 동기(def) 핸들러다 — 카카오 호출·기록 DB가 막히는 호출이라 스레드풀에서 돌게 한다.
"""

from __future__ import annotations

import logging
from typing import Annotated, Optional

from fastapi import APIRouter, Depends, Header, HTTPException

from .. import settings
from ..dependencies import checked_device_id, get_current_user
from ..schemas.contract import DisplayNameRequest, KakaoLoginRequest, MeResponse, SessionResponse
from ..services import accounts

_log = logging.getLogger("jeonseai")

router = APIRouter(prefix="/api", tags=["auth"])


@router.post("/auth/kakao", response_model=SessionResponse)
def kakao_login(
    body: KakaoLoginRequest,
    x_device_id: Optional[str] = Header(default=None, alias="X-Device-Id"),
) -> SessionResponse:
    """카카오 SDK가 준 액세스 토큰으로 로그인한다. 카카오에서는 **회원번호만** 받는다."""
    device_id = checked_device_id(x_device_id)  # 형식이 틀리면 400 (기록을 옮길 기기)
    if not settings.kakao_login_ready():
        if settings.kakao_app_id() and settings.account_hash_secret():
            _log.warning(
                "[로그인] ⚠ ACCOUNT_HASH_SECRET가 너무 짧아 카카오 로그인을 닫아 둠 "
                f"({settings.ACCOUNT_HASH_SECRET_MIN_LENGTH}자 이상)"
            )
        raise HTTPException(status_code=503, detail=accounts.MSG_NOT_READY)
    try:
        member_id = accounts.kakao_member_id(body.accessToken, app_id=settings.kakao_app_id())
    except accounts.TokenRejected as e:
        raise HTTPException(status_code=401, detail=accounts.MSG_TOKEN_REJECTED) from e
    except accounts.KakaoUnavailable as e:
        raise HTTPException(status_code=502, detail=accounts.MSG_KAKAO_UNAVAILABLE) from e

    # 회원번호는 여기서 계정 키로 바꾸고 버린다 — 아래로는 주인 값(acct-…)만 흐른다.
    owner = accounts.owner_for(accounts.account_key(member_id, secret=settings.account_hash_secret()))
    del member_id
    token, expires_at = accounts.open_session(owner, provider=accounts.PROVIDER_KAKAO)
    moved = accounts.claim_device_records(device_id, owner)
    _log.info(f"[로그인] 카카오 로그인 — 세션 {settings.session_days()}일 · 옮긴 리포트 {moved}건")
    return SessionResponse(
        sessionToken=token, expiresAt=expires_at, customerKey=accounts.customer_key(owner)
    )


@router.post("/auth/logout", status_code=204)
def logout(
    authorization: Annotated[Optional[str], Header(alias="Authorization")] = None,
) -> None:
    """이 세션을 지운다. 로그인하지 않았거나 이미 끝난 세션이어도 204(몇 번을 불러도 같다)."""
    token = accounts.bearer_token(authorization)
    if token:
        accounts.close_session(token)


@router.get("/me", response_model=MeResponse)
def me(user: str = Depends(get_current_user)) -> MeResponse:
    """지금 로그인 상태. 세션이 틀리거나 만료됐으면 401(`get_current_user`) — 앱은 세션을 지운다."""
    if accounts.is_account_owner(user):
        return MeResponse(
            loggedIn=True,
            provider=accounts.PROVIDER_KAKAO,
            customerKey=accounts.customer_key(user),
            displayName=accounts.display_name(user),
        )
    return MeResponse(loggedIn=False)


@router.post("/me/name", response_model=MeResponse)
def set_my_name(body: DisplayNameRequest, user: str = Depends(get_current_user)) -> MeResponse:
    """표시 이름 정하기 (2026-10-24) — 홈 인사말 "○○님 안녕하세요". 로그인했을 때만. 빈 값이면 지운다."""
    if not accounts.is_account_owner(user):
        raise HTTPException(status_code=401, detail="로그인한 뒤에 이름을 정할 수 있어요")
    try:
        accounts.set_display_name(user, body.displayName)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return me(user)


@router.delete("/me", status_code=204)
def delete_me(user: str = Depends(get_current_user)) -> None:
    """회원 탈퇴 — 이 계정의 리포트·대조 기준·캐시 쪽지·패스·세션을 **전부** 지운다(되돌릴 수 없다).

    카카오와의 연결 끊기(unlink)는 앱이 카카오 SDK로 한다(카카오 토큰은 앱에만 있다).
    """
    if not accounts.is_account_owner(user):
        raise HTTPException(status_code=401, detail="로그인한 뒤에 탈퇴할 수 있어요")
    accounts.delete_account(user)
