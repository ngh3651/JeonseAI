# 시스템 아키텍처 (architecture.md)

> 전세AI프의 최종 산출물 기획을 기반으로 한 아키텍처 플로우차트입니다.
> Phase E(더미→실기능 교체) 기준으로, **핵심 불변 원칙인 "규칙 엔진이 판정 → LLM은 설명만"
> 가드레일**이 구조에 어떻게 박혀 있는지를 중심으로 그렸습니다.
>
> 상태 표기: ✅ 구현 완료 · 🔄 진행 중 · ⏳ 예정(Phase 표기)
>
> GitHub·VS Code(Mermaid 확장)·Obsidian 등에서 다이어그램이 렌더링됩니다.

---

## 1. 전체 시스템 아키텍처

앱은 계약(api-contract.md)만 알고 서버 내부는 모릅니다. 서버는 라우터 → 서비스 계층으로
분리되고, 국내 AI(Upstage)만 외부 호출합니다.

```mermaid
flowchart TB
    subgraph APP["📱 Flutter 앱 (안드로이드 우선)"]
        direction TB
        SCR["화면 screens/<br/>홈·검색·로딩·리포트·판례·시뮬레이터·질문·챗봇"]
        REPOIF["Repository 인터페이스<br/>(화면은 여기에만 의존)"]
        APIREPO["ApiAnalysisRepository<br/>ApiContentRepository"]
        CLIENT["api_client.dart<br/>(멀티파트·타임아웃 180초)"]
        SCR --> REPOIF --> APIREPO --> CLIENT
    end

    subgraph SERVER["🖥️ FastAPI 백엔드"]
        direction TB
        ROUTER["라우터 routers/<br/>reports.py · content.py<br/>(엔드포인트 9종)"]
        AUTH["get_current_user<br/>(개발모드=항상 통과)"]
        SVC["서비스 계층 services/"]
        ROUTER -.인증.-> AUTH
        ROUTER --> SVC
    end

    subgraph UPSTAGE["🇰🇷 국내 AI · Upstage"]
        IE["Information Extract<br/>(등기부 구조화 추출)"]
        SOLAR["Solar Pro 2<br/>(설명 문장 생성)"]
    end

    CLIENT -->|"HTTP · adb reverse<br/>127.0.0.1:8000"| ROUTER
    SVC -->|"이미지→PDF 병합·1회 호출"| IE
    SVC -->|"판정 JSON만 전달"| SOLAR

    classDef app fill:#E3F2FD,stroke:#1565C0,color:#0D47A1
    classDef server fill:#E8F5E9,stroke:#2E7D32,color:#1B5E20
    classDef ai fill:#FFF3E0,stroke:#E65100,color:#BF360C
    class SCR,REPOIF,APIREPO,CLIENT app
    class ROUTER,AUTH,SVC server
    class IE,SOLAR ai
```

---

## 2. 사용자 기능 여정 (화면 단위 E2E)

앱 실행부터 안전도 리포트까지, 그리고 리포트에서 갈라지는 심화 기능·상시 보조 기능까지의
사용자 흐름입니다. **핵심은 안전도 리포트**이고, 판례·시뮬레이터·질문은 리포트에서 파생됩니다.

