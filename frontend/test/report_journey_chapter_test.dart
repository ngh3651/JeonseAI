/// 리포트 5장 '계약 여정' (2026-10-30 R2 — 다음 행동 칸의 마지막 한 줄이 장으로 올라왔다).
///
/// 못 박는 것:
///   ① 머리 「5 / 5 · 날짜 알림 · 등기 변동 확인」 + "계약 여정" · '다음 행동' 제목은 없다
///   ② 띠 = 여정의 다음 단계(체크 안 된 첫 단계) — 날짜 없으면 이름만, 있으면 · 날짜 + D-day
///   ③ 여정에서 체크·날짜를 바꾸면 이 장이 **그 자리에서** 바뀐다 (가계약금·계약서 체크 → 잔금)
///   ④ 그 단계 할 일을 모두 · [자세히 ⌄]는 없다 · 알림 문장은 없다
///   ⑤ 360dp · 글자 130%에서 넘치지 않는다
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/journey/journey_logic.dart';
import 'package:jeonse_ai/screens/journey/journey_parts.dart';
import 'package:jeonse_ai/screens/report/journey_chapter.dart';
import 'package:jeonse_ai/screens/report/report_screen.dart';
import 'package:jeonse_ai/state/journey_progress_store.dart';
import 'package:jeonse_ai/state/journey_schedule_store.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneWidth, kPhoneHeight;

late List<JourneyStage> _stages;

DateTime _day(int offset) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day + offset);
}

Future<void> _pump(WidgetTester tester, {double scale = 1}) async {
  tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AnalysisRepository>(
          create: (_) => DummyAnalysisRepository(),
        ),
        Provider<ContentRepository>(create: (_) => DummyContentRepository()),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const ReportScreen(reportId: 'dummy-danger'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('journey-chapter-more')),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

String _key(WidgetTester tester) =>
    tester.widget<JourneyChapter>(find.byType(JourneyChapter)).propertyKey;

String _bandTitle(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('journey-chapter-title')),
        matching: find.byType(Text),
      ),
    )
    .data!
    .replaceAll('\u2060', ''); // AppText가 넣는 줄바꿈 막이 글자

void main() {
  setUpAll(() async {
    _stages = await DummyContentRepository().journeyStages();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    JourneyScheduleStore.instance.resetForTest();
    JourneyProgressStore.instance.resetForTest();
  });

  testWidgets('① 머리 · 다음 행동 제목 없음', (tester) async {
    await _pump(tester);
    expect(find.koText('5 / 5'), findsOneWidget);
    expect(find.koText('날짜 알림'), findsOneWidget);
    expect(find.koText('등기 변동 확인'), findsOneWidget);
    expect(find.koText('계약 여정'), findsOneWidget);
    expect(find.koText('다음 행동'), findsNothing);
    expect(find.byKey(const ValueKey('report-action-journey')), findsNothing);
  });

  testWidgets('② 날짜 없으면 다음 단계 이름만 — 분석 직후 = 가계약금 보내기 전', (tester) async {
    await _pump(tester);
    expect(find.koText('다음 일정'), findsOneWidget);
    expect(_bandTitle(tester), _stages[1].title);
    expect(find.byKey(const ValueKey('journey-chapter-dday')), findsNothing);
    expect(find.koTextContaining('단계 중'), findsNothing);
  });

  testWidgets('③ 여정에서 가계약금·계약서를 체크하면 그 자리에서 잔금으로, 날짜를 넣으면 D-day', (
    tester,
  ) async {
    await _pump(tester);
    final key = _key(tester);
    await JourneyProgressStore.instance.setCheckedThrough(key, 2);
    await tester.pumpAndSettle();
    expect(_bandTitle(tester), _stages[3].title);

    await JourneyScheduleStore.instance.save(
      key,
      const JourneySchedule().copyWith(JourneyDateKey.balance, _day(8)),
    );
    await tester.pumpAndSettle();
    expect(_bandTitle(tester), '${_stages[3].title} · ${slashDate(_day(8))}');
    expect(find.koText('D-8'), findsOneWidget);

    // 여정 화면과 같은 계산 — 같은 단계
    final p = JourneyProgress.forProperty(_stages, key);
    expect(p.headlineIndex, 3);
  });

  testWidgets('④ 할 일 모두 · 자세히 버튼·알림 문장 없음', (tester) async {
    await _pump(tester);
    final rows = find.descendant(
      of: find.byKey(const ValueKey('report-chapter-journey')),
      matching: find.byType(JourneyItemRow),
    );
    expect(rows, findsNWidgets(_stages[1].items.length));
    expect(find.koText('외 2개'), findsNothing);
    expect(find.koText('더 챙기면 좋은 것'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('report-chapter-journey')),
        matching: find.koText('자세히'),
      ).hitTestable(),
      findsNothing,
      reason: '자리만 남고 보이지 않는다',
    );
    expect(find.koTextContaining('오전 8시'), findsNothing);
  });

  testWidgets('⑤ 글자 130%에서도 넘치지 않는다', (tester) async {
    await _pump(tester, scale: 1.3);
    expect(tester.takeException(), isNull);
  });
}
