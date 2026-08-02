# 정리(삭제·교체) 대상 트래커 (cleanup-tracker.md)

> **living document.** 더미·스캐폴딩·테스트용 임시 산출물을 **놓치지 않고 적기에 정리**하기 위한 목록입니다.
> 원칙: 임시 파일을 만들 때마다 여기에 "무엇을 / 언제(어느 Phase) 삭제·교체" 를 함께 기록하고,
> 실구현으로 교체되는 시점에 이 목록을 근거로 정리한다. (지금 당장 지우는 게 아니라, 때가 되면 반영)
>
> 상태 표기: ⏳ 대기(아직 필요) · ✅ 정리 완료

| 대상 | 무엇 | 삭제·교체 시점 | 상태 |
|---|---|---|---|
| `backend/app/dummy_data.py` | 앱 더미를 그대로 옮긴 서버 더미 응답(리포트·판례·질문·용어·여정) | **Phase E**: 실제 추출(Information Extract)·규칙 엔진·LLM·큐레이션으로 교체되면 삭제/축소 | ⏳ |
| `backend/app/dependencies.py`의 `DEV_MODE_AUTH`(개발모드 인증) | 토큰 검사 없이 항상 통과하는 임시 인증 | **실인증 도입 시**(Supabase 등): `get_current_user`의 실검증 블록으로 교체, 개발모드 스위치 제거 | ⏳ |
| `backend/app/main.py`의 `POST /api/upload` | 앱↔서버 통신 파이프 검증용 레거시 엔드포인트 | **D-3/E**: `POST /api/analyze`가 분석 흐름을 대체하면 삭제 검토(검증 자산이라 필요 시까지 보존) | ⏳ |
| `frontend/lib/repositories/`의 `DummyAnalysisRepository`·`DummyContentRepository` | 로컬 더미 리포지토리 구현 | **D-3 완료**: 프로덕션 주입은 Api*로 교체됨. 현재 **위젯 테스트 전용**(main.dart 오버라이드로만 주입) — Phase E 정리 시 test/ 하위로 이동 또는 삭제 | ⏳ |
| `frontend/lib/design_system/gallery/component_gallery_screen.dart` (`/gallery` 라우트) | 디자인 시스템 카탈로그(개발·팀 공유용, 제품 진입점 없음) | **출시/시연 정리 시(Phase F)**: 내부용으로 유지할지 제거할지 결정 | ⏳ |
| `backend/app/main.py`의 `app.router.routes.extend(...)` 우회 | fastapi 0.139+starlette 1.3.1에서 `include_router`가 깨져 쓴 임시 우회 | **라이브러리 버전 정리 시**: 정상 버전에서 `app.include_router(...)`로 되돌림 | ⏳ |
| 스크래치패드 검증 스크립트(예: `d2_verify.py`) | API 수동 검증용 임시 스크립트 | 즉시성 산출물 — 스크래치패드에 두고 저장소에 커밋하지 않음(추적 대상 아님) | — |
| `backend/data/` 안의 `is_sample: true` 항목 | 큐레이션 양식을 보여주는 형식 예시(판례 2건·악성임대인 1건 — 가짜 데이터) | **E-2/E-3**: 팀 실데이터 반영 시 삭제 (README.md에 규칙 명시) | ⏳ |
| `backend/scripts/run_rules.py` | 규칙 엔진 픽스처 판정표 러너(육안 확인용 임시 개발 도구, E-1b 산출물) | **E-6**: 개발 도구로 유지할지 삭제할지 결정 | ⏳ |
| `backend/scripts/test_extract.py` | E-1c에서 로직이 `services/extraction.py`로 승격되어 **thin CLI**로 축소됨(실행 시 크레딧 소모) | **E-6**: 개발 도구로 유지할지 삭제할지 결정 | ⏳ |
| `backend/app/services/store.py`의 dummy_data 예시 시드 import | 예시 리포트 2건을 dummy_data에서 빌려 시드 | **E-6**: dummy_data 삭제 시 예시 시드를 store/data로 이전 | ⏳ |
| `frontend/lib/app/config.dart`의 `devAutoLogin` | 개발용 자동 로그인("개발자" 회원으로 시작) — 팀 테스트 편의, 게이트 로직은 유지 | **실 로그인 도입 시 제거**. 시연 리허설(F)에서 비회원 연출 필요 시 false로 확인 | ⏳ |
| `frontend/lib/repositories/price_source.dart` | 시세 입력 소스 격리 설계 스캐폴드(`PriceSource`/`ManualPriceSource`, [2026-07-03] 결정). 현재 런타임 미배선(주석 참조만) — 죽은 코드지만 의도된 확장점 | **E-4/국토부 실거래가 API 도입 시**: `MarketPriceApiSource`로 배선하거나, 도입 안 하면 명시적 제거 결정 | ⏳ |
| `backend/data/cases.json` (구 판례 양식) | E-3 이전의 수기 큐레이션 판례 파일(샘플 2건) — `data/precedents/`(RAG 신 방식)로 대체 예정 | **E-3**: 판례 화면이 RAG 매칭으로 전환되면 삭제(참조하는 dummy_data와 함께) | ⏳ |
| `backend/scripts/demo_precedent.py` | 판례 RAG E2E 검증 CLI(계약 무변경 개발 도구, 2026-07-22 야간 작업) | **E-3**: 라우터 통합 후 개발 도구로 유지할지 삭제할지 결정 (run_rules.py와 동일 취급) | ⏳ |
| 법제처 API `OC=test` 폴백 (`collect_precedents.py`) | 정식 인증값 없이 개발용으로 동작하는 임시 경로 | **정식 OC 발급 시**: `.env`에 `LAW_API_OC` 추가 — 코드 무변경, 폴백 경고만 안 뜨게 됨. 대량 수집 전 필수 | ⏳ |
| `backend/data/precedents/seed_cases.json`의 `curated_by: "야간 자율 작업(웹 검증) — 정민재 검수 대기"` 7건 | 개발자 웹 검증 시드 — 정민재 실큐레이션 도착 전 임시 콘텐츠(사건번호·출처는 실제) | **E-3**: 정민재 검수·보강 후 curated_by 갱신, 문구(요약·조언) 팀 검수 | ⏳ |
| `backend/scripts/test_ocr_coords.py` | OCR 하이라이트 **사전 검증** CLI(Document OCR 좌표가 쓸 만한지 판정용, 2026-07-27). 검증 실패 시 기능과 함께 폐기 | **매칭 로직을 `services/`로 승격한 뒤 삭제.** 검증 실패로 기능을 폐기하면 그 시점에 즉시 삭제 | ⏳ |
| `backend/out/` | `test_ocr_coords.py` 산출물(OCR 원본 JSON·마킹 이미지). **등기부 소유자 실명 포함** → `.gitignore` 처리(커밋 안 됨) | **E-6 정리 스윕**: 로컬 폴더 삭제. 기능 폐기 시에는 그 시점에 삭제. **2026-07-28부터 서버 저장분은 `artifacts.py`가 최근 5회분만 유지**(절차가 아니라 코드) | ⏳ |
| `backend/app/services/artifacts.py` | 진단용 원응답의 저장 위치·보관 상한(최근 5회분). **임시 파일이 아니라 임시 파일을 관리하는 코드**다 | `SAVE_IE_RAW`·`SAVE_OCR_RAW`를 둘 다 걷어내는 날 함께 삭제 | ⏳ |
| `backend/scripts/measure_ie_reproducibility.py` | IE 재현성 영점 측정 CLI(2026-07-28). 실행 시 크레딧 소모 | **E-6**: 개발 도구로 유지할지 결정 (`run_rules.py`와 동일 취급). 모델·엔드포인트가 바뀔 때마다 다시 돌릴 가치가 있어 유지 쪽에 무게 | ⏳ |
| `backend/scripts/compare_llm.py` | 국내 LLM 비교 하네스(구조화·설명 2역할, 2026-07-28). 새 `services/llm` provider 계층을 그대로 쓴다 | **E-6**: 유지 쪽. 새 모델이 나오거나 A.X 키가 도착하면 그대로 다시 돌린다 | ⏳ |
| `backend/scripts/compare_llm_backends.py` | **선행 하네스**(2026-07-22, 4역할: explanation·precedent·tagging·case_compare). provider 설정을 자체 환경변수로 따로 들고 있어 `services/llm`과 **중복**된다 | **통합 대상**: precedent·tagging·case_compare 역할을 `compare_llm.py`로 옮긴 뒤 삭제. 지금 지우면 판례 쪽 비교 자산이 사라지므로 **오늘은 두었다** | ⏳ |