```mermaid
flowchart TB
    START(["앱 실행"]) --> ONB["온보딩 · 시작<br/>로그인/비회원 (로컬 목업)"]
    ONB --> HOME["🏠 홈 대시보드<br/>분석 이력 · 기능 바로가기"]

    HOME -->|"＋ 분석 시작<br/>(비회원은 로그인 유도)"| SEARCH["매물 검색<br/>등기부등본 사진 여러 장<br/>＋ 예정 전세보증금(필수)·시세(선택)"]
    SEARCH --> LOAD["분석 로딩"]
    LOAD --> PIPE{{"분석 파이프라인<br/>OCR → 규칙 판정 → 쉬운 설명<br/>(상세 §3)"}}
    PIPE --> REPORT["📋 안전도 리포트 ✅<br/>등급 게이지 → 지금 해야 할 일<br/>→ 근거 카드 펼쳐보기"]

    REPORT --> CASES["⚖️ 판례 매칭 🔄<br/>이 매물 위험과 비슷한 실제 판결<br/>(차별화 · 큐레이션 매칭 E-3)"]
    REPORT --> SIM["📉 손실 시뮬레이터 🔄<br/>경매 시 예상 손실·반환금<br/>(앱 로컬 계산 · 실계산 E-4)"]
    REPORT --> QST["❓ 중개사 질문 생성 ✅<br/>위험 요인별 물어볼 질문"]

    subgraph AMBIENT["🧭 상시 보조 (어디서나 진입)"]
        direction LR
        CHAT["💬 용어 챗봇<br/>용어만 쉽게 설명<br/>(판정·조언 안 함 · 실사전 E-5)"]
        JRN["🗺️ 계약 여정 체크리스트 ✅<br/>계약 전~입주 후 단계별 할 일"]
        GUIDE["📄 등기부등본 발급 가이드 ✅"]
    end
    HOME -.-> AMBIENT
    REPORT -.->|"용어 탭 · 다음 행동"| AMBIENT

    BACKLOG["🔮 백로그: CODEF 주소 자동조회<br/>주소만 입력 → 등기부 자동 발급"]
    BACKLOG -.->|"향후 대체 입력"| SEARCH

    classDef core fill:#E8F5E9,stroke:#2E7D32,color:#1B5E20,font-weight:bold
    classDef prog fill:#FFF9C4,stroke:#F9A825,color:#F57F17
    classDef flow fill:#E3F2FD,stroke:#1565C0,color:#0D47A1
    classDef amb fill:#F3E5F5,stroke:#6A1B9A,color:#4A148C
    classDef todo fill:#F5F5F5,stroke:#9E9E9E,color:#616161
    class REPORT,QST core
    class CASES,SIM prog
    class START,ONB,HOME,SEARCH,LOAD,PIPE flow
    class CHAT,JRN,GUIDE amb
    class BACKLOG todo
```

- **핵심(✅ 동작)**: 안전도 리포트 · 중개사 질문 생성 · 계약 여정 체크리스트 · 발급 가이드 · 홈/검색/로딩
- **🔄 화면 완성, 실기능 교체 대기**: 판례 매칭(위험 패턴 파생은 동작, 큐레이션 매칭 **E-3**) ·
  손실 시뮬레이터(계산은 예시값, 낙찰가율 출처 확보 후 실계산 **E-4**)
- **용어 챗봇**: 화면 동작(더미 사전) → **E-5**에서 `glossary.json` 실데이터로 분리
- 비회원은 **매물 분석 진입 시점에만** 로그인 유도(그 외 보조 기능은 자유 이용 — decisions.md 2026-07-03)

---

## 3. 분석 파이프라인 (핵심) — `POST /api/analyze`

등기부 사진 한 장이 안전도 리포트가 되기까지. **판정은 규칙 엔진이 확정하고, LLM은 그
판정을 받아 문장만 만든다**는 흐름이 한 방향으로 고정돼 있습니다.

```mermaid
flowchart TB
    START(["등기부 사진 여러 장<br/>+ 보증금 · 시세?"]) --> RB["report_builder.analyze()<br/>(조립 오케스트레이터)"]

    RB --> EXT["extraction.py<br/>이미지→PDF 병합→Upstage IE 호출"]
    EXT -->|"요약본 감지 시"| REJECT["400 거부<br/>'말소사항 포함 전부증명서로 올려주세요'"]
    EXT --> PARSE["RegistryExtract (schemas/internal.py)<br/>금액 파싱 실패=None '미상'(0 치환 금지)<br/>말소 불명=유효 간주"]

    PARSE --> RULE["⚖️ rule_engine.evaluate()<br/>근거 5종 판정"]
    THR["thresholds.py<br/>전세가율 90/80 · 선순위 60/90<br/>(← decisions.md 출처)"] -.기준값.-> RULE

    RULE --> VERDICT["🔒 RuleVerdict [판정 확정]<br/>grade · gaugeProgress<br/>seniorDebtAmount · evidences[]"]

    VERDICT --> EXP["explanation.py → Solar Pro<br/>설명 문장만 생성"]
    EXP -->|"실패·타임아웃·금지어"| FB["fallback_texts.py<br/>결정적 기본 문구"]
    EXP -->|"성공"| MERGE
    FB --> MERGE

    MERGE["report_builder 병합<br/>판정 필드 = verdict에서만 복사<br/>설명 필드 = LLM/폴백"]
    MERGE --> STORE["store.py (인메모리 이력)"]
    STORE --> REPORT(["Report (계약 §2.1)<br/>결론 크게 → 근거 펼침"])

    classDef judge fill:#E8F5E9,stroke:#2E7D32,color:#1B5E20,font-weight:bold
    classDef llm fill:#FFF3E0,stroke:#E65100,color:#BF360C
    classDef data fill:#F3E5F5,stroke:#6A1B9A,color:#4A148C
    classDef stop fill:#FFEBEE,stroke:#C62828,color:#B71C1C
    class RULE,VERDICT judge
    class EXP llm
    class THR data
    class REJECT stop
```

