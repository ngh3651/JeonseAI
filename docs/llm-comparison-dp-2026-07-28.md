# 국내 LLM 비교 — 구조화 · 설명 (2026-07-28)

> `backend/scripts/compare_llm.py` 가 생성했다.
> **개인정보 없음** — 개수·일치율·해시만 기록한다. 원본 응답은 `backend/out/llm_compare/`(커밋 금지).

## 읽기 전에 — 영점(noise floor)을 먼저 볼 것

`docs/ie-reproducibility-2026-07-28-complex.md`에서 **같은 입력을 5회 반복**했을 때
IE는 배열 길이가 전부 고정이었고, 자유서술 필드(`cause`) 하나만 흔들렸다.
**여기서 그 폭보다 작은 차이는 모델 차이로 볼 수 없다.**

## 측정 조건

- 레이아웃 출처: **`document_parse`** — dp_1.json, dp_2.json, dp_3.json, dp_4.json, dp_5.json (4,309자)
- 구조화 정답지(대조용): `ie_20260728_004234_156.json` — Upstage Information Extract 결과
- 설명 입력: `tests/fixtures/registry/mortgage_heavy.json` 판정 (실명 없음)
- 반복: 역할별 3회

## provider

| provider | 모델 | 상태 |
|---|---|---|
| `upstage` | `solar-pro2` | 사용 |
| `exaone` | `LGAI-EXAONE/K-EXAONE-236B-A23B` | 사용 |
| `ax` | `ax4` | **키 없음 → 건너뜀** (`AX_API_KEY`) |

> 키가 도착하면 `backend/.env`에 값만 넣으면 **코드 수정 없이** 이 표에 합류한다.

## 역할 ① 구조화 (OCR 텍스트 → 등기 필드)

| provider | 성공 | 중앙 응답(초) | 항목수 일치율 | 순위번호 일치율 | 회차 간 흔들림 |
|---|---|---|---|---|---|
| `upstage` | 3/3 | 6.5 | 100% | 100% | 흔들림(2종) |
| `exaone` | 3/3 | 9.7 | 75% | 88% | 흔들림(3종) |

### 필드별 항목 수 (IE vs 각 provider, 1회차 기준)

| 필드 | IE | upstage | exaone |
|---|---|---|---|
| `current_owners` | 2 | 2 | 1 |
| `mortgages` | 0 | 2 | 2 |
| `jeonse_rights` | 0 | 0 | 0 |
| `lease_registrations` | 0 | 0 | 0 |
| `provisional_seizures` | 0 | 0 | 0 |
| `seizures` | 0 | 0 | 0 |
| `auction_commencements` | 0 | 0 | 0 |
| `trust_registrations` | 0 | 0 | 0 |

## 역할 ② 설명 문장 (판정 JSON → 쉬운 한국어)

제품과 **같은** 검증을 그대로 쓴다 — `ExplanationPayload`(extra=forbid) + `_BANNED_PHRASES`.

| provider | 성공 | 중앙 응답(초) | 스키마 통과 | 금지어 위반 | 해요체 위반 | 회차 간 흔들림 |
|---|---|---|---|---|---|---|
| `upstage` | 3/3 | 2.0 | 3/3 | 0건 | 0건 | 흔들림(3종) |
| `exaone` | 1/3 | 4.3 | 1/1 | 0건 | 0건 | 고정 |

> 금지어·해요체 위반이 있어도 **제품에서는 그 필드만 폴백으로 치환**되므로 화면에 나가지 않는다
> (`explanation.py`의 `_field_ok`). 이 표는 '얼마나 자주 폴백을 쓰게 되는가'를 재는 것이다.

## 관찰 (숫자가 말하지 않는 것)

- (아침에 사람이 채울 칸) 어떤 모델의 출력이 실제로 읽을 만했는지, 어디서 이상했는지.
- 승자를 단정하지 않는다. 이 표는 **판단 재료**이지 결론이 아니다.

