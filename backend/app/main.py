"""전세AI프 백엔드 (FastAPI).

현재는 헬스체크와 이미지 업로드 수신 엔드포인트를 제공합니다.
정보추출(Upstage Information Extract)·규칙 기반 위험판단·향후 RAG는 Phase E에서 교체합니다.
지금은 앱↔서버 통신 파이프 검증이 목적입니다.
"""

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="전세AI프 API", description="전세 위험 분석 백엔드")

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
    """헬스체크: 서버가 살아있는지 확인합니다."""
    return {"status": "ok"}


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
