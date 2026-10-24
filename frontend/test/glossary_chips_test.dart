/// S-12 챗봇 화면 (2026-10-24 대화형) — 추천 칩 + 대화가 그려지는 방식.
///
/// 못 박는 것:
///   · 빈 화면: 인사 + **AI 안내 한 줄** + 추천 칩 6개 + [더 보기]
///   · 말풍선 밑 **출처 라벨·'내 리포트 보기' 버튼·용어 밑줄이 없다**(규혁: "여기선 딱 챗봇만")
///   · `**굵게**`는 굵게, 표시 기호는 안 보인다
///   · **앞 대화를 통째로 보낸다**("더 쉽게"가 이어지게)
///   · 말풍선 폭이 화면의 75%를 넘지 않는다
///   · [새 대화]로 지운다
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/text/app_text.dart';
import 'package:jeonse_ai/design_system/text/keep_all.dart';
import 'package:jeonse_ai/design_system/theme.dart';
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

  /// null이면 질문을 되풀이한 답을 준다.
  final ChatReply? reply;

  /// 화면이 보낸 대화들(호출마다 한 묶음)
  final List<List<ChatTurn>> sent = [];

  @override
  Future<List<GlossaryTerm>> glossaryTerms() async => [
    for (final t in _serverTerms) GlossaryTerm(term: t, description: '$t 설명이에요.'),
  ];

  @override
  Future<ChatReply> chat(List<ChatTurn> messages) async {
    sent.add(List.of(messages));
    return reply ?? ChatReply(answer: '${messages.last.content} 설명이에요.', model: 'solar-pro2');
  }

  @override
  Future<List<CaseMatch>> matchedCases(String reportId) async => const [];

  @override
  Future<PrecedentStatus?> precedentStatus() async => null;

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

Future<_FakeContentRepo> _pump(
  WidgetTester tester, {
  ChatReply? reply,
  double textScale = 1.0,
  double width = 360,
}) async {
  final repo = _FakeContentRepo(reply: reply);
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
        Provider<ContentRepository>.value(value: repo),
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
  return repo;
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.byIcon(Icons.arrow_upward)); // 엔터는 줄바꿈 — 보내기는 버튼으로
  await tester.pumpAndSettle();
}

void main() {
  group('빈 상태', () {
    testWidgets('인사 + AI 안내 한 줄 + 추천 칩 6개 + [더 보기]', (tester) async {
      await _pump(tester);

      expect(find.koText('챗봇'), findsOneWidget);
      expect(find.koText('전세·부동산,\n뭐든 물어보세요'), findsOneWidget);
      expect(find.koText(kChatAiNotice), findsOneWidget);
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
    testWidgets('엔터는 줄바꿈이고 보내지 않는다', (tester) async {
      final repo = await _pump(tester);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.textInputAction, TextInputAction.newline);
      await tester.enterText(find.byType(TextField), '첫 줄\n둘째 줄');
      await tester.pumpAndSettle();
      expect(repo.sent, isEmpty);
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();
      expect(repo.sent.single.last.content, '첫 줄\n둘째 줄');
    });

    testWidgets('칩을 누르면 질문과 답 — 출처 라벨·유도 버튼·밑줄이 없다', (tester) async {
      await _pump(tester);

      await tester.tap(find.koText('근저당권'));
      await tester.pumpAndSettle();

      expect(find.koText('근저당권'), findsOneWidget); // 사용자 말풍선
      expect(find.koText('근저당권 설명이에요.'), findsOneWidget);
      for (final gone in ['검수된 용어 사전', '준비된 문구', 'solar-pro2', '내 리포트 보기', '매물 분석하러 가기']) {
        expect(find.koText(gone), findsNothing, reason: '$gone 이 보여요');
      }
    });

    testWidgets('**굵게**는 굵게 그리고 표시 기호는 안 보인다', (tester) async {
      await _pump(tester, reply: const ChatReply(answer: '가압류는 **집을 잠깐 묶어 두는 것**이에요.\n쉽죠?'));
      await _send(tester, '가압류 쉽게');

      expect(find.koTextContaining('**'), findsNothing);
      // 어절 줄바꿈 부호가 끼어 조각이 나뉠 수 있다 — 굵은 조각들의 글자를 모아 본다
      final boldText = StringBuffer();
      for (final r in tester.widgetList<RichText>(find.byType(RichText))) {
        r.text.visitChildren((s) {
          if (s is TextSpan && s.style?.fontWeight == FontWeight.w700) {
            boldText.write(stripWordJoiner(s.text ?? ''));
          }
          return true;
        });
      }
      expect(boldText.toString(), contains('집을 잠깐 묶어 두는 것'));
    });

    testWidgets('앞 대화를 통째로 보낸다 — "더 쉽게"가 이어진다', (tester) async {
      final repo = await _pump(tester);
      await _send(tester, '가압류 알려줘');
      await _send(tester, '더 쉽게');

      final last = repo.sent.last;
      expect(last.map((t) => t.isUser).toList(), [true, false, true]);
      expect(last.first.content, '가압류 알려줘');
      expect(last[1].content, '가압류 알려줘 설명이에요.');
      expect(last.last.content, '더 쉽게');
    });

    testWidgets('말풍선은 화면 폭의 75%를 넘지 않는다', (tester) async {
      final long = '아주 긴 질문이에요 ' * 10; // 한 줄을 넘칠 만큼만(화면 밖으로 밀리지 않게)
      await _pump(tester, reply: ChatReply(answer: '아주 긴 답이에요 ' * 10));
      await _send(tester, long);

      const limit = 360.0 * kBubbleWidthFactor;
      // 글자 덩어리의 폭 = 말풍선 안쪽 폭 → 말풍선 폭(75%)보다 작아야 한다
      expect(tester.getSize(find.koTextContaining('아주 긴 질문', skipOffstage: false)).width, lessThanOrEqualTo(limit));
      expect(tester.getSize(find.koTextContaining('아주 긴 답', skipOffstage: false)).width, lessThanOrEqualTo(limit));
      expect(tester.takeException(), isNull);
    });

    testWidgets('[새 대화]를 누르면 처음 화면으로', (tester) async {
      await _pump(tester);
      await _send(tester, '안녕');
      expect(find.koText(kChatAiNotice), findsNothing);

      await tester.tap(find.byTooltip('새 대화'));
      await tester.pumpAndSettle();
      expect(find.koText(kChatAiNotice), findsOneWidget);
    });
  });
}
