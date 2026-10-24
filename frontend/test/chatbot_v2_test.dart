/// S-12 챗봇 v2 위젯 테스트 (360×760) — 꾹 누르기 칩 · 밀어서 이어 묻기 · 인용 칩 · 지난 대화 서랍 · 첫 안내 · 글자 1.3배.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/design_system/tokens/app_colors.dart';
import 'package:jeonse_ai/models/chat_history.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/repositories/chat_history_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/chatbot/chat_history_drawer.dart';
import 'package:jeonse_ai/screens/chatbot/chat_history_logic.dart';
import 'package:jeonse_ai/screens/chatbot/chat_quote.dart';
import 'package:jeonse_ai/screens/chatbot/chat_selection.dart';
import 'package:jeonse_ai/screens/chatbot/chat_swipe.dart';
import 'package:jeonse_ai/screens/chatbot/glossary_chatbot_screen.dart';
import 'package:provider/provider.dart';

import 'support/ko_finders.dart';

/// 답: [answers]에 있으면 그것, 없으면 "<질문> 설명이에요.\n두 번째 줄이에요."
class _FakeContentRepo implements ContentRepository {
  _FakeContentRepo({this.answers = const {}, this.lines = 2});

  final Map<String, String> answers;

  /// 기본 답 줄 수 — 길게 만들면 화면 밖으로 밀린다
  final int lines;
  final List<List<ChatTurn>> sent = [];

  @override
  Future<ChatReply> chat(List<ChatTurn> messages) async {
    sent.add(List.of(messages));
    final last = messages.last.content.split('\n').last;
    final fixed = answers[last];
    if (fixed != null) return ChatReply(answer: fixed);
    return ChatReply(
      answer: ['$last 설명이에요.', for (var i = 2; i <= lines; i++) '$i번째 줄이에요.'].join('\n'),
    );
  }

  @override
  Future<List<GlossaryTerm>> glossaryTerms() async => const [];

  @override
  Future<List<CaseMatch>> matchedCases(String reportId) async => const [];

  @override
  Future<PrecedentStatus?> precedentStatus() async => null;

  @override
  Future<List<QuestionGroup>> questionGroups(String reportId) async => const [];

  @override
  Future<List<JourneyStage>> journeyStages() async => const [];
}

/// 안내를 이미 본 저장소 (첫 안내가 다른 시험을 흔들지 않게)
MemoryChatHistoryRepository _seenHistory([List<ChatConversation> initial = const []]) {
  final h = MemoryChatHistoryRepository(initial);
  h.markHint(ChatHint.swipe);
  h.markHint(ChatHint.drawerDot);
  h.markHint(ChatHint.drawerOpened);
  return h;
}

class _Harness {
  _Harness(this.repo, this.history);

  final _FakeContentRepo repo;
  final ChatHistoryRepository history;
  String? clipboard;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  _FakeContentRepo? repo,
  ChatHistoryRepository? history,
  double textScale = 1.0,
  bool disableAnimations = false,
}) async {
  final h = _Harness(repo ?? _FakeContentRepo(), history ?? _seenHistory());
  tester.view.physicalSize = const Size(360 * 3, 760 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  // 진동·클립보드 — 플랫폼 대신 받아 둔다
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      h.clipboard = (call.arguments as Map)['text'] as String?;
    }
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<ContentRepository>.value(value: h.repo),
        Provider<ChatHistoryRepository>.value(value: h.history),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: disableAnimations,
            ),
            child: const GlossaryChatbotScreen(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

/// 입력칸 = 화면 아래 입력 줄의 TextField (서랍 검색칸과 헷갈리지 않게 첫 번째)
Finder get _input => find.byType(TextField).first;

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(_input, text);
  await tester.tap(find.byIcon(Icons.arrow_upward));
  await tester.pumpAndSettle();
}

/// [text] 줄이 들어 있는 AI 말풍선(밀기 위젯)
Finder _botBubble(String text) =>
    find.ancestor(of: find.koTextContaining(text).first, matching: find.byType(SwipeToQuote));

