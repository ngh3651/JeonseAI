/// 앱 세션 상태 — 회원/비회원 구분 (IA.md §4).
///
/// 로그인은 로컬 목업이다 (decisions.md 2026-07-03 "이력은 기기 로컬 단일 저장").
/// 비회원 제한 규칙은 실서비스처럼 동작시키되, 인증 자체는 하지 않는다.
library;

import 'package:flutter/foundation.dart';

class AppSession extends ChangeNotifier {
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
