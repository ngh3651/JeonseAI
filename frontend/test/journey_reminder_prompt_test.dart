/// 계약 지킴이 알림 (P1-2) — **권한을 묻는 때와 말**을 못 박는다.
///
///   ① 잔금일·이사일을 저장한 순간, 알림이 꺼져 있으면 **이유를 먼저** 말하고 권한을 묻는다
///   ② 거절해도 앱은 그대로 — "그날 앱을 열면 맨 위 배너로 알려 드려요"
///   ③ 일정 시트의 약속 문구 = 실제 알림 시각
///   ④ 알림을 꺼 둔 사람도 그날 여정 화면을 열면 같은 말을 본다(잔금 당일·입주 다음 날 배너)
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/journey/balance_due_banner.dart';
import 'package:jeonse_ai/screens/journey/journey_reminder_prompt.dart';
import 'package:jeonse_ai/screens/journey/journey_schedule_sheet.dart';
import 'package:jeonse_ai/screens/journey/journey_screen.dart';
import 'package:jeonse_ai/services/journey_reminder_service.dart';
import 'package:jeonse_ai/services/journey_reminders.dart';
import 'package:jeonse_ai/services/local_notifications_platform.dart';
import 'package:jeonse_ai/state/app_session.dart';
import 'package:jeonse_ai/state/journey_schedule_store.dart';
import 'package:jeonse_ai/utils/money_format.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneHeight, kPhoneWidth;

class _FakePlatform implements ReminderPlatform {
  _FakePlatform({this.enabled = false, this.grant = true});

  bool? enabled;
  bool grant;
  int permissionRequests = 0;
  final Map<int, JourneyReminder> scheduled = {};

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
    scheduled[reminder.id] = reminder;
  }

  @override
  Future<void> cancel(int id) async {
    scheduled.remove(id);
  }
}

DateTime _day(int fromToday) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day + fromToday);
}

JourneySchedule _withBalance(int fromToday) =>
    const JourneySchedule().copyWith(JourneyDateKey.balance, _day(fromToday));

