"""카카오 로그인 — 토큰 확인 · 계정 키 · 세션 · 기록 옮기기 · 회원 탈퇴 (2026-10-22, P2-1).

흐름: 앱의 카카오 SDK가 로그인을 마치면 **카카오 액세스 토큰**을 준다 → 앱이 `POST /api/auth/kakao`로 넘긴다
→ 서버가 카카오 `GET /v1/user/access_token_info`에 묻는다(살아 있는 토큰인가 · 어느 앱의 토큰인가 · 회원번호)
→ **앱 ID가 우리 앱(`KAKAO_APP_ID`)과 같을 때만** 통과 → 계정 키를 만들고 세션을 연다 → 그 기기의 기록을 계정으로 옮긴다.

지키는 것:
- 카카오에서 받는 것은 **회원번호 하나**다. 이름·이메일·닉네임·프로필 사진은 받지도 묻지도 않는다
  (사용자 정보 API `/v2/user/me`를 부르지 않는다 — 토큰 정보 API만 쓴다).
- 회원번호 **원문은 어디에도 남기지 않는다**(DB·로그·응답). 계정 키 = HMAC-SHA256(`ACCOUNT_HASH_SECRET`, "kakao:"+회원번호),
  기록의 주인 = `acct-` + 계정 키 앞 32자리. 비밀 없이 주인 값만으로는 회원번호를 되찾을 수 없다.
- 세션 토큰은 무작위 값(`secrets.token_urlsafe(32)`)이고 DB에는 **SHA-256만** 남는다 — DB가 새어도 그 값으로 로그인할 수 없다.
- 카카오 호출은 이 파일의 `_get` 한 곳뿐이다 — 테스트는 이것을 바꿔 끼운다(실제 호출 0회).

저장: 기록 DB(`app.db`)의 `sessions` 표 — 이 모듈이 따로 연다(`store.db_path()` — payments·analysis_cache와 같은 방식).
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import secrets
import sqlite3
import threading
from contextlib import closing
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import requests

from .. import settings
from . import analysis_cache, payments, store

_log = logging.getLogger("jeonseai")

KAKAO_API_BASE = "https://kapi.kakao.com"
#: 액세스 토큰 정보 보기 — 응답 `{id: 회원번호, expires_in: 남은 초, app_id: 앱 ID}` (카카오 SDK `AccessTokenInfo`와 같은 칸).
TOKEN_INFO_PATH = "/v1/user/access_token_info"
_TIMEOUT_SECONDS = 10

PROVIDER_KAKAO = "kakao"
#: 계정 주인 앞머리. 기기 id로 이 앞머리를 보내면 400이다(사칭 차단 — `dependencies.get_current_user`).
ACCOUNT_PREFIX = "acct-"
#: 주인 값에 쓰는 계정 키 길이(16진수 32자리 = 128비트).
_OWNER_HEX = 32
#: `Authorization` 헤더로 받는 세션 토큰의 최대 길이 — 우리 토큰은 43자다. 터무니없이 긴 값은 DB까지 가지 않는다.
_MAX_TOKEN_LENGTH = 256

MSG_NOT_READY = "카카오 로그인이 아직 준비되지 않았어요"
MSG_TOKEN_REJECTED = "카카오 로그인을 확인하지 못했어요. 다시 로그인해 주세요"
MSG_KAKAO_UNAVAILABLE = "카카오에 연결하지 못했어요. 잠시 후 다시 시도해 주세요"
#: 세션이 틀리거나 만료됐을 때 — 앱은 이 401을 받으면 세션을 지우고 로그인을 안내한다.
MSG_SESSION_INVALID = "로그인이 끝났어요. 다시 로그인해 주세요"


# ── 카카오 호출 (테스트는 이 함수를 바꿔 끼운다) ────────────────────────────────


def _get(path: str, access_token: str) -> requests.Response:
    return requests.get(
        f"{KAKAO_API_BASE}{path}",
        headers={"Authorization": f"Bearer {access_token}"},
        timeout=_TIMEOUT_SECONDS,
    )


class TokenRejected(Exception):
    """카카오가 토큰을 받지 않았거나(만료·가짜) **다른 앱의 토큰**이다 → 401."""


class KakaoUnavailable(Exception):
    """카카오에 닿지 못했거나 응답이 이상하다 → 502 (잠시 뒤 다시)."""


def _kakao_code(resp: requests.Response) -> str:
    try:
        return str(resp.json().get("code"))
    except Exception:  # noqa: BLE001 — 로그용 숫자 하나
        return "?"


def kakao_member_id(access_token: str, *, app_id: str) -> int:
    """카카오 토큰 → **회원번호**. 우리 앱(`app_id`)의 토큰이 아니면 [TokenRejected].

    ⚠ 돌려준 회원번호는 [account_key]로 바로 바꾸고 버린다 — 로그·DB·응답에 쓰지 않는다.
    """
    try:
        resp = _get(TOKEN_INFO_PATH, access_token)
    except requests.RequestException as e:
        _log.error(f"[로그인] ⚠ 카카오 토큰 확인 API에 닿지 못함 ({type(e).__name__})")
        raise KakaoUnavailable() from e
    if resp.status_code in (400, 401):
        # -401: 만료·없는 토큰 / -2: 형식이 틀린 토큰 — 사용자가 다시 로그인하면 풀린다
        _log.info(f"[로그인] 카카오가 토큰을 받지 않음 (HTTP {resp.status_code}, 코드 {_kakao_code(resp)})")
        raise TokenRejected()
    if resp.status_code != 200:
        _log.error(f"[로그인] ⚠ 카카오 토큰 확인 API 오류 HTTP {resp.status_code} (코드 {_kakao_code(resp)})")
        raise KakaoUnavailable()
    try:
        body = resp.json()
    except ValueError as e:
        _log.error("[로그인] ⚠ 카카오 토큰 확인 응답이 JSON이 아님")
        raise KakaoUnavailable() from e
    if not isinstance(body, dict) or str(body.get("app_id")) != app_id.strip():
        # 다른 앱에서 받은 카카오 토큰으로 우리 서버에 들어오는 길을 막는다.
        _log.warning("[로그인] ⚠ 우리 앱의 토큰이 아니라 거부함 (앱 ID 불일치)")
        raise TokenRejected()
    member = body.get("id")
    if not isinstance(member, int) or isinstance(member, bool) or member <= 0:
        _log.warning("[로그인] ⚠ 카카오 응답에 회원번호가 없어 거부함")
        raise TokenRejected()
    return member


# ── 계정 키 · 주인 값 ─────────────────────────────────────────────────────────


def account_key(member_id: int, *, secret: str) -> str:
    """HMAC-SHA256(비밀, "kakao:"+회원번호) — 64자리 16진수. 같은 회원번호면 늘 같은 값."""
    return hmac.new(
        secret.encode("utf-8"), f"kakao:{member_id}".encode("utf-8"), hashlib.sha256
    ).hexdigest()


def owner_for(key: str) -> str:
    """계정 키 → 기록의 주인 값 `acct-<앞 32자리>`."""
    return ACCOUNT_PREFIX + key[:_OWNER_HEX]


def is_account_owner(owner: str) -> bool:
    return owner.startswith(ACCOUNT_PREFIX)


def pass_owner_key(owner: str) -> str:
    """계약 지킴이 패스(결제 기록)의 **주인 키** — 모양은 **이 함수 한 곳에서만** 정한다.

    `dependencies.get_pass_owner`가 요청마다 이것을 부르고, 로그인할 때 패스를 옮기는 것도 이것을 쓴다.
    로그인했으면 `account:<주인>`, 아니면 `device:<기기 id>`(2026-10-22 결제 작업이 정한 모양 그대로).
    """
    return f"account:{owner}" if is_account_owner(owner) else f"device:{owner}"


def customer_key(owner: str) -> str:
    """토스 결제위젯 `customerKey` — 계정 주인에서 만든다(`acct_` + 해시 40자 = 45자, 토스 규칙 2~50자).

    회원번호와 무관한 값이다(주인 값 자체가 비밀 키로 만든 HMAC이다). 앱은 로그인하면 이 값을 쓴다.
    """
    digest = hashlib.sha256(f"jeonseai-pass:{owner}".encode("utf-8")).hexdigest()
    return f"acct_{digest[:40]}"


# ── 세션 (기록 DB의 sessions 표) ────────────────────────────────────────────────

_SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
    token_hash TEXT NOT NULL PRIMARY KEY,
    owner      TEXT NOT NULL,
    provider   TEXT NOT NULL,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL
)
"""
_INDEX = "CREATE INDEX IF NOT EXISTS idx_sessions_owner ON sessions (owner)"

