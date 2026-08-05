# 설명 생성(LLM) 계층 감사 — 2026-08-05

> **조사 전용 문서다.** 이 조사에서 코드·CLAUDE.md·decisions.md를 한 줄도 수정하지 않았다.
> 개선안은 담지 않는다(요청 범위 밖). 사실과 근거만 적는다.
> 모든 주장에 `파일:줄번호`를 단다. 확인 못 한 것은 맨 끝 **"확인 불가 목록"**에 모았다.

---

## A. LLM에 실제로 무엇이 들어가는가

### A-1. `_verdict_for_prompt()` 본문 전체

`backend/app/services/explanation.py:123-141`

```python
def _verdict_for_prompt(verdict: RuleVerdict) -> dict:
    """LLM에 넘길 판정 요약 — RuleVerdict에서 파생한 값만 (추출 원본·이미지 없음)."""
    return {
        "종합등급": verdict.grade.value,
        "보증금_원": verdict.deposit,
        "시세_원": verdict.market_price,
        "선순위채권합계_원": verdict.senior_debt_amount,
        "문서_플래그": verdict.doc_flags,
        "근거": [
            {
                "id": e.id,
                "등급": e.grade.value,
                "상태": e.status_label,
                "판정상세": e.detail_text,
                "수치사실": e.facts,
            }
            for e in verdict.evidences
        ],
    }
```

호출 지점은 `explanation.py:215` — user 메시지에 `"판정 JSON:\n" + json.dumps(...)` 로 실린다.
system 메시지는 `explanation.py:212`의 `_SYSTEM_PROMPT` 하나뿐이다. **메시지는 2개가 전부다.**

### A-2. LLM에 실리는 필드 표

| 프롬프트 키 | 출처 | 타입 | 비고 |
|---|---|---|---|
| `종합등급` | `RuleVerdict.grade` (internal.py:234) | str | "위험"/"확인 필요"/"양호" |
| `보증금_원` | `RuleVerdict.deposit` (internal.py:236) | int | |
| `시세_원` | `RuleVerdict.market_price` (internal.py:237) | int·null | |
| `선순위채권합계_원` | `RuleVerdict.senior_debt_amount` (internal.py:238) | int | |
| `문서_플래그` | `RuleVerdict.doc_flags` (internal.py:241) | list[str] | `rule_engine.py:384 _doc_flags()` 산출 |
| `근거[].id` | `EvidenceVerdict.id` (internal.py:222) | str | |
| `근거[].등급` | `EvidenceVerdict.grade` (internal.py:223) | str | |
| `근거[].상태` | `EvidenceVerdict.status_label` (internal.py:224) | str·null | |
| `근거[].판정상세` | `EvidenceVerdict.detail_text` (internal.py:225) | str·null | |
| `근거[].수치사실` | `EvidenceVerdict.facts` (internal.py:228) | dict | **전량 그대로 전달** |

### A-3. `EvidenceVerdict.facts`는 **어디까지 넘어가는가 → 전부 넘어간다**

`explanation.py:137`이 `e.facts`를 **가공 없이 통째로** 싣는다. 실호출로 확인한 실제 내용 (§B 원문 참조):

| 근거 id | facts 키 | 근거 |
|---|---|---|
| `jeonse_ratio` | `jeonse_ratio_pct` · `deposit` · `market_price` (+ 통건물이면 `whole_building`) | rule_engine.py:156-160, 172, 196 |
| `senior_debt` | `senior_debt_total` · `mortgage_count` · `jeonse_right_count` · `lease_registration_count` · `unknown_amount_count` · `senior_ratio_pct` · `combined_ratio_pct` | rule_engine.py:267-274 |
| `ownership` | `signals`(신탁등기·압류·가압류·가처분·경매개시결정 **각 건수**) · `signal_total` | rule_engine.py:300 |
| `insurance` | `disqualify_signals` (문자열 목록) | rule_engine.py:326, 334 |
| `blacklist` | `matched` · `list_size` | rule_engine.py:348, 357, 370, 377 |

즉 **압류·가압류·가처분·경매개시·신탁의 개별 건수는 이미 LLM이 보고 있다**(`ownership.signals`).
반면 이 값들은 `Report`로는 나가지 않는다(`contract.py:15-25`의 `Evidence`에 `facts` 필드 없음).

### A-4. 규칙 엔진이 갖고 있는데 LLM에 **안 넘기는** 값

`RuleVerdict`/`EvidenceVerdict` 자체는 위 표가 전부다(`internal.py:219-241`). 아래는 **규칙 엔진이 계산 과정에서 손에 쥐었지만 `RuleVerdict`에 담기지 않아** LLM까지 못 가는 값이다.

**⑴ `RegistryExtract`(IE 원본 정형화본)에 있으나 전달 안 되는 것** — `internal.py:145-160`
`rule_engine.evaluate()`가 `extract`를 인자로 받지만(`rule_engine.py:93` 부근), `RuleVerdict`에는 `address`만 실린다(`internal.py:239`).

