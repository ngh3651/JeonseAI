/// 리포트 4장 '중개사에게 물어볼 질문' (2026-10-29 확정안) + 상세 대본 화면.
///
/// ① 「4 / 5」 · 띠 "AI가 이 집에서 뽑은 질문 N개" · **질문 2개까지만** · 합격선은 미리보기에 없다
/// ② 서버가 4장을 모르면(빈 묶음) 장 전체가 빠진다 · 경매 중이면 멈춤 문장
/// ③ 상세: 처음엔 1번만 펼침 · 다른 질문을 누르면 펼쳐짐 · '말로만 들었어요' → 특약 · 확인한 것 N / M
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/ask_cards.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/questions/ask_cards_screen.dart';
import 'package:jeonse_ai/screens/report/report_screen.dart';
import 'package:provider/provider.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneWidth, kPhoneHeight;

class _Content extends DummyContentRepository {
  _Content(this.data);
  final AskCards data;
  @override
  Future<AskCards> askCards(String reportId, {bool polish = false}) async => data;
}

void _phone(WidgetTester tester, {double scale = 1}) {
  tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<void> _pumpReport(WidgetTester tester, ContentRepository content, {double scale = 1}) async {
  _phone(tester, scale: scale);
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
}

Future<void> _pumpDetail(WidgetTester tester, ContentRepository content) async {
  _phone(tester);
  await tester.pumpWidget(
    Provider<ContentRepository>.value(
      value: content,
      child: MaterialApp(theme: buildAppTheme(), home: const AskCardsScreen(reportId: 'dummy-danger')),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('4장 미리보기는 질문 2개 + 띠 개수, 합격선은 안 보인다', (tester) async {
    await _pumpReport(tester, DummyContentRepository());
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('ask-chapter-more')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.koText('4 / 5'), findsOneWidget);
    expect(find.koText('AI가 이 집에서 뽑은 질문 3개'), findsOneWidget);
    expect(find.koText(kDummyAskCards.cards[0].ask), findsOneWidget);
    expect(find.koText(kDummyAskCards.cards[1].ask), findsOneWidget);
    expect(find.koText(kDummyAskCards.cards[2].ask), findsNothing, reason: '미리보기는 2개까지');
    expect(find.koText('합격선'), findsNothing);
  });

  testWidgets('글자 130%에서도 넘치지 않는다', (tester) async {
    await _pumpReport(tester, DummyContentRepository(), scale: 1.3);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('ask-chapter-more')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('서버가 4장을 모르면 장이 빠지고, 경매 중이면 멈춤 문장', (tester) async {
    await _pumpReport(tester, _Content(AskCards.empty));
    expect(find.byKey(const ValueKey('report-chapter-ask')), findsNothing);

    await _pumpReport(tester, _Content(const AskCards(stop: '경매가 진행 중인 집이에요.')));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('ask-chapter-stop')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.koText('경매가 진행 중인 집이에요.'), findsOneWidget);
  });

  testWidgets('상세: 1번만 펼쳐져 있고, 답을 고르면 기록·특약이 뜬다', (tester) async {
    await _pumpDetail(tester, DummyContentRepository());
    expect(find.koText('3가지만 확인하면 돼요'), findsOneWidget);
    expect(find.koText('0 / 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('ask-body-debt')), findsOneWidget);
    expect(find.byKey(const ValueKey('ask-body-tax')), findsNothing);

    final verbal = find.byKey(const ValueKey('ask-answer-debt-verbal'));
    await tester.ensureVisible(verbal);
    await tester.pumpAndSettle();
    await tester.tap(verbal);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ask-clause-debt')), findsOneWidget);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await tester.pumpAndSettle();
    expect(find.koText('1 / 3'), findsOneWidget);

    final taxToggle = find.byKey(const ValueKey('ask-toggle-tax'));
    await tester.scrollUntilVisible(taxToggle, 200, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(taxToggle);
    await tester.pumpAndSettle();
    await tester.tap(taxToggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ask-body-tax')), findsOneWidget);
    expect(find.byKey(const ValueKey('ask-body-debt')), findsNothing);
    expect(find.koTextContaining('법이 정한 서류'), findsOneWidget);
    AskAnswerStore.of('dummy-danger').clear();
  });
}
