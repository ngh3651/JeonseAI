/// 개인정보 화면 설정 — 지금은 **'사진 속 이름 가리기'** 스위치 하나 (2026-10-22, 앱 1단계).
///
/// 왜 필요한가: 등기부 사진에는 집주인 실명이 그대로 찍혀 있다. 내 폰으로 내 등기부를 볼 때는
/// 그 이름을 계약 상대의 신분증과 **대조하는 것이 이 화면의 목적**이라 보여야 한다.
/// 그런데 부스 시연·화면 공유처럼 **남이 보는 자리**에서는 가려야 한다 → 사용자가 고르게 한다.
///
/// - 기본값 **꺼짐** — 대조 기능이 기본이다(NOW.md P0-2: "내 폰의 내 등기부에선 집주인 이름 대조 기능 유지").
/// - 켜면 뷰어·리포트 진입 카드가 [MarkKind.carriesPersonalName]인 표시(지금은 집주인 이름)를
///   형광펜 대신 **불투명한 상자**로 덮는다.
/// - 이 폰의 SharedPreferences(`hide_names_in_photos_v1`)에만 저장한다. 서버는 모른다.
///
/// 화면은 Provider가 아니라 이 싱글턴을 직접 듣는다(`ListenableBuilder`) — 뷰어·카드를
/// 단독으로 띄우는 위젯 테스트가 Provider 없이도 그대로 돌게 하려는 것이다.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PrivacySettings extends ChangeNotifier {
  PrivacySettings._();

  static final PrivacySettings instance = PrivacySettings._();

  /// SharedPreferences 키 — 이름을 바꾸면 모든 폰의 설정이 꺼짐으로 돌아간다.
  static const String hideNamesKey = 'hide_names_in_photos_v1';

  bool _hideNamesInPhotos = false;
  bool _restored = false;

  /// 사진 속 이름(집주인 이름 칸)을 상자로 덮을지. 기본 false.
  bool get hideNamesInPhotos => _hideNamesInPhotos;

  /// 앱 시작 시 1회 — 첫 화면부터 저장된 값으로 그리게 미리 올린다.
  Future<void> restore() async {
    if (_restored) return;
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      final saved = prefs.getBool(hideNamesKey) ?? false;
      _restored = true;
      if (saved != _hideNamesInPhotos) {
        _hideNamesInPhotos = saved;
        notifyListeners();
      }
    } catch (e) {
      // 저장본을 못 읽어도 앱은 뜬다 — 기본값(꺼짐)으로 시작할 뿐이다.
      debugPrint('[개인정보설정] 저장본을 읽지 못했어요 (${e.runtimeType}) — 기본값(꺼짐)으로 시작합니다');
    }
  }

  /// 스위치를 바꾼다. 화면은 **바로** 바뀌고, 저장은 뒤따른다(실패해도 이번 실행 동안은 유지).
  Future<void> setHideNamesInPhotos(bool value) async {
    if (value == _hideNamesInPhotos) return;
    _hideNamesInPhotos = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      await prefs.setBool(hideNamesKey, value);
    } catch (e) {
      debugPrint('[개인정보설정] 저장하지 못했어요 (${e.runtimeType}) — 이번 실행 동안만 유지됩니다');
    }
  }

  /// 테스트가 앞 테스트의 값을 물려받지 않게 되돌린다 (싱글턴이라 상태가 남는다).
  @visibleForTesting
  void resetForTest({bool hideNamesInPhotos = false}) {
    _hideNamesInPhotos = hideNamesInPhotos;
    _restored = false;
    notifyListeners();
  }
}