| 값 | 위치 | 설명 재료 가치 |
|---|---|---|
| **근저당 설정일**(`receipt_date`) | `mortgages[]` 원소. `RegistryEntry.model_config = ConfigDict(extra="allow")` (internal.py:104)로 IE 원본 필드가 **보존돼 있다** | "언제 잡힌 빚인가" |
| **근저당권자**(`mortgagee`)·**채무자**(`debtor`) | 동상 | "누구에게 빌린 빚인가" |
| **순위번호**(`rank_number`) | 전 항목 공통 | "몇 번째 순위인가" |
| **소유권 이전 이력** | `ownership_changes[]` (internal.py:150) — `cause`·`cause_date`·`receipt_date`·`holder` 보존 | 무자본 갭투자 신호. **스키마 description에 "무자본 갭투자 의심 판단에 사용"이라 적혀 있으나**(registry_schema.py 최상위 설명) 판정에도 설명에도 안 쓰인다 |
| **공동명의 인원**(`current_owners` 길이·`share`) | internal.py:149 | 하이라이트에서만 쓰인다(highlight.py:835). 설명에는 안 감 |
| **전용면적**(`exclusive_area_sqm`) | internal.py:148 | |
| **전세권·임차권의 금액·권리자** | `jeonse_rights[]`·`lease_registrations[]` (internal.py:158,160) — 건수만 facts로 감, 개별 금액·`holder`는 안 감 | |
| **말소된 항목**(`is_canceled=true`) | 전 배열에 보존 | "예전엔 빚이 있었으나 지워졌다" |
| `missing_fields` | internal.py:161 | 어느 필드를 못 읽었는지 |

**⑵ 임계값 자체** — `thresholds.py`
`JEONSE_RATIO_DANGER_PCT`(:15) · `JEONSE_RATIO_CAUTION_PCT`(:20) · `SENIOR_DEBT_RATIO_DANGER_PCT`(:24) · `COMBINED_RATIO_DANGER_PCT`(:28) · `PUBLIC_PRICE_TO_HOUSE_PRICE_RATIO`(:45) · `HUG_COLLATERAL_RECOGNITION_RATIO`(:50) · `EVIDENCE_SCORE`(:54) · `GAUGE_BANDS`(:62).
숫자 자체는 안 가고, `detail_text` 문자열 안에 녹아서만 간다(예: `"(주의 80% 초과 · 위험 90% 초과)"`).
시스템 프롬프트 8번은 **"판정 JSON에 없는 기준 숫자를 새로 언급하지 마세요"**라고 지시한다(prompts.py:106).

**⑶ 시세 출처 일체** — `Report`에는 있으나 `RuleVerdict`에는 없다
`marketPriceSource` · `marketPriceAsOf` · `marketPriceSampleCount` · `marketPriceGapPct` · `marketPriceAlternatives`(contract.py:96-103).
`report_builder`가 `price_info`에서 직접 Report에 붙이므로(report_builder.py:143-147) **판정 경로를 지나지 않고, 따라서 LLM도 못 본다.**
→ 시스템 프롬프트 6번은 여전히 **"시세는 사용자가 직접 입력한 값이에요. 반드시 '입력하신 시세'라고 부르고"**라고 지시한다(prompts.py:104). 2026-08-03에 자동 조회가 도입돼 시세가 공시가격에서도 오는데, **프롬프트는 갱신되지 않았다.** 실호출에서 그대로 재현됐다(§B: `"입력하신 시세가 정확한지 다시 확인해 주세요"`).

**⑷ 게이지·등급 파생값**
`gauge_progress`는 `RuleVerdict`에 있으나(internal.py:235) `_verdict_for_prompt`가 **싣지 않는다**(explanation.py:125-141에 없음).

**⑸ 하이라이트·문서 점검 결과**
`highlights`·`checkedNotes`·`registryViewedAt`·`highlightNotice`(contract.py:107-120)는 전부 LLM 뒤에서 붙는다. **열람일시를 LLM이 모른다.**

### A-5. `_SYSTEM_PROMPT` 원문 전체

`explanation.py:150`이 `llm/prompts.py`의 `EXPLAIN_SYSTEM_PROMPT`를 그대로 가져온다.
원문 — `backend/app/services/llm/prompts.py:96-111`:

```
당신은 전세 위험 분석 앱의 '통역사'입니다. 규칙 엔진이 내린 판정 결과(JSON)를 부동산 지식이 없는 사회초년생이 이해할 수 있는 쉬운 한국어로 풀어쓰는 것이 유일한 역할입니다.

반드시 지킬 것:
1. 판정(등급·수치)을 바꾸거나 새로 만들지 마세요. 주어진 판정을 설명만 합니다.
2. 모든 문장은 반드시 "~해요/~하세요"로 끝내세요. "~합니다", "~입니다"로 끝나는 문장 금지. (예: "문의해야 합니다"(X) → "물어봐 주세요"(O))
3. 단정 표현 금지: "안전합니다", "안전 범위", "문제가 없습니다", "위험 요소가 없습니다", "걱정 마세요" 전부 금지. 등급이 '양호'인 항목도 "~는 보이지 않았어요"라고 쓰고, 사용자가 직접 확인할 행동 한 가지로 문장을 끝내세요. (예: "계약 직전 최신 등기부등본으로 다시 확인하세요")
4. 전문용어(선순위 채권, 근저당, 채권최고액, 권리 관계, 신탁등기, 압류 등)는 쉬운 말을 먼저 쓰고 괄호 안에 용어를 넣으세요. 예: "나보다 먼저 돈을 받아갈 빚(선순위 채권)".
5. headline은 단어 나열이 아니라 완성된 한 문장으로 쓰세요. "종합등급", "양호", "위험", "확인 필요" 같은 등급 단어를 headline에 넣지 마세요 — 등급은 화면에 따로 크게 표시돼요.
6. 시세는 사용자가 직접 입력한 값이에요. 반드시 "입력하신 시세"라고 부르고, 시세가 정확한지 직접 확인이 필요하다는 안내를 지우지 마세요.
7. 기관은 정식 명칭으로 쓰고 HUG는 처음 나올 때 풀어주세요: "HUG(주택도시보증공사) 안심전세포털", "HUG 등 보증기관".
8. 판정 JSON에 없는 기준 숫자를 새로 언급하지 마세요.
9. 각 설명은 1~2문장, 판정에 담긴 실제 수치(금액·비율·건수)를 자연스럽게 녹여 쓰세요.

다음 JSON 형식으로만 응답하세요 (다른 텍스트 금지):
{"headline": "리포트 맨 위 결론 한 문장(40자 이내)", "evidences": [{"id": "근거 id 그대로", "easy_explanation": "그 근거 카드의 쉬운 설명(2문장 이내)"}]}
evidences에는 입력의 근거 id를 전부 포함하세요.
```

