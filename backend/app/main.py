"""전세AI프 백엔드 (FastAPI).

현재는 헬스체크와 이미지 업로드 수신 엔드포인트를 제공합니다.
정보추출(Upstage Information Extract)·규칙 기반 위험판단·향후 RAG는 Phase E에서 교체합니다.
지금은 앱↔서버 통신 파이프 검증이 목적입니다.
"""

import logging
import time

from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .dependencies import app_key_ok
from .routers import content, reports

# ── 서버 콘솔 로그 (한국어, 사람이 읽는 용도) ──────────────────────────────────
# services 쪽도 같은 이름("jeonseai")의 로거를 쓴다. uvicorn 로그와 섞이지 않게 전용 핸들러.
logger = logging.getLogger("jeonseai")
if not logger.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(_handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False

app = FastAPI(title="전세AI프 API", description="전세 위험 분석 백엔드")

_LOG_SKIP_PATHS = {"/docs", "/openapi.json", "/favicon.ico"}


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

# 계약(docs/api-contract.md)대로의 더미 응답 엔드포인트 (Phase D-2).
# NOTE: 이 환경의 fastapi 0.139 + starlette 1.3.1 조합에서 app.include_router()가
#       라우트를 등록하지 못하는 버그가 있어(@app.get 데코레이터는 정상), 라우터의
#       이미 완성된 APIRoute 객체를 앱 라우터에 직접 붙인다. 각 라우트는 APIRouter의
#       prefix="/api"가 이미 반영돼 있어 경로가 완전한 상태다.
app.router.routes.extend(reports.router.routes)
app.router.routes.extend(content.router.routes)

# CORS 설정: Flutter 앱(모바일 에뮬레이터/실기기)에서 호출할 수 있도록 허용합니다.
# 주의: 개발 단계라 모든 origin을 허용합니다.
#       운영 배포 시에는 allow_origins를 실제 서비스 도메인으로 제한해야 합니다.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # TODO: 운영 배포 시 도메인 제한 필요
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 업로드 허용 형식 및 용량 상한
ALLOWED_CONTENT_TYPES = {"image/jpeg", "image/png", "image/webp"}
MAX_UPLOAD_BYTES = 10 * 1024 * 1024  # 10MB


@app.get("/")
def health_check():
    """헬스체크: 서버가 살아있는지 + 준비 상태(참/거짓)만 알려 줍니다.

    2026-10-21: 배포 뒤 "왜 시세가 안 나오지?"를 서버 로그 없이 알 수 있게 준비 상태를 붙였다.
    ⚠ **값은 절대 내보내지 않는다** — 키는 "설정돼 있는가"만, 경로·건수도 내보내지 않는다.
    ⚠ 키가 **유효한지**는 보지 않는다(외부 호출 0회 — 플랫폼이 몇 초마다 부를 수 있다).
      유효성은 `python scripts/check_keys.py`로 사람이 확인한다.
    """
    from . import settings
    from .services import official_price
    from .services.precedent.store import current_index_dir

    body: dict = {
        "status": "ok",
        # 시세 DB는 **둘 다** 있어야 참이다(공시가격 + 오피스텔 기준시가) — 반쪽이면 준비 안 됨.
        "priceDb": all(
            official_price.db_path(key).is_file() for key in official_price.DB_FILENAMES
        ),
        "precedentIndex": (current_index_dir() / "docs.jsonl").is_file(),
        "upstageKey": bool(settings.env_str("UPSTAGE_API_KEY")),
        "molitKey": bool(settings.env_str("MOLIT_API_KEY")),
    }
    commit = settings.env_str("RAILWAY_GIT_COMMIT_SHA")
    if commit:
        body["version"] = commit[:7]
    return body


@app.post("/api/upload")
async def upload_image(file: UploadFile = File(...)):
    """등기부등본 이미지를 수신합니다.

    현재 단계에서는 OCR을 수행하지 않고, 받은 파일의 메타데이터만 응답합니다.
    (앱↔서버 통신 파이프 검증용)
    """
    # 1) 형식 검증: 허용된 이미지 MIME 타입만 받습니다.
    if file.content_type not in ALLOWED_CONTENT_TYPES:
        raise HTTPException(
            status_code=400,
            detail="지원하지 않는 파일 형식입니다. JPEG, PNG, WEBP 이미지만 업로드할 수 있습니다.",
        )

    # 2) 파일 내용을 읽어 크기를 확인합니다.
    contents = await file.read()
    size_bytes = len(contents)

    # 3) 용량 상한 검증
    if size_bytes > MAX_UPLOAD_BYTES:
        raise HTTPException(
            status_code=413,
            detail="파일 용량이 너무 큽니다. 10MB 이하의 이미지만 업로드할 수 있습니다.",
        )

    # 4) 메타데이터만 응답 (OCR은 다음 단계)
    return {
        "filename": file.filename,
        "content_type": file.content_type,
        "size_bytes": size_bytes,
        "message": "이미지를 정상적으로 수신했습니다",
    }
