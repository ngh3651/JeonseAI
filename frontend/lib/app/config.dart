/// 앱 전역 설정.
///
/// 이 프로젝트는 안드로이드 실기기 전용입니다. (웹/에뮬레이터 기준 아님)
///
/// ── 서버 주소·앱 키는 **빌드할 때** 넣는다 (2026-10-22, 앱 1단계) ──────────────
/// 코드에 주소를 박아 두면 배포 주소가 바뀔 때마다 코드를 고쳐야 하고, 키를 커밋하게 된다.
/// 그래서 `--dart-define`으로 받는다:
/// ```
/// flutter build apk --release \
///   --dart-define=API_BASE_URL=https://<Railway 주소> \
///   --dart-define=APP_KEY=<서버의 APP_KEY와 같은 값>
/// ```
/// - 아무것도 안 넣으면(그냥 `flutter run`) 예전과 같다: `http://127.0.0.1:8000`.
///   USB로 연결한 뒤 `adb reverse tcp:8000 tcp:8000` 을 실행하면 폰의 127.0.0.1:8000 요청이
///   USB 터널을 통해 PC의 서버로 간다. (USB 재연결/PC 재부팅 시마다 다시 실행)
/// - CI(`.github/workflows/ci.yml`의 'APK 빌드')는 저장소 변수 `API_BASE_URL`과
///   비밀값 `APP_KEY`를 넣어 APK를 만든다.
library;

/// 빌드 때 받은 서버 주소. 안 넣었으면 기본값(로컬 + adb reverse).
const String _definedBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8000',
);

/// 서버 주소.
///
/// ⚠ `--dart-define=API_BASE_URL=` 처럼 **빈 값**이 들어오면 `defaultValue`가 쓰이지 않고
///   빈 문자열이 된다(CI에서 저장소 변수가 아직 없을 때 실제로 이렇게 된다).
///   빈 주소로는 어떤 요청도 못 보내므로 기본값으로 되돌린다.
const String baseUrl = _definedBaseUrl == ''
    ? 'http://127.0.0.1:8000'
    : _definedBaseUrl;

/// 요청 주소를 조립할 때 쓰는 서버 주소 — 끝의 `/`를 뗀다.
///
/// 변수에 `https://x.up.railway.app/` 처럼 끝에 `/`를 붙여 넣어도 `…app//api/…`가 되지 않게.
String get apiBaseUrl =>
    baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

/// 앱 키 — 서버에 `APP_KEY`가 설정돼 있으면 모든 `/api/*` 요청에 `X-App-Key`로 실어야 한다
/// (없거나 틀리면 401 — api-contract §1.1-1). 비어 있으면 헤더를 보내지 않는다.
///
/// ⚠ 앱에 들어가는 값이라 완벽한 비밀은 아니다(APK를 풀면 보인다). 주소만 알고 두드리는
///   사람을 막는 **정문**이다. 화면·로그에 절대 찍지 않는다.
const String appKey = String.fromEnvironment('APP_KEY');

/// 토스페이먼츠 개발자 문서에 **공개된 테스트용** 결제위젯 클라이언트 키 (2026-10-22, P2-1).
/// 이 키로 하는 결제는 실제로 청구되지 않는다. 문서 공개 값이라 비밀이 아니다.
const String kTossDocsTestClientKey = 'test_gck_docs_Ovk5rk1EwkEbP0W43n07xlzm';

/// 빌드 때 받은 토스 클라이언트 키 — `--dart-define=TOSS_CLIENT_KEY=test_gck_…`. 안 넣으면 문서 공개 테스트 키.
const String _definedTossClientKey = String.fromEnvironment(
  'TOSS_CLIENT_KEY',
  defaultValue: kTossDocsTestClientKey,
);

/// 토스 결제위젯 클라이언트 키. 빈 값(`--dart-define=TOSS_CLIENT_KEY=`)이면 문서 공개 테스트 키로 되돌린다.
const String tossClientKey = _definedTossClientKey == ''
    ? kTossDocsTestClientKey
    : _definedTossClientKey;

