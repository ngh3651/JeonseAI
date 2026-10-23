/// 로그인 서버 저장소 (계약 §3.15~§3.18 — 2026-10-22, P2-1 카카오 로그인).
///
/// 화면·세션은 이 인터페이스에만 의존한다. 실제 주입은 [ApiAuthRepository](서버), 위젯 테스트는 가짜.
/// 카카오 SDK 자체는 여기 없다 — services/kakao_login_gateway.dart.
library;

import '../services/api_client.dart';
import '../services/session_storage.dart';

/// `GET /api/me` — 지금 로그인 상태.
class MeStatus {
  const MeStatus({
    required this.loggedIn,
    this.provider,
    this.customerKey,
    this.displayName,
  });

  factory MeStatus.fromJson(Map<String, dynamic> json) => MeStatus(
    loggedIn: json['loggedIn'] == true,
    provider: json['provider'] as String?,
    customerKey: json['customerKey'] as String?,
    displayName: json['displayName'] as String?,
  );

  final bool loggedIn;
  final String? provider;
  final String? customerKey;

  /// 사용자가 앱에서 정한 이름(2026-10-24) — 홈 인사말 "○○님 안녕하세요". 없으면 null.
  final String? displayName;
}

abstract class AuthRepository {
  /// 카카오 액세스 토큰 → 서버 세션. 서버가 카카오에 물어 **우리 앱의 토큰인지** 확인하고,
  /// 이 기기(`X-Device-Id`)의 기록을 계정으로 옮긴다.
  Future<SavedSession> loginWithKakao(String kakaoAccessToken);

  /// 지금 세션이 살아 있는가. 세션이 끝났으면 서버가 401 → [ApiClient]가 세션을 지운다.
  Future<MeStatus> me();

  /// 그 세션만 끝낸다. [sessionToken]은 앱이 **먼저 지운** 세션(화면은 바로 로그아웃 상태가 된다).
  Future<void> logout(String sessionToken);

  /// 회원 탈퇴 — 그 계정의 기록·세션·패스를 서버에서 전부 지운다(되돌릴 수 없다).
  Future<void> deleteAccount();

  /// 표시 이름 정하기(빈 값이면 지우기) → 바뀐 상태 (계약 `POST /api/me/name`, 2026-10-24).
  Future<MeStatus> setDisplayName(String name);
}

class ApiAuthRepository implements AuthRepository {
  ApiAuthRepository({ApiClient? client}) : _api = client ?? ApiClient();

  final ApiClient _api;

  /// 서버가 카카오에 한 번 묻는다(최대 10초) — 앱은 조금 더 기다린다.
  static const Duration _loginTimeout = Duration(seconds: 20);

  @override
  Future<SavedSession> loginWithKakao(String kakaoAccessToken) async {
    final body = await _api.postJson('/api/auth/kakao', {
      'accessToken': kakaoAccessToken,
    }, timeout: _loginTimeout);
    final session = SavedSession.fromJson(body);
    if (session == null) {
      throw const ApiException('로그인 응답이 이상해요. 잠시 후 다시 시도해 주세요');
    }
    return session;
  }

  @override
  Future<MeStatus> me() async =>
      MeStatus.fromJson(await _api.getJson('/api/me') as Map<String, dynamic>);

  @override
  Future<void> logout(String sessionToken) async {
    await _api.postJson(
      '/api/auth/logout',
      const {},
      extraHeaders: {'Authorization': 'Bearer $sessionToken'},
    );
  }

  @override
  Future<void> deleteAccount() => _api.delete('/api/me');

  @override
  Future<MeStatus> setDisplayName(String name) async => MeStatus.fromJson(
    await _api.postJson('/api/me/name', {'displayName': name}) as Map<String, dynamic>,
  );
}
