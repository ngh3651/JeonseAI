/// **부스 모드** (2026-10-23, 결선 부스 다듬기 — 지수 운영 메모).
///
/// 왜 필요한가: 킨텍스 부스에서는 심사위원·관람객이 시연 폰을 직접 만진다. 누가 마이 화면의 [회원 탈퇴]를
/// 누르면 그 계정의 시연 기록이 서버에서 **전부 지워지고**, [로그아웃]·기록 삭제도 다음 시연을 망친다.
/// 그래서 부스 폰에서만 그 세 버튼을 숨긴다. 그 밖의 동작(분석·대조·공유·이름 가리기 …)은 그대로다.
///
/// - 켜고 끄는 법: 마이 화면 맨 아래 **앱 버전 줄을 7번 연속** 누른다(안드로이드 '개발자 옵션'과 같은 방식 —
///   관람객이 우연히 켜거나 끄기 어렵다). 바뀌면 토스트로 알린다.
/// - 이 폰의 SharedPreferences(`booth_mode_v1`)에만 저장한다. 서버는 모른다.
/// - 화면은 이 싱글턴을 직접 듣는다(`ListenableBuilder`) — 위젯 테스트가 Provider 없이 돌게.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BoothMode extends ChangeNotifier {
  BoothMode._();

  static final BoothMode instance = BoothMode._();

  /// SharedPreferences 키 — 이름을 바꾸면 모든 폰의 부스 모드가 꺼진다.
  static const String prefsKey = 'booth_mode_v1';

  /// 몇 번 연속으로 눌러야 켜지고 꺼지나.
  static const int tapsToToggle = 7;

  /// '연속'으로 치는 간격 — 이보다 오래 쉬면 처음부터 다시 센다.
  static const Duration tapWindow = Duration(seconds: 2);

  bool _on = false;
  int _taps = 0;
  DateTime? _lastTap;

  /// 부스 모드인가 — 켜져 있으면 로그아웃·회원 탈퇴·기록 지우기를 숨긴다.
  bool get on => _on;

  /// 앱 시작 시 1회.
  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(const Duration(seconds: 5));
      final saved = prefs.getBool(prefsKey) ?? false;
      if (saved != _on) {
        _on = saved;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[부스 모드] 저장본을 읽지 못했어요 (${e.runtimeType}) — 꺼진 채로 시작합니다');
    }
  }

  /// 버전 줄을 한 번 눌렀다. [tapsToToggle]번째 연속 탭이면 켜고 끈 뒤 새 값을, 아니면 null을 돌려준다.
  Future<bool?> registerTap({DateTime? now}) async {
    final DateTime t = now ?? DateTime.now();
    final last = _lastTap;
    _taps = (last != null && t.difference(last) <= tapWindow) ? _taps + 1 : 1;
    _lastTap = t;
    if (_taps < tapsToToggle) return null;
    _taps = 0;
    _lastTap = null;
    await setOn(!_on);
    return _on;
  }

  /// 화면은 바로 바뀌고, 저장은 뒤따른다(실패해도 이번 실행 동안은 유지).
  Future<void> setOn(bool value) async {
    if (value == _on) return;
    _on = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance().timeout(const Duration(seconds: 5));
      await prefs.setBool(prefsKey, value);
    } catch (e) {
      debugPrint('[부스 모드] 저장하지 못했어요 (${e.runtimeType}) — 이번 실행 동안만 유지됩니다');
    }
  }

  @visibleForTesting
  void resetForTest({bool on = false}) {
    _on = on;
    _taps = 0;
    _lastTap = null;
    notifyListeners();
  }
}