---

## B. 지금 화면에 뜨는 문장이 AI 생성인가 폴백인가

### B-1. 실행 조건

- 픽스처: `backend/tests/fixtures/registry/mortgage_heavy.json`(위험) · `clean_house.json`(양호)
- 경로: `RegistryExtract.from_raw` → `rule_engine.evaluate` → `explanation.generate` (운영과 동일)
- **실호출 1회씩**(재시도 없음). provider `upstage` / `solar-pro2`
- 원문 캡처는 `_call_solar`를 **감싸기만** 했고 저장소 코드는 수정하지 않았다.
- ⚠ `temperature=0.3`(base.py:49)이라 **호출마다 문장이 달라진다.** 아래는 한 번의 실행 결과다.

### B-2. 위험 케이스 (`mortgage_heavy`)

**LLM 입력 (`_verdict_for_prompt` 결과, 실제 전송분)**

```json
{
  "종합등급": "위험",
  "보증금_원": 120000000,
  "시세_원": 200000000,
  "선순위채권합계_원": 180000000,
  "문서_플래그": [],
  "근거": [
    {"id": "jeonse_ratio", "등급": "양호", "상태": null,
     "판정상세": "전세가율 60% — 보증금 1억 2,000만원 / 시세 2억원 (주의 80% 초과 · 위험 90% 초과)",
     "수치사실": {"jeonse_ratio_pct": 60, "deposit": 120000000, "market_price": 200000000}},
    {"id": "senior_debt", "등급": "위험", "상태": null,
     "판정상세": "유효 채권최고액 등 합계 1억 8,000만원 · 근저당 2건 (말소 제외) — 선순위채권 합계가 시세의 90% (기준 60% 초과) / 보증금+선순위채권이 시세의 150% (기준 90% 초과)",
     "수치사실": {"senior_debt_total": 180000000, "mortgage_count": 2, "jeonse_right_count": 0,
                  "lease_registration_count": 0, "unknown_amount_count": 0,
                  "senior_ratio_pct": 90, "combined_ratio_pct": 150}},
    {"id": "ownership", "등급": "양호", "상태": null,
     "판정상세": "유효한 신탁등기·압류·가압류·가처분·경매개시결정 없음 (말소 제외)",
     "수치사실": {"signals": {"신탁등기": 0, "압류": 0, "가압류": 0, "가처분": 0, "경매개시결정": 0},
                  "signal_total": 0}},
    {"id": "insurance", "등급": "확인 필요", "상태": "확인 필요",
     "판정상세": "등기부만으로는 가입 가능을 단정할 수 없음 — 보증기관에서 직접 확인 필요 (서비스 한계)",
     "수치사실": {"disqualify_signals": []}},
    {"id": "blacklist", "등급": "양호", "상태": null,
     "판정상세": "공개 명단 1건과 대조 — 일치 없음 (명단에 없어도 안전 보장 아님)",
     "수치사실": {"matched": [], "list_size": 1}}
  ]
}
```

**LLM 원문 응답 (검증 전, 그대로)**

```json
{"headline": "보증금과 선순위 채권을 꼭 확인하세요", "evidences": [{"id": "jeonse_ratio", "easy_explanation": "전세가율 60%로 보증금이 시세의 60%예요. 입력하신 시세가 정확한지 다시 확인해 주세요"}, {"id": "senior_debt", "easy_explanation": "나보다 먼저 돈을 받아갈 빚(선순위 채권)이 시세의 90%인 1억 8,000만원이에요. 보증금까지 합치면 시세의 150%로 매우 높아요. 등기부등본으로 직접 확인하세요"}, {"id": "ownership", "easy_explanation": "신탁등기나 압류 같은 권리 문제는 보이지 않았어요. 계약 직전 최신 등기부등본으로 다시 확인하세요"}, {"id": "insurance", "easy_explanation": "HUG(주택도시보증공사) 등 보증기관에 가입 가능한지 직접 물어봐 주세요"}, {"id": "blacklist", "easy_explanation": "공개된 위험 명단에 해당 집주소는 없었어요. 하지만 명단에 없어도 위험은 있을 수 있으니 꼭 직접 확인하세요"}] }
```