## 사용 규칙
- 새 임시/더미/스캐폴딩 파일을 만들면 **이 표에 한 줄 추가**한다(대상·무엇·삭제 시점).
- 해당 Phase에 도달하면 이 표를 근거로 **정리를 제안하고**, 정리하면 상태를 ✅로 바꾼다.
- 관련 원칙은 CLAUDE.md 4절(개발 방법론)에도 한 줄로 명시돼 있다.

## 개인정보 포함 산출물 — 작성 규칙 (2026-08-02 신설)

> **실명·상세주소·고유번호는 문서에 쓰지 않는다. 검증 기록에는 마스킹된 형태로만 남긴다.**

- 마스킹 기호: 자연인 **소유자A·B·C…**(갑구 등기 접수 순서) · 등기부 실체 법인 **법인A·B…** ·
  주민등록번호 `○○○○○○-○******` · 상세주소·건물명은 **같은 형식의 가상값**.
- **숫자·좌표·건수·날짜·금액은 원본 그대로 둔다** — 검증 기록의 가치가 거기 있다.
- 마스킹한 문서에는 상단에 고지 한 줄을 남긴다(어떤 기호가 무엇을 가리는지).
- 은행 등 일반 법인명·법인등록번호는 대상이 아니다(공개 정보, 특정 물건을 지목하지 않음).

