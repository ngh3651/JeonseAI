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

import hmac
import re
import threading
import time
from collections import deque
from typing import Optional

from fastapi import Depends, Header, HTTPException, Request

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


# ── 앱 키 (크레딧 보호의 정문) ─────────────────────────────────────────────────
# 검사 자체는 `main.py`의 미들웨어가 한다 — `/api/*` 전부에 빠짐없이 걸기 위해서다
# (라우터마다 의존성을 붙이면 새 엔드포인트에서 빠뜨린다).


def app_key_ok(sent: Optional[str]) -> bool:
    """`APP_KEY`가 비어 있으면 검사하지 않는다. 있으면 같은 값인지 **상수 시간**으로 비교한다."""
    expected = settings.app_key()
    if not expected:
        return True
    return hmac.compare_digest((sent or "").encode("utf-8"), expected.encode("utf-8"))


# ── 속도 제한 (기기 × IP, 최근 1시간) ──────────────────────────────────────────
# 외부 라이브러리 없이 메모리에 둔다. 서버가 재시작되면 초기화된다 — 크레딧을 지키는
# **과속 방지턱**이지 보안 장치가 아니다(정문은 APP_KEY).

_WINDOW_SECONDS = 3600.0
_hits: dict[tuple[str, str], deque[float]] = {}
_hits_lock = threading.Lock()


def client_ip(request: Request) -> str:
    """요청을 보낸 주소. 플랫폼 프록시(Railway 등) 뒤에서는 원래 주소가 `X-Forwarded-For`로 온다.

    ⚠ 헤더는 클라이언트가 지어낼 수 있다. 그래서 IP 하나만으로 제한하지 않고 **기기 id와 묶는다** —
      둘 다 바꿔 가며 우회하려면 APP_KEY부터 알아야 한다.
    """
    forwarded = (request.headers.get("x-forwarded-for") or "").split(",")[0].strip()
    if forwarded:
        return forwarded
    return request.client.host if request.client else "unknown"


def reset_rate_limit() -> None:
    """테스트용 — 쌓인 호출 기록을 비운다."""
    with _hits_lock:
        _hits.clear()


def limit_analyze(request: Request, device_id: str = Depends(get_current_user)) -> None:
    """분석·대조(Upstage 크레딧을 쓰는 두 API)에 거는 상한. 넘으면 429.

    상한 = `RATE_LIMIT_ANALYZE_PER_HOUR`(기본 30, 0 이하 = 제한 없음), 최근 1시간 이동 창.
    """
    limit = settings.rate_limit_analyze_per_hour()
    if limit <= 0:
        return
    key = (device_id, client_ip(request))
    now = time.monotonic()
    with _hits_lock:
        bucket = _hits.setdefault(key, deque())
        while bucket and now - bucket[0] >= _WINDOW_SECONDS:
            bucket.popleft()
        if len(bucket) >= limit:
            raise HTTPException(
                status_code=429,
                detail="분석을 너무 자주 했어요. 한 시간쯤 뒤에 다시 시도해 주세요",
            )
        bucket.append(now)
        # 빈 칸이 끝없이 쌓이지 않게 가끔 비운다
        if len(_hits) > 10_000:
            for k in [k for k, v in _hits.items() if not v]:
                _hits.pop(k, None)
