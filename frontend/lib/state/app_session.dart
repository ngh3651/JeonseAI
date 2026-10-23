/// 앱 세션 상태 — **카카오 로그인** 또는 **로그인 없이 둘러보기** (2026-10-22, P2-1).
///
/// 예전에는 로컬 목업이었다(아무 값이나 통과, 자동 로그인 '영호'). 이제:
/// - 로그인 = 카카오 SDK가 준 토큰을 서버(`POST /api/auth/kakao`)가 확인하고 **세션**을 준다 →
///   폰의 보안 저장소에 남기고([SessionStorage]) 모든 요청에 `Authorization: Bearer`([SessionCredentials]).
///   로그인하는 순간 이 기기의 기록·패스가 계정으로 옮겨진다(서버).
/// - 둘러보기 = 지금까지처럼 기기 id만 — 부스에서 카카오가 막혀도 분석은 된다.
/// - 카카오에서는 **회원번호만** 받는다(서버가 확인). 이름을 모르므로 인사말에 이름을 쓰지 않는다.
/// - 키가 없는 빌드(`--dart-define=KAKAO_NATIVE_APP_KEY` 없음)는 [kakaoAvailable]이 false — 화면이 카카오 버튼을 그리지 않는다.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app/config.dart';
import '../repositories/auth_repository.dart';
import '../services/api_client.dart';
import '../services/kakao_login_gateway.dart';
import '../services/kakao_sdk_login_gateway.dart';
import '../services/session_credentials.dart';
import '../services/session_storage.dart';

/// 카카오 로그인 한 번의 결과.
enum LoginResult { success, canceled, failed, unavailable }

class LoginOutcome {
  const LoginOutcome(this.result, [this.message]);

  final LoginResult result;

  /// 실패일 때 화면에 보여 줄 쉬운 말.
  final String? message;

  bool get ok => result == LoginResult.success;
}

/// 회원 탈퇴 결과 — 서버 기록을 지웠는가, 카카오 연결도 끊었는가.
class WithdrawOutcome {
  const WithdrawOutcome({
    required this.deleted,
    this.kakaoUnlinked = false,
    this.message,
  });

  /// 서버의 기록·세션·패스를 지웠다.
  final bool deleted;

  /// 카카오 연결 끊기까지 됐다(실패해도 서버 기록은 이미 지워졌다).
  final bool kakaoUnlinked;

  /// 못 지웠을 때 화면에 보여 줄 쉬운 말.
  final String? message;
}

class AppSession extends ChangeNotifier {
  /// 테스트는 가짜를 넣는다. 아무것도 안 넣으면 진짜(보안 저장소·카카오 SDK·서버).
  AppSession({
    SessionStorage? storage,
    KakaoLoginGateway? kakao,
    AuthRepository? auth,
    bool? kakaoEnabled,
    SessionCredentials? credentials,
    this.onAccountChanged,
  }) : _storage = storage ?? SecureSessionStorage(),
       _kakao = kakao ?? KakaoSdkLoginGateway(),
       _auth = auth ?? ApiAuthRepository(),
       _kakaoEnabled = kakaoEnabled ?? kakaoLoginAvailable,
       _credentials = credentials ?? SessionCredentials.instance {
    _credentials.onRejected = _onSessionRejected;
  }

  /// 앱 전체가 함께 쓰는 세션(main.dart가 켤 때 [restore]한다).
  static final AppSession instance = AppSession();

  final SessionStorage _storage;
  final KakaoLoginGateway _kakao;
  final AuthRepository _auth;
  final bool _kakaoEnabled;
  final SessionCredentials _credentials;

  /// 로그인·로그아웃·탈퇴로 **주인**이 바뀐 뒤 — 패스 표시 등을 다시 묻는다(main.dart가 넣는다).
  Future<void> Function()? onAccountChanged;

  /// 세션이 서버에서 끝났을 때(401) — 화면에 "다시 로그인해 주세요"를 띄운다(main.dart가 넣는다).
  void Function()? onSessionExpired;

  SavedSession? _session;
  bool _busy = false;
  String? _displayName;

  /// 사용자가 정한 이름(로그인했을 때만) — 홈 인사말 "○○님 안녕하세요" (2026-10-24).
  String? get displayName => _session == null ? null : _displayName;

  bool get isLoggedIn => _session != null;

  /// 로그인하지 않았다(= 로그인 없이 둘러보기, 기기 id).
  bool get isGuest => _session == null;

  /// 이 빌드에 카카오 키가 있는가 — 없으면 카카오 버튼을 그리지 않는다.
  bool get kakaoAvailable => _kakaoEnabled;

  /// 로그인·탈퇴가 진행 중이다(버튼을 잠근다).
  bool get busy => _busy;

  void _apply(SavedSession? session) {
    _session = session;
    if (session == null) {
      _credentials.clear();
    } else {
      _credentials.set(token: session.token, customerKey: session.customerKey);
    }
  }

  /// 앱을 켤 때 — 폰에 남긴 세션을 올린다. 만료 시각이 지났으면 지운다(서버도 401을 줄 것이므로).
  Future<void> restore({DateTime? now}) async {
    final saved = await _storage.read();
    if (saved == null) return;
    if (saved.isExpiredAt((now ?? DateTime.now()).toUtc())) {
      await _storage.clear();
      return;
    }
    _apply(saved);
    notifyListeners();
  }