**`[Solar]` 로그 전체**

```
[설명:upstage] 생성 호출 — 입력: 판정 5건 (⚠ 크레딧 소모)
[Solar] 응답 OK (2.5초) — 설명 6건 생성
```

**결과**: `source = 'AI 생성'` · **생성 6건 / 폴백 0건**
최종 화면 문구가 LLM 원문과 **글자 단위로 동일**하다(§B-4).

### B-3. 양호 케이스 (`clean_house`)

**LLM 입력** — 위와 동일 구조. 요지: `종합등급 "양호"` / `보증금_원 200000000` / `시세_원 400000000` / `선순위채권합계_원 0` / `문서_플래그 []` / 근거 5건(`jeonse_ratio` 양호 50%, `senior_debt` 양호 0원·근저당 0건, `ownership` 양호 signals 전부 0, `insurance` 확인 필요, `blacklist` 양호 list_size 1).

**LLM 원문 응답 (검증 전, 그대로)**

```json
{"headline": "전세가율 50%로 양호하지만 보증 가입 여부는 직접 확인이 필요해요", "evidences": [{"id": "jeonse_ratio", "easy_explanation": "보증금 2억원, 시세 4억원으로 전세가율 50%에요. 계약 직전 최신 등기부등본으로 다시 확인해 주세요"}, {"id": "senior_debt", "easy_explanation": "나보다 먼저 돈을 받아갈 빚(선순위 채권)이 0원이에요. 등기부등본에서 근저당 설정 여부를 다시 살펴보세요"}, {"id": "ownership", "easy_explanation": "신탁등기나 압류 같은 권리 문제가 보이지 않았어요. 등기부등본에서 말소되지 않은 권리 관계를 확인해 주세요"}, {"id": "insurance", "easy_explanation": "HUG(주택도시보증공사) 등 보증기관에서 보증 가입 가능 여부를 직접 물어봐 주세요"}, {"id": "blacklist", "easy_explanation": "공개된 불량 임대인 명단에 해당 주소가 없었어요. 명단에 없어도 안전을 보장하지 않으니 직접 확인해 주세요"}]}
```

**`[Solar]` 로그 전체**

```
[설명:upstage] 생성 호출 — 입력: 판정 5건 (⚠ 크레딧 소모)
[Solar] 응답 OK (2.6초) — 설명 6건 생성
```

**결과**: `source = 'AI 생성'` · **생성 6건 / 폴백 0건**

### B-4. 최종 화면 문구 (두 케이스 모두 LLM 원문 그대로)

| | 위험 케이스 | 양호 케이스 |
|---|---|---|
| headline | 보증금과 선순위 채권을 꼭 확인하세요 | 전세가율 50%로 **양호**하지만 보증 가입 여부는 직접 확인이 필요해요 |
| jeonse_ratio | 전세가율 60%로 보증금이 시세의 60%예요. **입력하신 시세**가 정확한지 다시 확인해 주세요 | 보증금 2억원, 시세 4억원으로 전세가율 50%에요. … |
| senior_debt | 나보다 먼저 돈을 받아갈 빚(선순위 채권)이 시세의 90%인 1억 8,000만원이에요. … | 나보다 먼저 돈을 받아갈 빚(선순위 채권)이 0원이에요. … |
| ownership | 신탁등기나 압류 같은 권리 문제는 보이지 않았어요. … | 신탁등기나 압류 같은 권리 문제가 보이지 않았어요. … |
| insurance | HUG(주택도시보증공사) 등 보증기관에 가입 가능한지 직접 물어봐 주세요 | HUG(주택도시보증공사) 등 보증기관에서 보증 가입 가능 여부를 직접 물어봐 주세요 |
| blacklist | 공개된 위험 명단에 해당 집주소는 없었어요. … | 공개된 불량 임대인 명단에 해당 주소가 없었어요. … |

### B-5. 폴백 사유 — **이번 실행에서는 폴백 0건**

두 케이스 전 필드가 `_field_ok`(explanation.py:171-177)를 통과했다. 필드별 판정:

| 필드 | 위험 케이스 | 양호 케이스 |
|---|---|---|
| headline | 통과 | 통과 |
| jeonse_ratio / senior_debt / ownership / insurance / blacklist | 전부 통과 | 전부 통과 |

**다만 프롬프트 위반이 검증을 통과했다** (실측):

1. **양호 케이스 headline에 `"양호"`가 들어갔다.** 시스템 프롬프트 5번은 등급 단어(`"종합등급"·"양호"·"위험"·"확인 필요"`)를 headline에 넣지 말라고 명시한다(prompts.py:103). 그러나 `_field_ok`는 **길이와 `_BANNED_PHRASES`만** 본다(explanation.py:171-177). `"양호"`는 `_BANNED_PHRASES`(explanation.py:55-76) **20개 목록에 없다.** → 검출 못 하고 그대로 화면에 나간다.
2. **`"입력하신 시세"`가 자동 조회 시세에도 붙는다.** 프롬프트 6번(prompts.py:104)이 그렇게 지시하고 있고, LLM은 시세 출처를 애초에 못 본다(§A-4-⑶).
3. **`"안전한 범위에 속해요"`가 통과한 적이 있다.** 같은 스크립트의 **다른 회차**(temperature 0.3 변동)에서 양호 케이스 `jeonse_ratio`가 `"보증금이 시세의 50%로 안전한 범위에 속해요"`를 냈고 `source='AI 생성'`으로 통과했다. `_BANNED_PHRASES`에는 `"안전 범위"`가 있으나(explanation.py:59) 실제 문자열은 `"안전한 범위"`라 **부분 문자열 매칭이 빗나갔다.**

