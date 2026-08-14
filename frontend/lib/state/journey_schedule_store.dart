/// 계약 일정 — **이 휴대폰에만** 저장한다 (S-11).
///
/// 왜 서버에 보내지 않나: 잔금일·이사일은 그 사람이 어디로 이사 가는지, 언제 큰돈이
/// 움직이는지를 그대로 알려주는 정보다. 여정 화면이 이 날짜로 하는 일(D-1 알림, 단계
/// 강조)은 전부 기기 안에서 할 수 있으므로 **서버는 알 필요가 없다.** 시트에 적힌
/// "이 날짜는 이 휴대폰에만 저장돼요"가 지켜지는 지점이 여기다.
///
/// 매물 키는 **주소를 정규화한 값**이다. 리포트 id가 아니라 주소인 이유: 등기부를 다시
/// 떼어 대조하면 같은 집에 새 리포트가 생기는데, id를 키로 쓰면 그때마다 일정이
/// 사라진다. 사용자가 넣은 것은 "이 집의 계약 일정"이지 "이 분석의 일정"이 아니다.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/content_models.dart';

/// 주소 → 매물 키. 공백·표기 흔들림을 걷어낸 뒤 소문자화한다.
String journeyPropertyKey(String address) {
  final trimmed = address.replaceAll(RegExp(r'\s+'), '');
  return trimmed.isEmpty ? '(주소없음)' : trimmed;
}

/// 한 매물의 계약 일정. 넣지 않은 날은 null — **비워 두는 것이 정상**이다.
@immutable
class JourneySchedule {
  const JourneySchedule({this.dates = const {}});

  final Map<JourneyDateKey, DateTime> dates;

  bool get isEmpty => dates.isEmpty;

  /// 그 단계의 날짜. `moveInNext`(입주 다음 날)는 묻지 않고 이사일에서 계산한다.
  DateTime? operator [](JourneyDateKey key) {
    if (key == JourneyDateKey.moveInNext) {
      final moveIn = dates[JourneyDateKey.moveIn];
      return moveIn?.add(const Duration(days: 1));
    }
    return dates[key];
  }

  DateTime? get balance => this[JourneyDateKey.balance];

  JourneySchedule copyWith(JourneyDateKey key, DateTime? value) {
    final next = Map<JourneyDateKey, DateTime>.from(dates);
    if (value == null) {
      next.remove(key);
    } else {
      next[key] = DateTime(value.year, value.month, value.day);
    }
    return JourneySchedule(dates: next);
  }

  /// 잔금일까지 남은 날. 오늘이면 0, 내일이면 1. 잔금일이 없으면 null.
  int? get daysUntilBalance {
    final due = balance;
    if (due == null) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return DateTime(due.year, due.month, due.day).difference(today).inDays;
  }

  /// 잔금일이 **내일**인가 — 이 앱이 가장 크게 경고하는 하루 (D-1).
  bool get isBalanceTomorrow => daysUntilBalance == 1;

  Map<String, String> toJson() => {
    for (final e in dates.entries)
      e.key.name:
          '${e.value.year.toString().padLeft(4, '0')}-'
          '${e.value.month.toString().padLeft(2, '0')}-'
          '${e.value.day.toString().padLeft(2, '0')}',
  };

  factory JourneySchedule.fromJson(Map<String, dynamic> json) {
    final dates = <JourneyDateKey, DateTime>{};
    for (final entry in json.entries) {
      final key = JourneyDateKey.fromWire(entry.key);
      final value = DateTime.tryParse(entry.value as String? ?? '');
      // 계산으로 얻는 날(moveInNext)은 저장하지 않는다 — 이사일 하나만 진실이다.
      if (key == null || key == JourneyDateKey.moveInNext || value == null) continue;
      dates[key] = value;
    }
    return JourneySchedule(dates: dates);
  }
}

class JourneyScheduleStore extends ChangeNotifier {
  JourneyScheduleStore._();

  static final JourneyScheduleStore instance = JourneyScheduleStore._();

  static const String _schedulesKey = 'journey_schedules_v1';
  static const String _selectedKey = 'journey_selected_v1';

  final Map<String, JourneySchedule> _schedules = {};
  String? _selectedPropertyKey;
  bool _restored = false;

  /// 여정에 연결된 매물 키. 없으면 매물 선택 화면이 뜬다.
  String? get selectedPropertyKey => _selectedPropertyKey;

  bool get restored => _restored;

  /// 앱 시작 시 1회 — 화면 build()에서 기다리지 않도록 미리 메모리로 올린다.
  Future<void> restore() async {
    if (_restored) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_schedulesKey);
      if (raw != null) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          _schedules[entry.key] = JourneySchedule.fromJson(
            (entry.value as Map).cast<String, dynamic>(),
          );
        }
      }
      _selectedPropertyKey = prefs.getString(_selectedKey);
    } catch (e) {
      // 저장본이 깨져도 앱은 뜬다 — 일정이 비어 있는 것으로 시작할 뿐이다.
      debugPrint('[여정일정] 저장본을 읽지 못했어요 (${e.runtimeType}) — 빈 일정으로 시작합니다');
    }
    _restored = true;
    notifyListeners();
  }

  JourneySchedule scheduleFor(String propertyKey) =>
      _schedules[propertyKey] ?? const JourneySchedule();

  /// 테스트가 앞 테스트의 일정을 물려받지 않게 비운다 (싱글턴이라 상태가 남는다).
  @visibleForTesting
  void resetForTest() {
    _schedules.clear();
    _selectedPropertyKey = null;
    _restored = false;
  }

  /// 이 기기에 일정이 하나라도 저장돼 있는 매물 키 목록.
  Iterable<String> get scheduledKeys =>
      _schedules.entries.where((e) => !e.value.isEmpty).map((e) => e.key);

  Future<void> save(String propertyKey, JourneySchedule schedule) async {
    if (schedule.isEmpty) {
      _schedules.remove(propertyKey);
    } else {
      _schedules[propertyKey] = schedule;
    }
    notifyListeners();
    await _persistSchedules();
  }

  Future<void> select(String? propertyKey) async {
    if (_selectedPropertyKey == propertyKey) return;
    _selectedPropertyKey = propertyKey;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (propertyKey == null) {
        await prefs.remove(_selectedKey);
      } else {
        await prefs.setString(_selectedKey, propertyKey);
      }
    } catch (e) {
      debugPrint('[여정일정] 선택한 매물을 저장하지 못했어요 (${e.runtimeType})');
    }
  }

  Future<void> _persistSchedules() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _schedulesKey,
        jsonEncode({for (final e in _schedules.entries) e.key: e.value.toJson()}),
      );
    } catch (e) {
      debugPrint('[여정일정] 일정을 저장하지 못했어요 (${e.runtimeType}) — 이번 세션에만 남습니다');
    }
  }
}
