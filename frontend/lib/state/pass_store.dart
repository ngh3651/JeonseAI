/// 이 기기의 **계약 지킴이 패스** — 화면이 "지킴이 패스" 표시를 붙일지 본다 (2026-10-22, P2-1).
///
/// - 패스가 없어도 **기능은 막지 않는다**(알림·재대조 그대로) — 표시만 붙인다. 시연에서 막히면 안 된다.
/// - 정답은 서버(`GET /api/me/pass`)다. 앱을 켤 때 한 번 묻고([refresh]), 결제가 끝나면 바로 넣는다([set]).
/// - 못 물으면(서버 꺼짐) 조용히 '없음'으로 둔다.
/// - 주인 키(누구의 패스인가)는 서버는 `get_pass_owner`, 앱은 [passOwnerKey] 한 곳에서만 정한다.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/pricing.dart';
import '../repositories/payment_repository.dart';
import '../services/device_id.dart';

class PassStore extends ChangeNotifier {
  PassStore._();

  static final PassStore instance = PassStore._();

  GuardianPass? _pass;

  /// 가장 최근 패스. 없으면 null.
  GuardianPass? get pass => _pass;

  bool get active => _pass != null;

  /// 서버에 묻는다. 실패해도 예외를 내지 않는다(지금 값 그대로).
  Future<void> refresh(PaymentRepository repository) async {
    try {
      final GuardianPass? latest = await repository.myPass();
      if (latest?.orderId == _pass?.orderId) return;
      _pass = latest;
      notifyListeners();
    } catch (e) {
      debugPrint('[패스] 패스가 있는지 확인하지 못했어요 (${e.runtimeType}) — 표시만 빠집니다');
    }
  }

  /// 결제 승인 직후 — 서버가 돌려준 패스를 바로 넣는다.
  void set(GuardianPass pass) {
    _pass = pass;
    notifyListeners();
  }

  /// 테스트용 — 앞 테스트의 패스를 물려받지 않게.
  @visibleForTesting
  void resetForTest() {
    _pass = null;
  }
}

/// 결제의 **주인 키** — 앱에서는 이 함수 **한 곳에서만** 정한다 (2026-10-22, P2-1).
///
/// 토스 결제위젯의 `customerKey`로 쓴다. 지금은 **기기 id**에서 만든다(서버 주인 키 `device:<기기 id>`와 같은 주인).
/// 기기 id를 그대로 넘기지 않고 SHA-256으로 바꿔 넘긴다 — 기기 id는 서버에서 내 기록을 여는 열쇠라
/// 결제사에도 보여 주지 않는다. 카카오 로그인이 붙으면 **여기만** 계정 키로 바꾼다.
Future<String> passOwnerKey() async =>
    passOwnerKeyFor(await DeviceId.instance.get());

/// 토스 `customerKey` 규칙: 2~50자, 영문·숫자·`-_=.@`. → `device_` + 해시 40자 = 47자.
@visibleForTesting
String passOwnerKeyFor(String deviceId) {
  final digest = sha256.convert(utf8.encode('jeonseai-pass:$deviceId'));
  return 'device_${digest.toString().substring(0, 40)}';
}
