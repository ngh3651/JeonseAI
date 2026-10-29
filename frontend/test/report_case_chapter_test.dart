/// 리포트 3장 '판례 매칭' (2026-10-29 확정안 J10).
///
/// ① 「3 / 5」 · '실제 판례' · 'AI 매칭' 칩 · 제목 ② 띠 "AI가 실제 판례 중 이 집에 맞춰 고른 N건"
/// ③ 1순위 판례의 결과 문장 · 사건번호 ④ '대법원 판례'라고 부르지 않는다 ⑤ 판례가 없으면 그렇게 말한다
/// ⑥ 다음 행동 칸에서 빠졌다 ⑦ 글자 130%
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/components/app_card.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/report/report_screen.dart';
import 'package:jeonse_ai/state/case_prefetch.dart';
import 'package:provider/provider.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneWidth, kPhoneHeight;

class _Content extends DummyContentRepository {
  _Content(this.cases);
  final List<CaseMatch> cases;
  @override
  Future<List<CaseMatch>> matchedCases(String reportId) async => cases;
}

Future<void> _pump(WidgetTester tester, ContentRepository content, {double scale = 1}) async {
  CasePrefetch.clear();
  tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AnalysisRepository>(create: (_) => DummyAnalysisRepository()),
        Provider<ContentRepository>.value(value: content),
      ],
      child: MaterialApp(theme: buildAppTheme(), home: const ReportScreen(reportId: 'dummy-danger')),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('case-chapter-more')),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('머리 · 띠 · 1순위 판례', (tester) async {
    final dummy = await DummyContentRepository().matchedCases('dummy-danger');
    await _pump(tester, _Content(dummy));
    expect(find.koText('3 / 5'), findsOneWidget);
    expect(find.koText('실제 판례'), findsOneWidget);
    expect(find.koText('AI 매칭'), findsOneWidget);
    expect(find.koText('AI가 실제 판례 중 이 집에 맞춰 고른 ${dummy.length}건'), findsOneWidget);
    expect(find.koText(dummy.first.caseNo), findsOneWidget);
    expect(find.koTextContaining('대법원 판례'), findsNothing);
    expect(find.koText('자세히 보기'), findsWidgets);
  });

  testWidgets('판례가 없으면 띠 없이 그렇게 말한다', (tester) async {
    await _pump(tester, _Content(const []));
    expect(find.byKey(const ValueKey('case-chapter-band')), findsNothing);
    expect(find.koText('이 집과 연결되는 판례를 아직 찾지 못했어요'), findsOneWidget);
  });

  testWidgets('다음 행동 칸에는 판례 매칭이 없다', (tester) async {
    await _pump(tester, DummyContentRepository());
    await tester.scrollUntilVisible(
      find.koText('계약 여정'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.ancestor(of: find.koText('판례 매칭'), matching: find.byType(AppCard)),
      findsNothing,
      reason: '판례 매칭은 3장 제목으로만 있고 다음 행동 칸에는 없다',
    );
  });

  testWidgets('글자 130%에서도 넘치지 않는다', (tester) async {
    await _pump(tester, DummyContentRepository(), scale: 1.3);
    expect(tester.takeException(), isNull);
  });
}
