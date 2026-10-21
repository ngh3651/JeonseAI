"""호출자 구분 — 요청을 받기 전에 거치는 문 (2026-10-21 배포 준비).

예전에는 `DEV_MODE_AUTH = True` 상수 하나가 **인증 우회 + 실명 원응답 저장**을 함께 켰다.
끄면 모든 API가 401로 막혀, 켠 채로는 개인정보가 쌓이고 끈 채로는 서비스가 멈췄다.
그래서 둘을 나눴다 (docs/decisions.md 2026-10-21):

- **원응답 저장** → `SAVE_RAW_RESPONSES` 환경변수(기본 꺼짐) — `settings.save_raw_responses()`
- **호출자 구분** → 아래 `get_current_user` = 기기 id(`X-Device-Id` 헤더)

진짜 로그인(카카오)이 붙으면 이 함수가 계정 id를 돌려주게 바꾸면 된다 — 라우터는
"누구의 기록인가"를 이 함수의 반환값으로만 판단한다.
"""

from __future__ import annotations

import re
from typing import Optional

from fastapi import Header, HTTPException

from . import settings

#: 앱이 처음 실행될 때 만들어 폰에 저장하는 기기 id 형식 (UUID 등).
_DEVICE_ID_RE = re.compile(r"[A-Za-z0-9-]{8,64}")


def get_current_user(
    x_device_id: Optional[str] = Header(default=None, alias="X-Device-Id"),
) -> str:
    """이 요청을 보낸 **기기 id**. 기록(리포트·대조 기준·판례 캐시)의 주인이 된다.

    - 헤더가 있으면 형식(`[A-Za-z0-9-]{8,64}`)을 검사한다. 어긋나면 400.
    - 헤더가 없으면: `REQUIRE_DEVICE_ID=1`이면 400, 아니면 옛 앱이 함께 쓰는 `legacy-device`.
      (새 앱이 헤더를 보내기 전까지 지금 앱이 그대로 동작하게 하는 임시 통로)
    """
    raw = (x_device_id or "").strip()
    if not raw:
        if settings.require_device_id():
            raise HTTPException(
                status_code=400,
                detail="기기 정보가 없어요. 앱을 최신 버전으로 업데이트해 주세요",
            )
        return settings.LEGACY_DEVICE_ID
    # ⚠ 공용 통로 이름을 직접 보내는 것은 막는다 — `REQUIRE_DEVICE_ID=1`로 통로를 닫은 뒤에도
    #   헤더 하나로 옛 앱의 공용 기록에 들어가는 길이 남지 않게.
    if raw == settings.LEGACY_DEVICE_ID or not _DEVICE_ID_RE.fullmatch(raw):
        raise HTTPException(status_code=400, detail="기기 정보 형식이 올바르지 않아요")
    return raw
