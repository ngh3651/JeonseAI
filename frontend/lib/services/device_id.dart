/// 이 폰의 **기기 id** — 서버가 "누구의 기록인가"를 가르는 이름표 (api-contract §1.1-1).
///
/// 서버는 리포트·대조 기준을 이 id의 것으로 저장하고, 같은 id로 물어볼 때만 보여 준다.
/// 그래서 다른 폰에서는 내 기록이 안 보인다(NOW.md P0-1 완료 조건).
///
/// - 처음 실행할 때 **UUID v4를 한 번만** 만들어 SharedPreferences(`device_id_v1`)에 넣고,
///   그 뒤로는 늘 같은 값을 쓴다. 앱을 지우면 새 id가 생긴다(= 예전 기록과 끊긴다).
/// - 새 패키지 없이 `Random.secure()`로 만든다 — 추측할 수 없어야 남의 기록을 못 연다.
/// - 저장소가 없는 환경(위젯 테스트 등)에서는 **이번 실행 동안만 쓰는 id**를 만든다.
///   어떤 경우에도 헤더는 실린다.
///
/// ⚠ 개인정보가 아니다 — 무작위 값이라 사람·폰 모델과 연결되지 않는다. 그래도 화면에는 띄우지 않는다.
library;

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// UUID v4 (RFC 4122) 문자열 — `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` (36자, 소문자).
///
/// [random]은 테스트에서만 넘긴다(기본은 암호학적으로 안전한 `Random.secure()`).
String generateUuidV4([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // 버전 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // 변형: RFC 4122
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// 서버가 받아 주는 형식 — `[A-Za-z0-9-]{8,64}`, 그리고 옛 앱 공용 통로 이름(`legacy-device`)은 안 된다.
/// 저장본이 이 형식이 아니면(깨졌거나 손으로 바꿨으면) 새로 만든다 — 그대로 보내면 400이다.
bool isValidDeviceId(String? value) =>
    value != null &&
    value != 'legacy-device' &&
    RegExp(r'^[A-Za-z0-9-]{8,64}$').hasMatch(value);

class DeviceId {
  DeviceId._();

  static final DeviceId instance = DeviceId._();

  /// SharedPreferences 키. 이름을 바꾸면 모든 폰이 새 id를 받아 **예전 기록을 잃는다.**
  static const String prefsKey = 'device_id_v1';

  /// 저장소를 기다리는 상한. 실기기에서는 수십 ms면 끝나므로 넉넉하게 잡는다 —
  /// 목적은 하나다: 저장소가 끝내 답하지 않아도 **서버 요청이 영영 멈추지 않게.**
  /// (위젯 테스트처럼 플러그인이 없는 환경에서는 답이 오지 않는다)
  static const Duration _prefsTimeout = Duration(seconds: 5);

  Future<String>? _pending;

  /// 이 기기의 id. 여러 요청이 동시에 물어도 **한 번만** 만들고 저장한다.
  /// 저장소를 못 쓰면 이번 실행 동안만 쓰는 id를 만들어 **이번 실행 내내 같은 값**을 쓴다
  /// (요청마다 다른 id를 보내면 방금 만든 리포트를 바로 다음 요청이 404로 못 연다).
  Future<String> get() => _pending ??= _load();

  Future<String> _load() async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance().timeout(_prefsTimeout);
    } catch (e) {
      debugPrint(
        '[기기id] 저장소를 열지 못했어요 (${e.runtimeType}) — 이번 실행 동안만 쓰는 id로 보냅니다',
      );
      return generateUuidV4();
    }
    try {
      final saved = prefs.getString(prefsKey);
      if (isValidDeviceId(saved)) return saved!;
    } catch (e) {
      // 같은 키에 문자열이 아닌 값이 들어 있으면 getString이 던진다 — 새로 만들어 덮어쓴다.
      debugPrint('[기기id] 저장된 id를 읽지 못했어요 (${e.runtimeType}) — 새로 만듭니다');
    }
    final fresh = generateUuidV4();
    try {
      await prefs.setString(prefsKey, fresh).timeout(_prefsTimeout);
    } catch (e) {
      debugPrint(
        '[기기id] 새 id를 저장하지 못했어요 (${e.runtimeType}) — 이번 실행 동안만 이 id를 씁니다',
      );
    }
    return fresh;
  }

  /// 테스트가 앞 테스트의 id를 물려받지 않게 비운다 (싱글턴이라 상태가 남는다).
  @visibleForTesting
  void resetForTest() => _pending = null;
}
