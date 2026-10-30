"""저장 데이터 잠금 (2026-10-30 보안) — DB 파일이 통째로 새어도 내용을 읽지 못하게.

무엇을 하나:
- **칸 암호화**: 리포트·대조 기준·다시 판정 재료·표시 이름을 DB에 쓸 때 AES(Fernet)로 잠그고, 읽을 때 푼다.
  잠근 값은 `enc1:`로 시작한다. 이 기능 전에 쓴 평문 행도 그대로 읽는다(서버가 켜질 때 뒤에서 잠근다).
- **기기 id 가리기**: 기록의 주인 칸에 기기 id 원문 대신 HMAC 값(`dv-…`)을 쓴다. DB가 새어도
  그 값으로 앱 행세를 해 앞으로의 기록을 엿볼 수 없다.

열쇠는 환경변수 `DATA_SECRET` **하나**다(32자 이상 무작위). 여기서 용도별 열쇠를 따로 뽑는다(같은 열쇠를 두 곳에 쓰지 않게).
⚠ **한 번 정하면 바꾸지 않는다** — 바꾸면 잠근 기록을 못 읽고, 기기 주인 값이 달라져 기록이 안 보인다.
비어 있으면(로컬 개발·테스트) 예전처럼 평문으로 쓰고 기기 id도 그대로 쓴다 — 서버가 켜질 때 로그 `[보안]` 한 줄로 보인다.

막는 것: 볼륨·백업·DB 파일만 새는 경우. 서버 프로세스 자체를 빼앗기면(환경변수까지) 막지 못한다.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import threading

from cryptography.fernet import Fernet, InvalidToken

from .. import settings

_log = logging.getLogger("jeonseai")

#: 잠근 값의 앞머리 — 평문 JSON(`{`로 시작)과 섞여 있어도 가려 읽는다
PREFIX = "enc1:"
#: 기기 주인 값의 앞머리 — 계정(`acct-`)·옛 공용 칸(`legacy-device`)과 겹치지 않는다
DEVICE_OWNER_PREFIX = "dv-"
#: `DATA_SECRET` 최소 길이 — 짧으면 쓰지 않는다(약한 열쇠로 잠근 척하지 않게)
MIN_SECRET_LENGTH = 32

_cache_lock = threading.Lock()
_cached: tuple[str, Fernet | None, bytes | None] | None = None


class SealedUnavailable(Exception):
    """잠긴 값인데 열쇠가 없거나 맞지 않는다 — 그 행은 읽지 못한 것으로 친다."""


def _keys() -> tuple[Fernet | None, bytes | None]:
    """(칸 암호화 열쇠, 기기 id 가리기 열쇠). 비밀이 없거나 짧으면 (None, None)."""
    global _cached
    secret = settings.env_str("DATA_SECRET")
    with _cache_lock:
        if _cached is not None and _cached[0] == secret:
            return _cached[1], _cached[2]
        if len(secret) < MIN_SECRET_LENGTH:
            if secret:
                _log.error(
                    f"[보안] ⚠ DATA_SECRET가 너무 짧아 저장 데이터 잠금을 켜지 않음 ({MIN_SECRET_LENGTH}자 이상)"
                )
            fernet, owner_key = None, None
        else:
            raw = secret.encode("utf-8")
            enc = hmac.new(raw, b"jeonseai:db-encryption:v1", hashlib.sha256).digest()
            fernet = Fernet(base64.urlsafe_b64encode(enc))
            owner_key = hmac.new(raw, b"jeonseai:device-owner:v1", hashlib.sha256).digest()
        _cached = (secret, fernet, owner_key)
        return fernet, owner_key


def enabled() -> bool:
    """저장 데이터 잠금이 켜져 있나."""
    return _keys()[0] is not None


def key_fingerprint() -> str | None:
    """지금 열쇠의 지문(16자) — 열쇠 자체는 드러나지 않는다. 열쇠가 없으면 None.

    DB(`meta.data_key_fp`)에 적어 두고, 서버가 켜질 때 견준다 — 열쇠가 바뀌었거나 빠졌으면 크게 알린다
    (바뀐 열쇠로는 잠근 기록을 못 열고 기기 기록이 안 보인다 — 2026-10-30 보안 리뷰).
    """
    if not enabled():
        return None
    secret = settings.env_str("DATA_SECRET").encode("utf-8")
    return hmac.new(secret, b"jeonseai:key-check:v1", hashlib.sha256).hexdigest()[:16]


def is_sealed(value: str | None) -> bool:
    return bool(value) and value.startswith(PREFIX)


def seal(text: str) -> str:
    """DB에 쓰기 직전 — 열쇠가 있으면 잠근 값, 없으면 그대로."""
    fernet, _ = _keys()
    if fernet is None:
        return text
    return PREFIX + fernet.encrypt(text.encode("utf-8")).decode("ascii")


def unseal(value: str) -> str:
    """DB에서 읽은 직후 — 잠근 값이면 풀고, 옛 평문이면 그대로. 풀 수 없으면 [SealedUnavailable]."""
    if not is_sealed(value):
        return value
    fernet, _ = _keys()
    if fernet is None:
        raise SealedUnavailable("DATA_SECRET가 없어 잠긴 기록을 읽을 수 없어요")
    try:
        return fernet.decrypt(value[len(PREFIX):].encode("ascii")).decode("utf-8")
    except (InvalidToken, ValueError) as e:
        raise SealedUnavailable("열쇠가 맞지 않아 잠긴 기록을 읽을 수 없어요") from e


def device_owner(device_id: str) -> str:
    """기기 id → 기록의 주인 값. 열쇠가 있으면 `dv-` + HMAC 앞 32자리, 없으면 기기 id 그대로."""
    _, owner_key = _keys()
    if owner_key is None:
        return device_id
    digest = hmac.new(owner_key, device_id.encode("utf-8"), hashlib.sha256).hexdigest()
    return DEVICE_OWNER_PREFIX + digest[:32]


def reset_for_test() -> None:
    """테스트용 — 환경변수를 바꾼 뒤 열쇠를 다시 읽게 한다."""
    global _cached
    with _cache_lock:
        _cached = None