  /// 서버에 지금 세션이 살아 있는지 한 번 묻는다(앱 시작 뒤). 끝났으면 401 → [ApiClient]가 지우고 알린다.
  /// 네트워크가 없으면 그대로 둔다(다음 요청에서 알게 된다).
  Future<void> verify() async {
    if (_session == null) return;
    try {
      final me = await _auth.me();
      if (!me.loggedIn) {
        await _clearLocal();
      } else if (me.displayName != _displayName) {
        _displayName = me.displayName;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[로그인] 세션을 확인하지 못했어요 (${e.runtimeType}) — 그대로 둡니다');
    }
  }

  /// 카카오로 로그인 → 서버 세션 → 폰에 남김.
  Future<LoginOutcome> signInWithKakao() async {
    if (!_kakaoEnabled) {
      return const LoginOutcome(
        LoginResult.unavailable,
        '카카오 로그인이 아직 준비되지 않았어요',
      );
    }
    if (_busy) return const LoginOutcome(LoginResult.canceled);
    _busy = true;
    notifyListeners();
    LoginOutcome outcome;
    try {
      final kakaoToken = await _kakao.login();
      final session = await _auth.loginWithKakao(kakaoToken);
      await _storage.write(session);
      _apply(session);
      outcome = const LoginOutcome(LoginResult.success);
    } on KakaoLoginCanceled {
      outcome = const LoginOutcome(LoginResult.canceled);
    } on KakaoLoginFailed catch (e) {
      outcome = LoginOutcome(LoginResult.failed, e.message);
    } on ApiException catch (e) {
      outcome = LoginOutcome(LoginResult.failed, e.message);
    } catch (e) {
      debugPrint('[로그인] 실패 (${e.runtimeType})');
      outcome = const LoginOutcome(
        LoginResult.failed,
        '로그인하지 못했어요. 잠시 후 다시 시도해 주세요',
      );
    }
    _busy = false;
    notifyListeners();
    if (outcome.ok) {
      await verify(); // 이 계정에 정해 둔 이름을 받아 온다
      await _accountChanged();
    }
    return outcome;
  }

  /// 표시 이름 정하기 → 실패하면 사용자에게 보일 한 줄, 성공하면 null.
  Future<String?> setDisplayName(String name) async {
    if (_session == null) return '로그인한 뒤에 이름을 정할 수 있어요';
    try {
      final me = await _auth.setDisplayName(name);
      _displayName = me.displayName;
      notifyListeners();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      return '이름을 저장하지 못했어요. 잠시 후 다시 시도해 주세요';
    }
  }

  /// 로그인 없이 둘러보기 — 기기 id로 쓴다(세션이 있었다면 그대로 둔다: 화면에서 고른 것뿐).
  void continueAsGuest() {}

  /// 로그아웃 — 이 폰의 세션을 **먼저** 지우고(화면은 바로 둘러보기), 서버·카카오에는 뒤에서 알린다.
  Future<void> signOut() async {
    final token = _session?.token;
    await _clearLocal();
    if (token != null) {
      try {
        await _auth.logout(token);
      } catch (e) {
        debugPrint('[로그인] 서버 로그아웃을 알리지 못했어요 (${e.runtimeType}) — 세션은 만료되면 끝납니다');
      }
    }
    try {
      await _kakao.logout();
    } catch (e) {
      debugPrint('[로그인] 카카오 로그아웃 실패 (${e.runtimeType})');
    }
    await _accountChanged();
  }

  /// 회원 탈퇴 — 서버의 기록·세션·패스를 **먼저** 지우고, 그다음 카카오 연결을 끊는다.
  ///
  /// 순서가 중요하다: 서버 삭제가 실패하면 아무것도 끊지 않는다(다시 시도할 수 있게).
  /// 카카오 끊기만 실패하면 서버 기록은 이미 없다 — 화면이 "카카오 연결은 카카오 설정에서 끊을 수 있어요"를 알린다.
  Future<WithdrawOutcome> deleteAccount() async {
    if (_session == null) {
      return const WithdrawOutcome(
        deleted: false,
        message: '로그인한 뒤에 탈퇴할 수 있어요',
      );
    }
    if (_busy) return const WithdrawOutcome(deleted: false);
    _busy = true;
    notifyListeners();
    try {
      await _auth.deleteAccount();
    } on ApiException catch (e) {
      _busy = false;
      notifyListeners();
      return WithdrawOutcome(deleted: false, message: e.message);
    } catch (_) {
      _busy = false;
      notifyListeners();
      return const WithdrawOutcome(
        deleted: false,
        message: '탈퇴하지 못했어요. 잠시 후 다시 시도해 주세요',
      );
    }
    var unlinked = false;
    try {
      await _kakao.unlink();
      unlinked = true;
    } catch (e) {
      debugPrint('[탈퇴] 카카오 연결 끊기 실패 (${e.runtimeType}) — 서버 기록은 이미 지웠어요');
    }
    _busy = false;
    await _clearLocal();
    await _accountChanged();
    return WithdrawOutcome(deleted: true, kakaoUnlinked: unlinked);
  }

  Future<void> _clearLocal() async {
    _apply(null);
    _displayName = null;
    notifyListeners();
    await _storage.clear();
  }

  /// 서버가 세션을 거절했다(401) — [SessionCredentials]는 이미 비었다. 폰 저장본을 지우고 알린다.
  void _onSessionRejected() {
    if (_session == null) return;
    _session = null;
    notifyListeners();
    unawaited(_storage.clear());
    onSessionExpired?.call();
    unawaited(_accountChanged());
  }

  Future<void> _accountChanged() async {
    final callback = onAccountChanged;
    if (callback == null) return;
    try {
      await callback();
    } catch (e) {
      debugPrint('[로그인] 계정이 바뀐 뒤 정리 실패 (${e.runtimeType})');
    }
  }

  @override
  void dispose() {
    // 버려진 세션이 401 알림을 받지 않게(테스트가 화면마다 새로 만든다).
    if (_credentials.onRejected == _onSessionRejected) {
      _credentials.onRejected = null;
    }
    super.dispose();
  }
}
