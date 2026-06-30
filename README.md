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
