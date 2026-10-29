/// S-07 리포트 하단 '다음 행동' (2026-08-14 D12 → 2026-10-29).
///
/// 예전 2×2 그리드의 칸이 리포트 장으로 올라갔다 — 손실 → 2장, 판례 → 3장, **질문 → 4장**.
/// 이 파일이 못 박는 것:
///   ① 다음 행동에는 **계약 여정 한 줄**만 남는다(등급과 무관)
///   ② '중개사에게 물어볼 질문'은 다음 행동 칸이 아니라 4장 제목으로 **한 번만** 보인다
///   ③ 360dp에서 넘치지 않는다(위젯 테스트는 넘치면 스스로 실패한다)
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/report/report_screen.dart';
import 'package:provider/provider.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneWidth, kPhoneHeight;

Future<void> _pumpReport(WidgetTester tester, String reportId) async {
  tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AnalysisRepository>(create: (_) => DummyAnalysisRepository()),
        Provider<ContentRepository>(create: (_) => DummyContentRepository()),
      ],
      child: MaterialApp(theme: buildAppTheme(), home: ReportScreen(reportId: reportId)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('report-action-journey')),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final id in const ['dummy-danger', 'dummy-caution']) {
    testWidgets('[$id] 다음 행동은 계약 여정 한 줄', (tester) async {
      await _pumpReport(tester, id);
      expect(find.byKey(const ValueKey('report-action-journey')), findsOneWidget);
      expect(find.koText('계약 여정'), findsOneWidget);
      // 질문은 4장 제목 하나뿐 — 다음 행동 칸에 또 있으면 같은 입구가 둘이 된다
      expect(find.koText('중개사에게 물어볼 질문').evaluate().length, lessThanOrEqualTo(1));
      expect(find.koText('질문 생성기'), findsNothing);
      expect(find.koText('체크리스트'), findsNothing);
    });
  }

  testWidgets('계약 여정 줄은 화면 폭을 다 쓴다 (360dp)', (tester) async {
    await _pumpReport(tester, 'dummy-danger');
    final size = tester.getSize(find.byKey(const ValueKey('report-action-journey')));
    // 360dp 화면 - 화면패딩 40 = 320dp
    expect(size.width, closeTo(320, 0.5));
  });
}
