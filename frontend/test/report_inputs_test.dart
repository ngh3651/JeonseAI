// 리포트 입력값 고치기 (2026-10-29 QA) — 같은 리포트를 고치고, 그 자리에서 새 값으로 다시 그린다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/screens/report/report_screen.dart';
import 'package:provider/provider.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneWidth, kPhoneHeight;

Map<String, dynamic> _json({
  String alias = '샘플빌라',
  int deposit = 120000000,
  bool rejudgeReady = true,
  String grade = '양호',
}) => {
  'id': 'r-edit',
  'alias': alias,
  'address': '서울특별시 샘플구 샘플동 1-1',
  'analyzedAt': '2026-10-29T10:00:00+09:00',
  'grade': grade,
  'gaugeProgress': 0.8,
  'headline': '큰 위험 신호는 보이지 않았어요',
  'nextAction': '확인하세요',
  'topRiskSummary': '전세가율 40%',
  'deposit': deposit,
  'marketPrice': 300000000,
  'marketPriceSource': 'official_price',
  'seniorDebtAmount': 0,
  'evidences': [],
  'rejudgeReady': rejudgeReady,
};

class _Repo extends DummyAnalysisRepository {
  _Repo(this.current);

  AnalysisReport current;
  ReportInputs? sent;

  @override
  Future<AnalysisReport?> getReport(String id) async => current;

  @override
  Future<List<AnalysisReport>> getHistory() async => [current];

  @override
  Future<AnalysisReport> updateInputs(
    String reportId,
    ReportInputs inputs,
  ) async {
    sent = inputs;
    current = AnalysisReport.fromJson(
      _json(alias: inputs.alias, deposit: inputs.deposit, grade: '위험'),
    );
    return current;
  }
}

Future<_Repo> _open(WidgetTester tester, Map<String, dynamic> json) async {
  tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final repo = _Repo(AnalysisReport.fromJson(json));
  await tester.pumpWidget(
    ChangeNotifierProvider<AnalysisRepository>.value(
      value: repo,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const ReportScreen(reportId: 'r-edit'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('보증금을 고치면 같은 리포트가 새 값·새 등급으로 다시 그려진다', (tester) async {
    final repo = await _open(tester, _json());
    await tester.tap(find.byKey(const ValueKey('report-edit-button')));
    await tester.pumpAndSettle();
    // 지금 값이 채워져 있다 — 시세는 자동으로 찾은 값이라 칸은 비어 있고, 비우면 그 값을 쓴다고 말한다
    expect(find.koText('12000'), findsOneWidget);
    expect(find.koTextContaining('자동으로 찾은 값'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('inputs-deposit-field')),
      '28000',
    );
    await tester.enterText(
      find.byKey(const ValueKey('inputs-alias-field')),
      '고친 집',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.koText('저장하고 다시 판정하기'));
    await tester.pumpAndSettle();

    expect(repo.sent!.deposit, 280000000);
    expect(repo.sent!.marketPrice, isNull); // 자동 시세 그대로
    expect(repo.sent!.alias, '고친 집');
    expect(find.koText('고친 집'), findsWidgets); // 앱바 제목이 바로 바뀐다
    expect(find.koText('새 값으로 다시 판정했어요'), findsOneWidget);
  });

  testWidgets('별칭만 바꾸면 "저장" — 다시 판정하지 않는다', (tester) async {
    final repo = await _open(tester, _json());
    await tester.tap(find.byKey(const ValueKey('report-edit-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('inputs-alias-field')),
      '새 이름',
    );
    await tester.pumpAndSettle();
    expect(find.koText('저장하고 다시 판정하기'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('inputs-save-button')));
    await tester.pumpAndSettle();
    expect(repo.sent!.deposit, 120000000);
    expect(find.koText('이름을 바꿨어요'), findsOneWidget);
  });

  testWidgets('고칠 재료도 사진도 없는 옛 리포트는 숫자 칸을 잠근다', (tester) async {
    await _open(tester, _json(rejudgeReady: false));
    await tester.tap(find.byKey(const ValueKey('report-edit-button')));
    await tester.pumpAndSettle();
    final TextField deposit = tester.widget(
      find.byKey(const ValueKey('inputs-deposit-field')),
    );
    expect(deposit.enabled, isFalse);
    expect(find.koTextContaining('이름만 바꿀 수 있어요'), findsOneWidget);
  });
}
