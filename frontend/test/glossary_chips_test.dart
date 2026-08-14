/// S-12 용어 챗봇 화면 — 추천 칩 레이아웃 + 답변/거절이 그려지는 방식.
///
/// 배경: 용어 사전이 6개 → 18개로 늘면서(terms.json 일원화) 칩 줄이 깨질 수 있다는
/// 우려가 인계 문서에 남아 있었다. 2026-08-14 재설계에서 **빈 상태 2열 그리드 + [더 보기]**로
/// 정리했고, 이 파일이 그 결정을 고정한다.
///
/// 함께 못 박는 것 (2026-08-14 AI 연결):
///   · 답변 아래 **출처 라벨**이 항상 보인다(검수된 사전 / 모델명 / 준비된 문구)
///   · 거절이 **실패처럼 보이지 않는다** — 경고색·에러 아이콘 없이 유도 버튼만
///   · 답변 속 어려운 말에 **점선 밑줄**(TermText)이 붙는다
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/components/term_tooltip_sheet.dart';
import 'package:jeonse_ai/design_system/text/app_text.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/design_system/tokens/app_colors.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/chatbot/glossary_chatbot_screen.dart';
import 'package:jeonse_ai/state/app_session.dart';
import 'package:provider/provider.dart';

import 'support/ko_finders.dart';

/// 서버가 실제로 내려주는 18개 (GET /api/glossary, 2026-08-14 확인).
/// **대항력은 없다** — 검수 대기라 응답에서 제외된다(docs/terms-review-queue.md).
const _serverTerms = <String>[
  '전세가율', '선순위 채권', '근저당권', '신탁등기', '압류', '가압류',
  '경매개시결정', '임차권등기', '확정일자', '전입신고', '등기사항전부증명서',
  '갑구', '을구', '말소', '다가구주택', '전세보증금 반환보증', 'HUG', '실거래가',
];

class _FakeContentRepo implements ContentRepository {
  _FakeContentRepo({this.reply});

  /// null이면 사전 답을 흉내 낸다.
  final GlossaryAnswer? reply;

  @override
  Future<List<GlossaryTerm>> glossaryTerms() async => [
    for (final t in _serverTerms) GlossaryTerm(term: t, description: '$t 설명이에요.'),
  ];

  @override
  Future<GlossaryAnswer> askGlossary(String query) async =>
      reply ??
      GlossaryAnswer(
        answer: '$query 설명이에요.',
        source: '검수된 용어 사전',
        term: query,
      );

  @override
  Future<List<CaseMatch>> matchedCases(String reportId) async => const [];

  @override
  Future<List<QuestionGroup>> questionGroups(String reportId) async => const [];

  @override
  Future<List<JourneyStage>> journeyStages() async => const [];
}

class _EmptyAnalysisRepo extends AnalysisRepository {
  @override
  Future<AnalysisReport> analyze(AnalysisRequest request) => throw UnimplementedError();

  @override
  Future<List<AnalysisReport>> getHistory() async => const [];

  @override
  Future<AnalysisReport?> getReport(String id) async => null;

  @override
  Future<void> deleteReport(String id) async {}

  @override
  Future<CompareResult> compareRegistry(String id, List<String> paths) async =>
      const CompareResult(
        outcome: CompareOutcome.noBaseline,
        headline: '기준 없음',
        baseline: CompareDoc(),
        current: CompareDoc(),
      );
}

