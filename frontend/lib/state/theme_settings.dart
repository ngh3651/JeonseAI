/// 화면 모드 — **시스템 따라 / 밝게 / 어둡게** (2026-10-30 다크 모드).
///
/// - 기본은 **시스템 따라**(폰의 다크 모드 설정을 그대로).
/// - 이 폰의 SharedPreferences(`theme_mode_v1`)에만 저장한다. 서버는 모른다.
/// - 실제 색은 [AppColors.apply]가 바꾸고, 앱 맨 위(`main.dart`의 테마 자리)가 화면 전체를 다시 그린다.
///
/// 화면은 Provider가 아니라 이 싱글턴을 직접 듣는다(`ListenableBuilder`) — 단독 위젯 테스트도 그대로 돈다.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

class ThemeSettings extends ChangeNotifier {
  ThemeSettings._();

  static final ThemeSettings instance = ThemeSettings._();

  /// SharedPreferences 키 — 이름을 바꾸면 모든 폰이 '시스템 따라'로 돌아간다.
  static const String modeKey = 'theme_mode_v1';

  ThemeMode _mode = ThemeMode.system;
  bool _restored = false;

  ThemeMode get mode => _mode;

  /// 앱 시작 시 1회 — 첫 화면부터 고른 모드로 그린다(밝은 화면이 한 번 번쩍이지 않게).
  Future<void> restore() async {
    if (_restored) return;
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      _restored = true;
      final saved = _parse(prefs.getString(modeKey));
      if (saved != _mode) {
        _mode = saved;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[화면 모드] 저장본을 읽지 못했어요 (${e.runtimeType}) — 시스템 따라로 시작합니다');
    }
  }

  /// 모드를 바꾼다. 화면은 **바로** 바뀌고, 저장은 뒤따른다(실패해도 이번 실행 동안은 유지).
  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      await prefs.setString(modeKey, mode.name);
    } catch (e) {
      debugPrint('[화면 모드] 저장하지 못했어요 (${e.runtimeType})');
    }
  }

  static ThemeMode _parse(String? name) => switch (name) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  /// 테스트용 — 처음 상태로
  @visibleForTesting
  void debugReset() {
    _mode = ThemeMode.system;
    _restored = false;
  }
}
