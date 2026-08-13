/// 앱 전역 설정.
///
/// 이 프로젝트는 안드로이드 실기기 전용입니다. (웹/에뮬레이터 기준 아님)
/// USB로 연결된 상태에서 `adb reverse tcp:8000 tcp:8000` 을 실행하면
/// 폰의 127.0.0.1:8000 요청이 USB 터널을 통해 PC의 127.0.0.1:8000 으로 전달됩니다.
/// Wi-Fi 경로를 타지 않으므로 PC/폰이 서로 다른 네트워크에 있어도 동작합니다.
///
/// !! adb reverse는 USB 재연결/PC 재부팅 시마다 다시 실행해야 합니다.
const String baseUrl = 'http://127.0.0.1:8000'; // 실기기용 (adb reverse 사용)

/// 개발용 자동 로그인 (팀 테스트 편의).
///
/// true면 앱이 `AppSession`의 `kDemoUserName` 회원으로 시작해 분석 진입 게이트(로그인 유도 바텀시트)를
/// 매번 통과하지 않아도 된다. 게이트·로그인 화면 로직 자체는 그대로 살아 있어서
/// 이 값을 false로 바꾸면 비회원 흐름을 언제든 다시 확인할 수 있다.
/// 실 로그인 도입 시 제거 — docs/cleanup-tracker.md 등록.
const bool devAutoLogin = true;

/// 개발용 등기부 사진·리포트 로컬 보관 (팀 테스트 편의).
///
/// true면 분석에 **실제로 전송한 JPEG**와 리포트 JSON을 앱 영구 저장소에 복사해 둔다.
/// 앱을 껐다 켜도, 백엔드를 재시작해도 '내가 올린 사진에서 보기'가 계속 열린다 —
/// 테스트할 때마다 재분석하며 Upstage 크레딧을 태우지 않아도 된다.
///
/// false면 예전처럼 **메모리 전용**이다: 복사·SharedPreferences 기록·복원이 전부
/// 건너뛰어지고, 앱을 껐다 켜면 사진이 사라져 뷰어 진입점도 함께 사라진다.
/// 제출·배포 때는 이 한 줄만 false로 바꾼다.
///
/// ⚠ 등기부 사진에는 소유자 실명·주소가 들어 있다. 그래서 켜 두더라도 최근
/// [RegistryPhotoStore.keepRecentReports]건만 남기고 오래된 것은 지운다.
/// 실 배포 시 제거 — docs/cleanup-tracker.md 등록.
const bool devKeepRegistryPhotos = true;
