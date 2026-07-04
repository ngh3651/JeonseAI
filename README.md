# 전세AI프 (JeonseAI)

전세 계약 전, **등기부등본을 분석해 깡통전세·전세사기 위험을 탐지**하고, 부동산에 무지한
일반인도 이해할 수 있게 **쉬운 말로 설명**해주는 안드로이드 앱입니다. (AI ROOKIE 본선 프로젝트)

- **프론트엔드**: Flutter 앱 (안드로이드 우선, iOS 확장 여지 유지)
- **백엔드**: FastAPI (정보추출·위험판단·향후 RAG)
- **정보추출**: Upstage **Information Extract** (등기부 필드를 스키마 기반으로 구조화 추출) /
  **리포트 문장 생성(향후)**: Upstage **Solar Pro**
- **위험 판단**: **규칙 기반 + 향후 RAG** (ML 분류 아님), 권위 있는 공식 출처 근거,
  **보수적 편향(경고 우선)**. 판정은 규칙 엔진이, 설명 문장만 LLM이 생성하는 가드레일 구조.

> 원칙·로드맵·결정 근거는 아래 문서를 참고하세요. **Claude Code로 개발할 때는
> [CLAUDE.md](CLAUDE.md)를 매 세션 가장 먼저 읽습니다.**
>
> | 문서 | 역할 |
> |---|---|
> | [CLAUDE.md](CLAUDE.md) | 프로젝트 안내·불변 원칙·개발 방법론 (가장 먼저 읽는 문서) |
> | [docs/plan.md](docs/plan.md) | Phase A~F 로드맵·진행 현황 |
> | [docs/IA.md](docs/IA.md) | 화면 트리·네비게이션 맵 |
> | [docs/user-scenario.md](docs/user-scenario.md) | 화면→버튼→액션 시나리오 |
> | [docs/decisions.md](docs/decisions.md) | 아키텍처 결정 로그 (append-only) |
> | [docs/registry-schema.md](docs/registry-schema.md) | 등기부 추출 스키마 설명 |

## 개발 방식 (2026-07-03 재정비)

기능을 하나씩 덧붙이던 방식을 멈추고, **전 화면이 더미 데이터로 처음부터 끝까지 관통하는
깡통 프로토타입을 먼저 완성**한 뒤 **화면 단위로 실기능을 교체**합니다. 진행은
**Phase A~F 로드맵**([docs/plan.md](docs/plan.md))을 따르고, 각 Phase 종료 시
**사용자 승인 게이트**를 거칩니다. 상세는 [CLAUDE.md](CLAUDE.md) 4절을 참고하세요.

## 협업·브랜치 규칙

- **개발자 2명은 담당 폴더를 나누지 않고, 같은 코드베이스를 시간대를 나눠 함께 개발**합니다
  (충돌 최소화). 공용 파일(`CLAUDE.md`, `docs/decisions.md` 등)은 수정 전에 먼저 알립니다.
- 브랜치는 **main + dev 2단계**로 운영합니다.
  - **`dev`**: 평소 작업은 전부 여기서 합니다.
  - **`main`**: 항상 안정적으로 도는 버전만 유지합니다. **Phase 하나가 끝나고
    정상 동작이 확인되면** 그때 `dev → main`으로 병합합니다.

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

**③ 작업한 내용 저장(커밋) & 올리기(푸시)**

```bash
git add .
git commit -m "무엇을 했는지 한국어로 간단히"
git push origin dev
```

**④ 충돌(conflict)이 뜨면**

`git pull origin dev` 했을 때 충돌 메시지가 뜨면, 어떤 파일에서 충돌 났는지 확인한 뒤
팀원에게 먼저 알려주세요. (파일 안에 `<<<<<<<`, `=======`, `>>>>>>>` 표시가 생깁니다)

**⑤ Phase가 끝나서 `main`에 반영할 때** (둘이 같이 확인 후 진행)

```bash
git checkout main
git pull origin main
git merge dev
git push origin main
git checkout dev
```

## 폴더 구조

