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
| `frontend/lib/repositories/`의 `DummyAnalysisRepository`·`DummyContentRepository` | 로컬 더미 리포지토리 구현 | **D-3~E**: `ApiRepository`로 구현 교체 후 더미는 삭제(또는 오프라인/테스트용으로만 격리) | ⏳ |
| `frontend/lib/design_system/gallery/component_gallery_screen.dart` (`/gallery` 라우트) | 디자인 시스템 카탈로그(개발·팀 공유용, 제품 진입점 없음) | **출시/시연 정리 시(Phase F)**: 내부용으로 유지할지 제거할지 결정 | ⏳ |
| `backend/app/main.py`의 `app.router.routes.extend(...)` 우회 | fastapi 0.139+starlette 1.3.1에서 `include_router`가 깨져 쓴 임시 우회 | **라이브러리 버전 정리 시**: 정상 버전에서 `app.include_router(...)`로 되돌림 | ⏳ |
| 스크래치패드 검증 스크립트(예: `d2_verify.py`) | API 수동 검증용 임시 스크립트 | 즉시성 산출물 — 스크래치패드에 두고 저장소에 커밋하지 않음(추적 대상 아님) | — |

## 사용 규칙
- 새 임시/더미/스캐폴딩 파일을 만들면 **이 표에 한 줄 추가**한다(대상·무엇·삭제 시점).
- 해당 Phase에 도달하면 이 표를 근거로 **정리를 제안하고**, 정리하면 상태를 ✅로 바꾼다.
- 관련 원칙은 CLAUDE.md 4절(개발 방법론)에도 한 줄로 명시돼 있다.