---

## 4. 가드레일 — LLM이 판정을 바꿀 수 없는 이유

"LLM은 통역사"라는 원칙이 **코드 구조로 강제**됩니다. 판정 필드가 LLM 출력 모델에
아예 존재하지 않아서, 환각이 섞여도 판정에 닿을 통로가 없습니다.

```mermaid
flowchart LR
    subgraph RULEZONE["⚖️ 규칙 엔진 영역 (판정 = 신뢰)"]
        RV["RuleVerdict<br/>grade · gauge · 금액 · evidence 등급"]
    end

    subgraph LLMZONE["🤖 LLM 영역 (설명만)"]
        direction TB
        IN["입력: 판정 JSON만<br/>(원본 이미지·추출 원본 전달 금지)"]
        OUT["출력: ExplanationPayload<br/>extra='forbid'<br/>headline · easy_explanation 만"]
        IN --> OUT
    end

    RV -->|"판정 요약 전달"| IN
    OUT -->|"설명 문장"| MERGE{{"report_builder 병합"}}
    RV ==>|"판정 필드는<br/>오직 여기서만"| MERGE
    MERGE --> REPORT["Report"]

    TAMPER["LLM이 grade='양호' 끼워넣기 시도"] -.->|"extra=forbid<br/>검증 실패"| DROP["폐기 → 폴백"]
    DROP -.-> MERGE

    NOTE["🧪 test_explanation_guardrail.py<br/>판정 조작해도 최종 판정 불변 assert"]

    classDef judge fill:#E8F5E9,stroke:#2E7D32,color:#1B5E20,font-weight:bold
    classDef llm fill:#FFF3E0,stroke:#E65100,color:#BF360C
    classDef test fill:#EDE7F6,stroke:#4527A0,color:#311B92
    classDef stop fill:#FFEBEE,stroke:#C62828,color:#B71C1C
    class RV judge
    class IN,OUT llm
    class NOTE test
    class TAMPER,DROP stop
```

**설명 실패해도 리포트는 항상 완성됩니다** — Solar Pro 호출이 실패/타임아웃/금지어에 걸리면
해당 부분만 `fallback_texts`의 결정적 문구로 치환하고, 판정은 그대로 나갑니다. 분석 실패로
격상되지 않습니다.

---

## 5. 엔드포인트 ↔ 서비스 매핑 (구현 상태)

```mermaid
flowchart LR
    subgraph EP["엔드포인트 (계약 9종)"]
        direction TB
        E1["POST /api/analyze ✅"]
        E2["GET /api/reports ✅"]
        E3["GET /api/reports/{id} ✅"]
        E4["DELETE /api/reports/{id} ✅"]
        E5["GET .../cases 🔄"]
        E6["GET .../questions ✅"]
        E7["GET /api/journey-stages ✅"]
        E8["GET /api/glossary ⏳"]
        E9["GET /api/glossary/lookup ⏳"]
    end

    E1 --> RB2["report_builder<br/>→ extraction·rule_engine·explanation·store"]
    E2 --> ST["store.py"]
    E3 --> ST
    E4 --> ST
    E5 --> CASE["patterns.py (위험패턴 파생) ✅<br/>+ 판례 매칭 🔄"]
    E6 --> Q["questions.py + data/questions.json ✅"]
    E7 --> DUM["dummy_data.py<br/>(정적 콘텐츠)"]
    E8 --> DUM
    E9 --> DUM

    CASE -.->|"E-3 예정"| CASEJSON["data/cases.json 실매칭"]
    DUM -.->|"E-5 예정"| GLOS["data/glossary.json"]

    classDef done fill:#E8F5E9,stroke:#2E7D32,color:#1B5E20
    classDef prog fill:#FFF9C4,stroke:#F9A825,color:#F57F17
    classDef todo fill:#F5F5F5,stroke:#9E9E9E,color:#616161
    class E1,E2,E3,E4,E6,E7,RB2,ST,Q done
    class E5,CASE prog
    class E8,E9,DUM,CASEJSON,GLOS todo
```

