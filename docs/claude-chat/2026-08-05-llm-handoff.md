# 설명 계층 인수인계 (2026-08-05)

> **다음 작업자에게.** 이 문서만 읽고 이어받을 수 있게 썼습니다.
> 배경이 더 필요하면 `2026-08-05-llm-explanation-audit.md`(감사) →
> `2026-08-05-llm-explanation-upgrade.md`(1차 개선) → `2026-08-05-llm-final.md`(2차) 순서.

---

## 1. 지금 어디까지 됐나

**설명 생성(LLM) 계층은 동작합니다.** 판정은 규칙 엔진이 하고 LLM은 문장만 씁니다.
이번 라운드에서 바뀐 것:

| | 상태 |
|---|---|
| 재료(LLM 입력) | 임계값·근저당 건별 상세·시세 출처·소유권 이력·**열람일시**·**찾아본 것**·**배정된 질문** |
| 문장 검증 | 패턴 6종 + 등급단어 3종 + **숫자 화이트리스트**(재료에 없는 수는 그 필드만 폴백) |
| 문단 | `\n` 4단 구성 (기준선 → 이 집 수치 → 무슨 뜻 → 확인할 행동) |
| 용어 툴팁 | `terms.json` 35개 중 **검수된 27개만** 응답에 나감. 문장 훑어 자동 부착 |
| 모델 비교 | EXAONE **그림자 로깅** (기본 OFF) + 집계 스크립트 |
| 테스트 | 561건 통과 |

## 2. 무엇이 **안** 됐나

| 미완 | 왜 |
|---|---|
| **terms.json 검수 8건** | 법령 확인이 필요. → `docs/terms-review-queue.md` (정민재) |
| **실기기에서 문단(`\n`) 렌더 확인** | `adb devices`에 기기가 없었다. 코드상 가능한 것까지만 확인 |
| **챗봇 칩 레이아웃** | 6개 → 18개로 늘었다. 앱 화면을 못 봤다 — **깨질 수 있다** |
| **하이라이트 시트 문구 15종** | 전부 백엔드 상수(`highlight.py:124 _SPECS`). LLM 미적용 — 손대지 않았다 |
| **용어 챗봇 LLM 미적용** | 여전히 부분 문자열 조회 + 404 거절. 데이터 원천만 `terms.json`으로 옮겼다 |
| **EXAONE 품질 채점** | 로그는 쌓이지만 **어느 문장이 더 좋은가는 사람이 읽어야 한다** |

---

## 3. 파일 지도 — 설명이 만들어지는 경로

```
요청 → report_builder._build()
        │
        ├─ rule_engine.evaluate()          ← 판정. **여기만 등급을 만든다**
        │     └ EvidenceVerdict.facts       ← 설명 재료가 담기는 곳
        │
        ├─ verdict.price_provenance / registry_viewed_at / checked_notes
        │     ← 판정이 끝난 **뒤** report_builder가 붙인다(판정이 못 보게)
        │
        ├─ explanation.generate(verdict, report_id=...)
        │     ├ _verdict_for_prompt()       ← **재료의 정본.** 여기 있는 것만 LLM이 본다
        │     ├ llm.explain_provider()      ← .env의 LLM_EXPLAIN_PROVIDER (기본 upstage)
        │     ├ text_guard.check()          ← 길이·금지표현·등급단어·숫자 화이트리스트
        │     ├ (실패 시) fallback_texts     ← 결정적 템플릿. 필드 단위로만 치환
        │     └ shadow_llm.maybe_run()      ← 그림자(반환값 없음). 기본 OFF
        │
        └─ terms.attach(최종 문장)          ← 용어 툴팁 자동 부착 (LLM·폴백 공통)
```

| 파일 | 무엇을 고칠 때 여는가 |
|---|---|
| `app/services/llm/prompts.py` | **문장 스타일·지시**를 바꿀 때 (`EXPLAIN_SYSTEM_PROMPT`) |
| `app/services/explanation.py` | **재료**를 늘리거나(`_verdict_for_prompt`) 검증 정책을 바꿀 때 |
| `app/services/text_guard.py` | 검증 **기계**(패턴·숫자 파싱)를 고칠 때 |
| `app/services/fallback_texts.py` | LLM 실패 시 나가는 **결정적 문구** |
| `app/services/terms.py` + `data/terms.json` | 용어 툴팁·챗봇 사전 |
| `app/services/llm/providers.py` | 모델 추가·엔드포인트·호출 파라미터 |
| `app/services/llm/base.py` | `EXPLAIN_TEMPERATURE`(0.6) 등 공통 파라미터 |
| `app/services/shadow_llm.py` | 그림자 로깅 |

**⚠ 재료를 늘릴 때는 반드시** `tests/test_explanation_guardrail.py`의
`allowed_top` 화이트리스트도 함께 고쳐야 합니다. 일부러 그렇게 만들었습니다 —
새 키가 조용히 프롬프트에 실리는 것을 막는 장치입니다.

---

## 4. EXAONE 비교를 이어서 하는 법

### ① 켜기

`backend/.env`에 한 줄:
```
SHADOW_LLM=exaone
```
`EXAONE_API_KEY`가 있어야 실제로 호출됩니다(없으면 로그 한 줄 남기고 건너뜁니다).

> ⚠ **켜면 분석 1건마다 크레딧이 추가로 듭니다.** 데이터를 모을 때만 켜고 끄세요.
> 끄는 법: 줄을 지우거나 `SHADOW_LLM=off`.

