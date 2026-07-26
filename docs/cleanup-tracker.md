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
| `backend/out/` | `test_ocr_coords.py` 산출물(OCR 원본 JSON·마킹 이미지). **등기부 소유자 실명 포함** → `.gitignore` 처리(커밋 안 됨) | **E-6 정리 스윕**: 로컬 폴더 삭제. 기능 폐기 시에는 그 시점에 삭제 | ⏳ |

## 사용 규칙
- 새 임시/더미/스캐폴딩 파일을 만들면 **이 표에 한 줄 추가**한다(대상·무엇·삭제 시점).
- 해당 Phase에 도달하면 이 표를 근거로 **정리를 제안하고**, 정리하면 상태를 ✅로 바꾼다.
- 관련 원칙은 CLAUDE.md 4절(개발 방법론)에도 한 줄로 명시돼 있다.

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
