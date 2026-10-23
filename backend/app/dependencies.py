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
import logging
import re
import threading
import time
from collections import deque
from typing import Optional

from fastapi import Header, HTTPException, Request

from . import settings

#: 앱이 처음 실행될 때 만들어 폰에 저장하는 기기 id 형식 (UUID 등).
_DEVICE_ID_RE = re.compile(r"[A-Za-z0-9-]{8,64}")

_log = logging.getLogger("jeonseai")


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


# ── 속도 제한 (최근 1시간 세 겹 + 하루 한 겹) ─────────────────────────────────────
# 외부 라이브러리 없이 메모리에 둔다. 서버가 재시작되면 초기화된다 — 크레딧을 지키는
# **과속 방지턱**이지 보안 장치가 아니다(정문은 APP_KEY).
#
# 2026-10-22 리뷰 반영: (기기 id, IP) 한 겹만 세면 `X-Device-Id`를 바꿔 가며 보내는 것만으로
# 끝없이 통과한다(리뷰어가 같은 IP에서 무작위 id 100개를 보내 전부 통과). 그래서 세 겹을 **모두** 통과해야 한다:
#   ① 기기 id × IP   `RATE_LIMIT_ANALYZE_PER_HOUR`(기본 30)    — 한 사람
#   ② IP 하나        `RATE_LIMIT_IP_PER_HOUR`(기본 60)         — id를 바꿔도 같은 주소면 함께 센다
#   ③ 서버 전체      `RATE_LIMIT_GLOBAL_PER_HOUR`(기본 300)    — 주소까지 바꿔도 크레딧 상한은 남는다
#   ④ 서버 전체·하루 `RATE_LIMIT_GLOBAL_PER_DAY`(기본 500)     — 최근 24시간. 앱 키가 새어 나가도 하루 지출에 뚜껑
#                                                                (2026-10-22, APK를 공개 링크로 내보내면서 추가)
# 0 이하로 둔 겹은 끈다.
# ⚠ 부스 폰들이 **같은 와이파이(같은 IP)**를 쓰면 ②를 함께 쓴다 → 결선 날에는 ②③을 올려 둔다(NOW.md).
#
# **언제 세나**: 라우터가 입력 검사(사진 장수·용량·리포트 존재 등)를 모두 통과시킨 뒤, 외부 API를
# 부르기 **직전에** `limit_analyze`를 부른다. 그래서 400·404·413·422로 거절된 요청과 '기준 없음'처럼
# 일을 하지 않은 대조는 세지 않는다. 일을 시작한 뒤의 실패(IE 오류 등)는 크레딧을 썼으므로 센다.

_WINDOW_SECONDS = 3600.0
_DAY_SECONDS = 86400.0
#: 기억하는 칸의 최대 개수 — 넘으면 마지막 호출이 가장 오래된 칸부터 버린다(메모리 상한).
_MAX_BUCKETS = 20_000
_GLOBAL = ("*", "*")
_GLOBAL_DAY = ("*", "day")
#: 청소(_cleanup)가 절대 버리지 않는 칸 — 서버 전체 칸들.
_PINNED = (_GLOBAL, _GLOBAL_DAY)

_MSG_HOUR = "분석을 너무 자주 했어요. 한 시간쯤 뒤에 다시 시도해 주세요"
_MSG_DAY = "오늘은 서버의 하루 분석 횟수를 다 썼어요. 내일 다시 시도해 주세요"

_hits: dict[tuple[str, str], deque[float]] = {}
_hits_lock = threading.Lock()


def client_ip(request: Request) -> str:
    """요청을 보낸 주소. 플랫폼 프록시(Railway 등) 뒤에서는 원래 주소가 `X-Forwarded-For` 맨 앞에 온다.

    ⚠ 이 헤더는 **프록시 앞에서는** 클라이언트가 지어낼 수 있다. Railway는 가장자리에서 덮어쓴다고
      안내하지만, 믿을 수 없는 환경에서도 크레딧 상한이 남도록 ③ 서버 전체 상한을 따로 둔다.
    """
    forwarded = (request.headers.get("x-forwarded-for") or "").split(",")[0].strip()
    if forwarded:
        return forwarded
    return request.client.host if request.client else "unknown"


def reset_rate_limit() -> None:
    """테스트용 — 쌓인 호출 기록을 비운다."""
    with _hits_lock:
        _hits.clear()


def _trim(bucket: deque[float], now: float, window: float = _WINDOW_SECONDS) -> None:
    while bucket and now - bucket[0] >= window:
        bucket.popleft()


def _cleanup(now: float) -> None:
    """마지막 호출이 1시간보다 오래된 칸은 버리고, 그래도 많으면 가장 오래 조용했던 칸부터 버린다.

    ⚠ `_hits_lock`을 쥔 채로 부른다. 서버 전체 칸(`_PINNED` — 시간·하루)은 버리지 않는다.
    """
    stale = [k for k, b in _hits.items() if k not in _PINNED and (not b or now - b[-1] >= _WINDOW_SECONDS)]
    for key in stale:
        _hits.pop(key, None)
    overflow = len(_hits) - _MAX_BUCKETS
    if overflow > 0:
        quietest = sorted((k for k in _hits if k not in _PINNED), key=lambda k: _hits[k][-1])
        for key in quietest[:overflow]:
            _hits.pop(key, None)


def limit_analyze(request: Request, device_id: str) -> None:
    """분석·대조 1건을 센다. 네 겹 중 하나라도 상한에 닿아 있으면 **세지 않고** 429.

    라우터가 입력 검사를 마친 뒤, 외부 API를 부르기 직전에 부른다(위 '언제 세나').
    확인과 기록을 한 잠금 안에서 하므로, 동시에 몰려 와도 상한을 넘겨 통과하지 못한다.
    """
    ip = client_ip(request)
    limits = [
        ((device_id, ip), settings.rate_limit_analyze_per_hour(), _WINDOW_SECONDS),
        (("ip", ip), settings.rate_limit_ip_per_hour(), _WINDOW_SECONDS),
        (_GLOBAL, settings.rate_limit_global_per_hour(), _WINDOW_SECONDS),
        (_GLOBAL_DAY, settings.rate_limit_global_per_day(), _DAY_SECONDS),
    ]
    limits = [(key, limit, window) for key, limit, window in limits if limit > 0]
    now = time.monotonic()
    with _hits_lock:
        for key, limit, window in limits:
            bucket = _hits.get(key)
            if bucket is not None:
                _trim(bucket, now, window)
                if len(bucket) >= limit:
                    if key == _GLOBAL_DAY:
                        # 운영자가 Railway 로그에서 바로 알아보게 남긴다(결선 날이면 상한을 올린다).
                        _log.warning(f"[속도 제한] 서버 하루 상한 {limit}회에 닿음 — RATE_LIMIT_GLOBAL_PER_DAY")
                    raise HTTPException(
                        status_code=429,
                        detail=_MSG_DAY if key == _GLOBAL_DAY else _MSG_HOUR,
                    )
        for key, _, _ in limits:
            _hits.setdefault(key, deque()).append(now)
        if len(_hits) > _MAX_BUCKETS:
            _cleanup(now)
