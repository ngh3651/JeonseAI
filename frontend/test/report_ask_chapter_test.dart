/// 리포트 4장 '중개사에게 물어볼 질문' (2026-10-29 확정안) + 상세 대본 화면.
///
/// ① 「4 / 5」 · 띠 "이 집에 맞춰 고른 질문 N개" · **질문 2개까지만** · 합격선은 미리보기에 없다
/// ② 서버가 4장을 모르면(빈 묶음) 장 전체가 빠진다 · 경매 중이면 멈춤 문장
/// ③ 상세(2026-11-01 리디자인): 처음엔 1번만 펼침 · 여러 개 함께 펼침 · [통과][조심] 탭 · 받을 것 큰 칸 · 체크 없음
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/ask_cards.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/common/ask_selection.dart';
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
    expect(find.koText('이 집에 맞춰 고른 질문 3개'), findsOneWidget);
    expect(find.koText('“${kDummyAskCards.cards[0].ask}”'), findsOneWidget);
    expect(find.koText('“${kDummyAskCards.cards[1].ask}”'), findsOneWidget);
    expect(find.koText('“${kDummyAskCards.cards[2].ask}”'), findsNothing, reason: '미리보기는 2개까지');
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

  testWidgets('상세(2026-11-01): 체크·한마디 띠 없음 · 1번만 펼친 채 시작 · 여러 개 함께 펼침', (tester) async {
    await _pumpDetail(tester, DummyContentRepository());
    expect(find.koText('3가지만 확인하면 돼요'), findsOneWidget);
    expect(find.koText('0 / 3'), findsNothing, reason: '확인한 것 막대 없음');
    expect(find.koTextContaining('현장에서 이 한마디'), findsNothing);
    expect(find.koTextContaining('중개사 답은?'), findsNothing);
    expect(find.byType(AskSelectionArea), findsOneWidget, reason: '꾹 눌러 챗봇에 묻기');
    expect(find.byKey(const ValueKey('ask-body-debt')), findsOneWidget);
    expect(find.byKey(const ValueKey('ask-body-tax')), findsNothing);

    final taxToggle = find.byKey(const ValueKey('ask-toggle-tax'));
    await tester.scrollUntilVisible(taxToggle, 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(taxToggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ask-body-tax')), findsOneWidget);
    expect(find.byKey(const ValueKey('ask-body-debt')), findsOneWidget, reason: '다른 카드를 펼쳐도 닫히지 않는다');
    expect(find.koTextContaining('법이 정한 서류'), findsOneWidget);
  });

  testWidgets('카드 안: 할 말 · [통과][조심] 탭(처음은 조심) · 받을 것 큰 칸 · 리포트 근거 칩', (tester) async {
    await _pumpDetail(tester, DummyContentRepository());
    // '이 집에서 본 것'은 여기 없다 — 리포트·사진에서 보기에 이미 있다(2026-11-01). 대신 리포트 근거로 가는 칩
    expect(find.koText('이 집에서 본 것'), findsNothing);
    expect(find.byKey(const ValueKey('ask-to-report-debt')), findsOneWidget);
    // 정해 둔 why면 'AI가 썼어요'를 붙이지 않는다
    expect(find.koTextContaining('AI가 썼어요'), findsNothing);
    // 조심 탭이 먼저 — 이 집 손해 · 핑계 · 받아치기
    final careful = find.byKey(const ValueKey('ask-careful-debt'));
    expect(careful, findsOneWidget);
    expect(find.descendant(of: careful, matching: find.koText('안 되면 경매 때 2,704만원을 못 받는 계산이에요')), findsOneWidget);
    expect(find.byKey(const ValueKey('ask-counter-debt')), findsOneWidget);
    expect(find.byKey(const ValueKey('ask-pass-debt')), findsNothing);
    // 통과 탭
    final passTab = find.byKey(const ValueKey('ask-tab-debt-pass'));
    await tester.ensureVisible(passTab);
    await tester.pumpAndSettle();
    await tester.tap(passTab);
    await tester.pumpAndSettle();
    final pass = find.byKey(const ValueKey('ask-pass-debt'));
    expect(find.descendant(of: pass, matching: find.koText('잔금 날 말소 · 특약에 글로')), findsOneWidget);
    expect(find.descendant(of: pass, matching: find.koTextContaining('못 받는')), findsNothing, reason: '빨간 풀이는 조심 탭에만');
    expect(find.byKey(const ValueKey('ask-careful-debt')), findsNothing);
    // 받을 것
    final docs = find.byKey(const ValueKey('ask-docs-debt'));
    expect(find.descendant(of: docs, matching: find.koText('말소 접수증')), findsOneWidget);
  });

  testWidgets('AI가 쓴 why에만 "✦ AI가 썼어요" · 받아치기의 근거 줄은 따로', (tester) async {
    final c = kDummyAskCards.cards[1];
    final ai = AskCard(
      id: c.id, title: c.title, legal: c.legal, facts: c.facts, why: '이 집 숫자로 다시 쓴 문장이에요.', whyByAi: true,
      ask: c.ask, okReply: c.okReply, badReply: c.badReply, counter: c.counter, passLine: c.passLine,
      docs: c.docs, clause: c.clause, stopSub: c.stopSub,
    );
    await _pumpDetail(tester, _Content(AskCards(cards: [ai])));
    expect(find.koText('✦ AI가 썼어요'), findsOneWidget);
    // 조심 머리 = 합격선 빨간 풀이가 없으니 정해 둔 멈춤 풀이
    expect(find.koText(c.stopSub), findsOneWidget);
    expect(find.koText('“계약할 때 집주인이 보여 줘야 하는 서류예요”'), findsOneWidget);
    expect(find.koText('(주택임대차보호법 제3조의7)'), findsOneWidget);
  });

  testWidgets('상세 글자 130%에서도 넘치지 않는다', (tester) async {
    _phone(tester, scale: 1.3);
    await tester.pumpWidget(
      Provider<ContentRepository>.value(
        value: DummyContentRepository(),
        child: MaterialApp(theme: buildAppTheme(), home: const AskCardsScreen(reportId: 'dummy-danger')),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('질문 → 리포트 근거 짝 · 조심 머리 고르기', () {
    expect(askEvidenceFor('debt'), 'senior_debt');
    expect(askEvidenceFor('seizure'), 'ownership');
    expect(askEvidenceFor('insurance'), 'insurance');
    expect(askEvidenceFor('tax'), isNull, reason: '밀린 세금은 리포트에 짝 카드가 없다');
    expect(askCarefulLine(kDummyAskCards.cards[0]), '안 되면 경매 때 2,704만원을 못 받는 계산이에요');
    expect(askCarefulLine(kDummyAskCards.cards[2]), kDummyAskCards.cards[2].stopSub);
  });
}