/// 말풍선 몸통(테두리를 가진 상자)
BoxDecoration _bubbleDecoration(WidgetTester tester, String text) {
  final box = find.descendant(of: _botBubble(text), matching: find.byType(AnimatedContainer)).first;
  return tester.widget<AnimatedContainer>(box).decoration! as BoxDecoration;
}

Future<void> _swipe(WidgetTester tester, String text, double dx) async {
  await tester.drag(_botBubble(text), Offset(-dx, 0));
  await tester.pumpAndSettle();
}

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(find.byTooltip('지난 대화'));
  await tester.pumpAndSettle();
}

Finder get _drawerSearch =>
    find.descendant(of: find.byType(ChatHistoryDrawer), matching: find.byType(TextField));

ChatConversation _conv(String id, String title, DateTime at, {String answer = '답이에요.'}) => ChatConversation(
  id: id,
  title: title,
  createdAt: at,
  updatedAt: at,
  entries: [
    ChatEntry(id: '$id-u', isUser: true, text: title),
    ChatEntry(id: '$id-b', isUser: false, text: answer),
  ],
);

void main() {
  group('꾹 누르기 = 글자 선택 + 칩', () {
    testWidgets('AI 말풍선 → 누른 줄 전체 선택 + [복사][답글] · 복사하면 "복사했어요" 2초', (tester) async {
      final h = await _pump(tester, repo: _FakeContentRepo(answers: {'근저당권?': '근저당권은 담보 표시예요.\n은행이 먼저 받아 가요.'}));
      await _send(tester, '근저당권?');

      await tester.longPress(find.koText('은행이 먼저 받아 가요.'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatSelectionChip), findsOneWidget);
      expect(find.koText('복사'), findsOneWidget);
      expect(find.koText('답글'), findsOneWidget);
      expect(find.text('Select all'), findsNothing, reason: '안드로이드 기본 메뉴 대신 칩만');
      expect(find.text('Share'), findsNothing);

      await tester.tap(find.koText('복사'));
      await tester.pump();
      await tester.pump();
      expect(h.clipboard, '은행이 먼저 받아 가요.', reason: '낱말이 아니라 누른 줄(문장) 전체');
      expect(find.byType(ChatSelectionChip), findsNothing);
      expect(tester.widget<CopiedToast>(find.byType(CopiedToast)).visible, isTrue);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(tester.widget<CopiedToast>(find.byType(CopiedToast)).visible, isFalse);
    });

    testWidgets('내 말풍선 → [복사]만', (tester) async {
      final h = await _pump(tester);
      await _send(tester, '확정일자 언제 받아요');
      await tester.longPress(find.koText('확정일자 언제 받아요'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatSelectionChip), findsOneWidget);
      expect(find.koText('복사'), findsOneWidget);
      expect(find.koText('답글'), findsNothing);
      await tester.tap(find.koText('복사'));
      await tester.pump();
      expect(h.clipboard, '확정일자 언제 받아요');
      await tester.pumpAndSettle(const Duration(seconds: 3));
    });

    testWidgets('[답글] → 고른 글자만 인용', (tester) async {
      final h = await _pump(tester, repo: _FakeContentRepo(answers: {'근저당권?': '근저당권은 담보 표시예요.\n은행이 먼저 받아 가요.'}));
      await _send(tester, '근저당권?');
      await tester.longPress(find.koText('은행이 먼저 받아 가요.'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('답글'));
      await tester.pumpAndSettle();
      expect(find.byType(QuoteBand), findsOneWidget);
      expect(tester.widget<QuoteBand>(find.byType(QuoteBand)).quote, '은행이 먼저 받아 가요.');
      await _send(tester, '왜요?');
      expect(h.repo.sent.last.last.content, '$kQuoteLeadPart\n「은행이 먼저 받아 가요.」\n왜요?');
    });
  });

  group('왼쪽으로 밀어서 이어 묻기', () {
    testWidgets('64 넘게 밀면 인용 띠 + 입력칸 포커스 + 테두리 primaryBright 2 · [X]로 취소', (tester) async {
      await _pump(tester);
      await _send(tester, '가압류');
      expect(find.byType(QuoteBand), findsNothing);

      await _swipe(tester, '가압류 설명이에요.', 100);
      expect(find.byType(QuoteBand), findsOneWidget);
      expect(find.koText(kQuoteBandLabel), findsOneWidget);
      expect(
        find.descendant(of: find.byType(QuoteBand), matching: find.text('가압류 설명이에요.')),
        findsOneWidget,
        reason: '인용 첫 줄',
      );
      expect(tester.widget<TextField>(_input).focusNode!.hasFocus, isTrue);
      expect(find.text(kQuoteHint), findsOneWidget);
      final border = _bubbleDecoration(tester, '가압류 설명이에요.').border! as Border;
      expect(border.top.color, AppColors.primaryBright);
      expect(border.top.width, 2);

      await tester.tap(find.byTooltip('인용 취소'));
      await tester.pumpAndSettle();
      expect(find.byType(QuoteBand), findsNothing);
      expect((_bubbleDecoration(tester, '가압류 설명이에요.').border! as Border).top.color, AppColors.line);
    });

    testWidgets('덜 밀면 제자리 · 인용 안 됨', (tester) async {
      await _pump(tester);
      await _send(tester, '가압류');
      await _swipe(tester, '가압류 설명이에요.', 40);
      expect(find.byType(QuoteBand), findsNothing);
      expect(find.byKey(const ValueKey('swipe-arrow')), findsNothing, reason: '놓으면 제자리');
    });

    testWidgets('미는 동안 화살표가 보이고 그림자가 생긴다', (tester) async {
      await _pump(tester);
      await _send(tester, '가압류');
      final gesture = await tester.startGesture(tester.getCenter(_botBubble('가압류 설명이에요.')));
      await gesture.moveBy(const Offset(-20, 0));
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      expect(find.byKey(const ValueKey('swipe-arrow')), findsOneWidget);
      expect(_bubbleDecoration(tester, '가압류 설명이에요.').boxShadow, isNotEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byType(QuoteBand), findsNothing);
    });

    testWidgets('내 말풍선은 밀리지 않는다', (tester) async {
      await _pump(tester);
      await _send(tester, '가압류');
      await tester.drag(find.koText('가압류'), const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(find.byType(QuoteBand), findsNothing);
    });

    testWidgets('인용해서 보내면 내 말풍선 위 인용 칩 · 질문은 그대로 · 누르면 원래 답으로 스크롤 + 1초 반짝', (tester) async {
      final h = await _pump(tester, repo: _FakeContentRepo(lines: 6));
      await _send(tester, '첫 질문');
      await _send(tester, '둘째 질문');
      await _send(tester, '셋째 질문');

      // 화면 밖으로 밀린 첫 답으로 올라가 민다
      await tester.ensureVisible(find.koText('첫 질문 설명이에요.'));
      await tester.pumpAndSettle();
      await _swipe(tester, '첫 질문 설명이에요.', 100);
      await _send(tester, '이거 더 쉽게');

      expect(find.byType(QuoteChip), findsOneWidget);
      expect(find.koText('이거 더 쉽게'), findsOneWidget, reason: '화면엔 질문만');
      final sent = h.repo.sent.last.last.content;
      expect(sent, endsWith('\n이거 더 쉽게'), reason: '질문은 끝에 통째로');
      expect(sent, contains('첫 질문 설명이에요.'), reason: '인용이 AI에게 간다');

      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      expect(tester.getRect(_botBubble('첫 질문 설명이에요.')).bottom, lessThan(viewport.top), reason: '원래 답은 화면 밖');

      await tester.tap(find.byType(QuoteChip));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final r = tester.getRect(_botBubble('첫 질문 설명이에요.'));
      expect(r.bottom > viewport.top && r.top < viewport.bottom, isTrue, reason: '원래 답으로 스크롤');
      expect((_bubbleDecoration(tester, '첫 질문 설명이에요.').border! as Border).top.color, AppColors.primaryBright);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect((_bubbleDecoration(tester, '첫 질문 설명이에요.').border! as Border).top.color, AppColors.line);
    });

    testWidgets('기다리는 중 말풍선 · 연결 실패 안내는 밀기·꾹 누르기 없음', (tester) async {
      await _pump(tester);
      await _send(tester, '가압류');
      // 기다리는 중·실패 줄에는 밀기 위젯이 붙지 않는다 (답 말풍선 1개에만)
      expect(find.byType(SwipeToQuote), findsOneWidget);
      expect(find.byType(ChatSelectableText), findsNWidgets(2), reason: '내 말 1 + 답 1');
    });
  });

  group('지난 대화', () {
    testWidgets('[새 대화] → 기록에 저장 → 서랍에 보임 → 눌러서 다시 열고 이어 묻기', (tester) async {
      final history = _seenHistory();
      final h = await _pump(tester, history: history);
      await _send(tester, '가압류 알려줘');
      await tester.tap(find.byTooltip('새 대화'));
      await tester.pumpAndSettle();
      expect(find.koText(kChatAiNotice), findsOneWidget, reason: '빈 화면');

      await _openDrawer(tester);
      expect(find.byType(ChatHistoryDrawer), findsOneWidget);
      expect(find.koText('지난 대화'), findsOneWidget);
      expect(find.koText('오늘'), findsOneWidget);
      expect(find.koText('가압류 알려줘'), findsOneWidget);
      expect(find.koTextContaining('가압류 알려줘 설명이에요.'), findsOneWidget, reason: '시간 · 마지막 답 첫 줄');

      await tester.tap(find.koText('가압류 알려줘'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatHistoryDrawer), findsNothing);
      expect(find.koText('가압류 알려줘 설명이에요.'), findsOneWidget, reason: '그대로 다시 그림');

      await _send(tester, '더 쉽게');
      final turns = h.repo.sent.last;
      expect(turns.map((t) => t.content).toList(), [
        '가압류 알려줘',
        '가압류 알려줘 설명이에요.\n2번째 줄이에요.',
        '더 쉽게',
      ]);
      final saved = await history.list();
      expect(saved.length, 1, reason: '같은 대화 끝에 붙는다');
      expect(saved.single.entries.length, 4);
    });

    testWidgets('이어 물은 대화가 목록 맨 위로', (tester) async {
      final now = DateTime.now();
      final history = _seenHistory([
        _conv('a', '확정일자', now.subtract(const Duration(minutes: 30))),
        _conv('b', '전입신고', now.subtract(const Duration(minutes: 10))),
      ]);
      await _pump(tester, history: history);
      await _openDrawer(tester);
      await tester.tap(find.koText('확정일자'));
      await tester.pumpAndSettle();
      await _send(tester, '더 알려줘');
      expect((await history.list()).map((c) => c.id), ['a', 'b']);
    });

    testWidgets('묶음 이름 · 지금 연 대화는 primarySoft', (tester) async {
      final now = DateTime.now();
      final history = _seenHistory([
        _conv('t', '오늘 질문', now),
        _conv('y', '어제 질문', now.subtract(const Duration(days: 1))),
        _conv('w', '며칠 전 질문', now.subtract(const Duration(days: 3))),
        _conv('m', '오래된 질문', now.subtract(const Duration(days: 60))),
      ]);
      await _pump(tester, history: history);
      await _openDrawer(tester);
      for (final label in ['오늘', '어제', '지난 7일', chatGroupLabel(now.subtract(const Duration(days: 60)), now)]) {
        expect(find.koText(label), findsOneWidget, reason: label);
      }
      // 연 대화 표시
      await tester.tap(find.koText('어제 질문'));
      await tester.pumpAndSettle();
      await _openDrawer(tester);
      final row = tester.widget<Material>(find.byKey(const ValueKey('chat-row-y')));
      expect(row.color, AppColors.primarySoft);
      expect(tester.widget<Material>(find.byKey(const ValueKey('chat-row-t'))).color, AppColors.surface);
    });

    testWidgets('검색 — 제목·본문, 개수 머리글, 맞은 글자 강조, 없으면 안내, [X]로 지우기', (tester) async {
      final now = DateTime.now();
      final history = _seenHistory([
        _conv('a', '근저당권이 뭐예요?', now),
        _conv('b', '확정일자', now.subtract(const Duration(hours: 1)),
            answer: '주민센터에 가서 계약서를 내밀면 근저당이 아니라 확정일자를 받아요.'),
        _conv('c', '전입신고', now.subtract(const Duration(hours: 2))),
      ]);
      await _pump(tester, history: history);
      await _openDrawer(tester);
      expect(find.koText('새 대화'), findsOneWidget);

      await tester.enterText(_drawerSearch, '근저당');
      await tester.pumpAndSettle();
      expect(find.koText("'근저당'이 들어간 대화 2개"), findsOneWidget);
      expect(find.koText('새 대화'), findsNothing, reason: '검색 중엔 [+ 새 대화] 숨김');
      expect(find.koText('전입신고'), findsNothing);
      expect(find.textContaining('…'), findsOneWidget, reason: '앞이 잘린 본문 줄');
      // 맞은 글자는 primarySoft 바탕 + primaryDeep
      var highlighted = 0;
      for (final rt in tester.widgetList<RichText>(find.descendant(of: find.byType(ChatHistoryDrawer), matching: find.byType(RichText)))) {
        rt.text.visitChildren((span) {
          if (span is TextSpan && span.style?.backgroundColor == AppColors.primarySoft && span.text == '근저당') {
            expect(span.style?.color, AppColors.primaryDeep);
            highlighted++;
          }
          return true;
        });
      }
      expect(highlighted, greaterThanOrEqualTo(2));

      await tester.enterText(_drawerSearch, '가압류');
      await tester.pumpAndSettle();
      expect(find.koText("'가압류'가 들어간 대화가 없어요"), findsOneWidget);

      await tester.tap(find.byTooltip('검색어 지우기'));
      await tester.pumpAndSettle();
      expect(find.koText('전입신고'), findsOneWidget);
      expect(find.koText('새 대화'), findsOneWidget);
    });

    testWidgets('⋯ 시트 → 이름 바꾸기', (tester) async {
      final history = _seenHistory([_conv('a', '근저당권이 뭐예요?', DateTime.now())]);
      await _pump(tester, history: history);
      await _openDrawer(tester);
      await tester.tap(find.byTooltip('대화 메뉴'));
      await tester.pumpAndSettle();
      expect(find.koText('이름 바꾸기'), findsOneWidget);
      expect(find.koText('삭제'), findsOneWidget);
      expect(find.koTextContaining('· 말 2개'), findsOneWidget);
      expect(find.koTextContaining('오늘 오'), findsOneWidget);

      await tester.tap(find.koText('이름 바꾸기'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget, reason: '이름 바꾸기 창');
      await tester.enterText(find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)), '근저당 공부');
      await tester.pump();
      final save = find.ancestor(of: find.koText('바꾸기'), matching: find.byType(FilledButton));
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull, reason: '[바꾸기]가 켜져 있다');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing, reason: '창이 닫혔다');
      expect((await history.list()).single.title, '근저당 공부', reason: '저장소에 바뀐 이름');
      expect(find.koText('근저당 공부'), findsOneWidget, reason: '서랍 줄에 바뀐 이름');
    });

    testWidgets('⋯ 시트 → 삭제 확인(빨간색 없음) → 사라짐 · 마지막 하나면 기록 없음 화면', (tester) async {
      final history = _seenHistory([_conv('a', '근저당권이 뭐예요?', DateTime.now())]);
      await _pump(tester, history: history);
      await _openDrawer(tester);
      await tester.tap(find.byTooltip('대화 메뉴'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('삭제'));
      await tester.pumpAndSettle();
      expect(find.koText('이 대화를 지울까요?'), findsOneWidget);
      expect(find.koText("'근저당권이 뭐예요?' 대화가 이 폰에서 지워져요. 지운 대화는 다시 볼 수 없어요."), findsOneWidget);
      final confirm = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(confirm.style?.backgroundColor?.resolve({}), AppColors.primary);
      expect(confirm.style?.backgroundColor?.resolve({}), isNot(AppColors.danger));

      // 취소하면 그대로
      await tester.tap(find.koText('취소'));
      await tester.pumpAndSettle();
      expect(find.koText('근저당권이 뭐예요?'), findsOneWidget);

      await tester.tap(find.byTooltip('대화 메뉴'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('삭제'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('지우기'));
      await tester.pumpAndSettle();
      expect(find.koText('근저당권이 뭐예요?'), findsNothing);
      expect(find.koText('아직 지난 대화가 없어요'), findsOneWidget);
      expect(await history.list(), isEmpty);
    });

    testWidgets('지금 연 대화를 지우면 챗봇 화면도 빈 화면으로', (tester) async {
      final history = _seenHistory();
      await _pump(tester, history: history);
      await _send(tester, '가압류 알려줘');
      await _openDrawer(tester);
      await tester.tap(find.byTooltip('대화 메뉴'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('삭제'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('지우기'));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(ChatHistoryDrawer))).pop();
      await tester.pumpAndSettle();
      expect(find.koText(kChatAiNotice), findsOneWidget);
    });

    testWidgets('기록 없음 — 세이프 + 안내, 검색칸은 흐리게(못 씀)', (tester) async {
      await _pump(tester);
      await _openDrawer(tester);
      expect(find.koText('아직 지난 대화가 없어요'), findsOneWidget);
      expect(find.koText('물어본 내용이 여기에 차곡차곡 쌓여요'), findsOneWidget);
      expect(tester.widget<TextField>(_drawerSearch).enabled, isFalse);
      expect(find.koTextContaining('이 폰에만'), findsNothing, reason: '저장 위치 안내 문구는 넣지 않음');
    });

    testWidgets('서랍은 폭 300, 바깥을 누르면 닫힌다', (tester) async {
      await _pump(tester);
      await _openDrawer(tester);
      expect(tester.getSize(find.byKey(const ValueKey('chat-drawer'))).width, kChatDrawerWidth);
      await tester.tapAt(const Offset(340, 400));
      await tester.pumpAndSettle();
      expect(find.byType(ChatHistoryDrawer), findsNothing);
    });

    testWidgets('왼쪽으로 밀면 서랍이 닫힌다', (tester) async {
      await _pump(tester);
      await _openDrawer(tester);
      await tester.drag(find.byKey(const ValueKey('chat-drawer')), const Offset(-150, 0));
      await tester.pumpAndSettle();
      expect(find.byType(ChatHistoryDrawer), findsNothing);
    });
  });

  group('첫 안내 — 한 번만', () {
    testWidgets('첫 답 1초 뒤 말풍선이 밀렸다 돌아오며 화살표가 비친다 · 다음 답엔 없다 · 다시 켜도 없다', (tester) async {
      final history = MemoryChatHistoryRepository();
      await _pump(tester, history: history);
      await tester.enterText(_input, '가압류');
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('swipe-arrow')), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('swipe-arrow')), findsOneWidget, reason: '1초 뒤 살짝 밀림');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('swipe-arrow')), findsNothing, reason: '0.6초 뒤 제자리');
      expect(await history.hintSeen(ChatHint.swipe), isTrue);

      await tester.enterText(_input, '근저당');
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));
      expect(find.byKey(const ValueKey('swipe-arrow')), findsNothing, reason: '두 번째 답엔 안내 없음');
      await tester.pumpAndSettle();

      // 앱을 다시 켜도(같은 저장소) 없음
      await _pump(tester, history: history);
      await tester.enterText(_input, '확정일자');
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));
      expect(find.byKey(const ValueKey('swipe-arrow')), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('애니메이션 끄기 설정이면 밀기 안내 생략', (tester) async {
      await _pump(tester, history: MemoryChatHistoryRepository(), disableAnimations: true);
      await tester.enterText(_input, '가압류');
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));
      expect(find.byKey(const ValueKey('swipe-arrow')), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('처음 [새 대화]로 기록이 생기면 [지난 대화] 점 → 서랍을 열면 사라지고 다시 안 나온다', (tester) async {
      final history = MemoryChatHistoryRepository();
      await history.markHint(ChatHint.swipe);
      await _pump(tester, history: history);
      expect(find.byKey(const ValueKey('drawer-dot')), findsNothing);
      await _send(tester, '가압류');
      expect(find.byKey(const ValueKey('drawer-dot')), findsNothing, reason: '기록에 넘어가기 전엔 없음');
      await tester.tap(find.byTooltip('새 대화'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('drawer-dot')), findsOneWidget);

      await _openDrawer(tester);
      Navigator.of(tester.element(find.byType(ChatHistoryDrawer))).pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('drawer-dot')), findsNothing);

      await _send(tester, '근저당');
      await tester.tap(find.byTooltip('새 대화'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('drawer-dot')), findsNothing, reason: '한 번만');

      await _pump(tester, history: history);
      expect(find.byKey(const ValueKey('drawer-dot')), findsNothing, reason: '다시 켜도 없음');
    });

    testWidgets('점을 본 뒤 서랍을 안 열고 앱을 다시 켜면 점은 남아 있다', (tester) async {
      final history = MemoryChatHistoryRepository();
      await history.markHint(ChatHint.swipe);
      await _pump(tester, history: history);
      await _send(tester, '가압류');
      await tester.tap(find.byTooltip('새 대화'));
      await tester.pumpAndSettle();
      await _pump(tester, history: history);
      expect(find.byKey(const ValueKey('drawer-dot')), findsOneWidget);
    });
  });

  group('글자 배율 1.3 — 넘침 없음', () {
    testWidgets('칩 · 인용 띠 · 인용 칩 · 알림', (tester) async {
      await _pump(
        tester,
        textScale: 1.3,
        repo: _FakeContentRepo(answers: {
          '근저당권?': '근저당권은 집을 담보로 돈을 빌렸다는 아주 긴 표시예요. 은행이 먼저 받아 가는 권리라서 꼭 확인해야 해요.\n은행이 먼저 받아 가요.',
        }),
      );
      await _send(tester, '근저당권?');
      await tester.longPress(find.koText('은행이 먼저 받아 가요.'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '칩');
      await tester.tap(find.koText('복사'));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '알림');
      await tester.pumpAndSettle(const Duration(seconds: 3));

      await _swipe(tester, '근저당권은 집을 담보로', 100);
      expect(find.byType(QuoteBand), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '인용 띠');
      await _send(tester, '먼저 받아 간다는 게 무슨 뜻이에요? 쉽게 알려 주세요');
      expect(find.byType(QuoteChip), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '인용 칩');
    });

    testWidgets('서랍 목록 · 검색 · 시트 · 삭제 확인 · 이름 바꾸기 · 기록 없음', (tester) async {
      final now = DateTime.now();
      const long = '보증금을 돌려받지 못할까 봐 걱정되는데 근저당이 많이 잡힌 집은 어떻게 해야 하나요';
      final history = _seenHistory([
        _conv('a', long, now, answer: '아주 긴 답이에요. $long'),
        _conv('b', '근저당', now.subtract(const Duration(days: 2))),
      ]);
      await _pump(tester, history: history, textScale: 1.3);
      await _openDrawer(tester);
      expect(tester.takeException(), isNull, reason: '목록');
      await tester.enterText(_drawerSearch, '근저당');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '검색');
      await tester.tap(find.byTooltip('검색어 지우기'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('대화 메뉴').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '시트');
      await tester.tap(find.koText('삭제'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '삭제 확인');
      await tester.tap(find.koText('취소'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('대화 메뉴').first);
      await tester.pumpAndSettle();
      await tester.tap(find.koText('이름 바꾸기'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '이름 바꾸기');
      await tester.tap(find.koText('취소'));
      await tester.pumpAndSettle();

      await _pump(tester, textScale: 1.3);
      await _openDrawer(tester);
      expect(tester.takeException(), isNull, reason: '기록 없음');
    });
  });
}
