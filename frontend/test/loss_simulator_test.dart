/// 손실 시뮬레이터 (2026-10-28 1단계) — 지역·용도 매각가율 · 슬라이더·보증보험 없음 · 빚>집값 · 시세 없음.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/loss_estimate.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/screens/simulator/loss_simulator_screen.dart';
import 'package:provider/provider.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneHeight, kPhoneWidth;

final _report = AnalysisReport(
  id: 'r1',
  alias: '서초동 빌라',
  address: '서울 서초구 서초동 1557-8',
  analyzedAt: DateTime(2026, 10, 28),
  grade: RiskGrade.danger,
  headline: 'h',
  nextAction: 'n',
  topRiskSummary: 't',
  deposit: 150000000,
  marketPrice: 400000000,
  seniorDebtAmount: 200000000,
  gaugeProgress: 0.9,
  evidences: const [],
);

class _Repo extends AnalysisRepository {
  _Repo(this.est);
  final LossEstimate? est;
  @override
  Future<AnalysisReport> analyze(AnalysisRequest request) async => _report;
  @override
  Future<List<AnalysisReport>> getHistory() async => [_report];
  @override
  Future<AnalysisReport?> getReport(String id) async => _report;
  @override
  Future<void> deleteReport(String id) async {}
  @override
  Future<CompareResult> compareRegistry(String id, List<String> p) => throw UnimplementedError();
  @override
  Future<LossEstimate?> getLossEstimate(String id) async => est;
}

const _ok = LossEstimate(
  status: LossStatus.ok,
  deposit: 150000000,
  basePrice: 400000000,
  seniorDebt: 200000000,
  ratePct: 75.0,
  region: '서울',
  use: '연립다세대',
  soldCount: 4808,
  period: '2025.11~2026.10',
  source: '대법원 법원경매정보 매각통계',
  expectedSale: 300000000,
  expectedReturn: 100000000,
  expectedLoss: 50000000,
);

Future<void> _pump(WidgetTester t, LossEstimate? est, {double scale = 1}) async {
  t.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  await t.pumpWidget(
    ChangeNotifierProvider<AnalysisRepository>.value(
      value: _Repo(est),
      child: MaterialApp(theme: buildAppTheme(), home: LossSimulatorScreen(key: UniqueKey(), reportId: 'r1')),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('계산함 — 돌려받을 돈 · 막대 · 계산 4줄 · 근거(지역·용도·기간·건수·출처)', (t) async {
    await _pump(t, _ok);
    expect(find.koText('1억원'), findsWidgets);
    expect(find.byKey(const ValueKey('loss-bar')), findsOneWidget);
    expect(find.koText('75%'), findsOneWidget);
    expect(find.koText('− 2억원'), findsOneWidget);
    expect(find.koTextContaining('서울 · 연립다세대 매각가율'), findsOneWidget);
    expect(find.koTextContaining('4,808건'), findsOneWidget);
    expect(find.koTextContaining('대법원 법원경매정보'), findsOneWidget);
    // 넣지 않은 것을 나열하지 않는다 (2026-10-28 규혁)
    expect(find.koTextContaining('최우선변제'), findsNothing);
    expect(find.koTextContaining('빠져 있어요'), findsNothing);
  });

  testWidgets('슬라이더·보증보험·예시 배너가 없다', (t) async {
    await _pump(t, _ok);
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.koTextContaining('보증보험'), findsNothing);
    expect(find.koTextContaining('예시'), findsNothing);
  });

  testWidgets('전국 값이면 근거에 "전국" · 용도를 모르면 "보수적으로" 한 줄', (t) async {
    await _pump(
      t,
      const LossEstimate(
        status: LossStatus.ok,
        deposit: 1,
        basePrice: 1,
        ratePct: 71.7,
        region: '전국',
        regionFallback: true,
        use: '오피스텔',
        useGuessed: true,
        expectedReturn: 0,
        expectedLoss: 1,
      ),
    );
    expect(find.koTextContaining('전국 · 오피스텔 매각가율'), findsOneWidget);
    expect(find.koText(kLossConservativeLine), findsOneWidget);
  });

  testWidgets('빚이 집값보다 크면 계산 대신 두 칸과 한 문장', (t) async {
    await _pump(
      t,
      const LossEstimate(
        status: LossStatus.debtExceeds,
        deposit: 150000000,
        basePrice: 572600000,
        seniorDebt: 1900000000,
        expectedReturn: 0,
        expectedLoss: 150000000,
      ),
    );
    expect(find.koText('돌려받기 어려워요'), findsOneWidget);
    expect(find.koText('19억원'), findsOneWidget);
    expect(find.byKey(const ValueKey('loss-bar')), findsNothing);
    expect(find.koTextContaining('최우선변제'), findsNothing);
  });

  testWidgets('시세가 없으면 계산하지 않는다 · 자료가 없으면 지어내지 않는다', (t) async {
    await _pump(t, const LossEstimate(status: LossStatus.noPrice, deposit: 1));
    expect(find.koText('집값을 몰라 계산할 수 없어요'), findsOneWidget);
    await _pump(t, const LossEstimate(status: LossStatus.noRate, deposit: 1));
    expect(find.koText('이 지역 경매 통계를 준비 중이에요'), findsOneWidget);
    await _pump(t, null);
    expect(find.koText('불러올 수 없어요'), findsOneWidget);
  });

  testWidgets('글자 130%에서도 깨지지 않는다', (t) async {
    await _pump(t, _ok, scale: 1.3);
    expect(t.takeException(), isNull);
  });

  test('서버 응답을 읽는다 — 모르는 상태는 자료 없음', () {
    final e = LossEstimate.fromJson({'status': 'debt_exceeds', 'deposit': 5, 'seniorDebt': 9});
    expect(e.status, LossStatus.debtExceeds);
    expect(LossEstimate.fromJson({'status': '???', 'deposit': 1}).status, LossStatus.noRate);
  });
}
