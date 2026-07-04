# 전세AI프 — Flutter 앱 (frontend)

전세AI프의 안드로이드 앱입니다. 등기부등본을 분석해 전세사기·깡통전세 위험을 쉬운 말로
설명해 줍니다. 프로젝트 전체 개요·실행 방법은 루트 [README.md](../README.md)를 참고하세요.

## 구조 (lib/)

- `app/` — `config.dart`(baseUrl), `router.dart`(go_router)
- `design_system/` — 토큰(색·타이포·간격)·테마·공용 컴포넌트·컴포넌트 갤러리
- `models/` — 데이터 모델 (더미 구조 = 향후 API 계약과 동일 형태)
- `repositories/` — 저장소 인터페이스 (`DummyRepository ↔ ApiRepository` 교체 지점)
- `services/` — 검증된 등기부 업로드 서비스 등
- `state/` — 세션(회원/비회원) 등 앱 상태 (Provider)
- `screens/` — 화면 (온보딩·시작·홈·매물검색·리포트·판례·시뮬레이터·질문·여정·챗봇·마이)
- `utils/` — 금액·날짜 포맷 등

## 실행

```bash
flutter pub get
adb reverse tcp:8000 tcp:8000   # 실기기 USB 연결 후, 서버 통신이 필요할 때
flutter run
```

- 화면은 **Repository 인터페이스에만 의존**합니다. 현재는 `DummyRepository`로 더미 데이터를
  쓰고, Phase D~E에서 `ApiRepository`로 구현만 교체합니다.
- 디자인은 **디자인 시스템 토큰·컴포넌트만 재사용**합니다 (개별 화면에 색·크기 하드코딩 금지).
