/// 계약 지킴이 알림 (P1-2) — **언제 울리는가**를 못 박는다.
///
///   ① 잔금일 하루 전 오전 9시 · 잔금일 당일 오전 8시 · 입주 다음 날 오전 9시
///   ② 지난 시각은 예약하지 않는다
///   ③ 날짜를 바꾸면 다시 걸고, 지우면 취소한다 (같은 집·같은 종류 = 같은 id)
///   ④ 알림을 누르면 그 집의 여정 화면으로 간다
///   ⑤ 플러그인이 실패해도 앱은 멈추지 않는다
///
/// 플러그인은 가짜([_FakePlatform])다 — 실제 휴대폰 알림을 띄우지 않는다.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/services/journey_reminder_service.dart';
import 'package:jeonse_ai/services/journey_reminders.dart';
import 'package:jeonse_ai/services/local_notifications_platform.dart';
import 'package:jeonse_ai/state/journey_schedule_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 플러그인 대신 — 무엇을 걸고 무엇을 지웠는지 기록만 한다.
class _FakePlatform implements ReminderPlatform {
  final Map<int, JourneyReminder> scheduled = {};
  final List<int> cancelled = [];
  bool? enabled = true;
  bool grant = true;
  bool failSchedule = false;
  int permissionRequests = 0;

  @override
  Future<void> initialize(void Function(String? payload) onTap) async {}

  @override
  Future<String?> launchPayload() async => null;

  @override
  Future<bool?> notificationsEnabled() async => enabled;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    enabled = grant;
    return grant;
  }

  @override
  Future<void> openSettings() async {}

  @override
  Future<void> schedule(JourneyReminder reminder) async {
    if (failSchedule) throw StateError('플러그인 실패 흉내');
    scheduled[reminder.id] = reminder;
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    scheduled.remove(id);
  }
}

JourneySchedule _schedule({DateTime? balance, DateTime? moveIn}) {
  var s = const JourneySchedule();
  if (balance != null) s = s.copyWith(JourneyDateKey.balance, balance);
  if (moveIn != null) s = s.copyWith(JourneyDateKey.moveIn, moveIn);
  return s;
}