| 대상 | 무엇 | 정리 시점 | 상태 |
|---|---|---|---|
| `backend/out/` · `backend/test_samples/` · `design_handoff_registry_viewer/` | 등기부 원본 이미지·OCR/IE 원응답. **소유자 실명 포함** | `.gitignore` 처리됨 — 2026-08-02 `git ls-files`로 **추적 0건 확인**. 로컬 폴더는 E-6 정리 스윕에서 삭제 | ✅ 미추적 확인 |
| `docs/` 검증 기록 6종(night-log·morning-report·ocr-highlight-findings·highlight-miss-diagnosis·feedback-log·presentation-material) | 실명·주민번호 앞자리·상세주소·건물명이 들어가 있었음 | **2026-08-02 마스킹 완료**(88건) → **2026-08-03 히스토리 재작성으로 과거 커밋에서도 제거** | ✅ |
| 테스트 픽스처 5종(`test_formatting`·`test_highlight`·`test_page_order`·`test_report_builder`·`registry_highlight_test.dart`) | 실제 물건의 상세주소·건물명을 픽스처로 사용 | **2026-08-02 가상 주소로 교체 완료**(형식 유지). 앞으로 픽스처는 처음부터 가상값으로 만든다 | ✅ |

### 2026-08-03 — git 히스토리 재작성 (되돌릴 수 없음)

`git filter-repo`로 **전 커밋(72개)의 파일 내용과 커밋 메시지**에서 등기부 개인정보를
치환했다. 2026-08-02 마스킹은 "현재 파일"만 고쳤을 뿐 과거 커밋에는 원본이 그대로
남아 있었다.

- **이전 커밋 해시는 전부 무효다.** 문서 안의 해시 참조가 2026-08-03 이전 것이라면
  낡은 값이다. 이번 작업에서 `docs/` 안 참조 47건은 새 해시로 갱신했지만, 그보다
  오래된 메모·이슈·채팅에 적힌 해시는 더 이상 어떤 커밋도 가리키지 않는다.
- 팀원은 **기존 로컬 클론을 버리고 다시 clone** 해야 한다(`git pull`은 두 히스토리를
  뒤섞는다). 안내문: `docs/team-notice-2026-08-03-history-rewrite.md`
- 커밋 개수·순서·메시지·작성일시는 보존했다(`--prune-empty never`). 바뀐 것은 해시와
  개인정보 문자열뿐이며, 바이너리 blob 50개는 재작성 전후 SHA가 동일함을 확인했다.
