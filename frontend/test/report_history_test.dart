/// 같은 집 덮어쓰기 + 이전 리포트 (2026-10-26, 그림 ⑭~⑯) + 꾹 눌러 [챗봇에 묻기].
///
///   ① 같은 집(주소, 띄어쓰기 무시)은 목록에 최신 1개만 — 별칭·보증금이 달라도 같은 집이다.
///   ② 리포트 앱바의 시계 버튼 → '이전 리포트' 시트(보는 중 · 첫 분석 · 최근 5건 안내).
///   ③ 지난 리포트를 열면 진한 띠 "○월 ○일자 지난 리포트" + [최신 보기].
///   ④ 리포트·여정·판례의 글자를 꾹 누르면 [복사][챗봇에 묻기] → 고른 글이 챗봇 인용으로 간다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeonse_ai/design_system/text/app_text.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/models/property_reports.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/common/ask_selection.dart';
import 'package:jeonse_ai/screens/report/report_history_sheet.dart';
import 'package:jeonse_ai/screens/report/report_screen.dart';
import 'package:jeonse_ai/state/chat_handoff.dart';
import 'package:jeonse_ai/state/journey_key_migration.dart';
import 'package:jeonse_ai/state/journey_progress_store.dart';
import 'package:jeonse_ai/state/journey_schedule_store.dart';
import 'package:jeonse_ai/utils/money_format.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';