const _key = '경기성남시분당구정자동456-7';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('예약 계산 (순수 함수)', () {
    final now = DateTime(2026, 11, 1, 10, 0);

    test('잔금일·이사일이 있으면 세 번 — 시각이 정확하다', () {
      final plan = planJourneyReminders(
        propertyKey: _key,
        alias: '정자동 빌라',
        schedule: _schedule(
          balance: DateTime(2026, 11, 5),
          moveIn: DateTime(2026, 11, 6),
        ),
        now: now,
      );

      expect(plan.map((r) => r.kind), [
        JourneyReminderKind.balanceEve,
        JourneyReminderKind.balanceDay,
        JourneyReminderKind.moveInNext,
      ]);
      expect(plan[0].fireAt, DateTime(2026, 11, 4, 9)); // 잔금 하루 전 오전 9시
      expect(plan[1].fireAt, DateTime(2026, 11, 5, 8)); // 잔금 당일 오전 8시
      expect(plan[2].fireAt, DateTime(2026, 11, 7, 9)); // 입주 다음 날 오전 9시
    });

    test('문구는 약속한 말 그대로 + 제목에 집 이름', () {
      final plan = planJourneyReminders(
        propertyKey: _key,
        alias: '정자동 빌라',
        schedule: _schedule(
          balance: DateTime(2026, 11, 5),
          moveIn: DateTime(2026, 11, 6),
        ),
        now: now,
      );

      expect(plan[0].body, startsWith('내일 잔금 전에 등기부를 다시 떼서 찍어 주세요'));
      expect(plan[1].body, '입금 전 마지막 확인 — 오늘 뗀 등기부로 대조해 주세요');
      expect(plan[2].title, startsWith('입주 다음 날 등기부 확인'));
      expect(plan[2].body, contains('대항력은 오늘 0시부터 생겨요'));
      for (final r in plan) {
        expect(r.title, endsWith(' · 정자동 빌라'));
        // 출처 없는 수치를 지어내지 않는다 — 문구의 숫자는 여정 데이터에 이미 있는 '0시'(대항력)뿐
        expect(
          RegExp(r'[0-9]').hasMatch(r.body.replaceAll('0시', '')),
          isFalse,
          reason: r.body,
        );
      }
    });

    test('지난 시각은 예약하지 않는다 — 잔금 당일 9시면 하루 전·당일 8시 알림이 빠진다', () {
      final plan = planJourneyReminders(
        propertyKey: _key,
        alias: '정자동 빌라',
        schedule: _schedule(
          balance: DateTime(2026, 11, 5),
          moveIn: DateTime(2026, 11, 6),
        ),
        now: DateTime(2026, 11, 5, 9, 0),
      );
      expect(plan.map((r) => r.kind), [JourneyReminderKind.moveInNext]);
    });

    test('정각 그 시각도 지난 것으로 본다 (플러그인은 과거 시각을 거부한다)', () {
      final plan = planJourneyReminders(
        propertyKey: _key,
        alias: '',
        schedule: _schedule(balance: DateTime(2026, 11, 5)),
        now: DateTime(2026, 11, 4, 9, 0),
      );
      expect(plan.map((r) => r.kind), [JourneyReminderKind.balanceDay]);
    });

    test('모두 지난 날짜면 아무것도 걸지 않는다', () {
      final plan = planJourneyReminders(
        propertyKey: _key,
        alias: '',
        schedule: _schedule(
          balance: DateTime(2026, 10, 1),
          moveIn: DateTime(2026, 10, 2),
        ),
        now: now,
      );
      expect(plan, isEmpty);
    });

    test('가계약금·계약서 날짜만 있으면 알림은 없다 (약속한 세 가지만)', () {
      final schedule = const JourneySchedule()
          .copyWith(JourneyDateKey.downPayment, DateTime(2026, 11, 10))
          .copyWith(JourneyDateKey.contract, DateTime(2026, 11, 12));
      final plan = planJourneyReminders(
        propertyKey: _key,
        alias: '',
        schedule: schedule,
        now: now,
      );
      expect(plan, isEmpty);
    });

    test('달이 바뀌어도 맞다 — 12월 1일 잔금이면 11월 30일 9시', () {
      final plan = planJourneyReminders(
        propertyKey: _key,
        alias: '',
        schedule: _schedule(balance: DateTime(2026, 12, 1)),
        now: now,
      );
      expect(plan.first.fireAt, DateTime(2026, 11, 30, 9));
    });

    test('집 이름이 비어 있으면 제목 뒤에 아무것도 붙이지 않는다', () {
      final plan = planJourneyReminders(
        propertyKey: _key,
        alias: '  ',
        schedule: _schedule(balance: DateTime(2026, 11, 5)),
        now: now,
      );
      expect(plan.first.title, '내일 잔금 보내는 날이에요');
    });
  });

  group('id · payload', () {
    test('같은 집·같은 종류는 늘 같은 id, 종류마다 다르다', () {
      final a = journeyReminderId(_key, JourneyReminderKind.balanceEve);
      expect(journeyReminderId(_key, JourneyReminderKind.balanceEve), a);
      final ids = journeyReminderIds(_key);
      expect(ids.toSet().length, 3);
      expect(ids.first, a);
      // 안드로이드 알림 id는 32비트 정수여야 한다
      for (final id in ids) {
        expect(id, inInclusiveRange(0, 0x7FFFFFFF));
      }
    });

    test('다른 집은 다른 id', () {
      final other = journeyReminderIds('서울강남구역삼동123-45');
      expect(other.toSet().intersection(journeyReminderIds(_key).toSet()), isEmpty);
    });

    test('payload ↔ 매물 키', () {
      final payload = journeyReminderPayload(_key);
      expect(journeyKeyFromPayload(payload), _key);
      expect(journeyKeyFromPayload('다른 알림'), isNull);
      expect(journeyKeyFromPayload(null), isNull);
      expect(journeyKeyFromPayload('journey|'), isNull);
    });

    test('안내용 시각 표기 — 오전·오후', () {
      expect(describeReminderTime(DateTime(2026, 11, 4, 9)), '11월 4일 (수) 오전 9시');
      expect(describeReminderTime(DateTime(2026, 11, 4, 12)), '11월 4일 (수) 오후 12시');
    });
  });

  group('오늘의 배너 — 알림과 같은 세 날', () {
    final schedule = _schedule(
      balance: DateTime(2026, 11, 5),
      moveIn: DateTime(2026, 11, 6),
    );

    test('잔금 하루 전 · 당일 · 입주 다음 날', () {
      expect(
        journeyAlertToday(schedule, now: DateTime(2026, 11, 4, 20)),
        JourneyReminderKind.balanceEve,
      );
      expect(
        journeyAlertToday(schedule, now: DateTime(2026, 11, 5, 7)),
        JourneyReminderKind.balanceDay,
      );
      expect(
        journeyAlertToday(schedule, now: DateTime(2026, 11, 7, 23)),
        JourneyReminderKind.moveInNext,
      );
    });

    test('그 밖의 날에는 배너가 없다', () {
      expect(journeyAlertToday(schedule, now: DateTime(2026, 11, 3, 9)), isNull);
      expect(journeyAlertToday(schedule, now: DateTime(2026, 11, 6, 9)), isNull);
      expect(journeyAlertToday(const JourneySchedule()), isNull);
    });

    test('잔금일과 입주 다음 날이 겹치면 잔금이 먼저다', () {
      final overlap = _schedule(
        balance: DateTime(2026, 11, 7),
        moveIn: DateTime(2026, 11, 6),
      );
      expect(
        journeyAlertToday(overlap, now: DateTime(2026, 11, 7, 9)),
        JourneyReminderKind.balanceDay,
      );
    });
  });

  group('예약 서비스 (가짜 플러그인)', () {
    late _FakePlatform platform;
    final svc = JourneyReminderService.instance;
    final now = DateTime(2026, 11, 1, 10);

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      JourneyScheduleStore.instance.resetForTest();
      svc.resetForTest();
      platform = _FakePlatform();
      svc.platformForTest = platform;
    });

    tearDown(svc.resetForTest);

    test('저장하면 건다 — 세 개', () async {
      await svc.sync(
        propertyKey: _key,
        alias: '정자동 빌라',
        schedule: _schedule(
          balance: DateTime(2026, 11, 5),
          moveIn: DateTime(2026, 11, 6),
        ),
        now: now,
      );
      expect(platform.scheduled.length, 3);
      expect(
        platform.scheduled.values.map((r) => r.payload).toSet(),
        {journeyReminderPayload(_key)},
      );
    });

    test('날짜를 바꾸면 새 시각으로 다시 건다 (옛 시각이 남지 않는다)', () async {
      await svc.sync(
        propertyKey: _key,
        alias: '정자동 빌라',
        schedule: _schedule(balance: DateTime(2026, 11, 5)),
        now: now,
      );
      await svc.sync(
        propertyKey: _key,
        alias: '정자동 빌라',
        schedule: _schedule(balance: DateTime(2026, 11, 10)),
        now: now,
      );
      final times = platform.scheduled.values.map((r) => r.fireAt).toList()..sort();
      expect(times, [DateTime(2026, 11, 9, 9), DateTime(2026, 11, 10, 8)]);
    });

    test('날짜를 지우면 취소한다', () async {
      await svc.sync(
        propertyKey: _key,
        alias: '정자동 빌라',
        schedule: _schedule(
          balance: DateTime(2026, 11, 5),
          moveIn: DateTime(2026, 11, 6),
        ),
        now: now,
      );
      // 이사일만 남기고 잔금일을 지운다
      await svc.sync(
        propertyKey: _key,
        alias: '정자동 빌라',
        schedule: _schedule(moveIn: DateTime(2026, 11, 6)),
        now: now,
      );
      expect(platform.scheduled.values.map((r) => r.kind), [
        JourneyReminderKind.moveInNext,
      ]);
      // 다 지우면 하나도 남지 않는다
      await svc.sync(
        propertyKey: _key,
        alias: '정자동 빌라',
        schedule: const JourneySchedule(),
        now: now,
      );
      expect(platform.scheduled, isEmpty);
      expect(platform.cancelled.toSet(), journeyReminderIds(_key).toSet());
    });

    test('다른 집의 알림은 건드리지 않는다', () async {
      await svc.sync(
        propertyKey: '서울강남구역삼동123-45',
        alias: '역삼동 오피스텔',
        schedule: _schedule(balance: DateTime(2026, 11, 20)),
        now: now,
      );
      await svc.sync(
        propertyKey: _key,
        alias: '정자동 빌라',
        schedule: const JourneySchedule(),
        now: now,
      );
      expect(platform.scheduled.length, 2);
      expect(platform.scheduled.values.every((r) => r.title.endsWith('역삼동 오피스텔')), isTrue);
    });

    test('플러그인이 실패해도 예외가 밖으로 나오지 않는다 (앱이 멈추지 않는다)', () async {
      platform.failSchedule = true;
      final plan = await svc.sync(
        propertyKey: _key,
        alias: '정자동 빌라',
        schedule: _schedule(balance: DateTime(2026, 11, 5)),
        now: now,
      );
      expect(plan.length, 2); // 계획은 그대로 돌려준다
      expect(platform.scheduled, isEmpty);
    });

    test('앱을 다시 켜면 저장된 일정으로 다시 건다 (강제 종료로 지워진 알림 되살리기)', () async {
      await JourneyScheduleStore.instance.save(
        _key,
        _schedule(balance: DateTime(2026, 11, 5)),
      );
      await svc.sync(
        propertyKey: _key,
        alias: '정자동 빌라',
        schedule: _schedule(balance: DateTime(2026, 11, 5)),
        now: now,
      );
      platform.scheduled.clear(); // 안드로이드가 강제 종료로 지운 상태

      await svc.resyncAll(JourneyScheduleStore.instance, now: now);

      expect(platform.scheduled.length, 2);
      // 집 이름도 기억해 둔 것으로 붙는다
      expect(platform.scheduled.values.every((r) => r.title.endsWith('정자동 빌라')), isTrue);
    });

    test('알림을 누르면 그 집을 고르고 여정 화면으로 간다', () async {
      String? went;
      svc.navigate = (location) => went = location;

      svc.openPayload(journeyReminderPayload(_key));
      await Future<void>.delayed(Duration.zero);

      expect(went, '/journey');
      expect(JourneyScheduleStore.instance.selectedPropertyKey, _key);
    });

    test('우리 알림이 아니면 아무 데도 가지 않는다', () {
      String? went;
      svc.navigate = (location) => went = location;
      svc.openPayload('something-else');
      expect(went, isNull);
    });

    test('준비되지 않은 휴대폰(초기화 실패)에서는 걸지 않고 조용히 넘어간다', () async {
      svc.resetForTest(); // 준비 안 됨
      final plan = await svc.sync(
        propertyKey: _key,
        alias: '',
        schedule: _schedule(balance: DateTime(2026, 11, 5)),
        now: now,
      );
      expect(plan, isNotEmpty);
      expect(await svc.notificationsEnabled(), isNull);
      expect(await svc.requestPermission(), isFalse);
    });
  });

  test('알림 채널 이름은 사용자가 설정에서 알아볼 수 있는 말이다', () {
    expect(LocalNotificationsPlatform.channelName, '계약 지킴이 알림');
  });
}
