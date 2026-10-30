"""호출자 구분 — 요청을 받기 전에 거치는 문 (2026-10-21 배포 준비).

예전에는 `DEV_MODE_AUTH = True` 상수 하나가 **인증 우회 + 실명 원응답 저장**을 함께 켰다.
끄면 모든 API가 401로 막혀, 켠 채로는 개인정보가 쌓이고 끈 채로는 서비스가 멈췄다.
그래서 둘을 나눴다 (docs/decisions.md 2026-10-21):

- **원응답 저장** → `SAVE_RAW_RESPONSES` 환경변수(기본 꺼짐) — `settings.save_raw_responses()`
- **호출자 구분** → 아래 `get_current_user` = 로그인 세션이 있으면 **계정**, 없으면 기기 id(`X-Device-Id` 헤더)

라우터는 "누구의 기록인가"를 `get_current_user`의 반환값으로만 판단한다 (2026-10-22 카카오 로그인 — 라우터는 그대로).
"""

from __future__ import annotations

import hmac
import logging
import re
import threading
import time
from collections import deque
from typing import Annotated, Optional

from fastapi import Depends, Header, HTTPException, Request

from . import settings
from .services import accounts, sealing

#: 앱이 처음 실행될 때 만들어 폰에 저장하는 기기 id 형식 (UUID 등).
_DEVICE_ID_RE = re.compile(r"[A-Za-z0-9-]{8,64}")

_log = logging.getLogger("jeonseai")


def checked_device_id(x_device_id: Optional[str]) -> Optional[str]:
    """`X-Device-Id` 헤더의 형식 검사. 없으면 None, 틀리면 400, 맞으면 그 값.

    ⚠ 막는 값 세 가지(사칭 차단):
      - 공용 통로 이름 `legacy-device` — `REQUIRE_DEVICE_ID=1`로 통로를 닫은 뒤에도 헤더 하나로
        옛 앱의 공용 기록에 들어가는 길이 남지 않게.
      - 계정 주인 앞머리 `acct-` — 기기 id를 `acct-…`로 보내 남의 **계정 기록**에 들어가는 길을 막는다
        (2026-10-22 카카오 로그인. 대소문자를 가리지 않는다).
      - 가린 기기 주인 앞머리 `dv-` (2026-10-30) — DB가 새어 주인 값을 알아도 그 값을 기기 id로 보내
        "옛 기록 옮기기"로 남의 기록을 끌어오지 못하게. 앱의 기기 id(UUID)는 16진수라 `dv-`로 시작할 수 없다.
    """
    raw = (x_device_id or "").strip()
    if not raw:
        return None
    if (
        raw == settings.LEGACY_DEVICE_ID
        or raw.lower().startswith(accounts.ACCOUNT_PREFIX)
        or raw.lower().startswith(sealing.DEVICE_OWNER_PREFIX)
        or not _DEVICE_ID_RE.fullmatch(raw)
    ):
        raise HTTPException(status_code=400, detail="기기 정보 형식이 올바르지 않아요")
    return raw


def get_current_user(
    x_device_id: Optional[str] = Header(default=None, alias="X-Device-Id"),
    authorization: Annotated[Optional[str], Header(alias="Authorization")] = None,
) -> str:
    """이 요청의 **주인** — 기록(리포트·대조 기준·판례 캐시·캐시 쪽지)과 패스가 이 값에 붙는다.

    - `X-Device-Id`가 있으면 형식부터 검사한다(틀리면 400 — [checked_device_id]).
    - `Authorization: Bearer <세션>`이 있으면: 살아 있는 세션이면 **계정 주인**(`acct-…`),
      틀리거나 만료됐으면 **401 "다시 로그인해 주세요"**(앱은 세션을 지우고 로그인을 안내한다).
    - 세션이 없으면(로그인 없이 둘러보기) **기기 id로 만든 주인 값**(열쇠가 있으면 HMAC으로 가린 `dv-…`, 없으면 원문).
      헤더도 없으면: `REQUIRE_DEVICE_ID=1`이면 400, 아니면 옛 앱이 함께 쓰는 `legacy-device`.
    """
    device_id = checked_device_id(x_device_id)
    token = accounts.bearer_token(authorization)
    if token is not None:
        session = accounts.session_for(token) if token else None
        if session is None:
            raise HTTPException(
                status_code=401,
                detail=accounts.MSG_SESSION_INVALID,
                headers={"WWW-Authenticate": 'Bearer error="invalid_token"'},
            )
        return session.owner
    if device_id is None:
        if settings.require_device_id():
            raise HTTPException(
                status_code=400,
                detail="기기 정보가 없어요. 앱을 최신 버전으로 업데이트해 주세요",
            )
        return settings.LEGACY_DEVICE_ID
    # 열쇠(DATA_SECRET)가 있으면 기기 id 원문 대신 가린 값(`dv-…`)이 주인이다 — DB가 새도 앱 행세를 못 하게(2026-10-30)
    return accounts.device_owner(device_id)


