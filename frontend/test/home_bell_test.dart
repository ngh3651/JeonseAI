/// 홈 — "오늘 중요한 일정" 종 버튼 (2026-10-27 홈_종버튼_시안 ①·②).
///
///   ① 홈에 큰 잔금 배너가 없다. 오늘 일정이 있을 때만 종에 빨간 점.
///   ② 종 → 시트 "오늘 중요한 일정" — 오늘 일정만, 여러 개면 위아래로. 없으면 한 줄.
///   ③ 집 이름이 길어도 "· 잔금일"은 잘리지 않는다.
///   ④ 상자를 누르면 그 집의 계약 여정이 그날 단계가 선택된 채 열린다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/models/property_reports.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/home/home_screen.dart';
import 'package:jeonse_ai/screens/home/today_schedule_sheet.dart';
import 'package:jeonse_ai/state/app_session.dart';
import 'package:jeonse_ai/state/journey_focus.dart';
import 'package:jeonse_ai/state/journey_progress_store.dart';
import 'package:jeonse_ai/state/journey_schedule_store.dart';
import 'package:jeonse_ai/utils/money_format.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';

AnalysisReport _r(String id, {required String alias, required String address}) {
  final at = DateTime.now();
  return AnalysisReport(
    id: id,
    alias: alias,
    address: address,
    analyzedAt: at,
    registryViewedAt: formatDate(at),
    grade: RiskGrade.caution,
    headline: '확인이 필요해요',
    nextAction: '직접 확인',
    topRiskSummary: '예시',
    deposit: 200000000,
    marketPrice: null,
    seniorDebtAmount: 0,
    gaugeProgress: 0.5,
    evidences: const [],
  );
}

class _Repo extends DummyAnalysisRepository {
  _Repo(this.reports);
  final List<AnalysisReport> reports;

  @override
  Future<List<AnalysisReport>> getHistory() async => reports;
}

final _a = _r('a', alias: '성산동 행복아파트', address: '서울 마포구 성산동 100-1');
final _b = _r(
  'b',
  alias: '서초동 1557-8 주건축물 제1동 아주 아주 긴 이름의 빌라',
  address: '서울 서초구 서초동 1557-8',
);

DateTime get _today {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

Future<void> _pumpHome(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360 * 3, 800 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
      GoRoute(
        path: '/journey',
        builder: (_, _) => const Scaffold(body: Text('여정 화면')),
      ),
    ],
  );
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSession()),
        ChangeNotifierProvider<AnalysisRepository>.value(
          value: _Repo([_a, _b]),
        ),
        Provider<ContentRepository>(create: (_) => DummyContentRepository()),
        ChangeNotifierProvider<JourneyScheduleStore>.value(
          value: JourneyScheduleStore.instance,
        ),
        ChangeNotifierProvider<JourneyProgressStore>.value(
          value: JourneyProgressStore.instance,
        ),
      ],
      child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

String _key(AnalysisReport r) => groupByProperty([r]).single.key;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    JourneyScheduleStore.instance.resetForTest();
    JourneyProgressStore.instance.resetForTest();
    JourneyFocus.pending.value = null;
    TodayBellSeen.instance.resetForTest();
  });

  testWidgets('종 시트를 열어 보면 빨간 점이 꺼진다 · 새 오늘 일정이 생기면 다시 켜진다', (tester) async {
    await JourneyScheduleStore.instance.save(
      _key(_a),
      const JourneySchedule().copyWith(JourneyDateKey.balance, _today),
    );
    await _pumpHome(tester);
    expect(find.byKey(const ValueKey('home-bell-dot')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-bell')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10)); // 시트 닫기
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-bell-dot')), findsNothing);
    // 다른 집에 오늘 일정이 새로 생겼다 → 다시 켜진다
    await JourneyScheduleStore.instance.save(
      _key(_b),
      const JourneySchedule().copyWith(JourneyDateKey.moveIn, _today),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-bell-dot')), findsOneWidget);
  });

  testWidgets('오늘 일정이 없으면 빨간 점 없음 · 시트엔 한 줄만', (tester) async {
    await JourneyScheduleStore.instance.save(
      _key(_a),
      const JourneySchedule().copyWith(
        JourneyDateKey.balance,
        _today.add(const Duration(days: 1)), // 내일 — 넣지 않는다
      ),
    );
    await _pumpHome(tester);
    expect(find.byKey(const ValueKey('home-bell')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-bell-dot')), findsNothing);
    expect(
      find.koTextContaining('잔금일이 내일이에요'),
      findsNothing,
      reason: '홈에 큰 배너 없음',
    );
    await tester.tap(find.byKey(const ValueKey('home-bell')));
    await tester.pumpAndSettle();
    expect(find.koText('오늘 중요한 일정'), findsOneWidget);
    expect(find.koText('오늘은 중요한 일정이 없어요'), findsOneWidget);
    expect(find.koText('오늘 중요한 일정이 있어요'), findsNothing);
  });

  testWidgets('오늘 일정 2개 → 빨간 점 · 시트에 위아래로 · 긴 이름도 "· 계약서"는 보인다', (
    tester,
  ) async {
    await JourneyScheduleStore.instance.save(
      _key(_a),
      const JourneySchedule().copyWith(JourneyDateKey.balance, _today),
    );
    await JourneyScheduleStore.instance.save(
      _key(_b),
      const JourneySchedule().copyWith(JourneyDateKey.contract, _today),
    );
    await _pumpHome(tester);
    expect(find.byKey(const ValueKey('home-bell-dot')), findsOneWidget);
    expect(
      find.koTextContaining('오늘이 잔금일이에요'),
      findsNothing,
      reason: '홈에 큰 배너 없음',
    );
    expect(find.koText('최근 분석과 대조하기'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('home-bell')));
    await tester.pumpAndSettle();
    expect(find.koText('오늘 중요한 일정이 있어요'), findsNWidgets(2));
    final first = tester.getRect(
      find.byKey(ValueKey('today-event-${_key(_a)}-balance')),
    );
    final second = tester.getRect(
      find.byKey(ValueKey('today-event-${_key(_b)}-contract')),
    );
    expect(
      second.top - first.bottom,
      closeTo(14, 0.5),
      reason: '위아래로 쌓고 사이 14',
    );
    expect(find.koText(' · 잔금일'), findsOneWidget);
    // 긴 이름은 …으로 줄고 일정 이름은 상자 안에 다 보인다
    final label = tester.getRect(find.koText(' · 계약서'));
    expect(label.right, lessThanOrEqualTo(second.right));
    expect(label.width, greaterThan(40));
  });

  testWidgets('상자를 누르면 그 집 + 그날 단계로 여정이 열린다', (tester) async {
    await JourneyScheduleStore.instance.save(
      _key(_b),
      const JourneySchedule().copyWith(JourneyDateKey.contract, _today),
    );
    await _pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('home-bell')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('today-event-${_key(_b)}-contract')));
    await tester.pumpAndSettle();
    expect(find.text('여정 화면'), findsOneWidget);
    expect(JourneyScheduleStore.instance.selectedPropertyKey, _key(_b));
    expect(JourneyFocus.pending.value, JourneyDateKey.contract);
  });
}
