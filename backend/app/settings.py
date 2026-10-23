"""서버 설정 — 환경변수를 **부를 때마다** 읽는다 (2026-10-21 배포 준비).

왜 이 파일이 생겼나:
예전에는 `dependencies.DEV_MODE_AUTH = True` 상수 하나가 **인증 우회**와 **실명 원응답 저장**을
함께 켰다. 끄면 모든 API가 401로 막혀 클라우드에 올릴 수 없었다. 또 몇몇 모듈은 import 순간에
`os.environ`을 읽어서, `backend/.env`가 읽히기 **전**의 값(=기본값)으로 굳었다.

여기서 지키는 두 가지:
1. 값은 **호출 시점**에 읽는다 — 테스트의 `monkeypatch.setenv`, 로컬 `.env`, 클라우드 플랫폼의
   Variables(Railway) 모두 같은 방식으로 먹는다.
2. `.env`는 **먼저** 한 번 읽되, 이미 있는 환경변수를 덮지 않는다 — 플랫폼 값이 이긴다.

⚠ 여기에는 **이름과 기본값만** 둔다. 키 값 자체를 로그·응답에 내보내는 함수는 만들지 않는다.
"""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

BACKEND_ROOT = Path(__file__).resolve().parents[1]

#: `X-Device-Id`를 보내지 않는 옛 앱이 **함께** 쓰는 기기 id.
#: 새 앱이 헤더를 보내기 전까지 지금 앱이 그대로 동작하게 하는 임시 통로다
#: (`REQUIRE_DEVICE_ID=1`이면 닫힌다).
LEGACY_DEVICE_ID = "legacy-device"

_TRUTHY = {"1", "true", "yes", "on"}
_dotenv_loaded = False


def load_env() -> None:
    """`backend/.env`를 한 번만 읽는다. 이미 설정된 환경변수는 덮지 않는다(override=False)."""
    global _dotenv_loaded
    if not _dotenv_loaded:
        load_dotenv(dotenv_path=BACKEND_ROOT / ".env")
        _dotenv_loaded = True


def env_str(name: str, default: str = "") -> str:
    load_env()
    return os.environ.get(name, default).strip()


def env_flag(name: str) -> bool:
    """`1/true/yes/on`이면 켜짐. 없거나 그 밖의 값은 **꺼짐**(안전한 쪽이 기본)."""
    return env_str(name).lower() in _TRUTHY


def env_int(name: str, default: int) -> int:
    raw = env_str(name)
    try:
        return int(raw) if raw else default
    except ValueError:
        return default


def env_path(name: str, default: Path) -> Path:
    raw = env_str(name)
    return Path(raw) if raw else default


# ── 스위치 ──────────────────────────────────────────────────────────────────


def save_raw_responses() -> bool:
    """IE·OCR·DP·실거래가 **원응답 저장**(`backend/out/runs`). 기본 꺼짐.

    원응답에는 등기부 실명·주소가 그대로 담긴다 → 로컬 디버깅에서만 켠다. 클라우드에서는 켜지 않는다.
    """
    return env_flag("SAVE_RAW_RESPONSES")


def require_device_id() -> bool:
    """`X-Device-Id` 헤더를 필수로 할지. 기본 꺼짐(옛 앱 호환)."""
    return env_flag("REQUIRE_DEVICE_ID")


def app_key() -> str:
    """`APP_KEY` — 설정돼 있으면 모든 `/api/*` 요청에 같은 값의 `X-App-Key`가 있어야 한다."""
    return env_str("APP_KEY")


def rate_limit_analyze_per_hour() -> int:
    """기기 id × IP별 분석(analyze + compare) 상한(최근 1시간). 0 이하면 이 겹은 끈다."""
    return env_int("RATE_LIMIT_ANALYZE_PER_HOUR", 30)


def rate_limit_ip_per_hour() -> int:
    """IP 하나의 분석 상한(최근 1시간) — 기기 id를 바꿔 가며 보내도 같은 주소면 함께 센다."""
    return env_int("RATE_LIMIT_IP_PER_HOUR", 60)


def rate_limit_global_per_hour() -> int:
    """서버 전체 분석 상한(최근 1시간) — 주소까지 바꿔도 남는 **크레딧 상한**."""
    return env_int("RATE_LIMIT_GLOBAL_PER_HOUR", 300)


def rate_limit_global_per_day() -> int:
    """서버 전체 분석 상한(최근 24시간) — **하루 크레딧 지출의 뚜껑** (2026-10-22).

    APK가 공개 링크로 나가면 앱 키는 누구나 꺼낼 수 있다. 시간 상한만으로는 하루 최대 300×24회까지
    열려 있어서, 하루 전체에 한 번 더 뚜껑을 씌운다. 기본 500 = 부스 폰 2대의 하루 시연·실측을
    넉넉히 덮는 값(운영 상한이지 위험 판정 수치가 아니다). 0 이하면 끈다.
    """
    return env_int("RATE_LIMIT_GLOBAL_PER_DAY", 500)


def docs_disabled() -> bool:
    """`DISABLE_DOCS=1`이면 `/docs`·`/openapi.json`을 끈다(공개 배포에서 API 지도를 숨긴다)."""
    return env_flag("DISABLE_DOCS")


#: 분석·대조 1회에 올릴 수 있는 사진 장수 상한. 앱은 10장까지 보내므로 넉넉하다.
MAX_PHOTOS_PER_REQUEST = 20


# ── 데이터 위치 (클라우드에서는 영구 볼륨 `/data` 아래로) ───────────────────────


def data_dir() -> Path:
    """분석 기록 DB(`app.db`)가 사는 곳. 기본 `backend/data/runtime` (git 제외)."""
    return env_path("DATA_DIR", BACKEND_ROOT / "data" / "runtime")


def price_db_dir() -> Path:
    """`official_price.sqlite`·`tax_base.sqlite`가 사는 곳. 기본 `backend/data/price`."""
    return env_path("PRICE_DB_DIR", BACKEND_ROOT / "data" / "price")


def precedent_index_dir() -> Path:
    """판례 벡터 인덱스(Chroma가 여기에 쓴다 → 쓰기 가능한 볼륨이어야 한다)."""
    return env_path("PRECEDENT_INDEX_DIR", BACKEND_ROOT / "data" / "precedents" / "index")
