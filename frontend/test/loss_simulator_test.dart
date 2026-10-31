/// 손실 시뮬레이터 (2026-10-28 1단계) — 지역·용도 매각가율 · 슬라이더·보증보험 없음 · 빚>집값 · 시세 없음 · 매매 시세 직접 입력.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  _Repo(this.est, {this.priced});
  final LossEstimate? est;

  /// 매매 시세를 넣었을 때 돌려줄 값 — 받은 시세를 기록한다
  final LossEstimate Function(int price)? priced;
  final List<int?> asked = [];
  @override
  Future<AnalysisReport> analyze(AnalysisRequest request) async => _report;
  @override
  Future<List<AnalysisReport>> getHistory() async => [_report];
  @override
  Future<AnalysisReport?> getReport(String id) async => _report;
  @override
  Future<void> deleteReport(String id) async {}
  @override
  Future<CompareResult> compareRegistry(String id, List<String> p) =>
      throw UnimplementedError();
  @override
  Future<LossEstimate?> getLossEstimate(String id, {int? marketPrice}) async {
    asked.add(marketPrice);
    if (marketPrice != null && priced != null) return priced!(marketPrice);
    return est;
  }
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

Future<_Repo> _pump(
  WidgetTester t,
  LossEstimate? est, {
  double scale = 1,
  LossEstimate Function(int price)? priced,
}) async {
  final repo = _Repo(est, priced: priced);
  t.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  await t.pumpWidget(
    ChangeNotifierProvider<AnalysisRepository>.value(
      value: repo,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: LossSimulatorScreen(key: UniqueKey(), reportId: 'r1'),
      ),
    ),
  );
  await t.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('계산함 — 돌려받을 돈 · 막대 · 계산 4줄 · 근거(지역·용도·기간·건수·출처)', (t) async {
    await _pump(t, _ok);
    expect(find.koText('1억원'), findsWidgets);
    expect(find.byKey(const ValueKey('loss-bar')), findsOneWidget);
    expect(find.koText('75%'), findsOneWidget);
    expect(find.koText('− 2억원'), findsOneWidget);
    expect(find.koText('매매 시세'), findsOneWidget);
    expect(find.koText('4억원'), findsOneWidget);
    // 근거 세 줄 — 기준 · 기간 · 출처
    expect(find.koText('기준'), findsOneWidget);
    expect(find.koText('서울 연립다세대 매각가율 · 4,808건'), findsOneWidget);
    expect(find.koText('기간'), findsOneWidget);
    expect(find.koText('2025.11~2026.10'), findsOneWidget);
    expect(find.koText('출처'), findsOneWidget);
    expect(find.koText('대법원 법원경매정보 매각통계'), findsOneWidget);
    // 연필은 이름 옆 — 금액은 모든 줄이 같은 오른쪽 끝
    expect(find.byKey(const ValueKey('loss-price-edit')), findsOneWidget);
    final double priceRight = t.getRect(find.koText('4억원')).right;
    final double debtRight = t.getRect(find.koText('− 2억원')).right;
    expect((priceRight - debtRight).abs(), lessThan(1));
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

  testWidgets('전국 값이면 근거에 "전국" · 고른 이유는 적지 않는다', (t) async {
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
    expect(find.koTextContaining('전국 오피스텔 매각가율'), findsOneWidget);
    expect(find.koTextContaining('보수적'), findsNothing);
    expect(find.koTextContaining('가장 낮은'), findsNothing);
    expect(find.koTextContaining('못 찾'), findsNothing);
  });

  testWidgets('빚이 집값보다 커도 같은 화면 — 0원 · 못 받음 = 보증금 · 낙찰가 줄 없음', (t) async {
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
    expect(find.byKey(const ValueKey('loss-hero')), findsOneWidget);
    expect(find.koText('0원'), findsWidgets);
    expect(find.koText('1억 5,000만원'), findsOneWidget);
    expect(find.koText('− 19억원'), findsOneWidget);
    expect(find.koText('경매 낙찰가'), findsNothing);
    expect(find.koTextContaining('최우선변제'), findsNothing);
  });

  testWidgets('시세가 없으면 같은 화면 — 회색 막대 · [입력하기] · 넣으면 바로 계산 (리포트는 그대로)', (
    t,
  ) async {
    final repo = await _pump(
      t,
      const LossEstimate(
        status: LossStatus.noPrice,
        deposit: 150000000,
        seniorDebt: 200000000,
        ratePct: 75.0,
        region: '서울',
        use: '연립다세대',
        soldCount: 4808,
      ),
      priced: (p) => LossEstimate(
        status: LossStatus.ok,
        deposit: 150000000,
        basePrice: p,
        seniorDebt: 200000000,
        ratePct: 75.0,
        region: '서울',
        use: '연립다세대',
        soldCount: 4808,
        expectedSale: p * 3 ~/ 4,
        expectedReturn: 100000000,
        expectedLoss: 50000000,
      ),
    );
    expect(find.koText(kLossNeedPrice), findsOneWidget);
    expect(find.byKey(const ValueKey('loss-bar-idle')), findsOneWidget);
    expect(find.byKey(const ValueKey('loss-bar')), findsNothing);
    expect(find.koText('입력하기'), findsOneWidget);
    expect(find.koText('75%'), findsOneWidget);
    expect(find.koText('− 2억원'), findsOneWidget);
    expect(find.koTextContaining('못 찾'), findsNothing);
    expect(find.koTextContaining('직접 입력'), findsNothing);

    await t.tap(find.koText('입력하기'));
    await t.pumpAndSettle();
    expect(find.koText('매매 시세'), findsWidgets);
    await t.enterText(find.byKey(const ValueKey('loss-price-field')), '40000');
    await t.pump();
    expect(find.koText('= 4억원'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('loss-price-apply')));
    await t.pumpAndSettle();

    expect(repo.asked.last, 400000000);
    expect(find.koText(kLossNeedPrice), findsNothing);
    expect(find.byKey(const ValueKey('loss-bar')), findsOneWidget);
    expect(find.koText('4억원'), findsOneWidget);
    expect(find.koText('3억원'), findsOneWidget);

    // 고치기 — 연필 줄을 누르면 지금 값이 들어 있다
    await t.tap(find.byKey(const ValueKey('loss-price-row')));
    await t.pumpAndSettle();
    expect(find.text('40000'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('loss-price-field')), '30000');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('loss-price-apply')));
    await t.pumpAndSettle();
    expect(repo.asked.last, 300000000);
    expect(find.koText('3억원'), findsOneWidget);
  });

  testWidgets('자료가 없으면 지어내지 않는다', (t) async {
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
    final e = LossEstimate.fromJson({
      'status': 'debt_exceeds',
      'deposit': 5,
      'seniorDebt': 9,
    });
    expect(e.status, LossStatus.debtExceeds);
    expect(
      LossEstimate.fromJson({'status': '???', 'deposit': 1}).status,
      LossStatus.noRate,
    );
  });

  // 실제 앱 글꼴(Pretendard)로 잰다 — 테스트 기본 글꼴은 글자마다 1em이라 실제보다 훨씬 넓다. 파일 맨 끝 묶음이라 다른 테스트에 영향 없음
  group('최우선변제 한 줄 (실제 글꼴)', () {
    setUpAll(() async {
      final loader = FontLoader('Pretendard');
      for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        loader.addFont(rootBundle.load('assets/fonts/Pretendard-$w.otf'));
      }
      await loader.load();
    });

    // 2026-10-31 규혁 — 못 받으면 '0원'(빨강)으로 통일, 아래 한 줄은 글자를 줄이지 않고 한 줄에, 지역·기준일은 '법령' 근거로
    testWidgets('최우선변제 — 보증금이 커서 못 받으면 0원 · 한 줄 · 지역은 법령 줄에', (t) async {
      await _pump(
        t,
        const LossEstimate(
          status: LossStatus.ok,
          deposit: 200000000,
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
          expectedLoss: 100000000,
          priorityStatus: PriorityStatus.overCap,
          priorityCap: 150000000,
          priorityRegion: '서울특별시',
          priorityTableFrom: '2021-05-11',
          priorityBaseDate: '2022-04-15',
          priorityBaseKind: '근저당',
          prioritySource: '주택임대차보호법 시행령 제10·11조',
        ),
      );
      final row = find.byKey(const ValueKey('loss-priority-row'));
      expect(
        find.descendant(of: row, matching: find.koText('0원')),
        findsOneWidget,
      );
      expect(find.koTextContaining('대상 아님'), findsNothing);
      final sub = find.byKey(const ValueKey('loss-priority-sub'));
      expect(
        find.descendant(
          of: sub,
          matching: find.koText('보증금 1억 5,000만원 이하만 받아요'),
        ),
        findsOneWidget,
      );
      // 한 줄 — 글자 높이 두 배보다 낮다
      final double h = t.getSize(sub).height;
      final double fs =
          (t
              .widget<RichText>(
                find.descendant(of: sub, matching: find.byType(RichText)).first,
              )
              .text
              .style
              ?.fontSize) ??
          14;
      expect(h, lessThan(fs * 2.2), reason: '한 줄에 들어간다');
      expect(
        find.koTextContaining('서울특별시 · 2022.4.15 근저당 기준'),
        findsOneWidget,
        reason: '지역·기준일은 법령 근거 줄',
      );
      expect(
        find.descendant(of: sub, matching: find.koTextContaining('서울특별시')),
        findsNothing,
      );
    });

    testWidgets('최우선변제 — 경매가 시작된 집은 0원 · 한 줄', (t) async {
      await _pump(
        t,
        const LossEstimate(
          status: LossStatus.ok,
          deposit: 100000000,
          basePrice: 400000000,
          seniorDebt: 200000000,
          ratePct: 75.0,
          region: '서울',
          use: '연립다세대',
          expectedSale: 300000000,
          expectedReturn: 100000000,
          expectedLoss: 0,
          priorityStatus: PriorityStatus.blockedAuction,
          prioritySource: '주택임대차보호법 시행령 제10·11조',
        ),
      );
      final sub = find.byKey(const ValueKey('loss-priority-sub'));
      expect(
        find.descendant(of: sub, matching: find.koText('경매 전에 입주한 세입자만 받아요')),
        findsOneWidget,
      );
      final double fs =
          (t
              .widget<RichText>(
                find.descendant(of: sub, matching: find.byType(RichText)).first,
              )
              .text
              .style
              ?.fontSize) ??
          14;
      expect(t.getSize(sub).height, lessThan(fs * 2.2));
    });
  });
}
