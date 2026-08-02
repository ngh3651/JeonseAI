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
> | **[docs/team-setup.md](docs/team-setup.md)** | **pull 받아 앱으로 실제 분석 테스트하는 법 (Upstage 키 발급·실행 순서)** |
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

시연은 **안드로이드 실기기 우선**이지만, **에뮬레이터로도 동일하게 테스트**할 수 있습니다.
팀원용 상세 절차(Upstage 키 발급 포함)는 **[docs/team-setup.md](docs/team-setup.md)**를 보세요.

```bash
cd frontend
flutter pub get

# 앱↔서버 통신 포트 터널링 — 에뮬레이터/실기기 공통.
# 앱의 127.0.0.1:8000 요청이 PC의 백엔드로 연결됩니다.
adb reverse tcp:8000 tcp:8000

flutter run
```

- 백엔드 주소는 [frontend/lib/app/config.dart](frontend/lib/app/config.dart)의 `baseUrl` 상수로
  분리되어 있으며, **`http://127.0.0.1:8000` 으로 고정**돼 있습니다.
- `adb reverse` 를 쓰면 폰의 `127.0.0.1:8000` 요청이 USB 터널을 통해 PC로 전달되므로,
  **Wi-Fi 네트워크와 무관하게 USB만 연결되면 동작**합니다. (PC의 LAN IP를 매번 확인할 필요 없음)
- ⚠ `adb reverse` 는 **USB 재연결·PC 재부팅 시마다 다시 실행**해야 합니다.

---

## 시세 자동조회 — **데이터 파일 도착 후 할 일** (2026-08-03)

> 코드는 전부 완성돼 있고 **데이터 파일만 없습니다.** 아래 순서대로 하면 동작합니다.
> 지금 상태에서도 앱은 정상 동작합니다 — 전세가율이 '확인 필요'로 남을 뿐입니다.

### 왜 필요한가 (30초)

실거래가 API만으로는 커버리지가 낮습니다. 실측 2건이 모두 실패했습니다 — 같은 면적 거래가
없거나 같은 지번 거래 자체가 없었습니다. 시세가 비면 **전세가율뿐 아니라 선순위채권 비율
판정까지 함께 죽어** 등급이 변별력을 잃습니다. 공시가격·기준시가는 정부가 매년 전수
산정하므로 이 한계가 없습니다.

### ① 파일을 어디에 둘지

```
backend/data/price/raw/          ← 여기에 받은 파일을 그대로 둡니다 (압축 풀지 않아도 됨)
```

| 받을 것 | 어디서 | 파일 형태 |
|---|---|---|
| 공동주택 공시가격 | 공공데이터포털 `국토교통부_공동주택 공시가격정보` | CSV 또는 ZIP |
| 오피스텔 기준시가 | 공공데이터포털 `국세청_오피스텔 및 상업용 건물 기준시가` | CSV 또는 ZIP |

> 압축 안의 **샘플데이터·레이아웃참고자료**를 꼭 함께 열어 보세요 — ③에서 컬럼을 확인할 때 씁니다.
> 이 폴더는 `.gitignore` 처리돼 있습니다. **git에 올리지 마세요** (수 GB).

### ② 어떤 명령을 어떤 순서로

```bash
cd backend
.venv/Scripts/python.exe scripts/price_status.py          # 지금 어디까지 됐는지
```

그다음 **소스마다** 아래 3단계를 반복합니다 (`--source official_price` / `--source tax_base`).

```bash
# 1) 구조 탐지 — 무엇이 들었는지 보고 매핑 초안을 만든다
.venv/Scripts/python.exe scripts/inspect_price_source.py \
    "data/price/raw/공동주택공시가격.zip" --source official_price --write

# 2) 사람이 확인 — backend/data/price_sources.json 을 열어 3가지를 채운다
#      price_unit      won | thousand_won | man_won
#      price_is_total  호별 총액이면 true, ㎡당 단가면 false
#      as_of           기준일 'YYYY-MM-DD' (2025년분이면 2025-01-01)
#    columns 를 ①의 레이아웃참고자료와 대조한 뒤  verified 를 true 로 바꾼다

# 3) SQLite 변환 (전국이 부담되면 --region 으로 좁힌다)
.venv/Scripts/python.exe scripts/build_price_db.py \
    "data/price/raw/공동주택공시가격.zip" --source official_price
#   시험 삼아 먼저 돌려보려면:  --limit 100000
#   수도권만:                  --region 서울 --region 경기 --region 인천
```