_db_lock = threading.Lock()


def _execute(sql: str, params: tuple = ()) -> list[tuple]:
    path = store.db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with _db_lock, closing(sqlite3.connect(path, timeout=10)) as conn, conn:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute(_SCHEMA)
        conn.execute(_INDEX)
        return conn.execute(sql, params).fetchall()


def _now() -> datetime:
    return datetime.now(timezone.utc)  # 테스트가 바꿔 끼운다(시간이 지난 것처럼)


def _iso(when: datetime) -> str:
    return when.isoformat(timespec="milliseconds")


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class Session:
    owner: str
    provider: str
    expires_at: str


def open_session(owner: str, *, provider: str = PROVIDER_KAKAO) -> tuple[str, str]:
    """새 세션 → (세션 토큰, 만료 시각). 토큰 원문은 돌려주기만 하고 DB에는 SHA-256만 넣는다.

    여는 김에 만료된 세션들을 치운다(표가 끝없이 커지지 않게).
    """
    token = secrets.token_urlsafe(32)
    now = _now()
    expires = _iso(now + timedelta(days=settings.session_days()))
    _execute(
        "INSERT INTO sessions (token_hash, owner, provider, created_at, expires_at) VALUES (?, ?, ?, ?, ?)",
        (_hash_token(token), owner, provider, _iso(now), expires),
    )
    _execute("DELETE FROM sessions WHERE expires_at <= ?", (_iso(now),))
    return token, expires


