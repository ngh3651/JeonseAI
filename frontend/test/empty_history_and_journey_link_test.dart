/// 예시 리포트 없애기 · 리포트 [계약 여정] 버튼 (2026-10-29).
///
/// ① 서버가 기록 끝에 붙이던 예시 리포트('성산동 행복아파트')를 없앴다 → 기록이 0건이면 홈·마이가
///    **빈 화면 안내**를 띄운다(여정의 빈 화면은 `journey_timeline_test.dart` '집이 없으면…'이 본다).
/// ② 리포트의 [계약 여정]은 **그 리포트의 집** 여정을 연다 — 전에는 마지막으로 골라 둔 다른 집이 열렸다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/property_reports.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/home/home_screen.dart';
import 'package:jeonse_ai/screens/journey/journey_parts.dart';
import 'package:jeonse_ai/screens/journey/journey_screen.dart';
import 'package:jeonse_ai/screens/my/my_screen.dart';
import 'package:jeonse_ai/screens/report/report_screen.dart';
import 'package:jeonse_ai/state/app_session.dart';
import 'package:jeonse_ai/state/journey_progress_store.dart';
import 'package:jeonse_ai/state/journey_schedule_store.dart';
import 'package:jeonse_ai/utils/money_format.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneWidth, kPhoneHeight;

AnalysisReport _r(String id, {required String alias, required String address, int daysAgo = 0}) {
  final at = DateTime.now().subtract(Duration(days: daysAgo, hours: 1));
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

  @override
  Future<AnalysisReport?> getReport(String id) async =>
      reports.where((r) => r.id == id).firstOrNull;
}

List<ChangeNotifierProvider> _stores() => [
  ChangeNotifierProvider<JourneyScheduleStore>.value(
    value: JourneyScheduleStore.instance,
  ),
  ChangeNotifierProvider<JourneyProgressStore>.value(
    value: JourneyProgressStore.instance,
  ),
];

void _phone(WidgetTester tester, {double height = kPhoneHeight}) {
  tester.view.physicalSize = Size(kPhoneWidth * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    JourneyScheduleStore.instance.resetForTest();
    JourneyProgressStore.instance.resetForTest();
  });

  group('기록 0건 = 빈 화면 안내 (예시 리포트 없음)', () {
    testWidgets('홈 — "아직 분석한 매물이 없어요" + [매물 분석 시작하기]', (tester) async {
      _phone(tester);
      final router = GoRouter(
        initialLocation: '/home',
        routes: [GoRoute(path: '/home', builder: (_, _) => const HomeScreen())],
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AppSession()),
            ChangeNotifierProvider<AnalysisRepository>.value(value: _Repo(const [])),
            Provider<ContentRepository>(create: (_) => DummyContentRepository()),
            ..._stores(),
          ],
          child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.koText('아직 분석한 매물이 없어요'), findsOneWidget);
      expect(find.koText('등기부등본 사진만 있으면 바로 시작할 수 있어요'), findsOneWidget);
      expect(find.koText('매물 분석 시작하기'), findsWidgets);
      expect(find.koText('성산동 행복아파트'), findsNothing);
    });

    testWidgets('마이 — "아직 분석한 매물이 없어요" + [매물 분석 시작하기]', (tester) async {
      _phone(tester, height: 1600);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AppSession()),
            ChangeNotifierProvider<AnalysisRepository>.value(value: _Repo(const [])),
            ..._stores(),
          ],
          child: MaterialApp(theme: buildAppTheme(), home: const MyScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.koText('아직 분석한 매물이 없어요'), findsOneWidget);
      expect(find.koText('매물 분석 시작하기'), findsOneWidget);
      expect(find.koText('성산동 행복아파트'), findsNothing);
    });
  });

  group('리포트 [계약 여정] = 그 집 여정', () {
    final a = _r('r-a', alias: 'A집 정자동 빌라', address: '경기 성남시 분당구 정자동 456-7');
    final b = _r('r-b', alias: 'B집 역삼동 오피스텔', address: '서울 강남구 역삼동 123-45', daysAgo: 3);

    testWidgets('집 A를 골라 둔 채 B 리포트에서 누르면 B 여정이 열린다', (tester) async {
      _phone(tester, height: 1600);
      final keyA = groupByProperty([a]).single.key;
      final keyB = groupByProperty([b]).single.key;
      await JourneyScheduleStore.instance.select(keyA);

      final router = GoRouter(
        initialLocation: '/report/${b.id}',
        routes: [
          GoRoute(
            path: '/report/:id',
            builder: (_, s) => ReportScreen(reportId: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/checklist',
            builder: (_, _) => const JourneyScreen(showBack: true),
          ),
        ],
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AppSession()),
            ChangeNotifierProvider<AnalysisRepository>.value(value: _Repo([a, b])),
            Provider<ContentRepository>(create: (_) => DummyContentRepository()),
            ..._stores(),
          ],
          child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.koText('계약 여정'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.koText('계약 여정'));
      await tester.pumpAndSettle();

      expect(JourneyScheduleStore.instance.selectedPropertyKey, keyB);
      final house = find.byType(HouseRow);
      expect(house, findsOneWidget);
      expect(find.descendant(of: house, matching: find.koText(b.alias)), findsOneWidget);
      expect(find.descendant(of: house, matching: find.koText(a.alias)), findsNothing);
    });
  });
}
