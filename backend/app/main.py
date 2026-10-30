"""전세AI프 백엔드 (FastAPI).

현재는 헬스체크와 이미지 업로드 수신 엔드포인트를 제공합니다.
정보추출(Upstage Information Extract)·규칙 기반 위험판단·향후 RAG는 Phase E에서 교체합니다.
지금은 앱↔서버 통신 파이프 검증이 목적입니다.
"""

import importlib.util
import json
import logging
import threading
import time
import traceback
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from PIL import Image

from . import settings
from .dependencies import app_key_ok
from .routers import auth, content, payments, reports

# 압축 폭탄 막기(2026-10-30 보안) — 라우터가 디코딩 전에 화소 수를 먼저 보고(`reports._check_pixels`),
# 그래도 새어 들어온 그림은 Pillow가 이 크기의 두 배를 넘으면 열지 않는다.
Image.MAX_IMAGE_PIXELS = settings.MAX_IMAGE_PIXELS

# ── 서버 콘솔 로그 (한국어, 사람이 읽는 용도) ──────────────────────────────────
# services 쪽도 같은 이름("jeonseai")의 로거를 쓴다. uvicorn 로그와 섞이지 않게 전용 핸들러.
class _SafeFormatter(logging.Formatter):
    """예외를 찍을 때 **오류 문장은 빼고** 종류와 위치(파일·줄·함수)만 남긴다 (2026-10-30 보안).

    오류 문장에는 등기부 글자(실명·주소)가 섞일 수 있다(예: 값을 읽다 실패한 칸의 내용). 위치는 우리 코드라 안전하다.
    """

    def formatException(self, ei) -> str:  # noqa: N802 — logging.Formatter의 이름
        lines: list[str] = []
        exc = ei[1]
        seen: set[int] = set()
        while exc is not None and id(exc) not in seen:
            seen.add(id(exc))
            for frame in traceback.extract_tb(exc.__traceback__):
                lines.append(f"  {Path(frame.filename).name}:{frame.lineno} {frame.name}")
            lines.append(f"{type(exc).__name__} (내용은 개인정보 보호를 위해 기록하지 않음)")
            exc = exc.__cause__ or exc.__context__
        return "\n".join(lines)