마지막으로 다시 점검하고, 괴리를 실측합니다.

```bash
.venv/Scripts/python.exe scripts/price_status.py
.venv/Scripts/python.exe scripts/measure_price_gap.py --lawd 11680 --lawd 11470 --limit 100
```

### ③ 각 단계에서 무엇이 보여야 정상인지

| 단계 | 정상 신호 | 이상 신호 |
|---|---|---|
| `price_status.py` (처음) | 실거래가 ✅ / 공시가격 ❌ / 기준시가 ❌ | 실거래가도 ❌면 `.env`의 `MOLIT_API_KEY`부터 |
| `inspect_price_source.py` | `인코딩 cp949 로 디코드 성공 (한글 N자 확인)` · 컬럼 목록에 한글이 정상 표시 · 필드마다 후보가 **근거와 함께** 제안됨 | 컬럼 이름이 `???`·`앾똠` 같으면 인코딩 오판 → `--member`로 다른 파일 지정 |
| 가격 단위 추정 | `price_unit=won 총액으로 보면 6.20억원` 처럼 **현실적인 금액**이 나오는 조합이 하나 | 어느 조합도 현실적이지 않으면 가격 컬럼 후보가 틀린 것 |
| `build_price_db.py` | 마지막에 **`✅ 검증 통과`** + `일치 10/10` | `❌` 가 하나라도 있으면 **그 DB를 쓰지 마세요** |
| 변환 통계 | 버린 행이 전체의 몇 % 수준 | 버린 행이 **절반을 넘으면** 컬럼 매핑이 틀렸을 가능성 |
| `price_status.py` (나중) | 공시가격 ✅ + 행 수·기준일 표시 | — |
| `measure_price_gap.py` | 실거래가÷공시기준 **중앙값이 1.0 근처** | 크게 벗어나면 140% 배수를 다시 정해야 함 |

### ④ 실패하면 무엇을 봐야 하는지

| 증상 | 원인·조치 |
|---|---|
| `컬럼 매핑이 아직 설정되지 않았습니다` | `price_sources.json`의 `verified`가 `false`. ②의 3가지를 채우고 `true`로 |
| `설정에 적힌 컬럼을 파일에서 찾지 못했습니다` | 출력된 **파일의 실제 컬럼**과 대조. `inspect --write`로 초안을 다시 만들면 됨 |
| `파일을 cp949 로 읽지 못했습니다` | `file_encoding`을 `utf-8`·`utf-8-sig`로 바꿔 재시도 |
| 버린 행 대부분이 `지번 없음` | `jibun_bon`/`jibun_bu` 매핑이 다른 컬럼을 가리키는 중 |
| 버린 행 대부분이 `기준일 없음` | `as_of`(소스 기준일)를 안 채웠거나 `columns.as_of`가 틀림 |
| `⚠ 공유면적이 빈 행 N건` 경고 | `price_is_total`이 `false`인데 공유면적이 비어 총액이 낮게 계산됨. 건수가 크면 매핑 재확인 |
| 앱에서 시세가 여전히 안 채워짐 | 서버 로그의 `[시세]` 줄을 보세요 — 후보·채택·괴리가 전부 찍힙니다 |
| 자동 조회가 되는데 값이 이상함 | 로그의 `매칭 dong_ho / ho / area / jibun_single` 을 확인. `area`·`jibun_single`은 느슨한 매칭이라 의심해 볼 것 |

### 지금 상태에서 이미 되는 것 / 안 되는 것

- ✅ 실거래가 조회(키가 있으면) · 단독·다가구 판정 보류 · 리포트에 출처 표시
- ❌ 공시가격·기준시가 조회(데이터 없음) · 괴리 탐지(두 소스가 다 있어야 함)
- ⚠ **단독·다가구는 데이터가 와도 전세가율을 내지 않습니다.** 등기부가 1개라
  앞순위 세입자 보증금 합계를 알 수 없기 때문입니다 — 의도된 한계입니다.
```
