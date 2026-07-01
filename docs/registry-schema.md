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
- **필드 키는 영문 snake_case, 의미는 한국어 설명(`description`)에 담는다.** 아래 표가
  영문 키 ↔ 한국어 의미 대응표다.

### 구조 = "최상위 평면(flat)" (STEP 2-B-1에서 확정)

STEP 2-A에서는 표제부/갑구/을구를 **객체 그룹**으로 묶었으나, Upstage Information
Extract 제약 때문에 **최상위 평면 구조로 바꿨다**:

> **최상위(first-level) 속성은 `string`/`integer`/`number`/`array`만 허용되고,
> `object`(중첩 객체)는 배열의 원소로만 허용된다.** (동기 호출 한도: 100페이지 / 100속성)

따라서 표제부 필드는 최상위 scalar로, 갑구/을구 목록은 최상위 array로 두었다.
어느 구(區)에 속하는지는 아래 표의 그룹 제목과 스키마 파일 주석의 `[표제부]/[갑구]/[을구]`
접두어로 표시한다. (전체 최상위 필드 12개)

## 1. [표제부] 부동산 기본 표시 (최상위 scalar)

| 필드 | 타입 | 의미 | 어디에 쓰나 |
|---|---|---|---|
| `address` | string | 소재지(주소) | 물건 식별, (향후) 실거래가·시세 조회 키 |
| `exclusive_area_sqm` | number | 건물 전용면적(㎡) | (향후) 면적당 시세로 적정 보증금 판단 |

## 2. [갑구] 소유권에 관한 사항 (최상위 array/scalar)

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

## 3. [을구] 소유권 이외의 권리 (최상위 array)

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

## 4. 확인된 API 사양 (STEP 2-B-1, Upstage 공식 문서)

| 항목 | 확인 결과 |
|---|---|
| Endpoint | `POST https://api.upstage.ai/v1/information-extraction` |
| Model | `information-extract` |
| 스키마 전달 | `response_format` (type=`json_schema`) — `build_response_format()` 형태가 맞음 |
| 이미지 전달 | base64 data URL을 `messages` content에 `type="image_url"`로 |
| 응답 위치 | `choices[0].message.content`에 **JSON 문자열**로 담겨 옴 → 파싱 필요 |
| 스키마 제약 | **최상위는 scalar/array만, object는 배열 원소로만** / 100페이지·100속성 한도 |

**남은 소소한 확인(실호출로 검증):**
- 배열 원소 object 안의 `boolean`(is_canceled)·`number`(금액)이 타입 그대로 오는지.
  흔들리면(금액이 문자열 등) string으로 받고 후처리. → 검증 스크립트가 자동 요약해 줌.

## 5. 검증 방법 (STEP 2-B-1 스크립트)

스크립트: [backend/scripts/test_extract.py](../backend/scripts/test_extract.py)

1. 말소사항이 포함된 실제 등기부등본 이미지 1건을 `backend/test_samples/`에 넣는다.
   (이 폴더는 `.gitignore`로 제외 — 개인정보 커밋 방지)
2. 스크립트 실행 → 반환 JSON을 예쁘게 출력하고, 맨 아래 **검증 요약**을 자동으로 보여준다:
   - 근저당 개수 / 그중 말소 건수
   - 채권최고액이 숫자로 왔는지(타입 점검)
   - 현재 소유자 이름 목록
   - 가압류/가처분/압류/경매/신탁 각 건수(유효 건수)
3. **말소 항목이 `is_canceled=true`로 정확히 구분되는지**를 최우선으로 육안 확인한다.

실행 명령(backend 폴더에서):

```powershell
.\.venv\Scripts\python.exe scripts\test_extract.py test_samples\sample_registry.jpg
```