- 🔄 **판례(cases)**: 위험 패턴 파생은 실동작(`patterns.py`)하지만 매칭은 아직 더미 — **E-3**에서
  `data/cases.json` 큐레이션 매칭으로 교체.
- ⏳ **용어(glossary)**: 아직 `dummy_data` — **E-5**(여유 시)에서 `data/glossary.json`으로 분리.
- **여정(journey-stages)**: 정적 콘텐츠라 교체 대상 아님(계약상 모든 사용자 동일).

---

## 6. 데이터 소스 & 팀 편집 영역

수치는 **권위 출처 → decisions.md → 코드** 순서로만 흐르고, 큐레이션 콘텐츠는 비개발
팀원이 코드 없이 채웁니다.

```mermaid
flowchart TB
    subgraph AUTH_SRC["📚 권위 출처 (수치의 근거)"]
        HUG["HUG 전세보증 가입요건"]
        REB["한국부동산원 사이렌"]
        LAW["법제처 · 주임법"]
    end

    DEC["decisions.md<br/>(출처와 함께 기록 · append-only)"]
    HUG --> DEC
    REB --> DEC
    LAW --> DEC
    DEC -->|"1:1 대응 주석"| THR2["services/thresholds.py<br/>(코드의 유일한 수치 저장소)"]
    THR2 --> RULE2["rule_engine ⚖️"]

    subgraph TEAM["✍️ 비개발 팀원 편집 (backend/data/)"]
        direction TB
        CASES["cases.json — 판례 (정민재)"]
        QJSON["questions.json — 중개사 질문 (최가은)"]
        BL["blacklist.json — 악성임대인 (김시원)"]
    end

    QJSON --> QSVC["questions.py<br/>템플릿+조건부 변형"]
    CASES -.->|"E-3"| CASESVC["case_matching (예정)"]
    BL --> RULE2

    RA["🔍 rule-auditor<br/>출처 없는 수치 감사"] -.감사.-> THR2

    classDef src fill:#E1F5FE,stroke:#0277BD,color:#01579B
    classDef data fill:#F3E5F5,stroke:#6A1B9A,color:#4A148C
    classDef team fill:#FFF8E1,stroke:#FF8F00,color:#E65100
    classDef audit fill:#EDE7F6,stroke:#4527A0,color:#311B92
    class HUG,REB,LAW src
    class DEC,THR2 data
    class CASES,QJSON,BL team
    class RA audit
```

---

## 7. 배포·연결 (개발/시연 환경)

```mermaid
flowchart LR
    PHONE["📱 안드로이드 기기<br/>(실기기/에뮬레이터)"]
    subgraph PCBOX["💻 개발 PC"]
        UV["uvicorn :8000<br/>run-backend.ps1"]
        ENV[".env<br/>UPSTAGE_API_KEY"]
        UV --- ENV
    end
    PHONE <-->|"adb reverse tcp:8000<br/>(USB 터널 · Wi-Fi 무관)"| UV
    UV <-->|"HTTPS"| CLOUD["🇰🇷 Upstage API"]

    classDef dev fill:#ECEFF1,stroke:#455A64,color:#263238
    classDef ai fill:#FFF3E0,stroke:#E65100,color:#BF360C
    class PHONE,UV,ENV dev
    class CLOUD ai
```

---

## 핵심 불변 원칙 (아키텍처에 박힌 것)

1. **판정 = 규칙 엔진, 설명 = LLM** — LLM 출력 모델에 판정 필드가 없어 구조적으로 차단 (§3·§4)
2. **출처 없는 수치 금지** — 모든 임계값은 `decisions.md → thresholds.py`만 경유 (§6)
3. **보수적 편향** — 금액 파싱 실패=미상(0 치환 금지), 말소 불명=유효 간주, 페이지 누락 시 양호 금지 (§3)
4. **앱↔계약 무변경** — 실기능 교체는 서버 내부(services/)에서만 (§1·§5)
5. **국내 AI만** — Upstage Information Extract + Solar Pro (§1)