- 재작성 전 백업: `../JeonseAI-backup.git` (`git clone --mirror`). **이 백업에는 원본
  개인정보가 그대로 들어 있다** — 공유 금지, 검증이 끝나면 삭제 대상.
- 치환 규칙 파일은 원본 문자열을 담고 있으므로 저장소 밖에서 쓰고 **작업 후 삭제**했다.

---

## [2026-07-09] 레포 정리 스캔 결과 (분류1 ✅ 완료 · 분류2 트래커 승격 완료)

> 목표: 앞으로 안 쓸 파일·부산물·빈 폴더 정리. **위 표의 기능 스캐폴딩(dummy_data·DEV_MODE_AUTH·
> /api/upload·더미 리포지토리·gallery·run_rules·test_extract 등)은 이번 대상 아님**(Phase 스케줄·기능 변경).
> 전제: 추적 파일 207개, 삭제 후보는 grep으로 참조 0 확인. 기능·동작 변경 없음.

### 분류 1 — 명백한 정크 (✅ 2026-07-09 삭제 완료)
| 경로 | 왜 불필요 | git 추적 | 상태 |
|---|---|---|---|
| `frontend/.gitkeep` | 0바이트 빈 디렉터리 마커. frontend는 파일이 가득 차 있어 불필요. 코드·pubspec·docs 참조 0 | 추적됨 | ✅ `git rm` 완료. 회귀 통과(analyze 0·test 2/2·pytest 61/61) |

### 분류 1b — 로컬 빌드 부산물 (git 무관, 권장: 그대로 둠)
| 경로 | 설명 | git 추적 |
|---|---|---|
| `frontend/android/.gradle/8.14/expanded`, `.../vcsMetadata`, `frontend/android/.kotlin/sessions` | Gradle/Kotlin 로컬 빌드 캐시의 빈 폴더. 빌드 시 재생성됨 | 미추적(빈 폴더는 git이 추적 안 함) |
- → **삭제해도 git 정리 효과 없음**(커밋에 없음). 빌드 툴 관리 영역이라 손대지 않는 것을 권장.

### 분류 2 — 검토 필요 (✅ 삭제 안 함 · 위 트래커 표로 승격 완료)
| 경로 | 상태 | 판단 |
|---|---|---|
| `frontend/lib/repositories/price_source.dart` | 런타임 import·사용 0(주석 참조만: `analysis_report.dart`). `PriceSource`/`ManualPriceSource`/`MarketPriceApiSource` | **[2026-07-03] 결정 "Phase B 시세 입력 소스 격리"의 설계 스캐폴드**(수동 입력 ↔ 국토부 실거래가 API 교체점). **삭제하지 않음** — 위 정리 트래커 표에 "E-4/실거래가 API 도입 시 배선 또는 명시적 제거 결정"으로 승격 완료(⏳) |

### 분류 3 — 구조 정리(이동) 제안
- **없음.** 위치가 어색한 비코드 파일 없음. `docs/draft/`(브레인스토밍 초안)·`scripts/`·`backend/scripts/`는 모두 docs·코드에서 참조되어 유지. 기능 코드 이동은 참조 깨짐 위험으로 제외.

### 스캔 클린 확인
- 정크 패턴(`.DS_Store`/`Thumbs.db`/`*.bak`/`*_old`/`*_copy`/`사본`/`*.tmp`/`*.log`/`*~`) **추적분 0건**.
- 백엔드 `app/**/*.py` 미import orphan **0건**.
- 루트 `assets/` 마스코트 이동 후 잔여 **없음**(빈 폴더 제거 완료).

**승인 시**: 분류 1(`frontend/.gitkeep`) `git rm` → `flutter analyze`·`flutter test`·`pytest` 회귀 확인 → 이 절 상태를 ✅로 갱신. 분류 2는 별도 지시(트래커 승격 또는 유지).

---

## [2026-07-27] OCR 하이라이트 야간 작업 산출물 (**기능 채택 미확정**)

