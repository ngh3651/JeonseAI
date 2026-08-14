/// 앱 세션 상태 — 회원/비회원 구분 (IA.md §4).
///
/// 로그인은 로컬 목업이다 (decisions.md 2026-07-03 "이력은 기기 로컬 단일 저장").
/// 비회원 제한 규칙은 실서비스처럼 동작시키되, 인증 자체는 하지 않는다.
library;

import 'package:flutter/foundation.dart';

import '../app/config.dart';

/// 목업 로그인이 쓰는 **표시 이름** — 화면 인사말(`○○님`)에 그대로 나간다.
///
/// [2026-08-14 D11] 예전에는 자리마다 달랐다 — 자동 로그인은 '개발자', 로그인 화면
/// 기본값은 '지수'. 어느 경로로 들어왔느냐에 따라 홈 인사말이 바뀌어, 시연 영상에서
/// 같은 앱이 두 사람으로 보였다. 한 곳으로 모으고 팀 대표 이름 '영호'로 통일한다.
///
/// ⚠ 로그인 **기능**은 손대지 않았다(목업 그대로). 이 상수는 표시 이름일 뿐이다.
/// ⚠ 코드·문서 곳곳의 '지수'는 페르소나 리뷰어 **김지수**(docs/personas.md)라 그대로 둔다.
const String kDemoUserName = '영호';

class AppSession extends ChangeNotifier {
  /// 개발용 자동 로그인(config.devAutoLogin)이 켜져 있으면 [kDemoUserName] 회원으로 시작한다.
  /// 로그아웃하면 그 세션 동안은 비회원 흐름을 그대로 테스트할 수 있다.
  AppSession() {
    if (devAutoLogin) {
      _isGuest = false;
      _userName = kDemoUserName;
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
