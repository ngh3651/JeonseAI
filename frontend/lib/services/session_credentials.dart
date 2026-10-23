/// 지금 로그인 세션의 **열쇠** — 서버 요청에 싣는 값의 유일한 자리 (메모리, 2026-10-22 카카오 로그인).
///
/// - [token]: 서버가 준 세션 토큰. [ApiClient]가 모든 요청에 `Authorization: Bearer <토큰>`으로 싣는다.
/// - [customerKey]: 서버가 계정에서 만든 토스 `customerKey` — 결제 주인 키(`passOwnerKey`)가 로그인했을 때 쓴다.
///
/// 폰에 남기는 일은 [SessionStorage](flutter_secure_storage), 화면 상태는 `AppSession`이 맡는다.
/// 이 파일은 서비스 층(서버 통신)이 화면 상태를 모르고도 열쇠를 꺼내 쓰게 하는 **한 칸**이다.
library;

import 'package:flutter/foundation.dart';

class SessionCredentials {
  SessionCredentials._();

  static final SessionCredentials instance = SessionCredentials._();

  String? _token;
  String? _customerKey;

  String? get token => _token;
  String? get customerKey => _customerKey;
  bool get hasSession => _token != null;

  /// 서버가 세션을 거절했을 때(401 `invalid_token`) 부른다 — `AppSession`이 듣고 세션을 지운 뒤 로그인을 안내한다.
  void Function()? onRejected;

  void set({required String token, String? customerKey}) {
    _token = token.isEmpty ? null : token;
    _customerKey = (customerKey == null || customerKey.isEmpty)
        ? null
        : customerKey;
  }

  void clear() {
    _token = null;
    _customerKey = null;
  }

  /// [sentToken]으로 보낸 요청이 401(세션 만료·틀림)을 받았다.
  ///
  /// 그사이 새로 로그인해 열쇠가 바뀌었으면 **아무것도 하지 않는다** — 옛 요청의 401이 새 세션을 지우면 안 된다.
  void reject(String sentToken) {
    if (_token == null || _token != sentToken) return;
    clear();
    onRejected?.call();
  }

  @visibleForTesting
  void resetForTest() {
    clear();
    onRejected = null;
  }
}
