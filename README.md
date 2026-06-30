# 전세AI프 (jeonse-ai)

전세 계약 전, **등기부등본을 분석해 깡통전세·전세사기 위험을 탐지**하고, 부동산에 무지한 일반인도 이해할 수 있게 **쉬운 말로 설명**해주는 서비스입니다.

- **프론트엔드**: Flutter 앱 (입력·결과 표시)
- **백엔드**: FastAPI (OCR·위험판단·향후 RAG)
- **OCR**: Upstage Document Parse / **리포트(향후)**: Upstage Solar Pro
- **위험 판단**: 규칙 기반 + 향후 RAG (ML 분류 아님), 권위 있는 공식 출처 근거, **보수적 편향(경고 우선)**

자세한 원칙과 향후 과제는 [CLAUDE.md](CLAUDE.md)와 [docs/decisions.md](docs/decisions.md)를 참고하세요.

## 폴더 구조

```
jeonse-ai/
├── backend/                  # FastAPI 백엔드
│   ├── app/
│   │   └── main.py           # 헬스체크 엔드포인트 (GET / → {"status":"ok"})
│   └── requirements.txt      # 백엔드 의존성
├── frontend/                 # Flutter 앱 (스캐폴딩은 STEP 1에서)
├── docs/
│   └── decisions.md          # 아키텍처 결정 로그 (append-only)
├── .claude/                  # Claude Code 규칙·명령
│   ├── rules/
│   │   ├── risk-scoring.md
│   │   └── api-design.md
│   └── commands/
│       └── add-decision.md
├── CLAUDE.md                 # 프로젝트 안내 (Claude Code가 먼저 읽는 문서)
├── .gitignore
└── README.md
```

## 백엔드 실행 방법

```bash
cd backend

# (권장) 가상환경
python -m venv .venv
# Windows PowerShell:  .venv\Scripts\Activate.ps1
# macOS/Linux:         source .venv/bin/activate

# 의존성 설치
pip install -r requirements.txt

# 개발 서버 실행
uvicorn app.main:app --reload
```

실행 후 브라우저에서 <http://127.0.0.1:8000> 으로 접속하면 `{"status":"ok"}` 가 보입니다.
API 문서는 <http://127.0.0.1:8000/docs> 에서 확인할 수 있습니다.

### 이미지 업로드 엔드포인트 테스트 (curl)

`POST /api/upload` 는 이미지 1개를 multipart/form-data로 받아 메타데이터를 돌려줍니다.
(현재 단계에서는 OCR을 하지 않고 "받았다"는 응답만 합니다.)

```bash
# test.jpg 를 실제 이미지 경로로 바꿔서 실행하세요.
curl -X POST http://127.0.0.1:8000/api/upload \
  -F "file=@test.jpg;type=image/jpeg"
```

정상 응답 예시:

```json
{
  "filename": "test.jpg",
  "content_type": "image/jpeg",
  "size_bytes": 123456,
  "message": "이미지를 정상적으로 수신했습니다"
}
```

- 허용 형식: `image/jpeg`, `image/png`, `image/webp` (그 외에는 400, 한국어 메시지)
- 용량 상한: 10MB (초과 시 413, 한국어 메시지)

## 앱(프론트엔드) 실행 방법

```bash
cd frontend
flutter pub get
flutter run            # 연결된 에뮬레이터/실기기에서 실행
```

- 백엔드 주소는 [frontend/lib/main.dart](frontend/lib/main.dart) 상단의 `baseUrl` 상수로 분리되어 있습니다.
  - **Android 에뮬레이터**: PC의 localhost는 `10.0.2.2` 로 접근 (기본값 `http://10.0.2.2:8000`)
  - **iOS 시뮬레이터**: `http://127.0.0.1:8000`
  - **실기기(같은 와이파이)**: PC의 LAN IP, 예 `http://192.168.0.10:8000`