### ② 케이스 쌓기

두 가지 방법:
- **실사용**: 앱에서 분석을 돌린다. 실제 등기부라 가장 가치 있는 데이터.
- **픽스처**: `tests/fixtures/registry/*.json`으로 돌린다(크레딧 적게 듦).
  ```bash
  cd backend
  .venv/Scripts/python.exe -c "
  import json,sys; sys.path.insert(0,'.')
  from app.schemas.internal import RegistryExtract
  from app.services import explanation, rule_engine
  for n in ['mortgage_heavy','clean_house','trust_seizure','canceled_only','messy_amounts']:
      d=json.load(open(f'tests/fixtures/registry/{n}.json',encoding='utf-8'))
      v=rule_engine.evaluate(RegistryExtract.from_raw(d['registry']),
          deposit=d['inputs']['deposit'], market_price=d['inputs'].get('market_price'),
          blacklist_entries=d.get('blacklist'))
      explanation.generate(v, report_id=n)
  import time; time.sleep(30)   # 그림자 스레드가 끝날 때까지
  "
  ```

로그 위치: `backend/logs/llm_shadow/YYYY-MM-DD.jsonl` (`.gitignore` 처리됨)

### ③ 집계

```bash
cd backend
.venv/Scripts/python.exe scripts/shadow_report.py              # 전체
.venv/Scripts/python.exe scripts/shadow_report.py --date 2026-08-06
.venv/Scripts/python.exe scripts/shadow_report.py --samples 5  # 문장 예시도
```

### ④ 무엇을 보고 판단하나

**표가 답해 주는 것**
- 어느 모델이 더 빠른가 (평균·중앙 지연)
- 형식을 더 잘 지키는가 (JSON 파싱 실패율·폴백률)
- 어떤 검증에 자주 걸리는가 (사유 분포 — 금지 표현/등급 단어/재료에 없는 수치)

**표가 답해 주지 못하는 것 — 사람이 해야 합니다**
> 어느 문장이 **더 좋은가.**

`--samples N`으로 두 모델의 원문을 나란히 뽑아 읽고, 아래를 채점하세요:
1. **이 집에만 해당하는 사실**이 들어 있나 (설정일·순위·채권자·열람일 등)
2. 부동산을 모르는 사람이 읽고 **무엇을 해야 할지** 알 수 있나
3. 문단이 읽기 좋게 나뉘어 있나
4. 단정하지 않으면서도 **위험을 분명히** 말하나

> 참고 초기 관측(3건): upstage 3.5초 / exaone 7.2초. 폴백률 upstage 11.1% / exaone 0.0%.
> **표본 3건은 아무것도 증명하지 못합니다.** 최소 수십 건은 모아야 합니다.

---

## 5. 남은 과제 (우선순위 순)

| # | 과제 | 왜 / 어디서 |
|---|---|---|
| 1 | **terms.json 검수 8건** | 사용자가 사실로 읽는 문장이다. `docs/terms-review-queue.md` |
| 2 | **실기기 확인** — 문단 렌더 · 챗봇 칩 18개 레이아웃 | 코드상 가능하지만 눈으로 못 봤다 |
| 3 | **EXAONE 케이스 축적 + 사람 채점** | §4 |
| 4 | 하이라이트 시트 문구 15종 | `highlight.py:124 _SPECS` — 지금은 전부 상수. 개인화 여지 |
| 5 | 용어 챗봇 실연동 | plan.md E-5. 지금은 부분 문자열 조회 |
| 6 | 형식 지시 검증 | 해요체·용어 괄호 순서는 **여전히 미검증**이다. 온도를 더 올리려면 필요 |

---

## 6. 건드릴 때 조심할 것

1. **판정에 손대지 마세요.** 등급은 `rule_engine`만 만듭니다. `facts`에 키를 더하는 것은
   판정이 아니지만, 등급 계산식(`worst`/`_gauge`/임계값 비교)은 건드리면 안 됩니다.
   `tests/test_verdict_regression.py`가 픽스처 7건의 등급을 봉인합니다.
2. **임계값은 `thresholds.py`에만.** 출처 없는 수치 금지(`.claude/rules/risk-scoring.md`).
3. **계약(`api-contract.md`)·앱은 이번 라운드에서 손대지 않았습니다.** 바꿔야 한다면
   먼저 사용자에게 확인하세요 — 앱과 서버가 따로 배포되지 않습니다.
4. **그림자 출력을 사용자 경로에 쓰지 마세요.** `maybe_run()`이 반환값을 안 주는 것이
   설계입니다. 반환하도록 고치는 순간 그 보장이 사라집니다.
5. **폴백 문구를 LLM으로 바꾸지 마세요.** 폴백이 나가는 때는 LLM이 죽었을 때입니다.

---

## 7. 자주 쓰는 명령

```bash
cd backend
.venv/Scripts/python.exe -m pytest -q                    # 561건
.venv/Scripts/python.exe scripts/run_rules.py            # 판정표 육안 확인
.venv/Scripts/python.exe scripts/shadow_report.py        # 그림자 로그 집계
.venv/Scripts/python.exe scripts/price_status.py         # 시세 데이터 준비 상태

# 실기기
adb reverse tcp:8000 tcp:8000
.venv/Scripts/python.exe -m uvicorn app.main:app --port 8000
cd ../frontend && flutter run
```