```
JeonseAI/
├── backend/                       # FastAPI 백엔드
│   ├── app/
│   │   ├── main.py                # 헬스체크 + 이미지 업로드 수신 엔드포인트
│   │   └── schemas/
│   │       └── registry_schema.py # 등기부 정보추출 스키마 (Information Extract용)
│   ├── scripts/
│   │   └── test_extract.py        # Information Extract 실호출 검증 스크립트
│   ├── requirements.txt
│   └── .env                       # UPSTAGE_API_KEY (git 미추적)
├── frontend/                      # Flutter 앱 (안드로이드 우선)
│   └── lib/
│       ├── main.dart              # 앱 엔트리 (Provider 주입 + 라우터)
│       ├── app/                   # config(baseUrl)·router
│       ├── design_system/         # 토큰·테마·공용 컴포넌트·갤러리
│       ├── models/                # 데이터 모델 (더미 = 향후 API 계약 형태)
│       ├── repositories/          # 저장소 인터페이스 (Dummy ↔ Api 교체 지점)
│       ├── services/              # 검증된 업로드 서비스 등
│       ├── state/                 # 세션(회원/비회원) 등 앱 상태
│       ├── screens/               # 화면 (온보딩~마이)
│       └── utils/                 # 금액·날짜 포맷 등
├── docs/                          # 기획·결정 문서 (위 표 참고)
├── .claude/                       # Claude Code 규칙·명령·서브에이전트
│   ├── rules/                     # risk-scoring, api-design
│   ├── commands/                  # add-decision
│   └── agents/                    # 리뷰 서브에이전트 6종
├── CLAUDE.md
├── .gitignore
└── README.md
```

## 백엔드 실행 방법

```bash
cd backend

# (권장) 가상환경 — 폴더를 옮겼다면 .venv를 지우고 새로 만드세요
python -m venv .venv
# Windows PowerShell:  .venv\Scripts\Activate.ps1
# macOS/Linux:         source .venv/bin/activate

pip install -r requirements.txt
uvicorn app.main:app --reload
```

실행 후 <http://127.0.0.1:8000> 접속 시 `{"status":"ok"}` 가 보이고,
API 문서는 <http://127.0.0.1:8000/docs> 에서 확인할 수 있습니다.

### 이미지 업로드 엔드포인트 테스트 (curl)

`POST /api/upload` 는 이미지 1개를 multipart/form-data로 받아 메타데이터를 돌려줍니다.
(현재 단계에서는 정보추출을 하지 않고 "받았다"는 응답만 합니다. 실기능은 Phase E-1에서 교체.)

```bash
curl -X POST http://127.0.0.1:8000/api/upload \
  -F "file=@test.jpg;type=image/jpeg"
```

- 허용 형식: `image/jpeg`, `image/png`, `image/webp` (그 외에는 400, 한국어 메시지)
- 용량 상한: 10MB (초과 시 413, 한국어 메시지)

## 앱(프론트엔드) 실행 방법

이 앱은 **안드로이드 실기기 전용**으로 개발·시연합니다. (에뮬레이터·웹 기준 아님)

```bash
cd frontend
flutter pub get

# 실기기를 USB로 연결한 뒤, 앱↔서버 통신이 필요하면 포트를 터널링합니다.
adb reverse tcp:8000 tcp:8000

flutter run
```

- 백엔드 주소는 [frontend/lib/app/config.dart](frontend/lib/app/config.dart)의 `baseUrl` 상수로
  분리되어 있으며, **`http://127.0.0.1:8000` 으로 고정**돼 있습니다.
- `adb reverse` 를 쓰면 폰의 `127.0.0.1:8000` 요청이 USB 터널을 통해 PC로 전달되므로,
  **Wi-Fi 네트워크와 무관하게 USB만 연결되면 동작**합니다. (PC의 LAN IP를 매번 확인할 필요 없음)
- ⚠ `adb reverse` 는 **USB 재연결·PC 재부팅 시마다 다시 실행**해야 합니다.
```