Future<void> _pump(
  WidgetTester tester, {
  GlossaryAnswer? reply,
  double textScale = 1.0,
  double width = 360,
}) async {
  tester.view.physicalSize = Size(width * 3, 800 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSession()),
        ChangeNotifierProvider<AnalysisRepository>(
          create: (_) => _EmptyAnalysisRepo(),
        ),
        Provider<ContentRepository>(create: (_) => _FakeContentRepo(reply: reply)),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: const GlossaryChatbotScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('빈 상태', () {
    testWidgets('인사 두 줄 + 추천 칩 6개 + [더 보기]', (tester) async {
      await _pump(tester);

      expect(find.koText('어려운 부동산 말,\n제가 쉽게 풀어드릴게요'), findsOneWidget);
      expect(find.koText('궁금한 걸 눌러보거나 직접 물어보세요'), findsOneWidget);
      expect(find.byType(ActionChip), findsNWidgets(kFeaturedChipCount));
      expect(find.koTextContaining('더 보기'), findsOneWidget);
    });

    testWidgets('첫 칩 순서는 촬영 대본 순서로 고정된다', (tester) async {
      await _pump(tester);

      // 칩 라벨은 AppText라 원문(data)을 그대로 읽는다(줄바꿈 부호는 그릴 때 붙는다).
      final labels = tester
          .widgetList<ActionChip>(find.byType(ActionChip))
          .map((c) => (c.label as AppText).data!)
          .toList();

      // 대항력은 검수 대기라 서버 응답에 없다 → 그 자리는 남은 용어가 채운다
      expect(labels.take(4).toList(), ['근저당권', '선순위 채권', '전세가율', '확정일자']);
      expect(labels.contains('신탁등기'), isTrue);
      expect(labels.length, kFeaturedChipCount);
    });

    testWidgets('[더 보기]를 누르면 나머지가 펼쳐진다', (tester) async {
      await _pump(tester);

      await tester.tap(find.koTextContaining('더 보기'));
      await tester.pumpAndSettle();

      expect(find.byType(ActionChip), findsNWidgets(_serverTerms.length));
    });

    testWidgets('글자 배율 2.0·좁은 화면에서도 칩이 넘치지 않는다', (tester) async {
      for (final scale in [1.3, 2.0]) {
        await _pump(tester, textScale: scale, width: 320);
        expect(tester.takeException(), isNull, reason: '글자 배율 $scale 에서 깨졌어요');
      }
    });
  });

  group('대화', () {
    testWidgets('칩을 누르면 질문과 답, 그리고 출처 라벨이 보인다', (tester) async {
      await _pump(tester);

      await tester.tap(find.koText('근저당권'));
      await tester.pumpAndSettle();

      expect(find.koText('근저당권'), findsOneWidget); // 사용자 말풍선
      expect(find.koText('근저당권 설명이에요.'), findsOneWidget);
      // 출처를 숨기지 않는다 (D26과 같은 정직성 원칙)
      expect(find.koText('검수된 용어 사전'), findsOneWidget);
    });

    testWidgets('LLM 답변에는 모델명이 출처로 붙고 어려운 말에 밑줄이 붙는다', (tester) async {
      await _pump(
        tester,
        reply: const GlossaryAnswer(
          answer: '집주인의 빚이 많으면 보증금을 돌려받기 어려울 수 있어요.',
          source: 'solar-pro2',
          termGlossary: {'보증금': '집을 빌리며 맡기는 돈이에요.'},
        ),
      );

      await tester.enterText(find.byType(TextField), '집주인이 빚이 많으면 어떻게 되나요?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(find.koText('solar-pro2'), findsOneWidget);
      expect(find.byType(TermText), findsOneWidget);
    });

    testWidgets('거절은 실패처럼 보이지 않는다 — 경고색 없이 유도 버튼만', (tester) async {
      await _pump(tester, reply: GlossaryAnswer.fallback);

      await tester.enterText(find.byType(TextField), '이 집 계약해도 돼요?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(find.koTextContaining('안전도 리포트'), findsOneWidget);
      expect(find.koText('매물 분석하러 가기'), findsOneWidget);
      expect(find.koText('준비된 문구'), findsOneWidget);
      // 빨강·경고 아이콘을 쓰지 않는다
      expect(find.byIcon(Icons.error), findsNothing);
      expect(find.byIcon(Icons.warning_amber), findsNothing);
      final texts = tester.widgetList<Text>(find.byType(Text));
      expect(
        texts.any((t) => t.style?.color == AppColors.danger),
        isFalse,
        reason: '거절 문구에 경고색이 쓰였어요',
      );
    });
  });
}