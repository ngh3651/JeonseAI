/// 카카오 로그인 경계 — 화면·세션은 이것만 안다 (2026-10-22, P2-1).
///
/// 진짜는 카카오 공식 Flutter SDK([KakaoSdkLoginGateway], kakao_sdk_login_gateway.dart — SDK를 부르는 **유일한 곳**),
/// 위젯 테스트는 가짜를 넣는다(카카오톡·브라우저를 테스트에서 띄울 수 없다).
///
/// 카카오에서 받는 것은 **액세스 토큰 하나**다. 앱은 그것을 서버(`POST /api/auth/kakao`)에 넘기고 버린다 —
/// 회원번호 확인은 서버가 카카오에 직접 묻는다. 이름·이메일·닉네임·프로필 사진은 묻지 않는다(사용자 정보 API를 안 부른다).
library;

/// 사용자가 카카오 로그인 화면을 닫았다(뒤로 가기·취소) — 오류가 아니라 취소다. 안내 없이 조용히 돌아간다.
class KakaoLoginCanceled implements Exception {
  const KakaoLoginCanceled();
}

/// 카카오 로그인이 실패했다(네트워크·설정 등). [message]는 화면에 보여 줄 쉬운 말.
class KakaoLoginFailed implements Exception {
  const KakaoLoginFailed(this.message);

  final String message;

  @override
  String toString() => 'KakaoLoginFailed: $message';
}

abstract class KakaoLoginGateway {
  /// 카카오톡이 있으면 카카오톡으로, 없으면 카카오계정(브라우저)으로 로그인하고 **액세스 토큰**을 돌려준다.
  /// 취소면 [KakaoLoginCanceled], 실패면 [KakaoLoginFailed].
  Future<String> login();

  /// 카카오 쪽 로그아웃(이 폰의 카카오 토큰 지우기). 실패해도 우리 로그아웃은 끝난다.
  Future<void> logout();

  /// 카카오 **연결 끊기**(회원 탈퇴 때). 실패하면 예외 — 화면이 사용자에게 알린다.
  Future<void> unlink();
}
