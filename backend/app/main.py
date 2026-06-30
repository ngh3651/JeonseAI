"""전세AI프 백엔드 (FastAPI).

현재 단계(STEP 0)에서는 헬스체크 엔드포인트만 제공합니다.
OCR·위험판단·RAG는 다음 단계에서 구현합니다.
"""

from fastapi import FastAPI

app = FastAPI(title="전세AI프 API", description="전세 위험 분석 백엔드")


@app.get("/")
def health_check():
    """헬스체크: 서버가 살아있는지 확인합니다."""
    return {"status": "ok"}