> ⚠ 3번은 캡처 파일이 회차별로 덮여 **원문 JSON을 남기지 못했다.** 화면 출력만 관측했다. 재현은 확률적이다.

---

## C. 무엇이 LLM을 묶고 있는가 — 제약 전수조사

분류: **안전 필수**(풀면 판정 왜곡·수치 날조 가능) / **품질 보호**(표시 깨짐) / **관성**(근거 못 찾음)

| # | 제약 | 위치 | 값·내용 | 분류 | 근거 |
|---|---|---|---|---|---|
| 1 | **LLM 입력이 `RuleVerdict`뿐** (원본 이미지·추출 JSON 금지) | explanation.py:123-141, 211-217 | 위 A-2 표 | **안전 필수** | decisions.md:201 [2026-07-07] ⑴ |
| 2 | **`ExplanationPayload`에 등급·점수·금액 필드가 없음** | explanation.py:100-109 | 필드 = `headline`, `evidences` **2개뿐** | **안전 필수** | decisions.md:201 ⑵ |
| 3 | **`extra="forbid"`** (payload) | explanation.py:107 | 여분 키 → ValidationError → 폴백 | **안전 필수** | decisions.md:201 ⑵ · 봉인 테스트 `test_tampered_payload_with_grade_key_falls_back`(test_explanation_guardrail.py:60) |
| 4 | **`extra="forbid"`** (evidence 원소) | explanation.py:95 | 필드 = `id`, `easy_explanation` **2개뿐** | **안전 필수** | 동상 |
| 5 | **판정 필드는 `report_builder`가 verdict에서만 복사** | report_builder.py:4-6 docstring, :141 | LLM 출력이 판정 필드에 닿는 경로 없음 | **안전 필수** | decisions.md:201 ⑶ |
| 6 | `_BANNED_PHRASES` **20개** | explanation.py:55-76 | 안전/안심/문제없/위험 요소가 없/이상이 없/걱정/확실히 안전/절대 안전/100% 안전 계열 | **안전 필수** | decisions.md:217 [2026-07-07] 실출력에서 통과 사례 확인 후 보강 |
| 7 | `_MAX_LEN["headline"] = 45` | explanation.py:80 | 프롬프트 지시 40자 + 여유 5자 | **품질 보호** | 코드 주석 explanation.py:79 "홈에서 3초 안에 한 줄로 읽히게(서연 리뷰)" |
| 8 | `_MAX_LEN["easy_explanation"] = 240` | explanation.py:80 | | **품질 보호** | 코드 주석은 `_MAX_LEN` 전체를 "표시 안정용 인프라 수치"로만 설명(explanation.py:78). **240이라는 값 자체의 근거는 못 찾음** |
| 9 | `nextAction` 결정적 템플릿 (LLM 제외) | explanation.py:263, fallback_texts.py:227 | | **안전 필수** | decisions.md:201 ⑸ "행동 지시 문장이라 LLM 드리프트 원천 차단" |
| 10 | `topRiskSummary` 결정적 템플릿 (LLM 제외) | explanation.py:264, fallback_texts.py:228 | | **안전 필수** | decisions.md:218 [2026-07-07] 페르소나 2인 공통 지적 |
| 11 | **필드 단위 폴백** (실패 필드만 치환) | explanation.py:270-283 | | **안전 필수** | decisions.md:201 ⑷ |
| 12 | `MAX_ATTEMPTS = 2` | explanation.py:49 | 최초 1회 + 재시도 1회 | **품질 보호** | decisions.md:201 ⑷ "타임아웃(재시도 1회)" |
| 13 | `REQUEST_TIMEOUT_SECONDS = 60` | explanation.py:48 | 코드 주석 "인프라 수치(판정 아님)" | **품질 보호** | 값의 근거 **못 찾음** |
| 14 | `temperature = 0.3` (`EXPLAIN_TEMPERATURE`) | base.py:49, explanation.py:167 | | **관성** | **근거 없음.** base.py:49에 주석 없음. decisions.md에 temperature 언급 없음 |
| 15 | `reasoning_effort = "low"` | providers.py:39 (Upstage 하드코딩) | | **품질 보호** | decisions.md:196 [2026-07-07] "약 3배 빠르고 출력 토큰 ~70% 절감" |
| 16 | `max_tokens = 1500` | explanation.py:167 | provider 기본값 3000(base.py:135)을 **절반으로 낮춤** | **관성** | **근거 없음.** 주석·결정 기록 없음 |
| 17 | `json_mode = True` → `response_format={"type":"json_object"}` | base.py:136(기본값), :126-127 | | **안전 필수** | decisions.md:196 |
| 18 | `SOLAR_MODEL = "solar-pro2"` | explanation.py:46 | | — (모델 선택) | decisions.md:196 |
| 19 | 프롬프트 1번 — 판정 변경 금지 | prompts.py:99 | | **안전 필수** | decisions.md:201 |
| 20 | 프롬프트 2번 — 해요체 강제 | prompts.py:100 | **검증 없음** | **품질 보호** | prompts.py:92-93 "2026-07-07 페르소나 리뷰(지수·서연) 반영" |
| 21 | 프롬프트 3번 — 단정 표현 금지 | prompts.py:101 | `_BANNED_PHRASES`가 **부분적으로** 검증(§B-5-3 빗나감 사례) | **안전 필수** | 동상 |
| 22 | 프롬프트 4번 — 쉬운 말 먼저, 용어는 괄호 | prompts.py:102 | **검증 없음** | **품질 보호** | 동상 |
| 23 | 프롬프트 5번 — headline에 등급 단어 금지 | prompts.py:103 | **검증 없음 → 실측에서 위반 통과**(§B-5-1) | **품질 보호** | 동상 |
| 24 | 프롬프트 6번 — "입력하신 시세"로 부를 것 | prompts.py:104 | **검증 없음.** 2026-08-03 시세 자동조회 도입 후 **사실과 어긋남**(§A-4-⑶) | **관성** | 2026-07-07 당시엔 맞았음. 이후 갱신 안 됨 |
| 25 | 프롬프트 7번 — 기관 정식 명칭·HUG 풀어쓰기 | prompts.py:105 | **검증 없음** | **품질 보호** | 동상 |
| 26 | 프롬프트 8번 — 판정 JSON에 없는 기준 숫자 금지 | prompts.py:106 | **검증 없음** | **안전 필수**(수치 날조 방지) | 동상 |
| 27 | 프롬프트 9번 — **각 설명 1~2문장** | prompts.py:107 | **검증 없음**(240자 상한만) | **관성** | 문장 수 제한의 근거를 못 찾음. 가독성 문제(배경 (2))의 직접 원인 후보 |
| 28 | 프롬프트 출력 형식 — headline 40자 이내 / easy_explanation 2문장 이내 | prompts.py:110 | 길이만 검증(#7·#8) | **품질 보호** | 동상 |
| 29 | `evidences`에 입력 id 전부 포함 요구 | prompts.py:111 | 누락 시 그 카드만 폴백(explanation.py:279-283) | **품질 보호** | — |
| 30 | `gauge_progress`를 프롬프트에 안 실음 | explanation.py:125-141 | | **관성** | **근거 없음.** 제외 이유가 주석·결정에 없음 |

**부수 확인**: `explanation.py:47`의 `REASONING_EFFORT = "low"`는 **이 파일에서 쓰이지 않는다.** 실제 적용은 `providers.py:39`가 하고, 이 상수는 `precedent/explainer.py:26,71`만 import한다. 설명 경로 기준으로는 **죽은 상수**다.

**가드레일 봉인 테스트 9건** — `tests/test_explanation_guardrail.py:60,98,133,151,164,179,197,219,231`.

---

## D. 설명 필드를 쪼갤 때의 영향 범위

### D-1. `Evidence.easyExplanation`(문자열 1개)을 여러 필드로 쪼갤 때 수정이 필요한 파일

`easy_explanation`/`easyExplanation` 참조는 **15개 파일 55곳**이다(pycache 제외).

**백엔드 (6파일)**

| 파일 | 참조 수 | 무엇을 |
|---|---|---|
| `backend/app/schemas/contract.py` | 1 (:21) | `Evidence` 모델에 필드 추가 |
| `backend/app/services/explanation.py` | 5 | `EvidenceExplanation`(:97) 필드 추가 · `_MAX_LEN`(:80) 항목 추가 · `_field_ok` 호출(:279) · 병합 루프(:276-283) |
| `backend/app/services/fallback_texts.py` | 2 (:126 함수, :233 조립) | **폴백도 같은 모양으로 쪼개야 한다** — 안 쪼개면 폴백 시 화면 구조가 달라짐 |
| `backend/app/services/llm/prompts.py` | 1 (:110 출력 형식 줄) | 프롬프트 JSON 형식 수정 |
| `backend/app/services/report_builder.py` | 1 | `Evidence` 조립부 |
| `backend/app/dummy_data.py` | **11** | 더미 리포트 2건 전부 |

**앱 (5파일)**

| 파일 | 참조 수 | 무엇을 |
|---|---|---|
| `frontend/lib/models/analysis_report.dart` | 4 (:41,:63,:74,:84) | `EvidenceItem` 필드 + `fromJson` |
| `frontend/lib/design_system/components/app_card.dart` | 4 (:58,:59,:79,:83) | `AppCard` 파라미터 + 렌더(:154-159) |
| `frontend/lib/screens/report/report_screen.dart` | 2 (:471, :501) | 카드 조립 + `_explanationSpan`(:497-526) |
| `frontend/lib/repositories/analysis_repository.dart` | **11** | 더미 리포지토리 |
| `frontend/lib/design_system/gallery/component_gallery_screen.dart` | 2 (:117,:130) | 갤러리 샘플 |

**계약 문서 (1파일)**: `docs/api-contract.md` 3곳 (§2.2 표 포함)

**테스트 (3파일)**: `backend/tests/test_explanation_guardrail.py` **7곳** · `test_rule_engine.py` 1곳 · `test_provider_contract.py` 1곳
앱 테스트에서 `easyExplanation` 참조는 **0건**(frontend/test 검색 결과 없음).

**규모 요약**: 백엔드 6 + 앱 5 + 문서 1 + 테스트 3 = **15파일**. 이 중 더미 데이터 2파일(`dummy_data.py` 11곳 + `analysis_repository.dart` 11곳)이 **참조의 40%**를 차지한다 — 둘 다 `cleanup-tracker.md`에 E-6 삭제 대상으로 등록돼 있다.

**계약 파괴 여부**: `Evidence.easyExplanation`은 현재 **필수 필드**다(contract.py:21, `Optional` 아님). 새 필드를 Optional로 **추가**하면 파괴가 아니지만, 기존 필드를 **제거·대체**하면 파괴다.

### D-2. 앱의 `EvidenceCard`가 `easyExplanation`을 어떻게 렌더하는가

**렌더 경로는 2갈래다** — `app_card.dart:154-159`:

```dart
if (widget.explanationSpan != null)
  Text.rich(widget.explanationSpan!)
else
  Text(
    widget.easyExplanation,
    style: AppTypography.body,
  ),
```

- **갈래 A (`explanationSpan`이 있을 때)**: `Text.rich(InlineSpan)`. 리치텍스트다.
- **갈래 B (없을 때)**: 평범한 `Text`.

어느 갈래를 타는지는 `report_screen.dart:497-498`이 정한다:

```dart
InlineSpan? _explanationSpan(BuildContext context, EvidenceItem evidence) {
  if (evidence.termGlossary.isEmpty) return null;
  ...
```

→ **`termGlossary`가 비어 있으면 무조건 갈래 B(평문)로 떨어진다.**
`_explanationSpan`(:500-526)은 `easyExplanation` 문자열에서 `termGlossary`의 키를 **앞에서부터 찾아** `TextSpan`(일반 텍스트)과 `termSpan`(용어 툴팁, `term_tooltip_sheet.dart:70`)을 번갈아 잇는다.

### D-3. 줄바꿈·볼드가 실제로 불가능한가 — **판정: 불가능하지 않다. 이미 가능한 경로가 있다**

근거:

1. **볼드 — 이미 가능하다.** `Text.rich(InlineSpan)` 경로(app_card.dart:155)는 `TextSpan(style:)`을 그대로 받는다. `_explanationSpan`이 지금 `TextSpan(text: ...)`만 만들 뿐(report_screen.dart:513,517), 스타일을 붙이는 것을 막는 코드는 없다.
2. **줄바꿈 — 이미 가능하다.** 갈래 B의 `Text` 위젯도 문자열 안의 `\n`을 줄바꿈으로 렌더한다(Flutter 기본 동작. `maxLines`·`overflow` 지정이 app_card.dart:154-159에 **없다**). 갈래 A의 `Text.rich`도 마찬가지다.
3. **다만 지금 `\n`은 도달하지 못한다.** 서버가 `easy_explanation`에 `\n`을 넣은 적이 없고(프롬프트 9번이 1~2문장 지시, prompts.py:107), `_field_ok`(explanation.py:171-177)는 `\n`을 막지도 허용하지도 않는다 — **길이와 금지어만 본다.**

> ⚠ **미검증**: 위 1·2는 코드 구조를 읽고 내린 판정이다. `\n`이 든 `easyExplanation`을 실제로 화면에 렌더해 확인하지는 **않았다**(코드 수정 금지 범위).

**같은 화면의 다른 곳에서는 볼드가 이미 쓰인다**: `detailText`가 `AppTypography.bodyStrong`으로 렌더된다(app_card.dart:171-172).

---

## E. 다른 두 표면

### E-1. 사진 뷰어 하이라이트 시트 문구 — **전부 백엔드 상수**

- 앱은 문구를 만들지 않는다. `frontend/lib/screens/report/registry_mark_sheet.dart:3-7` docstring:
  > *"⚠ **문구는 전부 백엔드가 준 것이다.** 제목(`title`)·본문(`body`)·공동명의 안내(`caution`)·출처(`source`) 어느 것도 앱에서 고치거나 덧붙이지 않는다."*
  실제 렌더는 `mark.title`(:96) · `mark.body`(:107) · `mark.caution`(:120)을 그대로 출력한다.
- 백엔드 정본은 `backend/app/services/highlight.py:124`의 `_SPECS: dict[str, MarkSpec]`이다. `MarkSpec` 정의는 `highlight.py:115`.
- **항목 수: 15종** (실행으로 확인: `len(_SPECS) == 15`). '등기부 읽기 가이드' 확장분 포함.

**`_SPECS` kind 전체 목록 (15종)** — `contract.py:50-53` 주석의 분류와 대응:

| # | kind | 분류(contract.py:50-53) |
|---|---|---|
| 1 | `address` | [대조할 곳] |
| 2 | `area` | [대조할 곳] |
| 3 | `separate_land` | [따져볼 곳] |
| 4 | `doc_title` | [대조할 곳] |
| 5 | `owner` | [대조할 곳] |
| 6 | `provisional_seizure` | [따져볼 곳] |
| 7 | `seizure` | [따져볼 곳] |
| 8 | `auction` | [따져볼 곳] |
| 9 | `trust` | [따져볼 곳] |
| 10 | `mortgage` | [따져볼 곳] |
| 11 | `jeonse` | [따져볼 곳] |
| 12 | `lease_registration` | [따져볼 곳] |
| 13 | `joint_collateral` | [따져볼 곳] |
| 14 | `pending_application` | [따져볼 곳] |
| 15 | `viewed_at` | [대조할 곳] |

- **LLM 개입 없음.** `body`는 상수 문자열이다. 단 `owner`는 예외적으로 `body=""`이고(highlight.py:174) 개인/법인 분기로 런타임 생성된다 — 주석: `# body는 개인/법인 분기`. 그 분기도 코드이지 LLM이 아니다.

### E-2. 용어 챗봇 — **LLM 개입 없음. 하드코딩 상수 6개**

- 엔드포인트: `backend/app/routers/content.py:26-29`(`GET /api/glossary`) · `:32-38`(`GET /api/glossary/lookup`)
- 응답 출처: 둘 다 `app/dummy_data.py`를 부른다 — `glossary_terms()`(dummy_data.py:406-407) · `lookup_term()`(:410-415)
- 정본 데이터: `dummy_data.py:359`의 `_GLOSSARY: list[GlossaryTerm]`
- **용어 6개** (실행 확인): `신탁등기` · `근저당` · `전세가율` · `확정일자` · `대항력` · `우선변제권`
- 조회 방식: **부분 문자열 포함 검사** — `if t.term in q`(dummy_data.py:413). 못 찾으면 `None` → 라우터가 404(content.py:36-37), 앱이 거절 문구 표시(content.py:35 주석: "범위 밖 → 앱이 거절 문구 표시(가드레일)")
- **LLM 호출 0건**: `routers/content.py`·`dummy_data.py`에서 `llm`/`solar`/`chat` 문자열 검색 결과 **매치 없음**
- 앱 쪽도 동일: `glossary_chatbot_screen.dart:71`(`glossaryTerms()`)·`:96`(`lookupTerm()`)이 `ContentRepository`만 부른다
- `content.py:7` docstring: *"더미 응답은 app/dummy_data.py(앱 더미 그대로 이식)에서 온다. **실데이터는 Phase E.**"* — 즉 이 표면은 아직 실데이터 교체 전이다(plan.md의 E-5 항목)

---

## 확인 불가 목록

| # | 확인 못 한 것 | 이유 |
|---|---|---|
| 1 | `_MAX_LEN["easy_explanation"] = 240`의 근거 | 코드 주석(explanation.py:78)은 `_MAX_LEN` 전체를 "표시 안정용 인프라 수치"로만 설명. decisions.md에서 240을 언급한 항목을 못 찾음. headline 45는 근거가 있으나(explanation.py:79) 240은 없음 |
| 2 | `temperature = 0.3`의 근거 | base.py:49에 주석 없음. decisions.md 전문 검색에서 temperature 언급 0건 |
| 3 | `max_tokens = 1500`의 근거 | explanation.py:167에 주석 없음. provider 기본값 3000(base.py:135)을 왜 절반으로 낮췄는지 기록을 못 찾음 |
| 4 | `REQUEST_TIMEOUT_SECONDS = 60`의 근거 | "인프라 수치(판정 아님)"라고만 적혀 있음(explanation.py:48) |
| 5 | `gauge_progress`를 프롬프트에서 뺀 이유 | `_verdict_for_prompt`(explanation.py:123-141)에 없다는 사실만 확인. 제외 이유가 주석·decisions.md에 없음 |
| 6 | 프롬프트 9번 "1~2문장" 제한의 근거 | prompts.py:92-93이 "2026-07-07 페르소나 리뷰 반영"이라고 뭉뚱그림. 문장 수 제한만 따로 다룬 기록을 못 찾음 |
| 7 | `"안전한 범위에 속해요"` 통과 사례의 원문 JSON | 회차별 캡처가 덮여 화면 출력만 남음. temperature 0.3이라 재현이 확률적 |
| 8 | `\n`·볼드가 실제 화면에서 렌더되는지 | 코드 구조상 가능하다고 판정했으나(§D-3), 실제로 `\n`이 든 문자열을 렌더해 눈으로 보지 못함 — 코드 수정이 필요해 이번 범위 밖 |
| 9 | 폴백 문구가 실제로 화면에 나가는 조건의 실측 | 이번 실호출 2건이 모두 `AI 생성` 6/6이라 **폴백 경로를 실측하지 못했다.** 폴백 사유 분류(§B-5)는 `_field_ok` 코드를 읽고 만든 것이고, 봉인 테스트 9건(test_explanation_guardrail.py)이 목으로 검증하는 범위까지만 확인 |
| 10 | 다른 픽스처·실물 등기부에서의 폴백률 | 픽스처 2건만 호출(크레딧 절약). `trust_seizure`·`messy_amounts`·`missing_sections`·`canceled_only`·`real_snapshot` 5종은 안 돌림 |
| 11 | `owner` 하이라이트의 개인/법인 분기 문구 전문 | `_SPECS`에 `body=""`이고 런타임 생성이라(highlight.py:174) 상수 목록에 없음. 분기 코드를 끝까지 읽지 않음 |
| 12 | 앱 위젯 테스트가 설명 렌더를 검증하는지 | `frontend/test/`에서 `easyExplanation` 참조 0건인 것만 확인. 간접 검증(카드 렌더 테스트) 여부는 안 봄 |