> 이 기능이 폐기되면 아래 항목은 **전부 함께 삭제**된다. 채택되면 각 시점에 정리한다.
> 검증 기록: `docs/ocr-highlight-findings.md` · 진행 로그: `docs/night-log.md`
>
> **2026-07-29**: `feat/reading-guide` → `dev` 병합 완료(브랜치 삭제). 기능 채택은 **여전히 미확정** —
> 미검증 항목: 폰 촬영본, 유효 근저당 샘플.

| 대상 | 무엇 | 삭제·교체 시점 | 상태 |
|---|---|---|---|
| `docs/night-log.md` | 야간 작업 실시간 진행 로그(2026-07-27). 아침 보고서의 근거 원본 | **보존 결정(2026-07-28).** `docs/presentation-material.md`가 이 로그의 실측값을 인용하고 `ocr-highlight-findings.md`도 참조한다 — 발표 스토리의 원재료라 남긴다 | ✅ 보존 |
| `docs/RESUME.md` | 중단 대비 이어받기 메모(4줄 고정 양식) | **작업 종료 시 삭제.** 다음 야간 작업 때 다시 만든다 | ✅ **2026-07-28 갱신.** 지우는 대신 07-28 세션 상태로 덮어썼다 — 남은 항목 7건이 실제로 있어 빈 파일보다 이 편이 이어받기에 낫다 |
| `docs/highlight-miss-diagnosis-2026-07-29.md` | 형광펜 누락 3건(A 전용면적·B 공동담보목록·C 근저당 4번째)의 **원인 규명 기록**. 저장된 원응답만으로 "OCR이 못 읽었나 / 규칙이 못 집었나"를 가른 근거 — A는 수정 완료, **B·C·D는 미해결 제안으로 남아 있다** | **B·C·D가 모두 처리될 때까지 보존.** 셋 다 반영되면 night-log와 같은 취급으로 넘겨 판단(발표 재료로 인용되면 보존). 기능 폐기 시 함께 삭제 | ⏳ |
| `docs/morning-check.md` | 아침에 실기기로 확인하는 절차서 | **확인 완료 후**: 절차가 반복 가치가 있으면 `docs/team-setup.md`로 흡수, 아니면 삭제 | ⏳ **아직 유효.** 2026-07-28 세션에서도 실기기가 연결돼 있지 않아 육안 확인을 못 했다 — 그 확인이 끝나기 전에는 지우지 않는다 |
| `backend/scripts/test_ocr_coords.py` | 검증 CLI. 로직은 `app/services/ocr_layout.py`로 **이미 승격됨** — 지금은 그 모듈을 검증·시각화하는 역할만 | **좌표 정합이 실기기에서 확정된 뒤 삭제.** 기능 폐기 시 즉시 삭제 | ⏳ |
| `backend/out/` (`ocr_*.json`, `marked_*.png`, `items_summary.md`) | 검증 산출물. **등기부 소유자 실명 포함** → `.gitignore` 처리(커밋 안 됨) | **E-6 정리 스윕**에서 로컬 폴더 삭제. 단 `ocr_3.json`·`ocr_4.json`은 pytest 픽스처로 쓰이므로(없으면 9건 skip) 그 전까지 보존 | ⏳ |
| `extraction.py`의 `SAVE_IE_RAW`(개발 모드 IE 추출 결과 저장) → `backend/out/ie_<타임스탬프>.json` | IE가 항목마다 `is_canceled`·`rank_number`·`amount`를 무엇으로 줬는지 크레딧 0원으로 다시 보기 위한 재료(2026-07-27 추가 — 근거 카드 27.8억 vs 하이라이트 14억 불일치를 조사할 때 IE 응답이 없어 재호출해야 했던 경험). `SAVE_OCR_RAW`와 동일하게 `DEV_MODE_AUTH`에 묶여 운영 전환 시 자동 off. **실명·주소 포함 → 커밋 금지** | **IE 말소 판정 정확도가 확인되면 저장 코드(`SAVE_IE_RAW`·`_save_raw_ie`) 제거.** 운영 전환 시 자동으로 꺼지므로 급하지 않음 | ⏳ |
| `ocr.py`의 `SAVE_OCR_RAW`(개발 모드 OCR 원응답 저장) → **`backend/out/runs/<회차>/ocr_<stem>.json`** | 서비스 실호출(`run_ocr`) 시 OCR 원응답을 out/에 남기는 **개발 모드 전용** 경로. 레이아웃 임계값(`_GAP_RATIO` 등, 밤 샘플 1건 실측값)을 다른 해상도·등기부에서 크레딧 없이 재측정하기 위한 재료(2026-07-27 추가). `DEV_MODE_AUTH`에 묶여 운영 전환 시 자동 off. **실명 포함 → 커밋 금지**. **2026-07-28: 저장 경로를 회차 폴더로 옮겨 덮어쓰기 사고를 없앴다**(예전에는 앱이 늘 `page_N.jpg`로 보내 매 분석마다 이전 회차가 사라졌다) | **임계값이 여러 등기부로 확정되면 저장 코드(`SAVE_OCR_RAW`·`_save_raw_ocr`) 제거.** 기능 폐기 시 본체(ocr.py)와 함께 삭제 | ⏳ |
| `frontend` 뷰어의 **좌표 진단 토글**(`_debug`, `registry_viewer_screen.dart`) | 매칭된 좌표의 터치 영역을 파랗게 그리고 원본/표시 크기를 로그로 찍는 개발용 스위치. 현재 `kDebugMode`로 릴리스에서는 숨김 | **✅ 2026-07-27 제거 완료.** 실기기(SM-S931N)에서 터치 판정이 정확한 것이 확인되어 토글·파란 네모·`_debug` 상태를 전부 걷어냈다. 위젯 테스트의 디버그 케이스는 그 자리를 이어받아 **그어짐 중간 상태** 검사로 바뀌었다 | ✅ |
| `backend/app/services/ocr.py` · `ocr_layout.py` · `highlight.py` | OCR 하이라이트 본체 3종 | **기능 폐기 시 삭제**(+ `report_builder.analyze`의 병렬 호출 되돌리기 + `contract.py`의 `Highlight`/`highlights`/`highlightNotice`/`checkedNotes` 제거) | ⏳ |
| `backend/tests/test_highlight.py` | 하이라이트 테스트 39건. 그중 9건은 `out/ocr_*.json`이 있을 때만 실행(없으면 skip) | 위 본체와 함께 | ⏳ |
| `frontend/lib/state/registry_photo_store.dart` | 전송 JPEG 경로 보관. 2026-07-27 **세션 메모리 → 앱 영구 저장소 복사**로 전환(결정 ⑤ 뒤집음) | 위 본체와 함께 | ⏳ |
| `frontend/lib/app/config.dart`의 `devKeepRegistryPhotos` + 저장물 `<앱 문서폴더>/registry_photos/<reportId>/`(page_N.jpg·report.json) + SharedPreferences 키 `registry_photos_v1` | 개발용 사진·리포트 로컬 보관 — 앱/서버 재시작 후에도 뷰어를 열어 **재분석 크레딧을 태우지 않기 위한** 스위치. **등기부 소유자 실명·주소가 기기에 남는다**(최근 5건만 유지) | **제출·시연 빌드에서 `false`로 전환**(그러면 예전 메모리 전용 동작). 실 배포 시에는 스위치·보관 코드·`shared_preferences` 의존성까지 제거하고, 기기에 남은 폴더도 지울 것 | ⏳ |
| `design_handoff_registry_viewer/` (레포 루트) | **[2026-07-28 보존 결정]** `assets/page1·2·4.png`가 **압류·가압류가 든 복잡 등기부의 유일한 로컬 사본**이 됐다(IE 재현성 측정 5회를 그 이미지로 했다). 지우면 다시 잴 수 없다. 삭제는 사용자 판단 후. — 2026-07-27 뷰어 재디자인 디자인 핸드오프 번들 — README(사양서)·HTML 시안·`support.js`·`assets/`(마스코트 3장 + **등기부 실명 샘플 3장**). `.gitignore` 처리(커밋 안 됨) | **뷰어 재디자인 구현 완료 후 로컬 폴더 삭제.** 복사해 뒀던 마스코트 3장은 **투명 배경 체크무늬가 픽셀로 구워져 있어 2026-07-27 삭제**했고, 앱은 기존 `mascot_<state>.png`를 쓴다 | ⏳ |