/// 테스트 키인가 — `test_`로 시작해야 한다. 아니면(실제 키 `live_…`) 결제 화면이 결제를 열지 않는다.
/// 결선은 테스트 결제만 한다(서버도 실제 키를 거부한다).
bool isTossTestKey(String key) => key.startsWith('test_');

/// 카카오 **네이티브 앱 키** — 빌드 때 `--dart-define=KAKAO_NATIVE_APP_KEY=…`로 넣는다 (2026-10-22, P2-1 카카오 로그인).
///
/// 카카오 개발자 콘솔 → 내 애플리케이션 → 앱 키의 '네이티브 앱 키'. APK 안에 들어가는 **공개 값**이다
/// (CI는 저장소 **변수** `KAKAO_NATIVE_APP_KEY`에서 넣는다). 안드로이드 쪽 리다이렉트 스킴(`kakao{키}`)도
/// 같은 값으로 `android/app/build.gradle.kts`가 채운다.
/// ⚠ 안 넣으면 카카오 버튼을 **아예 그리지 않는다**(가짜 버튼 금지) — '로그인 없이 둘러보기'만 남는다.
const String _definedKakaoNativeAppKey = String.fromEnvironment(
  'KAKAO_NATIVE_APP_KEY',
);

/// 앞뒤 공백을 걷어 낸 키. 영문·숫자가 아니면(붙여넣기 실수) 없는 것으로 본다 — Gradle도 같은 규칙이다.
String get kakaoNativeAppKey {
  final key = _definedKakaoNativeAppKey.trim();
  return RegExp(r'^[0-9A-Za-z]{8,64}$').hasMatch(key) ? key : '';
}

/// 카카오 로그인을 보여 줄 수 있는가 — 빌드 때 앱 키를 넣었을 때만.
bool get kakaoLoginAvailable => kakaoNativeAppKey.isNotEmpty;

/// 개인정보 처리방침 화면의 **서버 지역** (예: `싱가포르`) — Railway 배포 때 정해진다.
/// 비어 있으면 그 줄을 빼고 보여 준다(지어내지 않는다). 사람 할 일: NOW.md "Railway 지역 확인 후 상수 채우기".
const String kServerRegion = '';

/// 개인정보 처리방침 화면의 **문의처** (예: 팀 이메일) — 팀이 정하면 채운다. 비어 있으면 그 줄을 뺀다.
const String kPrivacyContact = '';

/// **폰 원본 보관** — "폰엔 원본, 서버엔 가린 사본" (2026-10-22 규혁 결정).
///
/// true(기본)면 분석에 **실제로 전송한 JPEG**와 **원본 리포트**(실명이 보이는 분석 응답 JSON)를
/// 이 폰의 앱 저장소에 최근 [RegistryPhotoStore.keepRecentReports]건 남긴다. 서버 기록에는 이름을 가린 사본만
/// 있으므로, 리포트를 다시 열 때(기록 목록·같은 사진 캐시 포함) **이 폰의 원본을 먼저** 쓴다 — 그래야 실제 만난
/// 계약자와 이름을 맞춰 볼 수 있다. 기록을 지우면 폰 사본도 함께 지운다. 오래된 것부터 자동으로 지운다.
///
/// false면 **아무것도 남기지 않는다**(메모리 전용): 앱을 껐다 켜면 사진이 사라져 '내가 올린 사진에서 보기'도 사라지고,
/// 리포트는 서버의 가린 사본(`홍○○`)으로 보인다. 켰다가 끄면 다음 실행 때 남겨 둔 것까지 지운다.
///
/// 사진은 **서버에 저장하지 않는다** — 화면 문구는 `RegistryPhotoStore.retentionNotice` 한 곳에서
/// 이 값에 맞춰 만든다(문구와 동작이 어긋나지 않게).
const bool keepOriginalsOnPhone = true;
