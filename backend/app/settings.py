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
    """`X-Device-Id` 헤더를 필수로 할지. **기본 켜짐**(2026-10-30 보안).

    예전 기본은 꺼짐이었다 — 헤더 없는 옛 앱(8/14 빌드)이 함께 쓰는 공용 칸(`legacy-device`)을 열어 두려고.
    그 칸은 앱 키만 있으면 누구나 목록을 읽고 지울 수 있었다. 지금 앱은 모든 요청에 헤더를 싣는다(2026-10-22).
    옛 앱을 잠깐 다시 살려야 할 때만 `REQUIRE_DEVICE_ID=0`.
    """
    raw = env_str("REQUIRE_DEVICE_ID")
    return raw.lower() in _TRUTHY if raw else True


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


# ── 챗봇 질문 상한 (2026-10-24) — 챗봇이 매 질문 Solar를 부르게 되면서. 분석과 칸을 따로 센다.
# 운영 상한이지 위험 판정 수치가 아니다. 0 이하면 그 겹은 끈다.


def rate_limit_chat_per_hour() -> int:
    """기기 id × IP별 챗봇 질문 상한(최근 1시간) — 연타 장난."""
    return env_int("RATE_LIMIT_CHAT_PER_HOUR", 60)


def rate_limit_chat_ip_per_hour() -> int:
    """IP 하나의 챗봇 질문 상한(최근 1시간) — 부스 폰들은 같은 와이파이를 쓴다."""
    return env_int("RATE_LIMIT_CHAT_IP_PER_HOUR", 300)


def rate_limit_chat_global_per_day() -> int:
    """서버 전체 챗봇 질문 상한(최근 24시간) — 하루 크레딧 뚜껑."""
    return env_int("RATE_LIMIT_CHAT_GLOBAL_PER_DAY", 3000)


def data_secret_set() -> bool:
    """저장 데이터 잠금 열쇠(`DATA_SECRET`)가 있나 — 값은 `services/sealing.py`만 읽는다."""
    return bool(env_str("DATA_SECRET"))


def docs_disabled() -> bool:
    """`/docs`·`/openapi.json`을 끌지(공개 배포에서 API 지도를 숨긴다). `DISABLE_DOCS=1`이면 끈다.

    **Railway에서 돌면 기본으로 끈다**(2026-10-30 보안) — 변수를 깜빡해도 공개 주소에 API 지도가 드러나지 않게.
    Railway가 모든 서비스에 넣어 주는 `RAILWAY_ENVIRONMENT_NAME`·`RAILWAY_PROJECT_ID`로 안다.
    배포 서버에서 잠깐 켜야 하면 `DISABLE_DOCS=0`. 로컬 개발(변수 없음)은 그대로 켜져 있다.
    """
    raw = env_str("DISABLE_DOCS")
    if raw:
        return raw.lower() in _TRUTHY
    return bool(env_str("RAILWAY_ENVIRONMENT_NAME") or env_str("RAILWAY_PROJECT_ID"))


#: 분석·대조 1회에 올릴 수 있는 사진 장수 상한. 앱은 10장까지 보내므로 넉넉하다.
MAX_PHOTOS_PER_REQUEST = 20

#: 사진 한 장의 최대 용량. 앱이 보내는 JPEG는 장당 1~3MB다.
MAX_UPLOAD_BYTES = 10 * 1024 * 1024

#: 요청 하나의 최대 본문 크기 — 앱은 한 번에 최대 10장 × 장당 1~3MB를 보낸다(넉넉히 두 배). 넘으면 다 받기 **전에** 413.
#: 예전엔 본문을 끝까지 받아 메모리에 올린 뒤에 용량을 봤다 → 3GB 파일 하나로 서버가 죽을 수 있었다(2026-10-30 보안).
MAX_REQUEST_BYTES = 60 * 1024 * 1024

#: 사진 한 장의 최대 화소 수 — 앱 사진은 약 500만 화소(긴 변 2560 안팎, flutter_image_compress 기본 축소).
#: 이보다 크면 압축 폭탄으로 보고 읽지 않는다(668KB짜리 13000×13000 PNG 한 장이 메모리 830MB를 쓰는 것을 확인했다).
#: 4천만 → 1,600만(2026-10-30 보안 리뷰): 4천만 화소 PNG 한 장도 촬영 검사에 CPU 0.3초를 써, 20장이면 요청 하나로 6초를 붙잡았다.
MAX_IMAGE_PIXELS = 16_000_000


#: 토스페이먼츠 개발자 문서에 **공개된 테스트용** 결제위젯 시크릿 키 (2026-10-22, P2-1).
#: 이 키로 승인한 결제는 실제로 청구되지 않는다. 문서 공개 값이라 비밀이 아니다.
TOSS_DOCS_TEST_SECRET_KEY = "test_gsk_docs_OaPz8L5KdmQXkzRz3y47BMw6"