---

## [2026-07-28] 읽기 가이드·3경로 야간 작업 산출물

> 이번 세션에서 새로 생긴 것. **대부분은 임시가 아니라 정식 코드**이므로, 정리 대상이
> 아닌 것도 "왜 정리 대상이 아닌지"를 함께 적는다(다음 사람이 지우려다 멈출 수 있게).

| 대상 | 무엇 | 삭제·교체 시점 | 상태 |
|---|---|---|---|
| `backend/app/services/llm/` (5파일) | 국내 LLM provider 추상화 — 정식 코드 | **정리 대상 아님.** [2026-07-22 LLM 다원화] 결정의 구현체다 | — |
| `backend/app/services/cross_check.py` | 두 경로 대조 + 사용자 고지 — 정식 코드 | **정리 대상 아님** | — |
| `backend/app/services/artifacts.py` | 원응답 저장 위치·보관 상한 | `SAVE_IE_RAW`·`SAVE_OCR_RAW`를 둘 다 걷어내는 날 함께 삭제 | ⏳ |
| `backend/app/services/document_parse.py` | DP 호출 + 표 HTML → 텍스트. `LAYOUT_SOURCE=document_parse`일 때만 동작 | **DP를 안 쓰기로 확정되면** 삭제 + `report_builder._layout_text_for()`를 한 줄로 축소 | ⏳ |
| `backend/scripts/probe_document_parse.py` | DP 조사 CLI (실행 시 크레딧 소모) | **E-6**: 조사가 끝났으므로 삭제 후보. 단 DP 응답 구조가 바뀌면 다시 필요하다 | ⏳ |
| `backend/scripts/measure_ie_reproducibility.py` | IE 재현성 측정 CLI | **유지 쪽.** 모델·엔드포인트가 바뀔 때마다 다시 돌릴 가치가 있다 | ⏳ |
| `backend/scripts/compare_llm.py` | 국내 LLM 비교 하네스 (구조화·설명 2역할) | **유지 쪽.** A.X 키가 도착하면 그대로 다시 돌린다 | ⏳ |
| `backend/out/dp_*.json` · `out/llm_compare/` · `out/runs/` | DP 원응답 · LLM 비교 원본 · 회차별 IE/OCR 원응답. **전부 등기부 실명 포함** | `out/runs/`는 **코드가 최근 5회분만 유지**(artifacts.py). `dp_*`·`llm_compare/`는 **E-6 정리 스윕에서 수동 삭제** | ⏳ |
| `backend/scripts/check_market_price.py` | 실거래가 조회 검증 CLI(2026-07-29). 주소→법정동코드→조회→집계를 사람이 읽는 형태로 찍는다. **공공 API라 크레딧 소모 없음** | **시세 자동조회가 analyze에 배선된 뒤**: 개발 도구로 유지할지 결정(`run_rules.py`와 동일 취급). 기능을 도입하지 않기로 하면 `market_price.py`·`lawd_code.py`와 함께 삭제 | ⏳ |
| `backend/out/runs/<회차>/molit_*.json` | 실거래가 원응답 저장분(`market_price.SAVE_MOLIT_RAW`, `DEV_MODE_AUTH`에 묶임). 지번·면적·금액은 공개 정보라 개인정보는 아니지만 **어느 지번을 조회했는지**가 남는다 | `out/runs/`는 코드가 최근 5회분만 유지(artifacts.py). 저장 스위치는 **면적·지번 매칭이 여러 등기부로 확정되면 제거** | ⏳ |
| `frontend` 뷰어의 `kUnmarkedNoteMarkers` 문자열 매칭 | 서버 문구를 부분 문자열로 골라 화면에 그리는 임시 방식. **서버가 문구를 바꾸면 조용히 사라진다**(2026-07-28에 실제로 고지 3종이 탈락하고 있었다) | **`checkedNotes`에 분류 태그를 넣는 계약 변경이 승인되면** 이 목록을 통째로 삭제 (`docs/api-contract.md` §9.7에 부채로 명시) | ⏳ |
