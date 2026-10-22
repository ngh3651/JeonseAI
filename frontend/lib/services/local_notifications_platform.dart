/// 휴대폰 알림 플러그인(flutter_local_notifications)을 부르는 **유일한 곳** (2026-10-22, P1-2).
///
/// 플랫폼 종속 코드는 여기 한 파일에 가둔다(CLAUDE.md §6) — 나머지 앱은 [ReminderPlatform]만 안다.
/// 위젯·단위 테스트는 이 클래스 대신 가짜 [ReminderPlatform]을 넣는다.
///
/// 정한 것:
/// - **정확한 알람 권한(exact alarm)을 쓰지 않는다** — 구글 정책상 달력·알람 앱이 아니면 쓰기 어렵다.
///   `inexactAllowWhileIdle`(절전 중에도 울리되 몇 분 늦을 수 있음)로 예약한다. 잔금 알림은 몇 분 늦어도 된다.
/// - 시간대 데이터베이스를 내려받지 않는다: 울릴 때를 **폰의 시각으로 계산한 뒤 UTC 순간**으로 넘긴다.
///   (안드로이드 알람은 어차피 '몇 시 몇 분'이 아니라 '언제(절대 시각)'로 걸린다)
/// - 폰을 껐다 켜도 다시 걸린다 — 플러그인의 부팅 수신기(AndroidManifest.xml)가 맡는다.
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../design_system/tokens/app_colors.dart';
import 'journey_reminders.dart';

/// 알림 플러그인의 경계 — 이 다섯 가지만 쓴다.
abstract class ReminderPlatform {
  /// 앱이 켜질 때 1회. [onTap]은 앱이 떠 있는 동안 알림을 눌렀을 때 불린다.
  Future<void> initialize(void Function(String? payload) onTap);

  /// 알림을 눌러 앱이 **새로** 켜졌으면 그 알림의 payload. 아니면 null.
  Future<String?> launchPayload();

  /// 지금 알림이 켜져 있나. 모르면 null.
  Future<bool?> notificationsEnabled();

  /// 알림 권한을 묻는다(안드로이드 13 이상은 시스템 창). 허락되면 true.
  Future<bool> requestPermission();

  /// 이 앱의 알림 설정 화면을 연다(두 번 거절하면 시스템 창이 더 뜨지 않는다).
  Future<void> openSettings();

  Future<void> schedule(JourneyReminder reminder);

  Future<void> cancel(int id);
}

class LocalNotificationsPlatform implements ReminderPlatform {
  LocalNotificationsPlatform([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// 안드로이드 알림 채널 — 사용자가 설정에서 이 이름으로 켜고 끈다.
  static const String channelId = 'journey_reminders';
  static const String channelName = '계약 지킴이 알림';

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  IOSFlutterLocalNotificationsPlugin? get _ios =>
      _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin
      >();

  @override
  Future<void> initialize(void Function(String? payload) onTap) async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        // 상태 표시줄용 흰 종 모양 (res/drawable/ic_stat_journey.xml — res/raw/keep.xml이 릴리스에서도 남긴다)
        android: AndroidInitializationSettings('ic_stat_journey'),
        // 아이폰: 켜자마자 묻지 않는다 — 날짜를 저장하는 순간 이유와 함께 묻는다.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (response) => onTap(response.payload),
    );
  }

  @override
  Future<String?> launchPayload() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    return details.notificationResponse?.payload;
  }

  @override
  Future<bool?> notificationsEnabled() async {
    final android = _android;
    if (android != null) return android.areNotificationsEnabled();
    final ios = _ios;
    if (ios != null) return (await ios.checkPermissions())?.isEnabled;
    return null;
  }

  @override
  Future<bool> requestPermission() async {
    final android = _android;
    if (android != null) return await android.requestNotificationsPermission() ?? false;
    final ios = _ios;
    if (ios != null) return await ios.requestPermissions(alert: true, sound: true) ?? false;
    return false;
  }

  @override
  Future<void> openSettings() async {
    await _plugin.openAppNotificationSettings();
  }

  @override
  Future<void> schedule(JourneyReminder reminder) async {
    await _plugin.zonedSchedule(
      id: reminder.id,
      title: reminder.title,
      body: reminder.body,
      // 폰의 시각으로 계산한 '울릴 때' → 같은 순간의 UTC. 시간대 DB가 필요 없다.
      scheduledDate: tz.TZDateTime.from(reminder.fireAt, tz.UTC),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: '잔금 전·입주 다음 날에 등기부를 다시 떼라고 알려 드려요',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          // 잠금 화면에서 내용을 숨기도록 설정한 사람에게는 집 이름을 감춘다
          visibility: NotificationVisibility.private,
          color: AppColors.primary,
          // 접힌 알림은 한 줄만 보인다 — 펼치면 문장 전체가 보이게
          styleInformation: BigTextStyleInformation(reminder.body),
          // 계약 지킴이 패스가 있으면 머리줄에 표시만 (2026-10-22, P2-1)
          subText: reminder.subText,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: reminder.payload,
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);
}
