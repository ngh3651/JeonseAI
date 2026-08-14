<div align="center">

# 전세AI프 (JeonseAI)

**등기부등본을 찍으면, 전세사기 위험을 규칙으로 판정하고 쉬운 말로 설명해 주는 앱**

부동산을 모르는 사람이 계약 **전에** 스스로 위험을 확인할 수 있게 만든 안드로이드 앱입니다.
AI ROOKIE 본선 프로젝트.

![Flutter](https://img.shields.io/badge/Flutter-3.41-02569B?logo=flutter&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-Python_3.14-009688?logo=fastapi&logoColor=white)
![Upstage](https://img.shields.io/badge/Upstage-Information_Extract-6A5ACD)
![Upstage](https://img.shields.io/badge/Upstage-Document_OCR-6A5ACD)
![Upstage](https://img.shields.io/badge/Upstage-Solar_Pro_2-6A5ACD)
![Chroma](https://img.shields.io/badge/Chroma-precedent_RAG-FF6F61)
![pytest](https://img.shields.io/badge/pytest-687_passing-brightgreen?logo=pytest&logoColor=white)
![flutter test](https://img.shields.io/badge/flutter_test-188_passing-brightgreen?logo=flutter&logoColor=white)

</div>

---

<!-- TODO(규혁): 홈 / 리포트 / 뷰어 스크린샷 3장을 docs/images/ 에 넣고 아래 경로를 맞춰 주세요.
     파일명 예시: home.png · report.png · viewer.png (권장 폭 300px 내외, 3칸 나란히) -->

<div align="center">

| 홈 | 리포트 | 등기부 뷰어 |
|:---:|:---:|:---:|
| <img src="docs/images/home.png" width="240"> | <img src="docs/images/report.png" width="240"> | <img src="docs/images/viewer.png" width="240"> |
| 내 분석 이력과 잔금 D-1 경고 | 결론을 먼저, 근거는 펼쳐서 | 사진 위에 근거의 위치를 표시 |

</div>

---

## 무엇이 다른가

### 판정에는 AI가 없다

위험 등급은 규칙 엔진이 정하고, LLM은 **이미 정해진 판정을 사람 말로 옮기는 일만** 한다.
설명 생성기의 출력 스키마(`ExplanationPayload`)는 `extra="forbid"`이고 그 안에 등급·점수·금액
필드가 **아예 존재하지 않는다.** 모델이 `grade` 같은 키를 실어 보내면 검증에서 통째로 탈락하고
준비된 문구가 대신 나간다. 프롬프트로 "판정하지 마"라고 부탁하는 대신, 판정을 실어 보낼
통로 자체를 스키마에서 없앴다.

### 모르면 위험 쪽으로 말한다

미탐(위험을 놓침)은 오탐보다 훨씬 치명적이다. 그래서 서류가 불완전하거나 시세를 확인하지
못하면 **'양호'로 떨어지지 않고 '확인 필요'로 올라간다**(`floor_caution` 단일 지점). 종합
등급은 근거 카드 중 가장 나쁜 것을 따른다(worst-of). 단독·다가구는 등기부 한 장으로
앞순위 세입자 보증금 합계를 알 수 없어 전세가율을 **아예 내지 않는다** — 계산할 수 없는 것을
계산한 척하지 않는 쪽을 택했다.

### 출처 없는 숫자는 화면에 못 나간다

모든 임계값은 `backend/app/services/thresholds.py` 한 파일에만 있고, 상수마다 `decisions.md`
항목(날짜·출처)이 1:1로 붙어 있다 — 전세가율 90%는 HUG 담보인정비율, 선순위채권 60%는 HUG
가입요건이다. 감으로 정한 숫자는 코드에 넣지 않는다. 용어 툴팁도 같은 규칙을 따른다:
`terms.json`의 35개 중 근거를 댈 수 있는 27개(`verified=true`)만 앱으로 나가고, 나머지는
로드는 되지만 응답에서 걸러진다.

### 말소를 아는 형광펜

분석 결과를 등기부 **원본 사진 위에** 번호와 함께 표시한다(14종). 여기서 어려운 건 좌표가
아니라 **말소**다. 이미 갚아서 취소선이 그어진 근저당에 형광펜을 칠하면, 사용자는 없는 빚을
보고 겁을 먹는다. 그래서 `N번○○말소` 표기를 줄 원문에서 읽어 말소된 순위를 걷어내고, 표지와
꼬리말에 인쇄되는 상투구("말소사항 포함")는 말소 표식에서 제외한다. 말소를 판별하는 정규식은
프로젝트 전체에 **한 벌만** 둔다 — 두 벌이 되면 경로마다 '말소를 보는 눈'이 갈라진다.

### 판례는 사람이 검수했다

법제처 API로 실판례 원문 161건을 모아, 전세사기 관련성과 위험 태그 필터를 통과한 40건을
인덱싱했다(청크 612개). 그중 11건은 쉬운 말 요약과 조언까지 사람이 큐레이션했고, 4건은
사람이 사유를 적어 명시적으로 뺐다. 검수는 두 단계다 — ⑴ **출처 검증**: 사건번호를 공식 DB
원문 또는 교차 출처 2곳으로 확인 ⑵ **문구 검수**: 팀 법률 담당이 요약·조언 문장을 읽는다
(현재 10건 완료). 사용자에게 나가려면 세 관문을 전부 통과해야 한다: **출처가 확인된 판례일 것
· 판정 태그와 교집합이 1개 이상일 것 · 벡터 유사도가 하한선(0.45) 이상일 것.** 하나라도
미달이면 억지로 붙이지 않고 "아직 찾지 못했다"고 말한다. 문구 검수 전 판례는 차단하는 대신
카드에 검수 상태를 그대로 밝힌다.

### 챗봇은 규칙이 먼저 막는다

용어 챗봇은 LLM에 닿기 전에 규칙을 세 겹 지난다. **L1 판정 요구 차단**(규칙) → **L2 검수된
사전 직격** → **L3 도메인 게이트**(규칙) → **L4 Solar 생성 + 검증**. L1이 맨 앞인 것이 이
설계의 전부다: "근저당 잡힌 이 집, 계약해도 돼요?"는 사전에도 걸리고 도메인 키워드도 있어서,
판정 게이트가 뒤에 있으면 그대로 새 나간다. 거절을 모델에게 맡기지 않는 이유도 같다 —
프롬프트는 언젠가 뚫리지만 정규식은 안 뚫린다. 생성된 답변에 아라비아 숫자가 하나라도 있으면
폐기한다(챗봇에는 검증할 재료가 없어 화이트리스트를 만들 수 없다). 키가 없거나 타임아웃이
나면 예전과 똑같이 사전 기반으로 동작한다.

---

## 핵심 흐름

| # | 화면 | 무슨 일이 일어나는가 |
|---|---|---|
| 1 | 촬영 (`/analyze`) | 등기부등본을 여러 장 이어 찍고 보증금을 입력한다. 사진은 PDF로 병합해 추출 API를 **1회만** 호출한다 |
| 2 | 로딩 (`/loading`) | 추출 → 규칙 판정 → 설명 생성이 순서대로 돈다. 진행 단계를 문장으로 알려준다 |
| 3 | 리포트 (`/report/:id`) | 결론(등급)을 먼저 크게, 근거 카드 5장(전세가율·선순위채권·소유권·보증보험·악성임대인)은 펼쳐서 본다 |
| 4 | 등기부 뷰어 (`/registry/:id`) | 내가 찍은 사진 위에 번호가 붙는다. "이 말이 서류 어디에 있는지"를 눈으로 확인한다 |
| 5 | 판례 (`/cases/:id`) | 내 위험 신호와 태그가 겹치는 실제 대법원 판례를 카드로 보여준다 |
| 6 | 질문 (`/questions/:id`) | 판정 결과에서 파생된, 집주인·중개인에게 그대로 읽어 주면 되는 질문 목록 |
| 7 | 시뮬레이터 (`/simulator/:id`) | 경매로 넘어가면 보증금이 얼마나 돌아오는지 슬라이더로 움직여 본다 |
| 8 | 계약 여정 (`/journey`) | 계약 9단계 안내. 그중 4단계에서 "등기부 다시 떼기" 버튼이 뜬다 |
| 9 | 등기부 대조 (`/compare/:id`) | 계약 때 뗀 서류와 오늘 뗀 서류를 항목 단위로 맞춰본다 — **그 사이에 근저당이 새로 잡혔는지** 알려준다 |
| 10 | 용어 챗봇 (`/chatbot`) | 리포트에 나온 말이 무슨 뜻인지 물어본다. 판정은 절대 대답하지 않는다 |

---

## AI를 어디에 쓰나

전부 **국내 모델**이다(대회 규정). 모델명은 실제 호출 문자열이며, `.env`로 전부 교체 가능하다.

| 위치 | 모델 (호출 문자열) | 역할 | 가드레일 |
|---|---|---|---|
| 등기부 구조화 | `information-extract`<br/>`v1/information-extraction` | 사진 → 최상위 14개 필드로 구조화. 모든 등기 항목에 `is_canceled` 포함 | 스키마 고정(`response_format`). 판정 계층은 이 결과를 **읽기만** 한다 |
| 사진 글자·좌표 | `ocr`<br/>`v1/document-digitization` | 글자와 좌표를 얻어 원본 사진 위 하이라이트를 그린다 | 좌표만 쓴다. 등급을 만들지 않는다 |
| 두 번째 판독 (교차검증) | `solar-pro2`<br/>`v1/solar` | OCR 줄·칸 텍스트를 다시 구조화해 추출 결과와 대조 | **판정은 추출(IE) 기준으로 고정.** 불일치는 사용자 고지·표시 보류에만 쓴다. `LLM_STRUCTURE_PROVIDER=off`로 끌 수 있다 |
| 근거 설명 문장 | `solar-pro2` | 판정 JSON → 근거 카드의 쉬운 말 설명 | 출력 스키마에 등급·점수·금액 필드 없음(`extra="forbid"`). 단정 금지어·숫자 화이트리스트 검증. 실패 시 준비된 문구 |
| 판례 읽기 보조 | `solar-pro2` | 검색된 판례의 공통점 문장 작성 + 굵게 볼 구간 선택 | 사건번호·출처·조언은 서버가 원문에서 복사한다. 응답의 `case_id`가 검색 결과에 없으면 그 항목 폐기 |
| 판례 검색 | `embedding-passage` / `embedding-query`<br/>`v1/embeddings` | BM25 + 벡터 + 태그 필터 하이브리드 검색(RRF 융합), Chroma 저장 | **질의를 LLM이 만들지 않는다** — 규칙 판정에서 태그별 결정적 템플릿으로 생성 |
| 용어 챗봇 | `solar-pro2` | 사전에 없는 자연어 질문에 답한다 | L1~L3 규칙 게이트를 통과한 질문만 여기 닿는다. 답변에 아라비아 숫자가 있으면 폐기 |
| 섀도 비교 | `LGAI-EXAONE/K-EXAONE-236B-A23B` | 같은 입력을 두 번째 모델에도 태워 문장 품질을 로그로 비교 | **기본 OFF**(`.env`의 `SHADOW_LLM`). 아무것도 반환하지 않아 사용자 화면에 섞일 수 없다 |

---

## 숫자로 보는 프로젝트

| 항목 | 값 |
|---|---|
| 백엔드 테스트 | **687** (`pytest -q`) |
| 앱 테스트 | **188** (`flutter test`) · `flutter analyze` 무결 |
| 판례 | 수집 원문 **161**건 → 인덱스 **40**건(청크 612) → 큐레이션 **11**건 · 문구 검수 **10**건 · 명시 제외 **4**건 |
| 검수된 용어 | **27** / 35 (`verified=true`만 앱으로 나감) |
| 하이라이트 표시 종류 | **14** (정의 15종 중 1종은 스위치로 꺼 둠) |
| 시세 DB | **18,070,886**행 (공시가격 15,580,435 + 오피스텔 기준시가 2,490,451) |
| API 엔드포인트 | **12** (`/api` 11 + 헬스체크 1) |
| 등기부 추출 스키마 | 최상위 **14** 필드 |
| 계약 여정 | **9**단계 (그중 **4**단계에 등기부 대조) |

---

## 아키텍처

다이어그램과 계층별 상세는 **[docs/architecture.md](docs/architecture.md)** 에 있습니다.

앱은 계약(`docs/api-contract.md`)만 알고 서버 내부를 모른다 — 화면은 Repository 인터페이스에만
의존하고, 더미 구현과 API 구현을 갈아 끼우는 방식으로 개발했다. 서버는 라우터 → 서비스 계층으로
나뉘며, 위험 판정(`rule_engine.py`)과 문장 생성(`explanation.py`·`precedent/`·`chat.py`)이
**서로를 import하지 않는 별개 계층**이다. 판례 모듈은 판정을 읽기만 하고, 판정 모듈은 판례
모듈을 아예 참조하지 않는다 — 판례가 등급을 바꾸는 코드 경로 자체가 존재하지 않는다.
외부 호출은 Upstage(국내)뿐이고, 시세는 국토부·국세청 공개 데이터를 SQLite로 내려받아 조회한다.

---

## 실행 방법

팀원용 상세 절차(Upstage 키 발급 포함)는 **[docs/team-setup.md](docs/team-setup.md)** 를 보세요.

```bash
# 1) 백엔드 — backend/.env 에 UPSTAGE_API_KEY 를 먼저 넣습니다
cd backend && python -m venv .venv
source .venv/Scripts/activate          # PowerShell: .venv\Scripts\Activate.ps1 · macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt && uvicorn app.main:app --reload

# 2) 앱 — 안드로이드 실기기를 USB로 연결한 상태에서
cd frontend && flutter pub get
adb reverse tcp:8000 tcp:8000    # 폰의 127.0.0.1:8000 → PC 백엔드 (USB만 연결되면 Wi-Fi 무관)
flutter run
```

- 서버 주소는 `frontend/lib/app/config.dart`의 `baseUrl` 하나로 분리돼 있고 `http://127.0.0.1:8000` 고정입니다.
- ⚠ `adb reverse`는 **USB 재연결·PC 재부팅 때마다** 다시 실행해야 합니다.
- API 문서는 서버 실행 후 <http://127.0.0.1:8000/docs> 에서 볼 수 있습니다.

---

## 문서 체계

| 문서 | 역할 |
|---|---|
| [CLAUDE.md](CLAUDE.md) | 프로젝트 안내·불변 원칙·개발 방법론 (AI 협업 세션이 가장 먼저 읽는 문서) |
| [docs/architecture.md](docs/architecture.md) | 시스템 아키텍처 다이어그램 (Mermaid) |
| [docs/api-contract.md](docs/api-contract.md) | 앱↔서버 JSON 계약 — 더미↔실기능 교체의 기준점 |
| [docs/decisions.md](docs/decisions.md) | 아키텍처 결정 로그 (append-only, 의도→근거→결정 흐름으로 기록) |
| [docs/plan.md](docs/plan.md) | Phase A~F 로드맵·진행 현황 |
| [docs/IA.md](docs/IA.md) · [docs/user-scenario.md](docs/user-scenario.md) | 화면 트리·네비게이션 / 화면→버튼→액션 시나리오 |
| [docs/personas.md](docs/personas.md) | 페르소나 2인 정의 (리뷰 에이전트와 동기화) |
| [docs/registry-schema.md](docs/registry-schema.md) | 등기부 추출 스키마 설명 |
| [docs/precedent-rag.md](docs/precedent-rag.md) | 판례 RAG 파이프라인 인수인계 문서 |
| [docs/team-setup.md](docs/team-setup.md) | pull 받아 실제 분석까지 돌리는 법 (키 발급·실행 순서) |
| [docs/cleanup-tracker.md](docs/cleanup-tracker.md) | 임시·더미·스캐폴딩 정리 대상 목록 (living) |
| [docs/evaluation-criteria.md](docs/evaluation-criteria.md) | 대회 공식 배점표 |
| [docs/feedback-log.md](docs/feedback-log.md) · [docs/feedback/](docs/feedback/) | 팀·페르소나 피드백 원본과 처리 이력 |
| [docs/claude-chat/](docs/claude-chat/) | 채팅에서 확정된 결정·자료(인터뷰 정리본 등) 유입 인박스 |
| [docs/draft/](docs/draft/) | 브레인스토밍 초안 (확정 사양 아님) |
| [.claude/rules/](.claude/rules/) | `risk-scoring`(출처 없는 수치 금지) · `api-design` 규칙 |

---

## 팀 · 동크크

| 이름 | 역할 |
|---|---|
| **남규혁** | 팀장 · 메인 개발 (앱·서버 전반, 규칙 엔진, 가드레일 설계) |
| **정민재** | 법률 큐레이션 · 판례 검수 (전세사기 유형 연구, 법령·판례 자료 수집) |
| **이영호** | LLM · RAG (판례 검색 파이프라인 고도화) |
| **최가은** | 현장 인터뷰 · 검증 (부동산 중개인 인터뷰) |
| **김시원** | 경쟁 분석 · 페르소나 (유사 서비스 분석, 타깃 유저 관점) |

판정 기준에 쓰이는 수치는 **권위 있는 출처 → `docs/decisions.md` 기록 → 코드 반영** 순서로만
들어갑니다. 인터뷰 같은 비공식 자료는 문구·질문·조언 등 **판정하지 않는 계층에만** 반영합니다.

---

## 다음 단계

- **CODEF 연동** — 주소만 입력하면 등기부를 자동 발급받아 촬영 단계를 없앤다.
- **iOS** — 플랫폼 종속 코드를 격리해 두었으므로 빌드 타깃 추가로 확장한다.
- **임차인 서류 확장** — 등기부 외에 건축물대장·계약서까지 교차검증 범위를 넓힌다.