AnalysisReport _r(
  String id, {
  required int daysAgo,
  String alias = '성산동 행복아파트',
  String address = '서울 마포구 성산동 100-1',
  RiskGrade grade = RiskGrade.ok,
  String? propertyId,
}) {
  final at = DateTime.now().subtract(Duration(days: daysAgo));
  return AnalysisReport(
    id: id,
    alias: alias,
    address: address,
    analyzedAt: at,
    registryViewedAt: formatDate(at),
    propertyId: propertyId,
    grade: grade,
    headline: '큰 위험 신호는 보이지 않았어요',
    nextAction: '직접 확인',
    topRiskSummary: '예시',
    deposit: 240000000,
    marketPrice: null,
    seniorDebtAmount: 0,
    gaugeProgress: 0.3,
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

  @override
  Future<CompareResult> compareRegistry(String id, List<String> paths) =>
      throw UnimplementedError();
}

final _latest = _r('v3', daysAgo: 0, alias: '행복아파트 새 별칭');
final _mid = _r('v2', daysAgo: 27);
final _first = _r('v1', daysAgo: 73, grade: RiskGrade.caution);
final _other = _r('x1', daysAgo: 5, alias: '다른 집', address: '서울 마포구 성산동 200-9');

Future<void> _pumpReport(WidgetTester tester, String id) async {
  tester.view.physicalSize = const Size(360 * 3, 1600 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: '/report/$id',
    routes: [
      GoRoute(
        path: '/report/:id',
        builder: (_, s) => ReportScreen(
          key: ValueKey(s.pathParameters['id']),
          reportId: s.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/chatbot',
        builder: (_, _) => const Scaffold(body: Text('챗봇 화면')),
      ),
    ],
  );
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AnalysisRepository>.value(
          value: _Repo([_latest, _other, _mid, _first]),
        ),
        Provider<ContentRepository>(create: (_) => DummyContentRepository()),
      ],
      child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    JourneyProgressStore.instance.resetForTest();
    ChatHandoff.pending.value = null;
  });

  group('같은 집 묶기', () {
    test('주소가 같으면(띄어쓰기 무시) 한 집 — 목록엔 최신 1개, 별칭은 최신 값', () {
      final spaced = _r('v0', daysAgo: 90, address: '서울  마포구 성산동  100-1');
      final groups = groupByProperty([_latest, _other, _mid, _first, spaced]);
      expect(groups.length, 2);
      expect(groups.first.alias, '행복아파트 새 별칭');
      expect(groups.first.reports.map((r) => r.id), ['v3', 'v2', 'v1', 'v0']);
      expect(
        latestPerProperty([_latest, _other, _mid, _first]).map((r) => r.id),
        ['v3', 'x1'],
      );
      expect(
        versionsOf(_mid, [_latest, _other, _mid, _first]).map((r) => r.id),
        ['v3', 'v2', 'v1'],
      );
    });

    test('주소가 달리 읽혀도(도로명 병기) 같은 집 — 실기기 2026-10-27', () {
      final a = _r(
        'a',
        daysAgo: 0,
        alias: '위험한 집',
        address: '서울특별시 서초구 서초동 1557-8 주건축물 제1동',
      );
      final b = _r(
        'b',
        daysAgo: 1,
        alias: '서초동 1557-8',
        address: '서울특별시 서초구 서초동 1557-8 주건축물 제1동 [도로명주소] 서울특별시 서초구 반포대로26길 35',
      );
      expect(groupByProperty([a, b]).single.alias, '위험한 집');
    });

    test('고유번호가 같으면 주소가 달라도 한 집, 다르면 주소가 같아도 다른 집', () {
      final a = _r(
        'a',
        daysAgo: 0,
        address: '서초동 1557-8',
        propertyId: '11011996123456',
      );
      final b = _r(
        'b',
        daysAgo: 1,
        address: '전혀 다르게 읽힌 주소',
        propertyId: '11011996123456',
      );
      final c = _r(
        'c',
        daysAgo: 2,
        address: '서초동 1557-8',
        propertyId: '11011996999999',
      );
      final d = _r('d', daysAgo: 3, address: '서초동 1557-8'); // 고유번호를 못 읽음 → 주소로
      final groups = groupByProperty([a, b, c, d]);
      expect(groups.map((g) => g.reports.map((r) => r.id).toList()), [
        ['a', 'b', 'd'],
        ['c'],
      ]);
      expect(groups.first.key, '고유번호:11011996123456');
      expect(groups.first.legacyKeys, contains('서초동1557-8'));
    });

    test('주소를 못 읽은 리포트끼리는 묶지 않는다', () {
      final u1 = _r('u1', daysAgo: 0, address: '주소 미확인 (등기부 원본 확인 필요)');
      final u2 = _r('u2', daysAgo: 1, address: '주소 미확인 (등기부 원본 확인 필요)');
      expect(groupByProperty([u1, u2]).length, 2);
    });

    test('예전 열쇠로 넣어 둔 잔금일이 새 열쇠로 옮겨진다', () async {
      final schedules = JourneyScheduleStore.instance..resetForTest();
      final old = _r('o', daysAgo: 3, address: '서울 서초구 서초동 1557-8');
      final now = _r(
        'n',
        daysAgo: 0,
        address: '서울 서초구 서초동 1557-8',
        propertyId: '11011996123456',
      );
      await schedules.save(
        journeyPropertyKey(old.address),
        JourneySchedule(
          dates: {JourneyDateKey.balance: DateTime(2026, 11, 20)},
        ),
      );
      await schedules.select(journeyPropertyKey(old.address));
      final props = groupByProperty([now, old]);
      adoptLegacyPropertyKeys(props);
      await pumpEventQueue();
      expect(
        schedules.scheduleFor('고유번호:11011996123456').balance,
        DateTime(2026, 11, 20),
      );
      expect(
        schedules.scheduleFor(journeyPropertyKey(old.address)).isEmpty,
        isTrue,
      );
      expect(schedules.selectedPropertyKey, '고유번호:11011996123456');
    });

    test('같은 집은 최근 5건까지만', () {
      final many = [for (int i = 0; i < 7; i++) _r('m$i', daysAgo: i)];
      expect(groupByProperty(many).single.reports.length, kKeepReportVersions);
    });

    test('이전 리포트 아랫줄 — 첫 분석 · 대조 기록이 있으면 변동 없음/변동 N건', () async {
      expect(versionSubline(_first, isFirst: true), endsWith('· 첫 분석'));
      await JourneyProgressStore.instance.addCompare(
        'k',
        CompareLogEntry(at: DateTime.now(), changedCount: 0, reportId: 'v2'),
      );
      expect(versionSubline(_mid, isFirst: false), endsWith('· 변동 없음'));
      expect(versionSubline(_latest, isFirst: false), isNot(contains('변동')));
    });
  });

  group('리포트 화면', () {
    testWidgets('시계 버튼 → 이전 리포트 시트 (보는 중 · 첫 분석 · 최근 5건)', (tester) async {
      await _pumpReport(tester, 'v3');
      expect(
        find.byKey(const ValueKey('past-report-band')),
        findsNothing,
        reason: '최신 리포트엔 띠가 없다',
      );
      await tester.tap(find.byKey(const ValueKey('report-history-button')));
      await tester.pumpAndSettle();
      expect(find.koText('이전 리포트'), findsOneWidget);
      expect(find.koText('새 등기부로 분석할 때마다 위에 쌓여요'), findsOneWidget);
      expect(find.byKey(const ValueKey('report-version-v3')), findsOneWidget);
      expect(find.byKey(const ValueKey('report-version-v2')), findsOneWidget);
      expect(find.byKey(const ValueKey('report-version-v1')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('report-version-x1')),
        findsNothing,
        reason: '다른 집은 안 나온다',
      );
      expect(find.koText('보는 중'), findsOneWidget);
      expect(find.koTextContaining('첫 분석'), findsOneWidget);
      expect(find.koTextContaining('까지만 남아요'), findsOneWidget);
      // 지난 리포트를 고르면 그 리포트로 (쌓지 않고 바꿔 끼운다)
      await tester.tap(find.byKey(const ValueKey('report-version-v1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('past-report-band')), findsOneWidget);
      expect(find.koTextContaining('지난 리포트'), findsOneWidget);
    });

    testWidgets('지난 리포트 → [최신 보기]면 최신 리포트로', (tester) async {
      await _pumpReport(tester, 'v2');
      expect(find.byKey(const ValueKey('past-report-band')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('past-report-latest')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('past-report-band')), findsNothing);
      expect(find.koText('행복아파트 새 별칭'), findsWidgets);
    });

    testWidgets('글자를 꾹 누르면 [복사][챗봇에 묻기] → 고른 글이 챗봇 인용으로 간다', (tester) async {
      await _pumpReport(tester, 'v3');
      final headline = find.koText('큰 위험 신호는 보이지 않았어요').first;
      await tester.longPressAt(
        tester.getTopLeft(headline) + const Offset(12, 12),
      );
      await tester.pumpAndSettle();
      expect(find.koText('복사'), findsOneWidget);
      expect(find.koText(AskSelectionArea.askLabel), findsOneWidget);
      await tester.tap(find.koText(AskSelectionArea.askLabel));
      await tester.pumpAndSettle();
      expect(find.text('챗봇 화면'), findsOneWidget);
      expect(ChatHandoff.pending.value, isNotNull);
      expect(ChatHandoff.pending.value, '큰');
    });
  });

  testWidgets('AskSelectionArea — 꾹 누른 자리의 어절이 골라진다 (왼쪽 전체가 잡히지 않는다)', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(
            body: AskSelectionArea(
              child: SizedBox(
                width: 320,
                child: AppText('근저당은 집을 담보로 빌린 돈이에요', key: ValueKey('t')),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/chatbot',
          builder: (_, _) => const Scaffold(body: Text('챗봇 화면')),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    final box = tester.getRect(find.byKey(const ValueKey('t')));
    await tester.longPressAt(Offset(box.left + box.width * 0.6, box.center.dy));
    await tester.pumpAndSettle();
    await tester.tap(find.koText(AskSelectionArea.askLabel));
    await tester.pumpAndSettle();
    final picked = ChatHandoff.pending.value!;
    expect(picked.contains(' '), isFalse, reason: '어절 하나: $picked');
    expect(
      picked,
      isNot(startsWith('근저당은')),
      reason: '누른 자리보다 왼쪽이 통째로 잡히면 안 된다',
    );
  });
}
