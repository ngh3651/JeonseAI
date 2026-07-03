# 전세AI프 (jeonse-ai)

전세 계약 전, **등기부등본을 분석해 깡통전세·전세사기 위험을 탐지**하고, 부동산에 무지한 일반인도 이해할 수 있게 **쉬운 말로 설명**해주는 서비스입니다.

- **프론트엔드**: Flutter 앱 (입력·결과 표시)
- **백엔드**: FastAPI (OCR·위험판단·향후 RAG)
- **OCR**: Upstage Document Parse / **리포트(향후)**: Upstage Solar Pro
- **위험 판단**: 규칙 기반 + 향후 RAG (ML 분류 아님), 권위 있는 공식 출처 근거, **보수적 편향(경고 우선)**

자세한 원칙과 향후 과제는 [CLAUDE.md](CLAUDE.md)와 [docs/decisions.md](docs/decisions.md)를 참고하세요.

## 브랜치 작업 규칙

이 프로젝트는 **main + dev 2단계 브랜치**로 운영합니다.

- **`dev`**: 평소 작업은 전부 여기서 합니다. 팀원 둘 다 기본적으로 `dev`에 머무릅니다.
- **`main`**: 항상 안정적으로 돌아가는 버전만 유지합니다. 평소에 직접 커밋하지 않고,
  STEP 하나가 끝나고 정상 동작이 확인되면 그때 `dev → main`으로 병합합니다.
- **담당 분리**: `backend/`, `frontend/`를 각자 나눠서 작업해 충돌을 최소화합니다.
- **공용 파일 주의**: `CLAUDE.md`, `docs/decisions.md`처럼 두 사람이 같이 건드릴 수 있는 파일은,
  수정 전에 팀원과 먼저 이야기하고 진행합니다 (동시에 수정하면 충돌 해결이 번거로움).

### Git 명령어 가이드 (초보자용)

**① 처음 한 번만 — 내 컴퓨터에 레포 받기**

```bash
git clone https://github.com/ngh3651/JeonseAI.git
cd JeonseAI
git checkout dev
```

**② 작업을 시작하기 전 — 항상 최신 dev로 맞추기**

```bash
git checkout dev
git pull origin dev
```

**③ 작업하기**

평소처럼 코드를 수정하면 됩니다. (`backend/`는 A, `frontend/`는 B, 이런 식으로 담당 폴더 위주로)

**④ 작업한 내용 저장(커밋) & 올리기(푸시)**

```bash
git add .
git commit -m "무엇을 했는지 한국어로 간단히 (예: OCR 응답 파싱 로직 추가)"
git push origin dev
```

- `git add .` : 바뀐 파일들을 커밋 대상으로 담기
- `git commit -m "..."` : 담은 내용을 "저장"하기 (메시지는 필수)
- `git push origin dev` : 내 컴퓨터의 저장 내역을 GitHub의 `dev` 브랜치로 올리기

**⑤ 충돌(conflict)이 뜨면**

`git pull origin dev` 했을 때 충돌 메시지가 뜨면 당황하지 말고, 어떤 파일에서 충돌 났는지
확인한 뒤 팀원에게 먼저 알려주세요. (파일 안에 `<<<<<<<`, `=======`, `>>>>>>>` 표시가 생깁니다)

**⑥ STEP이 끝나서 `main`에 반영할 때** (둘이 같이 확인 후 진행)

```bash
git checkout main
git pull origin main
git merge dev
git push origin main
git checkout dev
```

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