def toss_secret_key() -> str:
    """토스페이먼츠 결제 승인 키(`TOSS_SECRET_KEY`). 비우면 문서 공개 **테스트** 키.

    ⚠ `test_`로 시작하지 않는 키(실제 키 `live_…`)는 결제 라우터가 **거부**한다 — 결선은 테스트 결제만.
    """
    return env_str("TOSS_SECRET_KEY") or TOSS_DOCS_TEST_SECRET_KEY


# ── 데이터 위치 (클라우드에서는 영구 볼륨 `/data` 아래로) ───────────────────────


def data_dir() -> Path:
    """분석 기록 DB(`app.db`)가 사는 곳. 기본 `backend/data/runtime` (git 제외)."""
    return env_path("DATA_DIR", BACKEND_ROOT / "data" / "runtime")


def price_db_dir() -> Path:
    """`official_price.sqlite`·`tax_base.sqlite`가 사는 곳. 기본 `backend/data/price`."""
    return env_path("PRICE_DB_DIR", BACKEND_ROOT / "data" / "price")


def precedent_update_dir() -> Path:
    """법제처에서 **자동으로 더 받은** 판례 원문·업데이트 기록이 사는 곳 (2026-10-24) — `${DATA_DIR}/precedents`.

    레포에 든 원문(`backend/data/precedents/raw`)은 배포 때마다 이미지에 다시 실리지만, 자동으로 받은 것은
    영구 볼륨에 남아야 다음 배포 뒤에도 그대로다.
    """
    return data_dir() / "precedents"


def precedent_update_days() -> int:
    """판례 자동 업데이트 간격(일) — `PRECEDENT_UPDATE_DAYS`, 기본 7. 0이면 끈다."""
    try:
        return max(0, int(env_str("PRECEDENT_UPDATE_DAYS") or 7))
    except ValueError:
        return 7


def law_api_oc() -> str:
    """법제처 Open API 인증값 — `LAW_API_OC`. 없으면 가이드 샘플 값 `test`(언제 막힐지 모름)."""
    return env_str("LAW_API_OC") or "test"


def precedent_index_dir() -> Path:
    """판례 벡터 인덱스(Chroma가 여기에 쓴다 → 쓰기 가능한 볼륨이어야 한다)."""
    return env_path("PRECEDENT_INDEX_DIR", BACKEND_ROOT / "data" / "precedents" / "index")


# ── 카카오 로그인 (2026-10-22, P2-1) ─────────────────────────────────────────
# 둘 다 있어야 `POST /api/auth/kakao`가 열린다. 하나라도 없으면 503 "카카오 로그인이 아직 준비되지 않았어요".

#: 계정 키 비밀의 최소 길이 — `secrets.token_urlsafe(32)`(43자)로 만든 값을 넣는다(NOW.md 사람 할 일).
#: 짧은 비밀은 HMAC을 약하게 만든다 → 이보다 짧으면 넣지 않은 것으로 본다.
ACCOUNT_HASH_SECRET_MIN_LENGTH = 32


def kakao_app_id() -> str:
    """카카오 개발자 콘솔의 **앱 ID**(숫자) — `KAKAO_APP_ID`. 받은 토큰이 **우리 앱의 토큰인지** 견준다.

    비밀이 아니다(앱 키 화면에 보이는 번호). 다른 앱에서 받은 카카오 토큰으로 우리 서버에 들어오는 것을 막는다.
    """
    return env_str("KAKAO_APP_ID")


def account_hash_secret() -> str:
    """계정 키를 만드는 비밀 — `ACCOUNT_HASH_SECRET`. 회원번호 원문 대신 HMAC 값만 남기려고 쓴다.

    ⚠ 한 번 정하면 **바꾸지 않는다** — 바꾸면 모든 계정 키가 달라져 기존 회원의 기록이 안 보인다.
    """
    return env_str("ACCOUNT_HASH_SECRET")


def kakao_login_ready() -> bool:
    """카카오 로그인을 받을 준비가 됐는가 — 앱 ID + 충분히 긴 계정 키 비밀."""
    return bool(kakao_app_id()) and len(account_hash_secret()) >= ACCOUNT_HASH_SECRET_MIN_LENGTH


def guest_record_days() -> int:
    """로그인 없이 쓴 기록(기기 칸)을 지우는 때 — 마지막 분석·결제 뒤 이 날수가 지나면. `GUEST_RECORD_DAYS`(기본 365).

    2026-10-30 보안: 앱을 지우면 기기 번호도 사라져 사용자가 서버 기록을 지울 길이 없다 → 오래 쓰지 않은 기기 칸은
    서버가 치운다(처리방침 "마지막으로 쓴 날부터 1년"). 0 이하면 끈다. 운영 설정이지 위험 판정 수치가 아니다.
    """
    return env_int("GUEST_RECORD_DAYS", 365)


def session_days() -> int:
    """로그인 세션이 살아 있는 날 수 — `SESSION_DAYS`(기본 30). 1보다 작게 넣으면 1일.

    운영 설정이지 위험 판정 수치가 아니다. 지나면 앱이 401을 받고 다시 로그인을 안내한다.
    """
    return max(1, env_int("SESSION_DAYS", 30))
