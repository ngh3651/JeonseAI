/// 카카오 공식 Flutter SDK(`kakao_flutter_sdk_user`)를 부르는 **유일한 곳** (2026-10-22, P2-1).
///
/// - 네이티브 앱 키는 빌드 때 넣는다(config.dart `kakaoNativeAppKey` — `--dart-define=KAKAO_NATIVE_APP_KEY`).
///   키가 없으면 화면이 카카오 버튼을 그리지 않으므로 여기까지 오지 않는다.
/// - 로그인 순서는 카카오 SDK 공식 예제(github.com/kakao/kakao_flutter_sdk — example `sdk_user_api.dart` '로그인 조합 예제')와 같다:
///   카카오톡이 있으면 카카오톡으로 → 사용자가 취소했으면(`PlatformException` `CANCELED`) 거기서 멈춤 →
///   그 밖의 실패(카카오톡에 로그인돼 있지 않음 등)면 카카오계정(브라우저)으로. 카카오톡이 없으면 바로 카카오계정으로.
/// - SDK 내부 로그는 끈다(`loggingEnabled: false` — 기본값). 회원번호를 찍는 로그가 있어서다.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart';

import '../app/config.dart';
import 'kakao_login_gateway.dart';

class KakaoSdkLoginGateway implements KakaoLoginGateway {
  KakaoSdkLoginGateway({String? nativeAppKey})
    : _nativeAppKey = nativeAppKey ?? kakaoNativeAppKey;

  final String _nativeAppKey;
  Future<void>? _initialized;

  static const String _failedMessage =
      '카카오 로그인을 하지 못했어요. 잠시 후 다시 시도해 주세요';

  /// SDK 초기화는 처음 쓸 때 한 번만. 실패하면 다음에 다시 시도한다.
  Future<void> _ensureInitialized() async {
    final pending = _initialized ??= KakaoSdk.init(
      nativeAppKey: _nativeAppKey,
      loggingEnabled: false,
    );
    try {
      await pending;
    } catch (_) {
      _initialized = null;
      rethrow;
    }
  }

  static bool _isCanceled(Object e) =>
      (e is PlatformException && e.code == 'CANCELED') ||
      (e is KakaoClientException && e.reason == ClientErrorCause.cancelled) ||
      (e is KakaoAuthException && e.error == AuthErrorCause.accessDenied);

  Future<OAuthToken> _loginToken() async {
    if (await isKakaoTalkInstalled()) {
      try {
        return await UserApi.instance.loginWithKakaoTalk();
      } catch (e) {
        if (_isCanceled(e)) rethrow;
        // 카카오톡에 연결된 카카오계정이 없는 경우 등 — 카카오계정(브라우저)으로 이어 간다.
        debugPrint('[카카오] 카카오톡 로그인 실패 (${e.runtimeType}) — 카카오계정으로 다시');
      }
    }
    return UserApi.instance.loginWithKakaoAccount();
  }

  @override
  Future<String> login() async {
    if (_nativeAppKey.isEmpty) {
      throw const KakaoLoginFailed('카카오 로그인이 아직 준비되지 않았어요');
    }
    try {
      await _ensureInitialized();
      final token = await _loginToken();
      return token.accessToken;
    } catch (e) {
      if (_isCanceled(e)) throw const KakaoLoginCanceled();
      // 오류 내용(토큰 등)은 찍지 않는다 — 종류만.
      debugPrint('[카카오] 로그인 실패 (${e.runtimeType})');
      throw const KakaoLoginFailed(_failedMessage);
    }
  }

  @override
  Future<void> logout() async {
    if (_nativeAppKey.isEmpty) return;
    await _ensureInitialized();
    await UserApi.instance.logout();
  }

  @override
  Future<void> unlink() async {
    if (_nativeAppKey.isEmpty) {
      throw const KakaoLoginFailed('카카오 로그인이 아직 준비되지 않았어요');
    }
    await _ensureInitialized();
    await UserApi.instance.unlink();
  }
}