logger = logging.getLogger("jeonseai")
if not logger.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(_SafeFormatter("%(message)s"))
    logger.addHandler(_handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False

def _load_prepare_runtime():
    """`backend/scripts/prepare_runtime.py`를 모듈로 읽는다(스크립트로도, 서버 안에서도 쓴다)."""
    path = Path(__file__).resolve().parents[1] / "scripts" / "prepare_runtime.py"
    spec = importlib.util.spec_from_file_location("prepare_runtime", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@asynccontextmanager
async def _lifespan(_app: FastAPI):
    """서버가 **먼저** 뜨고, 시작 준비(시세 DB 내려받기·판례 인덱스)는 뒤쪽 스레드에서 돈다 (2026-10-22).

    `PREPARE_RUNTIME_ON_START=1`일 때만(Dockerfile이 켠다) — 로컬 개발·테스트에서는 아무것도 받지 않는다.
    진행 상황은 `GET /`의 준비 상태로 보인다. 준비가 실패해도 서버는 그대로 돈다.
    """
    if settings.env_flag("PREPARE_RUNTIME_ON_START"):
        try:
            _load_prepare_runtime().start_background()
        except Exception as e:  # noqa: BLE001 — 준비가 서버 시작을 막지 않는다
            logger.info(f"[준비] ⚠ 시작 준비를 띄우지 못함 — 서버는 그대로 시작 ({type(e).__name__})")
        # 판례 자동 업데이트 알람시계 (2026-10-24) — 법제처에서 새 판례를 PRECEDENT_UPDATE_DAYS(기본 7)일마다
        try:
            from .services.precedent import updater

            updater.start_background()
        except Exception as e:  # noqa: BLE001
            logger.info(f"[판례 업데이트] ⚠ 알람시계를 띄우지 못함 ({type(e).__name__})")
        # 판례 검색 준비를 미리 (2026-10-26) — 첫 '판례 보기'가 색인 읽기까지 기다리지 않게. 뒤에서만 돈다.
        threading.Thread(target=_warm_precedents, name="precedent-warmup", daemon=True).start()
        # 오래된 기록 정리 (2026-10-30 보안) — 처리방침의 보관 기간을 서버가 스스로 지킨다
        _start_housekeeping()
    # 평문으로 남은 옛 기록을 잠근다(2026-10-30 보안) — 열쇠(DATA_SECRET)가 있을 때만, 뒤에서 한 번
    threading.Thread(target=_seal_existing, name="seal-existing", daemon=True).start()
    # 요청 횟수를 세던 IP를 요청이 끊긴 동안에도 2시간 안에 버린다(2026-10-30 보안, 처리방침과 같은 약속)
    from .dependencies import start_rate_limit_sweeper

    start_rate_limit_sweeper()
    yield


_housekeeping_started = False


def _start_housekeeping() -> None:
    """[_housekeeping] 스레드를 프로세스에 **한 번만** 띄운다."""
    global _housekeeping_started
    if _housekeeping_started:
        return
    _housekeeping_started = True
    threading.Thread(target=_housekeeping, name="housekeeping", daemon=True).start()


def _housekeeping(first_delay: float = 60.0, every: float = 3600.0) -> None:
    """한 시간마다 — ① 마지막으로 쓴 지 1년(`GUEST_RECORD_DAYS`)이 지난 기기 칸의 기록 ② 기간 지난 캐시 쪽지를 지운다.

    처리방침의 약속("로그인 없이 쓴 기록은 1년", "같은 사진 확인 값은 24시간")을 사람 손 없이 지키는 곳.
    실패해도 서버는 돈다 — 다음 차례에 다시 한다. 로그에는 지운 수와 오류 종류만 남는다.
    """
    time.sleep(first_delay)
    while True:
        try:
            from .services import accounts, analysis_cache

            accounts.sweep_inactive_guests()
            analysis_cache.purge_expired()
        except Exception as e:  # noqa: BLE001
            logger.error(f"[정리] ⚠ 오래된 기록 정리 실패 ({type(e).__name__})")
        time.sleep(every)


def _seal_existing() -> None:
    """서버가 켜질 때 뒤에서 한 번 — 열쇠 확인 · 기기 id 원문 주인 값 가리기 · 옛 평문 잠그기 · 상태 한 줄 로그.

    보안 설정은 공개 헬스체크(`GET /`)에 싣지 않고 **배포 로그**에만 남긴다(2026-10-30 보안 리뷰 — 바깥에서 설정을 엿보지 못하게).
    Railway → Deployments → Logs에서 `[보안]` 줄을 본다.
    """
    try:
        from .services import accounts, sealing, store

        device_rule = "기기 id 필수" if settings.require_device_id() else "⚠ 기기 id 없이도 받음(REQUIRE_DEVICE_ID=0)"
        key_state = store.check_key_fingerprint()
        if key_state == "mismatch":
            logger.error(
                "[보안] ⚠⚠ DATA_SECRET이 예전과 달라요 — 예전에 잠근 기록을 열 수 없고 기기 기록이 안 보여요. "
                "Railway 변수를 예전 값으로 되돌리세요"
            )
        elif key_state == "missing":
            logger.error(
                "[보안] ⚠⚠ DATA_SECRET이 빠졌어요 — 예전에 잠근 기록을 열 수 없고 새 기록은 잠기지 않아요. "
                "Railway 변수를 예전 값으로 되돌리세요"
            )
        if not sealing.enabled():
            if not settings.data_secret_set():
                logger.info(f"[보안] DATA_SECRET 없음 — 기록을 잠그지 않고 저장합니다(로컬 개발용) · {device_rule}")
            return  # 짧은 열쇠면 sealing이 이미 경고를 남겼다
        owners = accounts.mask_all_device_owners()
        sealed = store.seal_existing() + accounts.seal_existing_profiles()
        state = "열쇠 확인됨" if key_state in ("ok", "new") else "⚠ 열쇠가 예전과 다름"
        logger.info(
            f"[보안] 저장 데이터 잠금 켜짐 · {state} · {device_rule} — 옛 평문 {sealed}건 잠금 · 기기 주인 값 {owners}개 가림"
        )
    except Exception as e:  # noqa: BLE001 — 잠그기가 실패해도 서버는 돈다(새 기록은 잠겨서 쓰인다)
        logger.error(f"[보안] ⚠ 옛 기록 잠그기 실패 ({type(e).__name__})")


def _warm_precedents(wait_seconds: int = 1800, poll: float = 10.0) -> None:
    """판례 색인이 준비되면(시작 준비가 내려받는 중일 수 있다) 검색기를 한 번 만들어 둔다.

    ⚠ 색인이 **다 만들어진 뒤에만**(meta.json) 만든다 — 빈 색인으로 검색기를 만들면 재시작 전까지 판례가 0건으로 굳는다.
    외부 호출(임베딩·Solar) 없음 — 파일만 읽는다. 실패해도 첫 요청이 지금처럼 만들 뿐이다.
    """
    try:
        from .services.precedent import service as precedent_service
        from .services.precedent.store import current_index_dir

        waited = 0.0
        while not (current_index_dir() / "meta.json").is_file():
            if waited >= wait_seconds:
                logger.info("[판례] 미리 준비 — 색인이 아직 없어 건너뜀(첫 요청 때 만든다)")
                return
            time.sleep(poll)
            waited += poll
        t0 = time.perf_counter()
        precedent_service.get_service()
        logger.info(f"[판례] 미리 준비 끝 — 검색기 적재 {time.perf_counter() - t0:.1f}초")
    except Exception as e:  # noqa: BLE001 — 미리 준비가 서버를 깨뜨리지 않는다
        logger.info(f"[판례] 미리 준비 실패 — 첫 요청 때 만든다 ({type(e).__name__})")


# `DISABLE_DOCS=1`이면 API 문서(/docs·/openapi.json)를 끈다 — 공개 배포에서 API 지도를 숨긴다(2026-10-22).
_DOCS_OFF = settings.docs_disabled()
app = FastAPI(
    title="전세AI프 API",
    description="전세 위험 분석 백엔드",
    lifespan=_lifespan,
    docs_url=None if _DOCS_OFF else "/docs",
    redoc_url=None if _DOCS_OFF else "/redoc",
    openapi_url=None if _DOCS_OFF else "/openapi.json",
)

_LOG_SKIP_PATHS = {"/docs", "/openapi.json", "/favicon.ico"}

#: 모든 응답에 붙이는 보안 헤더 (2026-10-30). 이 서버는 앱 전용 API라 브라우저에 보일 화면이 없다.
_SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Strict-Transport-Security": "max-age=31536000",
    "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
}
#: API 문서 화면은 외부 스크립트를 쓰므로 위 CSP를 빼 준다(공개 배포에서는 `DISABLE_DOCS=1`로 아예 끈다)
_DOCS_PATHS = {"/docs", "/redoc", "/openapi.json", "/docs/oauth2-redirect"}


# ⚠ 미들웨어 순서: **나중에 등록한 것이 바깥**이다. 앱 키 검사를 먼저 등록해 안쪽에 두면
#   아래 요청 로그가 401도 한 줄로 남기고, CORS가 401 응답에도 헤더를 붙인다.
@app.middleware("http")
async def require_app_key(request: Request, call_next):
    """`APP_KEY`가 설정돼 있으면 `/api/*` 요청은 같은 값의 `X-App-Key`가 있어야 한다 (2026-10-21).

    배포 주소가 알려지면 누구나 분석을 돌려 **Upstage 크레딧**을 쓸 수 있다. 이 키가 정문이다.
    헬스체크(`GET /`)와 API 문서(`/docs`)는 열어 둔다 — 플랫폼 헬스체크와 사람 확인용이다.
    브라우저 사전 요청(OPTIONS)은 헤더를 싣지 못하므로 통과시킨다(CORS가 답한다).
    """
    path = request.url.path
    if (
        (path == "/api" or path.startswith("/api/"))
        and request.method != "OPTIONS"
        and not app_key_ok(request.headers.get("x-app-key"))
    ):
        return JSONResponse(
            status_code=401,
            content={"detail": "앱 인증 정보가 맞지 않아요. 앱을 최신 버전으로 업데이트해 주세요"},
        )
    return await call_next(request)


@app.middleware("http")
async def log_requests(request: Request, call_next):
    """모든 요청을 한 줄로 기록: 무엇을 호출했고, 몇 초 걸려, 어떤 상태로 끝났는지."""
    start = time.perf_counter()
    response = await call_next(request)
    if request.url.path not in _LOG_SKIP_PATHS:
        elapsed = time.perf_counter() - start
        logger.info(
            f"[요청] {request.method} {request.url.path} → {response.status_code} ({elapsed:.1f}초)"
        )
    return response


@app.middleware("http")
async def harden_responses(request: Request, call_next):
    """모든 응답에 보안 헤더를 붙이고, 예기치 못한 오류는 **안쪽 내용 없이** 한국어 한 줄 500으로 바꾼다 (2026-10-30).

    오류를 여기서 받으면 서버 프로그램(uvicorn)이 오류 문장째 로그에 찍지 않는다 — 문장에 등기부 글자가 섞일 수 있다.
    대신 위치만 남는 안전한 기록을 우리 로거로 남긴다([_SafeFormatter]).
    """
    try:
        response = await call_next(request)
    except Exception:  # noqa: BLE001 — 마지막 그물
        logger.error(f"[오류] {request.method} {request.url.path} 처리 중 예기치 못한 오류", exc_info=True)
        response = JSONResponse(
            status_code=500,
            content={"detail": "잠시 문제가 생겼어요. 조금 뒤 다시 시도해 주세요"},
        )
    for name, value in _SECURITY_HEADERS.items():
        if name == "Content-Security-Policy" and request.url.path in _DOCS_PATHS:
            continue
        response.headers.setdefault(name, value)
    if request.url.path.startswith("/api"):
        # 리포트·기록이 중간 캐시(프록시·폰)에 남지 않게
        response.headers["Cache-Control"] = "no-store"
    return response

# 계약(docs/api-contract.md)대로의 더미 응답 엔드포인트 (Phase D-2).
# NOTE: 이 환경의 fastapi 0.139 + starlette 1.3.1 조합에서 app.include_router()가
#       라우트를 등록하지 못하는 버그가 있어(@app.get 데코레이터는 정상), 라우터의
#       이미 완성된 APIRoute 객체를 앱 라우터에 직접 붙인다. 각 라우트는 APIRouter의
#       prefix="/api"가 이미 반영돼 있어 경로가 완전한 상태다.
app.router.routes.extend(reports.router.routes)
app.router.routes.extend(content.router.routes)
app.router.routes.extend(payments.router.routes)  # 요금제·테스트 결제 (2026-10-22)
app.router.routes.extend(auth.router.routes)  # 카카오 로그인·로그아웃·내 상태·회원 탈퇴 (2026-10-22)

# CORS는 두지 않는다 (2026-10-30 보안) — 이 서버를 부르는 것은 안드로이드 앱뿐이다(브라우저가 아니다).
# 예전엔 모든 웹사이트를 허용(`*`)해 두었다. 웹 버전을 만들면 그 도메인만 허용하는 설정을 다시 넣는다.


_MSG_BODY_TOO_LARGE = "보낸 사진이 너무 커요. 사진 수를 줄이거나 다시 찍어 주세요"


class LimitRequestBody:
    """요청 본문이 [max_bytes]를 넘으면 **다 받기 전에** 413으로 끊는다 (2026-10-30 보안 — 순수 ASGI, 가장 바깥).

    예전엔 업로드를 끝까지 받아 메모리에 올린 뒤에야 용량을 봤다 → 아주 큰 파일 하나로 서버가 죽을 수 있었다.
    `Content-Length`가 크면 바로 거절하고, 길이를 밝히지 않고 흘려보내는 본문도 받은 바이트를 세어 넘으면 끊는다.

    넘는 순간 예외를 던지지 않고 **'연결 끊김'을 건넨다** — 안쪽의 `@app.middleware("http")` 층이 받기를 작업 묶음
    (TaskGroup)으로 감싸 예외가 ExceptionGroup이 되고, FastAPI가 그것을 영어 400("There was an error parsing the
    body")으로 바꿨다(2026-10-30 보안 리뷰 재현). 그래서 안쪽이 무엇을 답하든 그 답을 버리고 우리가 한국어 413을 보낸다.
    """

    def __init__(self, app, max_bytes: int) -> None:
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        for name, value in scope.get("headers") or []:
            if name == b"content-length":
                try:
                    if int(value) > self.max_bytes:
                        await self._reject(send)
                        return
                except ValueError:
                    pass
        received = 0
        exceeded = False
        started = False
        rejected = False

        async def limited_receive():
            nonlocal received, exceeded
            if exceeded:
                return {"type": "http.disconnect"}
            message = await receive()
            if message.get("type") == "http.request":
                received += len(message.get("body", b""))
                if received > self.max_bytes:
                    exceeded = True
                    return {"type": "http.disconnect"}
            return message

        async def guarded_send(message):
            nonlocal started, rejected
            if exceeded and not started:
                # 상한을 넘은 요청 — 안쪽의 답(400·500 등)은 버리고 413을 한 번만 보낸다
                if not rejected:
                    rejected = True
                    await self._reject(send)
                return
            if message.get("type") == "http.response.start":
                started = True
            await send(message)

        try:
            await self.app(scope, limited_receive, guarded_send)
        except Exception:
            if not exceeded:
                raise
        if exceeded and not started and not rejected:
            rejected = True
            await self._reject(send)

    @staticmethod
    async def _reject(send) -> None:
        body = json.dumps({"detail": _MSG_BODY_TOO_LARGE}, ensure_ascii=False).encode("utf-8")
        await send(
            {
                "type": "http.response.start",
                "status": 413,
                "headers": [
                    (b"content-type", b"application/json"),
                    (b"content-length", str(len(body)).encode()),
                    (b"x-content-type-options", b"nosniff"),
                ],
            }
        )
        await send({"type": "http.response.body", "body": body})


app.add_middleware(LimitRequestBody, max_bytes=settings.MAX_REQUEST_BYTES)

@app.get("/")
def health_check():
    """헬스체크: 서버가 살아있는지 + 준비 상태(참/거짓)만 알려 줍니다.

    2026-10-21: 배포 뒤 "왜 시세가 안 나오지?"를 서버 로그 없이 알 수 있게 준비 상태를 붙였다.
    ⚠ **값은 절대 내보내지 않는다** — 키는 "설정돼 있는가"만, 경로·건수도 내보내지 않는다.
    ⚠ 키가 **유효한지**는 보지 않는다(외부 호출 0회 — 플랫폼이 몇 초마다 부를 수 있다).
      유효성은 `python scripts/check_keys.py`로 사람이 확인한다.
    """
    from .services import official_price, store
    from .services.precedent.store import current_index_dir

    body: dict = {
        "status": "ok",
        # 기록 DB에 실제로 쓸 수 있는가 — 볼륨 권한(RAILWAY_RUN_UID=0) 문제를 여기서 바로 본다
        "historyDb": store.writable(),
        # 시세 DB는 **둘 다** 있어야 참이다(공시가격 + 오피스텔 기준시가) — 반쪽이면 준비 안 됨.
        "priceDb": all(
            official_price.db_path(key).is_file() for key in official_price.DB_FILENAMES
        ),
        # 적재가 **맨 마지막에** 쓰는 meta.json으로 본다 — 중간에 끊긴 인덱스를 준비됐다고 하지 않는다
        "precedentIndex": (current_index_dir() / "meta.json").is_file(),
        "upstageKey": bool(settings.env_str("UPSTAGE_API_KEY")),
        "molitKey": bool(settings.env_str("MOLIT_API_KEY")),
        "lawOc": bool(settings.env_str("LAW_API_OC")),
    }
    # 판례 자동 업데이트 결과 (2026-10-24) — 로그를 열지 않고 "법제처에서 받아 왔나"를 본다. 날짜·성공 여부·실패 종류만.
    try:
        from .services.precedent import updater

        body["precedentUpdate"] = updater.health_summary()
        from .services import chat as chat_service

        body["chat"] = chat_service.stats()  # 챗봇이 AI로 답했나·고쳐 썼나·기본 문장이었나(2026-10-24)
        from .services.precedent import explainer as precedent_explainer

        body["precedentExplain"] = precedent_explainer.last_status()  # 판례 AI 설명 마지막 결과·폐기 이유(2026-10-24)
    except Exception:  # noqa: BLE001 — 헬스체크는 절대 실패하지 않는다
        pass
    commit = settings.env_str("RAILWAY_GIT_COMMIT_SHA")
    if commit:
        body["version"] = commit[:7]
    return body


