/// 앱 세션 상태 — 회원/비회원 구분 (IA.md §4).
///
/// 로그인은 로컬 목업이다 (decisions.md 2026-07-03 "이력은 기기 로컬 단일 저장").
/// 비회원 제한 규칙은 실서비스처럼 동작시키되, 인증 자체는 하지 않는다.
library;

import 'package:flutter/foundation.dart';

import '../app/config.dart';

class AppSession extends ChangeNotifier {
  /// 개발용 자동 로그인(config.devAutoLogin)이 켜져 있으면 "개발자" 회원으로 시작한다.
  /// 로그아웃하면 그 세션 동안은 비회원 흐름을 그대로 테스트할 수 있다.
  AppSession() {
    if (devAutoLogin) {
      _isGuest = false;
      _userName = '개발자';
    }
  }

  bool _isGuest = true;
  String? _userName;

  bool get isGuest => _isGuest;

  /// 회원이면 이름, 비회원이면 null
  String? get userName => _userName;

  /// 인사 문구용 표시 이름 (비회원은 이름 없음)
  String get greetingName => _userName ?? '';

  void signIn({required String name}) {
    _isGuest = false;
    _userName = name;
    notifyListeners();
  }

  void continueAsGuest() {
    _isGuest = true;
    _userName = null;
    notifyListeners();
  }

  void signOut() {
    _isGuest = true;
    _userName = null;
    notifyListeners();
  }
}
