/// 계약 지킴이 알림 — 예약·취소·권한·알림 눌렀을 때 (2026-10-22, P1-2).
///
/// - **무엇을 언제** 울릴지는 순수 함수 [planJourneyReminders]가 정한다(journey_reminders.dart).
/// - 이 클래스는 그 계획을 휴대폰에 걸고([sync]), 알림을 누르면 그 집의 여정 화면을 연다([openPayload]).
/// - 플러그인은 [ReminderPlatform] 뒤에 숨는다 — 테스트는 가짜를 넣는다([platformForTest]).
///
/// ⚠ 알림이 실패해도 **앱은 멈추지 않는다.** 모든 플랫폼 호출은 잡아서 로그 한 줄로 끝낸다.
///   알림이 안 와도 여정 화면의 배너(잔금 하루 전·당일·입주 다음 날)는 그대로 뜬다.
/// ⚠ 날짜·집 이름은 이 휴대폰 안에서만 쓴다. 서버로 보내지 않는다(journey_schedule_store.dart).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/journey_schedule_store.dart';
import 'journey_reminders.dart';
import 'local_notifications_platform.dart';

class JourneyReminderService {
  JourneyReminderService._();

  static final JourneyReminderService instance = JourneyReminderService._();

  /// 집 키 → 알림 제목에 붙일 집 이름. 앱을 다시 켤 때 알림을 다시 걸면서 쓴다.
  static const String _aliasKey = 'journey_reminder_alias_v1';

  static const Duration _prefsTimeout = Duration(seconds: 5);

  ReminderPlatform _platform = LocalNotificationsPlatform();
  bool _ready = false;

  /// 예약을 한 줄로 세운다 — 두 번 연달아 저장해도 취소·예약이 뒤섞이지 않게.
  Future<void> _queue = Future<void>.value();

  /// 알림을 눌렀을 때 화면을 옮기는 함수. main.dart가 라우터로 채운다(서비스는 화면을 모른다).
  void Function(String location)? navigate;

  /// 테스트용 — 가짜 플랫폼을 넣고 '준비됨'으로 만든다.
  @visibleForTesting
  set platformForTest(ReminderPlatform platform) {
    _platform = platform;
    _ready = true;
  }

  /// 테스트용 — 다음 테스트가 앞의 상태를 물려받지 않게.
  @visibleForTesting
  void resetForTest() {
    _platform = LocalNotificationsPlatform();
    _ready = false;
    _queue = Future<void>.value();
    navigate = null;
  }

  /// 앱 시작 때 1회. 실패해도 앱은 뜬다(알림만 빠진다).
  Future<void> init() async {
    try {
      await _platform.initialize(openPayload);
      _ready = true;
    } catch (e) {
      debugPrint('[알림] 알림 기능을 켜지 못했어요 (${e.runtimeType}) — 배너로만 안내합니다');
    }
  }

  /// 알림을 눌러 앱이 새로 켜졌으면 그 payload (main.dart가 첫 화면 뒤에 [openPayload]로 넘긴다).
  Future<String?> launchPayload() async {
    if (!_ready) return null;
    try {
      return await _platform.launchPayload();
    } catch (e) {
      debugPrint('[알림] 알림으로 켜졌는지 확인하지 못했어요 (${e.runtimeType})');
      return null;
    }
  }

  /// 알림을 눌렀다 → 그 집을 고르고 여정 화면으로. 우리 알림이 아니면 아무것도 안 한다.
  void openPayload(String? payload) {
    final key = journeyKeyFromPayload(payload);
    if (key == null) return;
    unawaited(JourneyScheduleStore.instance.select(key));
    navigate?.call('/journey');
  }

