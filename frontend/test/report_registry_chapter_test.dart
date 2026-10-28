/// 리포트 1장 '등기부에서 찾은 것' (2026-10-28 리포트 2안).
///
/// 못 박는 것:
///   ① 머리: 「1 / 5」 · 「AI 분석」 칩 · 제목 "등기부에서 찾은 것" — 예전 '근거 살펴보기' 제목·안내 줄은 없다
///   ② 사진 진입("내가 올린 사진에서 보기")과 근거 목록이 **한 카드** 안에 있고, 진입이 근거보다 위
///   ③ 근거는 한 줄(제목 · 뱃지) — 누르면 예전 카드처럼 펼쳐진다(부제 → 출처)
///   ④ 글자 130%에서도 넘치지 않는다
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/components/app_card.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/screens/report/registry_entry_card.dart';
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
    find.koText('등기부에서 찾은 것'),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('머리 · 한 카드 · 진입이 근거보다 위', (tester) async {
    await _pump(tester);
    expect(find.koText('1 / 5'), findsOneWidget);
    expect(find.koText('AI 분석'), findsOneWidget);
    expect(find.koText('등기부에서 찾은 것'), findsOneWidget);
    expect(find.koText('근거 살펴보기'), findsNothing);
    expect(find.koTextContaining('카드를 탭하면'), findsNothing);

    final entry = find.byType(RegistryEntryCard);
    expect(entry, findsOneWidget);
    final rows = find.descendant(of: entry, matching: find.byType(EvidenceCard));
    expect(rows, findsWidgets, reason: '근거 목록이 사진 카드 안에 있다');

    final double entryTitleY = tester
        .getTopLeft(find.koText('내가 올린 사진에서 보기'))
        .dy;
    final double firstRowY = tester.getTopLeft(rows.first).dy;
    expect(entryTitleY, lessThan(firstRowY));
  });

  testWidgets('근거 한 줄을 누르면 부제·출처가 펼쳐진다', (tester) async {
    await _pump(tester);
    final rows = find.byType(EvidenceCard);
    // 가장 심각한 1개는 처음부터 펼쳐져 있다 — 접혀 있는 줄 하나를 찾아 연다
    final EvidenceCard closed = tester
        .widgetList<EvidenceCard>(rows)
        .firstWhere((c) => !c.initiallyExpanded);
    expect(closed.inline, isTrue);
    final rowFinder = find.byWidget(closed);
    await tester.ensureVisible(rowFinder);
    await tester.pumpAndSettle();
    final subtitle = find.descendant(
      of: rowFinder,
      matching: find.koText(closed.termSubtitle),
    );
    expect(
      tester.widget<AnimatedCrossFade>(
        find.descendant(of: rowFinder, matching: find.byType(AnimatedCrossFade)),
      ).crossFadeState,
      CrossFadeState.showFirst,
    );
    await tester.tap(find.descendant(of: rowFinder, matching: find.koText(closed.title)));
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedCrossFade>(
        find.descendant(of: rowFinder, matching: find.byType(AnimatedCrossFade)),
      ).crossFadeState,
      CrossFadeState.showSecond,
    );
    expect(subtitle, findsOneWidget);
  });

  testWidgets('글자 130%에서도 넘치지 않는다', (tester) async {
    await _pump(tester, scale: 1.3);
    expect(tester.takeException(), isNull);
  });
}