def get_pass_owner(user: str = Depends(get_current_user)) -> str:
    """계약 지킴이 패스(결제 기록)의 **주인 키** (2026-10-22, P2-1 → 같은 날 카카오 로그인).

    로그인했으면 계정(`account:acct-…`), 아니면 기기(`device:<기기 id>`). 모양은 `accounts.pass_owner_key`
    **한 함수**가 정한다 — 로그인할 때 기기의 패스를 계정으로 옮기는 것도 같은 함수를 쓴다.
    결제 라우터와 저장소는 이 값만 쓴다.
    """
    return accounts.pass_owner_key(user)


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
_CHAT_GLOBAL_DAY = ("chat*", "day")
#: 청소(_cleanup)가 절대 버리지 않는 칸 — 서버 전체 칸들.
_PINNED = (_GLOBAL, _GLOBAL_DAY, _CHAT_GLOBAL_DAY)

_MSG_HOUR = "분석을 너무 자주 했어요. 한 시간쯤 뒤에 다시 시도해 주세요"
_MSG_DAY = "오늘은 서버의 하루 분석 횟수를 다 썼어요. 내일 다시 시도해 주세요"
_MSG_CHAT_HOUR = "질문을 너무 많이 보냈어요. 잠시 뒤에 다시 물어봐 주세요"
_MSG_CHAT_DAY = "오늘은 챗봇 질문을 다 썼어요. 내일 다시 물어봐 주세요"

_hits: dict[tuple, deque[float]] = {}
_hits_lock = threading.Lock()
#: 조용해진 칸(기기 id·IP가 든 칸)을 이 간격마다 치운다 — IP를 메모리에 오래 두지 않는다(2026-10-30 보안).
#: 예전엔 칸이 2만 개를 넘을 때만 치워, 한 번 온 IP가 서버를 다시 켤 때까지 남을 수 있었다.
#: 이제 마지막 호출 뒤 1시간(_WINDOW_SECONDS) + 최대 10분이면 버린다 → 처리방침 "2시간 안에 버려요".
_CLEANUP_EVERY_SECONDS = 600.0
_last_cleanup = 0.0


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
    global _last_cleanup
    with _hits_lock:
        _hits.clear()
        _last_cleanup = 0.0


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


def _requester_limits(request: Request, device_id: str) -> list:
    ip = client_ip(request)
    return [
        ((device_id, ip), settings.rate_limit_analyze_per_hour(), _WINDOW_SECONDS, _MSG_HOUR),
        (("ip", ip), settings.rate_limit_ip_per_hour(), _WINDOW_SECONDS, _MSG_HOUR),
    ]


def _global_limits() -> list:
    return [
        (_GLOBAL, settings.rate_limit_global_per_hour(), _WINDOW_SECONDS, _MSG_HOUR),
        (_GLOBAL_DAY, settings.rate_limit_global_per_day(), _DAY_SECONDS, _MSG_DAY),
    ]


def limit_analyze(request: Request, device_id: str) -> None:
    """분석·대조 1건을 네 겹 모두로 센다. 하나라도 상한에 닿아 있으면 **세지 않고** 429.

    확인과 기록을 한 잠금 안에서 하므로, 동시에 몰려 와도 상한을 넘겨 통과하지 못한다.
    라우터는 둘로 나눠 부른다 — [limit_requester](입력 검사 직후) + [limit_global](크레딧을 쓰기 직전).
    """
    _count(
        _requester_limits(request, device_id) + _global_limits(),
        day_key=_GLOBAL_DAY,
        day_env="RATE_LIMIT_GLOBAL_PER_DAY",
    )


