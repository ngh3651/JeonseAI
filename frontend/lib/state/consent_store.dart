/// 이용약관·개인정보 동의 기록 (2026-10-30) — **이 폰에만** 남긴다.
///
/// - 처음 [로그인 없이 둘러보기]·[카카오로 시작하기]를 누를 때, 그리고 분석을 시작할 때 동의 시트가 뜬다
///   (`screens/legal/consent_sheet.dart`의 `ensureConsent`). 한 번 동의하면 다시 묻지 않는다.
/// - 약관·처리방침 내용을 크게 바꾸면 [kConsentVersion]을 올린다 → 다음 분석 때 한 번 더 묻는다.
/// - 저장 값: 동의한 판(version) · 동의한 시각 · 만 14세 이상 확인. 이름·연락처 같은 개인정보는 없다.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 지금 약관·처리방침 판. 내용을 크게 바꾸면 날짜를 바꾼다(다시 동의를 받는다).
const String kConsentVersion = '2026-10-30';

class ConsentStore extends ChangeNotifier {
  ConsentStore._();

  static final ConsentStore instance = ConsentStore._();

  /// SharedPreferences 키
  static const String prefsKey = 'consent_v1';

  String? _version;
  DateTime? _agreedAt;
  bool _restored = false;

  /// 지금 판에 동의했나
  bool get hasCurrent => _version == kConsentVersion;

  /// 마지막으로 동의한 시각(없으면 null)
  DateTime? get agreedAt => _agreedAt;

  /// 앱 시작 시 1회 — 저장된 동의를 올린다. 못 읽으면 '동의 안 함'으로 시작(다시 묻는 쪽이 안전).
  Future<void> restore() async {
    if (_restored) return;
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      _restored = true;
      final raw = prefs.getString(prefsKey);
      if (raw == null) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _version = map['version'] as String?;
      final at = map['at'] as String?;
      _agreedAt = at == null ? null : DateTime.tryParse(at);
      notifyListeners();
    } catch (e) {
      debugPrint('[동의] 저장본을 읽지 못했어요 (${e.runtimeType})');
    }
  }

  /// 동의를 남긴다. 화면은 바로 넘어가고 저장은 뒤따른다.
  Future<void> agree({DateTime? now}) async {
    _version = kConsentVersion;
    _agreedAt = now ?? DateTime.now();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      await prefs.setString(
        prefsKey,
        jsonEncode({
          'version': _version,
          'at': _agreedAt!.toIso8601String(),
          'age14': true,
        }),
      );
    } catch (e) {
      debugPrint('[동의] 저장하지 못했어요 (${e.runtimeType})');
    }
  }

  /// 회원 탈퇴·기록 전체 삭제 뒤 — 다음에 다시 묻는다
  Future<void> forget() async {
    _version = null;
    _agreedAt = null;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsKey);
    } catch (_) {}
  }

  /// 테스트용 — 처음 상태로. [agreed]면 지금 판에 동의한 상태로 둔다.
  @visibleForTesting
  void debugReset({bool agreed = false}) {
    _restored = false;
    _version = agreed ? kConsentVersion : null;
    _agreedAt = agreed ? DateTime(2026, 10, 30) : null;
  }
}
