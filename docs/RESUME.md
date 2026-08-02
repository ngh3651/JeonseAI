# RESUME — 중단 시 이어서 하기

> 작업 단위마다 덮어쓴다. 재개하면 **코드보다 이 파일과 `docs/night-log-2026-07-28.md`를
> 먼저 읽어라.** (2026-07-28 야간 세션 종료 시점으로 갱신 — 이전 내용은 07-27 세션 것이었다)

## 1. 지금 어디까지

**2026-07-28 야간 세션 완료.** 브랜치 `feat/reading-guide` (기점 `8cb6cc5` = main = dev).
지시받은 작업 A~F + 추가 지시(Document Parse 조사) + §9 자율 과제 **전부 착수·완료**.
서브에이전트 6종(지수·서연·rule-auditor·gap-checker·design-reviewer·judge-reviewer) 투입.

## 2. 마지막 커밋

`c18da09` — fix: 리뷰 미반영분 처리. **빌드되는 상태.**
검증: 백엔드 pytest **297건** / flutter analyze 무오류 / flutter test **108건**.
판정 회귀 봉인(`tests/test_verdict_regression.py`)으로 픽스처 7건의 등급이 기점 커밋과 동일함을 확인.

## 3. 커밋 안 된 변경

없음. (`backend/out/`·`design_handoff_registry_viewer/`는 `.gitignore` — 실명 포함)

## 4. 남은 것 — 사람 판단이 필요해서 안 한 것

| # | 무엇 | 왜 안 했나 |
|---|---|---|
| 1 | **실기기 육안 확인** ⚠ 최우선 | `adb devices`에 기기 없음. 표시가 15종으로 늘어 **띠가 화면을 덮는지 눈으로 봐야 한다.** 절차: `docs/morning-report-2026-07-28.md` §7 |
| 2 | 캐러셀 **초기 선택을 가장 무거운 표시로** | `MarkKind`에 severity 축을 새로 넣는 설계 결정 (서연 #3·#4) |
| 3 | **요청 문구 복사 버튼** | 새 기능 (서연 #9 — "이번 작업에서 가장 값어치 있는 한 개") |
| 4 | `checkedNotes`에 **분류 태그** | `api-contract.md` 계약 변경 → 승인 필요. 지금은 마커 목록을 늘려 막아 둠 |
| 5 | `design_handoff_registry_viewer/` 삭제 여부 | 그 폴더의 이미지가 **복잡 문서(압류 포함)의 유일한 로컬 사본**. 지우면 IE 재현성을 다시 못 잰다 |
| 6 | `compare_llm_backends.py` 통합 | 선행 하네스에 판례 역할 3종이 있어 지금 지우면 자산이 사라진다 |
| 7 | mortgage·jeonse 문구를 행동 우선으로 | 2026-07-27에 이미 리뷰를 거친 문구 — 조용히 갈아치우지 않는다 |

## 5. 다음 세션에서 가장 먼저 볼 것

1. `docs/morning-report-2026-07-28.md` §5(못 한 것) · §8(리뷰 결과)
2. `docs/decisions.md` 맨 뒤 2026-07-28 항목 9건 + **"고려했으나 하지 않은 것"** 절
   → **조사·실험 착수 전에 반드시 훑는다.** 이번 세션에서 이미 기록돼 있던 것
     (EXAONE `enable_thinking=false`, FriendliAI 429)을 재발견하느라 시간을 썼다.
3. `docs/document-parse-probe-2026-07-28.md` — DP를 더 쓸지 말지의 근거

## 6. 되돌리는 법

전부: `git checkout main -- backend frontend` (문서는 측정 기록이라 되돌릴 필요 없음)
개별: `docs/morning-report-2026-07-28.md` §4의 표 — 결정별 되돌리기 지점 9개