def session_for(token: str) -> Session | None:
    """세션 토큰 → 세션. 없거나 만료됐으면 None(만료된 것은 지운다)."""
    if not token or len(token) > _MAX_TOKEN_LENGTH:
        return None
    digest = _hash_token(token)
    rows = _execute("SELECT owner, provider, expires_at FROM sessions WHERE token_hash = ?", (digest,))
    if not rows:
        return None
    owner, provider, expires_at = rows[0]
    try:
        expired = datetime.fromisoformat(expires_at) <= _now()
    except ValueError:
        expired = True  # 읽을 수 없는 시각 = 지난 것으로
    if expired:
        _execute("DELETE FROM sessions WHERE token_hash = ?", (digest,))
        return None
    return Session(owner=owner, provider=provider, expires_at=expires_at)


def close_session(token: str) -> None:
    """로그아웃 — 그 세션만 지운다(다른 폰의 로그인은 그대로). 없는 토큰이어도 조용히 끝난다."""
    if token and len(token) <= _MAX_TOKEN_LENGTH:
        _execute("DELETE FROM sessions WHERE token_hash = ?", (_hash_token(token),))


def bearer_token(authorization: str | None) -> str | None:
    """`Authorization: Bearer <토큰>` → 토큰. 헤더가 없거나 비었으면 None, 모양이 틀리면 빈 문자열(= 틀린 세션)."""
    raw = (authorization or "").strip()
    if not raw:
        return None
    scheme, _, value = raw.partition(" ")
    if scheme.lower() != "bearer":
        return ""
    return value.strip()


# ── 로그인 · 탈퇴 ─────────────────────────────────────────────────────────────


def claim_device_records(device_id: str | None, owner: str) -> int:
    """로그인하는 순간 — **그 기기의 기록을 계정으로 옮긴다**(리포트·대조 기준·판례 캐시·캐시 쪽지·패스). 옮긴 리포트 수.

    - 공용 통로(`legacy-device`)는 옮기지 않는다 — 헤더 없는 옛 앱들이 **함께 쓰는 칸**이라 남의 기록이 섞여 있다.
    - 여러 번 불러도 같다(옮길 것이 없으면 0) — 중간에 끊겨도 다음 로그인 때 나머지를 옮긴다.
    - 옮긴 뒤 그 기기로 '로그인 없이 둘러보기'를 하면 옮긴 기록은 안 보인다(이제 계정의 것이다).
    """
    if not device_id or device_id == settings.LEGACY_DEVICE_ID or is_account_owner(device_id):
        return 0
    moved = store.move_owner(device_id, owner)
    analysis_cache.move_owner(device_id, owner)
    passes = payments.move_owner(pass_owner_key(device_id), pass_owner_key(owner))
    if moved or passes:
        _log.info(f"[로그인] 이 기기의 기록을 계정으로 옮김 — 리포트 {moved}건 · 패스 {passes}건")
    return moved


def delete_account(owner: str) -> None:
    """회원 탈퇴 — 그 계정의 **기록·세션·패스를 전부** 지운다(되돌릴 수 없다)."""
    if not is_account_owner(owner):
        raise ValueError("계정 주인이 아니에요")
    reports = store.delete_owner(owner)
    analysis_cache.delete_owner(owner)
    passes = payments.delete_owner(pass_owner_key(owner))
    _execute("DELETE FROM sessions WHERE owner = ?", (owner,))
    _log.info(f"[탈퇴] 계정의 기록을 모두 지움 — 리포트 {reports}건 · 패스 {passes}건 · 세션 전부")


def sessions_for_test() -> list[tuple]:
    """테스트용 — 표에 실제로 무엇이 남았는지(토큰 원문·회원번호가 없는지) 본다."""
    return _execute("SELECT * FROM sessions")
