# 전세AI프 서버 (FastAPI) — 클라우드 배포용 이미지 (2026-10-21, Railway 기준)
#
# 저장소 맨 위에 둔다 → Railway가 Root Directory 설정 없이 바로 찾는다.
# 서버에 필요한 것만 담는다: backend/app · backend/data(판례 원본·질문·용어 등) · backend/scripts.
# 앱(frontend)·문서·테스트 샘플·로컬 산출물은 .dockerignore로 뺀다.
#
# 영구 볼륨은 /data 에 붙인다 (Railway → Add Volume → Mount path /data).
#   DATA_DIR=/data · PRICE_DB_DIR=/data/price · PRECEDENT_INDEX_DIR=/data/precedents-index
# ⚠ Railway 볼륨은 root 소유로 붙는다. 이 이미지는 root가 아닌 사용자(app)로 돈다 →
#   Railway Variables에 RAILWAY_RUN_UID=0 을 넣어야 볼륨에 쓸 수 있다(docs/NOW.md 배포 방법).
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# 의존성 먼저 — 코드만 바뀌면 이 층은 캐시를 다시 쓴다
COPY backend/requirements.txt ./requirements.txt
RUN pip install -r requirements.txt

COPY backend/app ./app
COPY backend/data ./data
COPY backend/scripts ./scripts

# root가 아닌 사용자. /data는 볼륨이 없을 때(로컬 docker run)를 위해 미리 만들어 둔다.
RUN useradd --create-home --uid 10001 app \
    && mkdir -p /data \
    && chown -R app:app /app /data
USER app

EXPOSE 8000

# 준비(폴더·시세 DB 내려받기·판례 인덱스) → 서버. 준비 단계는 실패해도 서버 시작을 막지 않는다.
CMD ["sh", "-c", "python scripts/prepare_runtime.py; exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
