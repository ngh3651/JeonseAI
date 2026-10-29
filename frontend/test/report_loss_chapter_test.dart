/// 리포트 2장 '손실 시뮬레이터' (2026-10-29 확정안 A2).
///
/// ① 「2 / 5」 · 회색 '실제 경매 통계' 칩 · 제목 ② 서버 계산 그대로(0원 · 못 받음 1억원)
/// ③ 시세가 없으면 같은 카드에 안내 ④ 다음 행동 칸에서는 빠졌다 
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/loss_estimate.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/screens/report/report_screen.dart';
import 'package:provider/provider.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneWidth, kPhoneHeight;

class _Repo extends DummyAnalysisRepository {
  _Repo(this.est);
  final LossEstimate? est;
  @override
  Future<LossEstimate?> getLossEstimate(String reportId, {int? marketPrice}) async => est;
}

Future<void> _pump(WidgetTester tester, LossEstimate? est, {double scale = 1}) async {
  tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    ChangeNotifierProvider<AnalysisRepository>(
      create: (_) => _Repo(est),
      child: MaterialApp(theme: buildAppTheme(), home: const ReportScreen(reportId: 'dummy-danger')),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('loss-chapter-more')),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

const _zero = LossEstimate(
  status: LossStatus.ok,
  deposit: 100000000,
  basePrice: 572600000,
  seniorDebt: 1400000000,
  ratePct: 70.9,
  expectedSale: 405869020,
  expectedReturn: 0,
  expectedLoss: 100000000,
);

void main() {
  testWidgets('머리 · 서버 계산 그대로', (tester) async {
    await _pump(tester, _zero);
    expect(find.koText('2 / 5'), findsOneWidget);
    expect(find.koText('실제 경매 통계'), findsOneWidget);
    expect(find.koText('경매로 넘어가면'), findsOneWidget);
    expect(find.byKey(const ValueKey('loss-chapter-bar')), findsOneWidget);
    expect(find.koTextContaining('1억원'), findsWidgets);
    expect(find.byKey(const ValueKey('loss-chapter-more')), findsOneWidget);
  });

  testWidgets('시세가 없으면 같은 카드에 안내', (tester) async {
    await _pump(tester, const LossEstimate(status: LossStatus.noPrice, deposit: 1));
    expect(find.koText('매매 시세를 넣으면 계산돼요'), findsOneWidget);
  });

  testWidgets('못 받아오면 그렇게 말한다', (tester) async {
    await _pump(tester, null);
    expect(find.koText('불러오지 못했어요'), findsOneWidget);
  });

  testWidgets('다음 행동 칸에는 손실 시뮬레이터가 없다', (tester) async {
    await _pump(tester, _zero);
    await tester.scrollUntilVisible(
      find.koText('계약 여정'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.koText('손실 시뮬레이터'), findsOneWidget, reason: '2장 제목 하나뿐');
  });

  testWidgets('글자 130%에서도 넘치지 않는다', (tester) async {
    await _pump(tester, _zero, scale: 1.3);
    expect(tester.takeException(), isNull);
  });
}