def limit_requester(request: Request, device_id: str) -> None:
    """한 사람(기기 id × IP)·한 주소(IP)의 분석 횟수 — 입력 검사를 마친 직후에 센다(촬영 거절도 센다)."""
    _count(_requester_limits(request, device_id), day_key=_GLOBAL_DAY, day_env="RATE_LIMIT_GLOBAL_PER_DAY")


def limit_global() -> None:
    """서버 전체(시간·하루) 분석 횟수 — **실제로 크레딧을 쓰기 직전에만** 센다(2026-10-30 보안).

    예전엔 같은 사진 캐시 적중·촬영 거절(크레딧 0원)도 서버 전체 칸을 깎았다. 그래서 흰 그림 한 장을
    주소 몇 개로 반복해 보내면 하루 상한(500)을 채워, 부스 시연까지 하루 종일 429가 될 수 있었다.
    """
    _count(_global_limits(), day_key=_GLOBAL_DAY, day_env="RATE_LIMIT_GLOBAL_PER_DAY")


def limit_chat(request: Request, device_id: str) -> None:
    """챗봇 질문 1건을 센다 (2026-10-24 — 질문마다 Solar를 부르게 되면서). 분석과 칸이 따로다."""
    ip = client_ip(request)
    _count(
        [
            (("chat", device_id, ip), settings.rate_limit_chat_per_hour(), _WINDOW_SECONDS, _MSG_CHAT_HOUR),
            (("chat-ip", ip), settings.rate_limit_chat_ip_per_hour(), _WINDOW_SECONDS, _MSG_CHAT_HOUR),
            (_CHAT_GLOBAL_DAY, settings.rate_limit_chat_global_per_day(), _DAY_SECONDS, _MSG_CHAT_DAY),
        ],
        day_key=_CHAT_GLOBAL_DAY,
        day_env="RATE_LIMIT_CHAT_GLOBAL_PER_DAY",
    )


def _count(limits: list, *, day_key: tuple, day_env: str) -> None:
    limits = [item for item in limits if item[1] > 0]
    now = time.monotonic()
    with _hits_lock:
        for key, limit, window, msg in limits:
            bucket = _hits.get(key)
            if bucket is not None:
                _trim(bucket, now, window)
                if len(bucket) >= limit:
                    if key == day_key:
                        # 운영자가 Railway 로그에서 바로 알아보게 남긴다(결선 날이면 상한을 올린다).
                        _log.warning(f"[속도 제한] 서버 하루 상한 {limit}회에 닿음 — {day_env}")
                    raise HTTPException(status_code=429, detail=msg)
        for key, _, _, _ in limits:
            _hits.setdefault(key, deque()).append(now)
        _maybe_cleanup(now)


def _maybe_cleanup(now: float) -> None:
    """칸이 너무 많거나, 마지막으로 치운 지 10분이 지났으면 치운다. ⚠ `_hits_lock`을 쥔 채로 부른다."""
    global _last_cleanup
    if len(_hits) > _MAX_BUCKETS or now - _last_cleanup >= _CLEANUP_EVERY_SECONDS:
        _cleanup(now)
        _last_cleanup = now


def sweep_rate_limits(now: float | None = None) -> int:
    """조용해진 칸을 지금 치운다 → 남은 칸 수. 요청이 끊긴 동안에도 IP가 남지 않게 뒤쪽 스레드가 부른다."""
    global _last_cleanup
    at = time.monotonic() if now is None else now
    with _hits_lock:
        _cleanup(at)
        _last_cleanup = at
        return len(_hits)


_sweeper_started = False


def start_rate_limit_sweeper() -> None:
    """10분마다 [sweep_rate_limits]를 부르는 뒤쪽 스레드를 **한 번만** 띄운다(서버 시작 때)."""
    global _sweeper_started
    with _hits_lock:
        if _sweeper_started:
            return
        _sweeper_started = True

    def _loop() -> None:
        while True:
            time.sleep(_CLEANUP_EVERY_SECONDS)
            try:
                sweep_rate_limits()
            except Exception:  # noqa: BLE001 — 청소가 실패해도 서버는 돈다
                pass

    threading.Thread(target=_loop, name="rate-limit-sweeper", daemon=True).start()
