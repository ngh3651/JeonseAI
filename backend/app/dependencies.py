"""인증 의존성 — **개발 모드 (계약 §1.2)**.

지금은 진짜 로그인 시스템(Supabase 등)이 없다. 인증을 실제로 걸어버리면 우리 스스로도
분석을 테스트할 수 없으므로, **이 함수는 토큰을 검사하지 않고 항상 통과**시킨다
(토큰이 없어도 200).

⚠ 인증 검사는 **오직 이 함수 한 곳**에 모여 있다. 나중에 진짜 인증(Supabase 등)을 켤 때는
`DEV_MODE_AUTH = False`로 바꾸고 아래 주석 처리된 실검증 블록을 채우기만 하면 된다.
그러면 `POST /api/analyze`·`DELETE /api/reports/{id}`가 토큰을 실제로 요구하게 된다.
"""

from __future__ import annotations

from typing import Optional

from fastapi import Header, HTTPException

# 개발 모드 스위치. True인 동안은 인증을 실제로 검사하지 않는다.
DEV_MODE_AUTH = True


def get_current_user(authorization: Optional[str] = Header(default=None)) -> dict:
    """인증이 필요한 엔드포인트가 의존하는 함수.

    개발 모드에서는 토큰 유무와 상관없이 항상 통과(가짜 사용자 반환)한다.
    """
    if DEV_MODE_AUTH:
        # 개발 모드: 항상 통과. 실인증 전환 시 이 분기를 제거한다.
        return {"id": "dev-user", "dev_mode": True}

    # ── 실인증을 켤 때(지금은 실행되지 않음) ────────────────────────────
    # if not authorization or not authorization.startswith("Bearer "):
    #     raise HTTPException(status_code=401, detail="로그인이 필요해요")
    # token = authorization.removeprefix("Bearer ").strip()
    # user = verify_token(token)   # 예: Supabase 토큰 검증
    # if user is None:
    #     raise HTTPException(status_code=401, detail="로그인이 필요해요")
    # return user
    raise HTTPException(status_code=401, detail="로그인이 필요해요")
