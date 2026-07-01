# 등기부등본 정보추출 스키마 설명

> STEP 2-A 산출물. Upstage Information Extract에 넘길 추출 스키마
> ([backend/app/schemas/registry_schema.py](../backend/app/schemas/registry_schema.py))를
> 사람이 읽기 쉽게 풀어 쓴 문서입니다. **이 단계에서는 아직 API를 호출하지 않습니다.**

## 0. 설계 핵심

- **말소 여부(`is_canceled`)가 가장 중요하다.** 등기부등본(말소사항 포함)에는 말소된
  항목도 함께 나온다(빨간 취소선). 그래서 **모든 등기 항목마다** `is_canceled`를 두어
  "현재 유효한 항목"과 "말소된 항목"을 구분한다.
- **여러 개일 수 있는 항목은 배열**이다(근저당권·가압류 등).
- **가압류/가처분/압류/경매/신탁도 boolean이 아니라 배열**이다. 항목마다 말소 여부가
  다를 수 있어서다. 위험판단에서는 "유효한(`is_canceled=false`) 항목이 하나라도
  있는가"로 '여부'를 계산한다.
- **필드 키는 영문 snake_case, 의미는 한국어 설명(`description`)에 담는다.** JSON 키
  인코딩/제약 리스크를 피하기 위함. 아래 표가 영문 키 ↔ 한국어 의미 대응표다.

## 1. 표제부 — `property_description`

| 필드 | 타입 | 의미 | 어디에 쓰나 |
|---|---|---|---|
| `address` | string | 소재지(주소) | 물건 식별, (향후) 실거래가·시세 조회 키 |
| `exclusive_area_sqm` | number | 건물 전용면적(㎡) | (향후) 면적당 시세로 적정 보증금 판단 |

## 2. 갑구 — `ownership_section` (소유권에 관한 사항)

### `current_owners` (배열) — 현재 유효한 소유자
| 필드 | 타입 | 의미 |
|---|---|---|
| `name` | string | 소유자 이름 |
| `share` | string | 지분(예: `1/2`, `단독`) |

- **용도**: 계약 상대(임대인)가 실제 소유자와 일치하는지 확인. 공동소유면 전원 동의 필요.

### `ownership_changes` (배열) — 소유권 변동 이력
| 필드 | 타입 | 의미 |
|---|---|---|
| `rank_number` | string | 순위번호 |
| `purpose` | string | 등기목적(소유권보존/이전 등) |
| `receipt_date` | string | 접수일자 |
| `cause` | string | 등기원인(매매/상속/증여 등) |
| `cause_date` | string | 등기원인 일자 |
| `holder` | string | 권리자(소유권 취득자) |
| `is_canceled` | boolean | 말소 여부 |

- **용도**: **무자본 갭투자 의심** 신호 탐지. 최근 소유권 이전 + 매매가 대비 과도한
  전세, 짧은 보유 후 명의 이전 등을 본다.

### 처분제한·제3자 권리 항목 (각각 배열)
`provisional_seizures`(가압류), `provisional_dispositions`(가처분), `seizures`(압류),
`auction_commencements`(경매개시결정) — 공통 필드:

| 필드 | 타입 | 의미 |
|---|---|---|
| `rank_number` | string | 순위번호 |
| `purpose` | string | 등기목적 |
| `receipt_date` | string | 접수일자 |
| `cause` | string | 등기원인(법원 결정 등) |
| `claimant` | string | 권리자/청구채권자 |
| `claim_amount` | number | 청구금액(원, 없으면 생략) |
| `is_canceled` | boolean | 말소 여부 |

- **용도**: 유효한 항목이 하나라도 있으면 **고위험**. 특히 압류·경매개시결정은 이미
  권리관계가 위태롭다는 강한 신호(보수적 편향에 따라 강하게 경고).

### `trust_registrations` (배열) — 신탁등기
| 필드 | 타입 | 의미 |
|---|---|---|
| `rank_number` | string | 순위번호 |
| `receipt_date` | string | 접수일자 |
| `trustee` | string | 수탁자(신탁회사 등) |
| `is_canceled` | boolean | 말소 여부 |

- **용도**: 신탁등기가 유효하면 **소유권이 수탁자에게** 있어, 원 소유자와 계약하면
  무효가 될 수 있는 대표적 위험. 유효 신탁은 강하게 경고.

## 3. 을구 — `encumbrance_section` (소유권 이외의 권리)

### `mortgages` (배열) — 근저당권
| 필드 | 타입 | 의미 |
|---|---|---|
| `rank_number` | string | 순위번호(선/후순위 판단) |
| `max_claim_amount` | number | 채권최고액(원) |
| `debtor` | string | 채무자 |
| `mortgagee` | string | 근저당권자(은행 등) |
| `receipt_date` | string | 접수일자 |
| `is_canceled` | boolean | 말소 여부 |

- **용도**: **선순위채권 규모** 산정의 핵심. 유효한 근저당의 채권최고액 합계가 크면
  깡통전세 위험↑. (구체 임계값은 `docs/decisions.md`에 출처와 함께 기록 후 사용)

### `jeonse_rights` (배열) — 전세권
| 필드 | 타입 | 의미 |
|---|---|---|
| `rank_number` | string | 순위번호 |
| `deposit_amount` | number | 전세금(원) |
| `holder` | string | 전세권자 |
| `receipt_date` | string | 접수일자 |
| `is_canceled` | boolean | 말소 여부 |

- **용도**: 유효한 선순위 전세권이 있으면 내 보증금 회수 순위가 밀린다.

### `lease_registrations` (배열) — 임차권(임차권등기명령)
| 필드 | 타입 | 의미 |
|---|---|---|
| `rank_number` | string | 순위번호 |
| `deposit_amount` | number | 임차보증금(원) |
| `holder` | string | 임차권자 |
| `receipt_date` | string | 접수일자 |
| `is_canceled` | boolean | 말소 여부 |

- **용도**: 임차권등기명령이 있었다는 것은 **과거 보증금 미반환 사고 이력**을 뜻하는
  강한 위험 신호.

## 4. 확인이 필요한 부분 (STEP 2-B에서 공식 문서로 검증)

아래는 현재 **확실하지 않아** 표시해 둔 항목이다. 실제 API 연동 전에
`console.upstage.ai/docs`에서 확인한다.

1. 스키마를 넘기는 정확한 형태(본 설계는 OpenAI 호환 `response_format` 가정).
2. 정확한 endpoint / model 이름.
3. 깊은 중첩(object→object→array→object) 지원 한계.
4. 금액(`number`) 추출 신뢰도 — "금 300,000,000원" 표기 대응. 흔들리면 string 후처리로 전환.
5. `required`/`additionalProperties` 존중 여부.

## 5. 다음 단계에서의 검증 계획 (요약)

실제 검증 방법은 별도로 정리하되, 요지는 다음과 같다.

1. 말소사항이 포함된 실제 등기부등본 이미지 1~2건으로 호출해 반환 JSON을 육안 대조.
2. **말소 항목이 `is_canceled=true`로 정확히 구분되는지**를 최우선으로 확인.
3. 금액이 숫자로 깔끔히 오는지 확인(안 되면 string 후처리).
4. 항목 개수(근저당 여러 건 등)가 배열로 빠짐없이 잡히는지 확인.