/// 버튼 하나 → [applyJourneyReminders]. 일정 시트의 '저장하기' 다음에 일어나는 일과 같다.
Future<void> _pumpSaver(WidgetTester tester, JourneySchedule schedule) async {
  tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => applyJourneyReminders(
                context,
                propertyKey: '경기성남시분당구정자동456-7',
                alias: '정자동 빌라',
                schedule: schedule,
              ),
              child: const Text('저장'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('저장'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final svc = JourneyReminderService.instance;
  late _FakePlatform platform;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    JourneyScheduleStore.instance.resetForTest();
    svc.resetForTest();
  });

  tearDown(svc.resetForTest);

  group('저장한 순간 권한 묻기', () {
    testWidgets('알림이 꺼져 있으면 이유와 시각을 먼저 보여 주고, 허락하면 맞춰 둔다', (tester) async {
      platform = _FakePlatform(enabled: false, grant: true);
      svc.platformForTest = platform;

      await _pumpSaver(tester, _withBalance(5));

      // 이유 → 권한 (이유 없이 시스템 창부터 띄우지 않는다)
      expect(find.koText('그날 알림을 보내 드릴까요?'), findsOneWidget);
      expect(find.koTextContaining('잔금 직전에 근저당을 새로 설정하는 방식이 많아요'), findsOneWidget);
      expect(find.koTextContaining('잔금 하루 전'), findsOneWidget);
      expect(find.koTextContaining('잔금 당일 아침'), findsOneWidget);
      expect(find.koTextContaining('날짜는 서버로 보내지 않아요'), findsOneWidget);
      expect(platform.permissionRequests, 0);

      await tester.tap(find.koText('알림 받기'));
      await tester.pumpAndSettle();

      expect(platform.permissionRequests, 1);
      expect(platform.scheduled.length, 2); // 하루 전 9시 + 당일 8시
      expect(find.koTextContaining('알림을 맞춰 뒀어요'), findsOneWidget);
    });

    testWidgets('거절하면 배너로 동작한다고 말한다 — 앱은 그대로', (tester) async {
      platform = _FakePlatform(enabled: false, grant: false);
      svc.platformForTest = platform;

      await _pumpSaver(tester, _withBalance(5));
      await tester.tap(find.koText('알림 받기'));
      await tester.pumpAndSettle();

      expect(platform.permissionRequests, 1);
      expect(find.koText(kReminderFallbackMessage), findsOneWidget);
      expect(find.text('알림 켜기'), findsOneWidget); // 나중에 설정에서 켤 길
    });

    testWidgets("'괜찮아요'를 고르면 시스템 권한 창을 띄우지 않는다", (tester) async {
      platform = _FakePlatform(enabled: false);
      svc.platformForTest = platform;

      await _pumpSaver(tester, _withBalance(5));
      await tester.tap(find.koTextContaining('괜찮아요'));
      await tester.pumpAndSettle();

      expect(platform.permissionRequests, 0);
      expect(find.koText(kReminderFallbackMessage), findsOneWidget);
      // 권한과 상관없이 예약은 걸어 둔다 — 나중에 설정에서 켜면 그대로 울린다
      expect(platform.scheduled.length, 2);
    });

    testWidgets('이미 켜져 있으면 묻지 않고 첫 알림 시각만 알려 준다', (tester) async {
      platform = _FakePlatform(enabled: true);
      svc.platformForTest = platform;

      await _pumpSaver(tester, _withBalance(5));

      expect(find.koText('그날 알림을 보내 드릴까요?'), findsNothing);
      expect(platform.permissionRequests, 0);
      final first = describeReminderTime(
        DateTime(_day(4).year, _day(4).month, _day(4).day, 9),
      );
      expect(find.koText('알림을 맞춰 뒀어요 · 첫 알림 $first'), findsOneWidget);
    });

    testWidgets('걸 알림이 없으면(계약서 날짜만) 권한을 묻지 않는다', (tester) async {
      platform = _FakePlatform(enabled: false);
      svc.platformForTest = platform;

      await _pumpSaver(
        tester,
        const JourneySchedule().copyWith(JourneyDateKey.contract, _day(3)),
      );

      expect(find.koText('그날 알림을 보내 드릴까요?'), findsNothing);
      expect(platform.permissionRequests, 0);
    });

    testWidgets('알림 기능을 못 쓰는 휴대폰이면 알림을 약속하지 않는다', (tester) async {
      // svc가 준비되지 않은 상태(초기화 실패와 같다)
      await _pumpSaver(tester, _withBalance(5));

      expect(find.koText('그날 알림을 보내 드릴까요?'), findsNothing);
      expect(find.koTextContaining('알림을 맞추지 못했어요'), findsOneWidget);
    });
  });

  group('일정 시트의 약속 = 실제 동작', () {
    testWidgets('잔금 칸·이사 칸 아래 문구가 알림 시각과 같다', (tester) async {
      tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => showJourneyScheduleSheet(
                  context,
                  initial: const JourneySchedule(),
                ),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();

      expect(find.koText(kBalanceReminderPromise), findsOneWidget);
      expect(find.koText(kMoveInReminderPromise), findsOneWidget);
      // 옛 문구("하루 전에 … 알려드려요")는 알림이 없을 때의 약속이었다
      expect(find.koText('하루 전에 등기부를 다시 떼라고 알려드려요'), findsNothing);
      // 약속한 시각이 계산 로직과 같다
      final plan = planJourneyReminders(
        propertyKey: 'k',
        alias: '',
        schedule: _withBalance(10).copyWith(JourneyDateKey.moveIn, _day(11)),
        now: DateTime.now(),
      );
      expect(plan.map((r) => r.fireAt.hour), [9, 8, 9]);
      expect(kBalanceReminderPromise, contains('하루 전 오전 9시'));
      expect(kBalanceReminderPromise, contains('당일 오전 8시'));
      expect(kMoveInReminderPromise, contains('입주 다음 날 오전 9시'));
    });
  });

  group('알림을 꺼 둔 사람을 위한 배너', () {
    final report = AnalysisReport(
      id: 'r-jeongja',
      alias: '정자동 빌라',
      address: '경기 성남시 분당구 정자동 456-7',
      analyzedAt: DateTime.now().subtract(const Duration(hours: 2)),
      registryViewedAt: formatDate(DateTime.now().subtract(const Duration(days: 3))),
      grade: RiskGrade.caution,
      headline: '확인이 필요해요',
      nextAction: '확인 후 결정하세요',
      topRiskSummary: '예시',
      deposit: 300000000,
      marketPrice: null,
      seniorDebtAmount: 0,
      gaugeProgress: 0.5,
      evidences: const [],
    );

    Future<void> pumpTimeline(WidgetTester tester, JourneySchedule schedule) async {
      tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final key = journeyPropertyKey(report.address);
      await JourneyScheduleStore.instance.save(key, schedule);
      await JourneyScheduleStore.instance.select(key);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AppSession()),
            ChangeNotifierProvider<AnalysisRepository>(
              create: (_) => _OneReportRepo(report),
            ),
            Provider<ContentRepository>(create: (_) => DummyContentRepository()),
            ChangeNotifierProvider<JourneyScheduleStore>.value(
              value: JourneyScheduleStore.instance,
            ),
          ],
          child: MaterialApp(theme: buildAppTheme(), home: const JourneyScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('잔금 당일 — "오늘이 잔금일이에요" + 대조 버튼', (tester) async {
      await pumpTimeline(tester, _withBalance(0));

      expect(find.koTextContaining('오늘이 잔금일이에요'), findsOneWidget);
      expect(find.koText(BalanceDueBanner.kBalanceDueMessage), findsOneWidget);
      expect(find.koText('지금 다시 떼서 대조하기'), findsOneWidget);
    });

    testWidgets('입주 다음 날 — 대항력 문구 + 대조 버튼', (tester) async {
      await pumpTimeline(
        tester,
        const JourneySchedule().copyWith(JourneyDateKey.moveIn, _day(-1)),
      );

      expect(find.koTextContaining('오늘은 입주 다음 날이에요'), findsOneWidget);
      expect(find.koText(BalanceDueBanner.kMoveInNextMessage), findsOneWidget);
      expect(find.koText('지금 다시 떼서 대조하기'), findsOneWidget);
    });

    testWidgets('그 밖의 날에는 배너가 없다', (tester) async {
      await pumpTimeline(tester, _withBalance(5));

      expect(find.koText('지금 다시 떼서 대조하기'), findsNothing);
    });
  });

  test('채널 이름', () {
    expect(LocalNotificationsPlatform.channelId, 'journey_reminders');
  });
}

class _OneReportRepo extends AnalysisRepository {
  _OneReportRepo(this.report);

  final AnalysisReport report;

  @override
  Future<AnalysisReport> analyze(AnalysisRequest request) async => report;

  @override
  Future<List<AnalysisReport>> getHistory() async => [report];

  @override
  Future<AnalysisReport?> getReport(String id) async => report;

  @override
  Future<void> deleteReport(String id) async {}

  @override
  Future<CompareResult> compareRegistry(String id, List<String> paths) async =>
      CompareResult(
        outcome: CompareOutcome.noBaseline,
        headline: '이 분석은 비교 기준으로 쓸 수 없어요',
        baseline: CompareDoc(reportId: id),
        current: const CompareDoc(),
      );
}
