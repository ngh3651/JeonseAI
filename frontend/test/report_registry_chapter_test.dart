/// 리포트 1장 '등기부에서 찾은 것' (2026-10-28 리포트 2안 → 1장 다듬기).
///
/// 못 박는 것:
///   ① 머리: 「1 / 5」 · 「AI 분석」 칩 · 제목 — 예전 '근거 살펴보기' 제목·안내 줄은 없다
///   ② 사진 카드(내가 올린 사진에서 보기)와 근거 카드가 **따로**, 사진 카드가 위, 사이에 요약 한 줄
///   ③ 근거는 위험 → 확인 필요 → 양호 순, 한 줄 아래에 "등급 · 부제"
///   ④ 리포트 본문에서 출처 칩(판정 · 규칙 기반 / 설명 · …)과 '중개사에게 물어볼 질문 보기' 버튼이 없다
///   ⑤ 줄을 누르면 펼쳐진다 · 글자 130%에서도 넘치지 않는다
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/components/source_label.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/screens/report/registry_entry_card.dart';
import 'package:jeonse_ai/screens/report/registry_findings.dart';
import 'package:jeonse_ai/screens/report/report_screen.dart';
import 'package:provider/provider.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneWidth, kPhoneHeight;

Future<void> _pump(WidgetTester tester, {double scale = 1}) async {
  tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    ChangeNotifierProvider<AnalysisRepository>(
      create: (_) => DummyAnalysisRepository(),
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const ReportScreen(reportId: 'dummy-danger'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('findings-card')),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('머리 · 사진 카드와 근거 카드가 따로 · 요약 한 줄', (tester) async {
    await _pump(tester);
    expect(find.koText('1 / 5'), findsOneWidget);
    expect(find.koText('AI 분석'), findsOneWidget);
    expect(find.koText('등기부에서 찾은 것'), findsOneWidget);
    expect(find.koText('근거 살펴보기'), findsNothing);
    expect(find.koTextContaining('카드를 탭하면'), findsNothing);

    final entry = find.byType(RegistryEntryCard);
    final card = find.byKey(const ValueKey('findings-card'));
    expect(find.descendant(of: entry, matching: find.byType(FindingRow)), findsNothing);
    expect(find.descendant(of: card, matching: find.byType(FindingRow)), findsWidgets);
    expect(
      tester.getBottomLeft(entry).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('findings-summary'))).dy),
    );
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey('findings-summary'))).dy,
      lessThan(tester.getTopLeft(card).dy),
    );
  });

  testWidgets('위험 → 확인 필요 → 양호 순 · 등급 · 부제 한 줄', (tester) async {
    await _pump(tester);
    final rows = tester.widgetList<FindingRow>(find.byType(FindingRow)).toList();
    int sev(RiskGrade g) => switch (g) {
      RiskGrade.danger => 2,
      RiskGrade.caution => 1,
      RiskGrade.ok => 0,
    };
    for (int i = 1; i < rows.length; i++) {
      expect(sev(rows[i - 1].item.grade) >= sev(rows[i].item.grade), isTrue);
    }
    final first = rows.first.item;
    expect(find.koText('${first.grade.label} · ${first.termSubtitle}'), findsOneWidget);
  });

  testWidgets('출처 칩 · 질문 보기 버튼이 리포트 본문에 없다', (tester) async {
    await _pump(tester);
    // 모든 줄을 펼친다
    for (final row in tester.widgetList<FindingRow>(find.byType(FindingRow)).toList()) {
      if (row.initiallyExpanded) continue;
      final f = find.byWidget(row);
      await tester.ensureVisible(f);
      await tester.tap(find.descendant(of: f, matching: find.koText(row.item.title)));
      await tester.pumpAndSettle();
    }
    expect(find.byType(VerdictSourceLabel), findsNothing);
    expect(find.koTextContaining('규칙 기반'), findsNothing);
    expect(find.koText('중개사에게 물어볼 질문 보기'), findsNothing);
  });

  testWidgets('줄을 누르면 펼쳐진다', (tester) async {
    await _pump(tester);
    final closed = tester
        .widgetList<FindingRow>(find.byType(FindingRow))
        .firstWhere((r) => !r.initiallyExpanded);
    final f = find.byWidget(closed);
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    AnimatedCrossFade fade() => tester.widget<AnimatedCrossFade>(
      find.descendant(of: f, matching: find.byType(AnimatedCrossFade)),
    );
    expect(fade().crossFadeState, CrossFadeState.showFirst);
    await tester.tap(find.descendant(of: f, matching: find.koText(closed.item.title)));
    await tester.pumpAndSettle();
    expect(fade().crossFadeState, CrossFadeState.showSecond);
  });

  testWidgets('글자 130%에서도 넘치지 않는다', (tester) async {
    await _pump(tester, scale: 1.3);
    expect(tester.takeException(), isNull);
  });
}
