# Information Extract 재현성 영점 측정 (2026-07-28)

> `backend/scripts/measure_ie_reproducibility.py` 가 생성했다.
> **개인정보 없음** — 값 대신 6자리 해시와 개수만 기록한다.

## 왜 쟀나

`out/ie_*.json` 3건(같은 문서)의 배열 길이 합계가 **18 / 16 / 16**으로 갈렸다.
이것이 모델의 흔들림인지 입력 차이인지 모르면, 다른 LLM과 비교했을 때 나온 차이가
**모델 차이인지 노이즈인지 구분할 수 없다.** 모든 AI 비교 실험의 영점이 여기다.

## 측정 조건

- 입력: 같은 이미지 5장 (`1.png, 2.png, 3.png, 4.png, 5.png`)
- 반복: 3회 (성공 3회)
- 모델·엔드포인트·스키마: 운영 경로와 동일 (`app/services/extraction.py`)

## 1. 응답 시간

| 회차 | 초 |
|---|---|
| 1 | 25.7 |
| 2 | 17.6 |
| 3 | 18.6 |
| **중앙값** | **18.6** |
| **최소~최대** | 17.6 ~ 25.7 |

## 2. 배열 길이 — 회차마다 같은가

| 필드 | 1회차 | 2회차 | 3회차 | 판정 |
|---|---|---|---|---|
| `current_owners` | 2 | 2 | 2 | 고정 |
| `ownership_changes` | 4 | 4 | 4 | 고정 |
| `provisional_seizures` | 0 | 0 | 0 | 고정 |
| `provisional_dispositions` | 0 | 0 | 0 | 고정 |
| `seizures` | 0 | 0 | 0 | 고정 |
| `auction_commencements` | 0 | 0 | 0 | 고정 |
| `trust_registrations` | 0 | 0 | 0 | 고정 |
| `mortgages` | 2 | 2 | 2 | 고정 |
| `jeonse_rights` | 0 | 0 | 0 | 고정 |
| `lease_registrations` | 0 | 0 | 0 | 고정 |
| **합계** | 8 | 8 | 8 | 고정 |

## 3. 스칼라 필드 — 값이 같은가 (해시 비교, 원문 미출력)

| 필드 | 1회차 | 2회차 | 3회차 | 판정 |
|---|---|---|---|---|
| `address` | `23a342` | `23a342` | `23a342` | 고정 |
| `document_title` | `c28380` | `c28380` | `c28380` | 고정 |
| `exclusive_area_sqm` | `e995db` | `e995db` | `e995db` | 고정 |

## 4. 항목 지문 — 같은 항목이 같은 내용으로 오는가

원소별 해시를 정렬해 비교한다(순서가 바뀌어도 집합이 같으면 '고정').

| 필드 | 판정 | 비고 |
|---|---|---|
| `current_owners` | 고정 |  |
| `ownership_changes` | 고정 |  |
| `provisional_seizures` | 고정 |  |
| `provisional_dispositions` | 고정 |  |
| `seizures` | 고정 |  |
| `auction_commencements` | 고정 |  |
| `trust_registrations` | 고정 |  |
| `mortgages` | 고정 |  |
| `jeonse_rights` | 고정 |  |
| `lease_registrations` | 고정 |  |

## 5. 결론

**같은 입력에는 같은 답이 나왔다** (이 표본에서). 배열 길이·항목 지문 모두 회차 간 동일.

→ `out/ie_*.json`의 18 / 16 / 16 차이는 **모델 흔들림으로 설명되지 않는다.**
   입력(사진 장수·구성)이 달랐을 가능성이 높다.

