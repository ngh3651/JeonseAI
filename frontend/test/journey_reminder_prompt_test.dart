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
import 'package:jeonse_ai/design_system/tokens/app_colors.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/journey/journey_reminder_prompt.dart';
import 'package:jeonse_ai/screens/journey/journey_schedule_sheet.dart';
import 'package:jeonse_ai/screens/journey/journey_screen.dart';
import 'package:jeonse_ai/services/journey_reminder_service.dart';
import 'package:jeonse_ai/services/journey_reminders.dart';
import 'package:jeonse_ai/services/local_notifications_platform.dart';
import 'package:jeonse_ai/state/app_session.dart';
import 'package:jeonse_ai/state/journey_progress_store.dart';
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
    JourneyProgressStore.instance.resetForTest();
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
      expect(find.koText(kReminderPermissionReason), findsOneWidget);
      expect(find.koTextContaining('그 하루가 빈틈이에요'), findsOneWidget);
      expect(find.koTextContaining('잔금 하루 전'), findsOneWidget);
      expect(find.koTextContaining('잔금 당일 아침'), findsOneWidget);
      expect(find.koTextContaining('날짜는 서버로 보내지 않아요'), findsOneWidget);
      expect(platform.permissionRequests, 0);

      await tester.tap(find.koText('알림 받기'));
      await tester.pumpAndSettle();

      expect(platform.permissionRequests, 1);
      expect(platform.scheduled.length, 2); // 하루 전 8시 + 당일 8시
      expect(find.koTextContaining('첫 알림이 와요'), findsOneWidget);
    });

    testWidgets('거절해도 아무 안내도 띄우지 않는다 (2026-10-26)', (tester) async {
      platform = _FakePlatform(enabled: false, grant: false);
      svc.platformForTest = platform;

      await _pumpSaver(tester, _withBalance(5));
      await tester.tap(find.koText('알림 받기'));
      await tester.pumpAndSettle();

      expect(platform.permissionRequests, 1);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.koTextContaining('알림이 꺼져 있어요'), findsNothing);
      expect(JourneyProgressStore.instance.notificationsOn, isFalse);
    });

    testWidgets("'괜찮아요'를 고르면 시트만 닫는다 — 권한 창도 안내도 없다", (tester) async {
      platform = _FakePlatform(enabled: false);
      svc.platformForTest = platform;

      await _pumpSaver(tester, _withBalance(5));
      expect(find.koText(kReminderDeclineLabel), findsOneWidget);
      await tester.tap(find.koText(kReminderDeclineLabel));
      await tester.pumpAndSettle();

      expect(platform.permissionRequests, 0);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.koTextContaining('알림이 꺼져 있어요'), findsNothing);
      expect(find.koTextContaining('직접 열'), findsNothing);
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
        DateTime(_day(4).year, _day(4).month, _day(4).day, 8),
      );
      // 잔금만 넣으면 첫 알림은 잔금 '하루 전' — 어느 날 알림인지 이름을 붙인다 (2026-11-01)
      expect(find.koText('잔금 하루 전 · $first에 첫 알림이 와요'), findsOneWidget);
      // 잔금은 하루 전·당일 아침 두 번
      expect(platform.scheduled.length, 2);
    });

    testWidgets('저장 뒤 가족·배우자에게 보내기 버튼이 없다 (2026-10-26 기능 뺌)', (tester) async {
      platform = _FakePlatform(enabled: true);
      svc.platformForTest = platform;
      await _pumpSaver(
        tester,
        _withBalance(5).copyWith(JourneyDateKey.moveIn, _day(6)),
      );
      expect(find.textContaining('가족'), findsNothing);
      expect(find.textContaining('배우자'), findsNothing);
    });

    testWidgets('걸 알림이 없으면(지난 날짜만) 권한을 묻지 않는다', (tester) async {
      platform = _FakePlatform(enabled: false);
      svc.platformForTest = platform;

      await _pumpSaver(
        tester,
        const JourneySchedule().copyWith(JourneyDateKey.contract, _day(-3)),
      );

      expect(find.koText('그날 알림을 보내 드릴까요?'), findsNothing);
      expect(platform.permissionRequests, 0);
    });

    testWidgets('알림 기능을 못 쓰는 휴대폰이면 알림을 약속하지 않는다', (tester) async {
      // svc가 준비되지 않은 상태(초기화 실패와 같다)
      await _pumpSaver(tester, _withBalance(5));

      expect(find.koText('그날 알림을 보내 드릴까요?'), findsNothing);
      // 알림을 약속하지 않고, 꺼져 있다는 안내도 띄우지 않는다
      expect(find.koTextContaining('첫 알림이 와요'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('일정 시트 (2026-10-27 시안)', () {
    Future<List<JourneySchedule?>> pumpSheet(
      WidgetTester tester,
      JourneySchedule initial, {
      double textScale = 1.0,
    }) async {
      tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final saved = <JourneySchedule?>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async => saved.add(
                  await showJourneyScheduleSheet(context, initial: initial),
                ),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      return saved;
    }

    Color? saveBg(WidgetTester tester) {
      final b = tester.widget<FilledButton>(
        find.byKey(const ValueKey('schedule-sheet-save')),
      );
      return b.style?.backgroundColor?.resolve(
        b.onPressed == null ? {WidgetState.disabled} : <WidgetState>{},
      );
    }

    testWidgets('처음 — 제목 "계약 일정", 칸 이름 4개, "날짜 선택", 저장은 회색 · 뺀 문구는 없다', (tester) async {
      await pumpSheet(tester, const JourneySchedule());
      expect(find.koText('계약 일정'), findsOneWidget);
      for (final name in ['가계약금', '계약서', '잔금', '이사']) {
        expect(find.koText(name), findsOneWidget, reason: name);
      }
      expect(find.koText('날짜 선택'), findsNWidgets(4));
      expect(saveBg(tester), const Color(0xFFECEFED));
      for (final gone in [
        '아직 안 정해진 날은 비워 두셔도 돼요',
        '잔금 하루 전과 당일 오전 8시에 등기부를 다시 떼라고 알림을 보내 드려요',
        '이사 날과 입주 다음 날 오전 8시에도 알려 드려요',
        '이 날짜는 이 휴대폰에만 저장돼요',
        '이 날짜가 가장 중요해요',
        '아직 안 정했어요',
        '잔금 보내는 날',
        '계약서 쓰는 날',
        '이사 오는 날',
      ]) {
        expect(find.koTextContaining(gone), findsNothing, reason: gone);
      }
    });

    testWidgets('일부 넣음 — 날짜가 초록 글씨, ×로 지우면 그 칸만 "날짜 선택"', (tester) async {
      final saved = await pumpSheet(
        tester,
        _withBalance(3).copyWith(JourneyDateKey.contract, _day(-1)),
      );
      expect(find.koText('날짜 선택'), findsNWidgets(2));
      expect(saveBg(tester), AppColors.primary);
      await tester.tap(find.byKey(const ValueKey('schedule-clear-contract')));
      await tester.pumpAndSettle();
      expect(find.koText('날짜 선택'), findsNWidgets(3));
      expect(find.byKey(const ValueKey('schedule-clear-balance')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('schedule-sheet-save')));
      await tester.pumpAndSettle();
      expect(saved.single!.dates.keys, [JourneyDateKey.balance]);
    });

    testWidgets('4개 다 넣어도 · 글자 130%에서도 깨지지 않고 날짜는 한 줄', (tester) async {
      var all = const JourneySchedule();
      for (final (i, k) in JourneyDateKey.editable.indexed) {
        all = all.copyWith(k, _day(i * 3 - 2));
      }
      await pumpSheet(tester, all, textScale: 1.3);
      expect(tester.takeException(), isNull);
      for (final k in JourneyDateKey.editable) {
        final text = tester.widget<Text>(
          find.descendant(
            of: find.byKey(ValueKey('schedule-date-${k.name}')),
            matching: find.byType(Text),
          ),
        );
        expect(text.maxLines, 1, reason: k.name);
      }
    });

    testWidgets('시트 안 글자는 15 / 17 / 18 / 24만 쓴다', (tester) async {
      await pumpSheet(tester, _withBalance(3));
      final sizes = <double>{
        for (final t in tester.widgetList<Text>(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Text),
          ),
        ))
          if (t.style?.fontSize != null) t.style!.fontSize!,
      };
      expect(sizes.difference({15, 17, 18, 24}), isEmpty, reason: '$sizes');
    });

    test('알림 시각은 그대로 — 모든 일정 오전 8시', () {
      final plan = planJourneyReminders(
        propertyKey: 'k',
        alias: '',
        schedule: _withBalance(10).copyWith(JourneyDateKey.moveIn, _day(11)),
        now: DateTime.now(),
      );
      expect(plan, isNotEmpty);
      expect(plan.map((r) => r.fireAt.hour).toSet(), {8});
    });
  });

  group('알림을 꺼 둔 사람을 위한 배너', () {
    final report = AnalysisReport(
      id: 'r-jeongja',
      alias: '정자동 빌라',
      address: '경기 성남시 분당구 정자동 456-7',
      analyzedAt: DateTime.now().subtract(const Duration(hours: 2)),
      registryViewedAt: formatDate(
        DateTime.now().subtract(const Duration(days: 3)),
      ),
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

    Future<void> pumpTimeline(
      WidgetTester tester,
      JourneySchedule schedule,
    ) async {
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
            Provider<ContentRepository>(
              create: (_) => DummyContentRepository(),
            ),
            ChangeNotifierProvider<JourneyScheduleStore>.value(
              value: JourneyScheduleStore.instance,
            ),
            ChangeNotifierProvider<JourneyProgressStore>.value(
              value: JourneyProgressStore.instance,
            ),
          ],
          child: MaterialApp(
            theme: buildAppTheme(),
            home: const JourneyScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // 2026-10-27 홈_종버튼_시안: 여정 화면 안에도 큰 배너를 띄우지 않는다 — 그날은 단계 칩 D-day·리포트 카드 회색 띠로
    testWidgets('잔금 당일에도 여정 화면에 큰 배너가 없다', (tester) async {
      await pumpTimeline(tester, _withBalance(0));
      expect(find.koTextContaining('오늘이 잔금일이에요'), findsNothing);
      expect(find.koTextContaining('돈을 보내기 직전에'), findsNothing);
    });

    testWidgets('입주 다음 날에도 큰 배너가 없다', (tester) async {
      await pumpTimeline(
        tester,
        const JourneySchedule().copyWith(JourneyDateKey.moveIn, _day(-1)),
      );
      expect(find.koTextContaining('오늘은 입주 다음 날이에요'), findsNothing);
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