  /// 이 집의 알림을 일정에 맞춰 **다시** 건다: 세 개를 모두 지우고, 계획에 있는 것만 건다.
  ///
  /// 날짜를 바꾸면 새 시각으로, 지우면 취소, 지난 시각은 빠진다. 돌려주는 값 = 이번에 건 알림.
  /// (플랫폼이 준비되지 않았어도 계획은 돌려준다 — 화면이 안내 문구를 고를 수 있게)
  Future<List<JourneyReminder>> sync({
    required String propertyKey,
    required String alias,
    required JourneySchedule schedule,
    DateTime? now,
  }) {
    final plan = planJourneyReminders(
      propertyKey: propertyKey,
      alias: alias,
      schedule: schedule,
      now: now ?? DateTime.now(),
    );
    final done = _queue.then((_) async {
      await _rememberAlias(propertyKey, alias);
      if (!_ready) return;
      // 하나가 실패해도 나머지는 건다 — 한 줄의 실패가 다른 알림을 지우지 않게 각각 잡는다.
      for (final id in journeyReminderIds(propertyKey)) {
        try {
          await _platform.cancel(id);
        } catch (e) {
          debugPrint('[알림] 옛 알림을 지우지 못했어요 (${e.runtimeType})');
        }
      }
      for (final reminder in plan) {
        try {
          await _platform.schedule(reminder);
        } catch (e) {
          debugPrint('[알림] 알림 1개를 예약하지 못했어요 (${e.runtimeType}) — 배너로만 안내합니다');
        }
      }
    });
    _queue = done.catchError((Object _) {});
    return done.then((_) => plan);
  }

  /// 이 휴대폰에 저장된 모든 일정의 알림을 다시 건다 — 앱을 켤 때마다.
  ///
  /// 왜: 안드로이드는 사용자가 앱을 **강제 종료**하면 걸어 둔 알람을 모두 지운다(부팅해도 안 돌아온다).
  /// 앱을 다시 켜는 순간 되살린다. 권한은 묻지 않는다(묻는 때는 날짜를 저장하는 순간뿐).
  Future<void> resyncAll(JourneyScheduleStore store, {DateTime? now}) async {
    if (!_ready) return;
    final aliases = await _loadAliases();
    for (final key in store.scheduledKeys.toList()) {
      await sync(
        propertyKey: key,
        alias: aliases[key] ?? '',
        schedule: store.scheduleFor(key),
        now: now,
      );
    }
  }

  Future<bool?> notificationsEnabled() async {
    if (!_ready) return null;
    try {
      return await _platform.notificationsEnabled();
    } catch (e) {
      debugPrint('[알림] 알림 허용 여부를 읽지 못했어요 (${e.runtimeType})');
      return null;
    }
  }

  Future<bool> requestPermission() async {
    if (!_ready) return false;
    try {
      return await _platform.requestPermission();
    } catch (e) {
      debugPrint('[알림] 알림 권한을 묻지 못했어요 (${e.runtimeType})');
      return false;
    }
  }

  Future<void> openSettings() async {
    if (!_ready) return;
    try {
      await _platform.openSettings();
    } catch (e) {
      debugPrint('[알림] 알림 설정 화면을 열지 못했어요 (${e.runtimeType})');
    }
  }

  // ── 집 이름 보관 (이 휴대폰에만) ─────────────────────────────────────────────

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance().timeout(_prefsTimeout);
    } catch (e) {
      debugPrint('[알림] 저장소를 열지 못했어요 (${e.runtimeType})');
      return null;
    }
  }

  Future<Map<String, String>> _loadAliases() async {
    final prefs = await _prefs();
    try {
      final raw = prefs?.getString(_aliasKey);
      if (raw == null) return {};
      return (jsonDecode(raw) as Map).map(
        (k, v) => MapEntry(k as String, v as String),
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> _rememberAlias(String propertyKey, String alias) async {
    final prefs = await _prefs();
    if (prefs == null) return;
    try {
      final aliases = await _loadAliases();
      if (aliases[propertyKey] == alias) return;
      aliases[propertyKey] = alias;
      await prefs.setString(_aliasKey, jsonEncode(aliases));
    } catch (_) {
      // 이름을 못 남기면 다음 재예약 때 제목에서 집 이름만 빠진다
    }
  }
}
