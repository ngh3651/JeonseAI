/// S-12 챗봇 화면 (2026-10-24 리디자인) — 빈 화면 · 대화 · 기다리는 중 · 연결 실패.
///
/// 못 박는 것 (Claude Design 협의 스펙):
///   · 빈 화면: 추천 질문 4개(누르면 바로 보냄), [더 보기] 없음, AI 안내 한 줄
///   · 말풍선 폭 ≤ 화면의 75%, 말풍선 밑 라벨·리포트 버튼 없음
///   · 기다리는 중: "답을 쓰고 있어요…" + 보내기 비활성
///   · 연결 실패: 안내 + [다시 시도](재전송), 경고 아이콘 없음
///   · 글자 배율 1.3에서 네 상태 모두 넘침 없음 · 입력칸은 4줄까지
///   · 앞 대화를 통째로 보낸다 · 엔터는 줄바꿈
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/text/keep_all.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/chatbot/chat_mascot.dart';
import 'package:jeonse_ai/screens/chatbot/glossary_chatbot_screen.dart';
import 'package:jeonse_ai/services/api_client.dart';
import 'package:jeonse_ai/state/app_session.dart';
import 'package:provider/provider.dart';

import 'support/ko_finders.dart';

/// 서버가 실제로 내려주는 18개 (GET /api/glossary, 2026-08-14 확인).
/// **대항력은 없다** — 검수 대기라 응답에서 제외된다(docs/terms-review-queue.md).
class _FakeContentRepo implements ContentRepository {
  _FakeContentRepo({this.reply, this.pending, this.fail = false});

  /// null이면 질문을 되풀이한 답을 준다.
  final ChatReply? reply;

  /// 있으면 이 Completer가 끝날 때까지 답을 기다린다(기다리는 중 상태 시험)
  final Completer<ChatReply>? pending;

  /// true면 연결 실패
  bool fail;

  /// 화면이 보낸 대화들(호출마다 한 묶음)
  final List<List<ChatTurn>> sent = [];

  @override
  Future<List<GlossaryTerm>> glossaryTerms() async => const [];

  @override
  Future<ChatReply> chat(List<ChatTurn> messages, {String? reportId}) async {
    sent.add(List.of(messages));
    if (fail) throw const ApiException('연결 실패');
    if (pending != null) return pending!.future;
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
  Completer<ChatReply>? pending,
  bool fail = false,
  double textScale = 1.0,
  double width = 360,
  bool disableAnimations = false,
}) async {
  final repo = _FakeContentRepo(reply: reply, pending: pending, fail: fail);
  tester.view.physicalSize = Size(width * 3, 760 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSession()),
        ChangeNotifierProvider<AnalysisRepository>(create: (_) => _EmptyAnalysisRepo()),
        Provider<ContentRepository>.value(value: repo),
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
  return repo;
}

/// 지금 달리는 세이프가 그리는 프레임 경로
String _runFrame(WidgetTester tester) {
  final img = tester.widget<Image>(find.descendant(of: find.byType(SafeRunning), matching: find.byType(Image)));
  final provider = img.image;
  final asset = provider is ResizeImage ? provider.imageProvider : provider;
  return (asset as AssetImage).assetName;
}

/// 보내고, 답이 올 때까지(기다리는 중이면 몇 프레임만)
Future<void> _send(WidgetTester tester, String text, {bool settle = true}) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.byIcon(Icons.arrow_upward)); // 엔터는 줄바꿈 — 보내기는 버튼으로
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('① 빈 화면', () {
    testWidgets('추천 질문 4개 + AI 안내, [더 보기]·단어 칩 없음', (tester) async {
      await _pump(tester);
      expect(find.koText('챗봇'), findsOneWidget);
      expect(find.koText('전세 · 부동산 · 리포트, 뭐든 물어보세요!'), findsOneWidget);
      expect(find.koText(kChatAiNotice), findsOneWidget);
      for (final q in kSuggestedQuestions) {
        expect(find.koText(q), findsOneWidget);
      }
      expect(kSuggestedQuestions.length, 4);
      expect(find.koTextContaining('더 보기'), findsNothing);
      expect(find.byType(ActionChip), findsNothing);
    });

    testWidgets('질문 카드를 누르면 그 문장을 바로 보낸다', (tester) async {
      final repo = await _pump(tester);
      await tester.tap(find.koText(kSuggestedQuestions[1]));
      await tester.pumpAndSettle();
      expect(repo.sent.single.single.content, kSuggestedQuestions[1]);
      expect(find.koText('${kSuggestedQuestions[1]} 설명이에요.'), findsOneWidget);
    });
  });

  group('② 대화', () {
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

    testWidgets('답에 출처 라벨·리포트 버튼이 없다', (tester) async {
      await _pump(tester);
      await _send(tester, '근저당권');
      expect(find.koText('근저당권 설명이에요.'), findsOneWidget);
      for (final gone in ['검수된 용어 사전', '준비된 문구', 'solar-pro2', '내 리포트 보기', '매물 분석하러 가기']) {
        expect(find.koText(gone), findsNothing, reason: '$gone 이 보여요');
      }
      expect(find.koText('세이프'), findsNothing, reason: '마스코트 옆 이름 줄은 뺐다(2026-10-24)');
    });

    testWidgets('**굵게**는 굵게(primaryDeep), 표시 기호는 안 보인다', (tester) async {
      await _pump(tester, reply: const ChatReply(answer: '가압류는 **집을 잠깐 묶어 두는 것**이에요.\n쉽죠?'));
      await _send(tester, '가압류 쉽게');
      expect(find.koTextContaining('**'), findsNothing);
      final boldText = StringBuffer();
      for (final r in tester.widgetList<RichText>(find.byType(RichText))) {
        r.text.visitChildren((s) {
          if (s is TextSpan && s.style?.fontWeight == FontWeight.w600) {
            boldText.write(stripWordJoiner(s.text ?? ''));
          }
          return true;
        });
      }
      expect(boldText.toString(), contains('집을 잠깐 묶어 두는 것'));
    });

    testWidgets('번호 목록·점 목록·주소 칸을 그린다', (tester) async {
      await _pump(
        tester,
        reply: const ChatReply(
          answer: '인터넷등기소(iros.go.kr)에서 떼요.\n1. 사이트 접속\n2. 주소 검색\n· 열람용 700원\n· 발급용 1,000원',
        ),
      );
      await _send(tester, '등기부 떼는 법');
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('iros.go.kr'), findsOneWidget);
      expect(find.koTextContaining('사이트 접속'), findsOneWidget);
      expect(find.koTextContaining('열람용 700원'), findsOneWidget);
      expect(tester.takeException(), isNull);
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
      await _pump(tester, reply: ChatReply(answer: '아주 긴 답이에요 ' * 10));
      await _send(tester, '아주 긴 질문이에요 ' * 10);
      const limit = 360.0 * kBubbleWidthFactor;
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

    testWidgets('입력칸은 4줄까지만 늘어나고 안에서 스크롤', (tester) async {
      await _pump(tester);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.minLines, 1);
      expect(field.maxLines, 4);
      final h1 = tester.getSize(find.byType(TextField)).height;
      await tester.enterText(find.byType(TextField), '1\n2\n3\n4');
      await tester.pumpAndSettle();
      final h4 = tester.getSize(find.byType(TextField)).height;
      await tester.enterText(find.byType(TextField), '1\n2\n3\n4\n5');
      await tester.pumpAndSettle();
      final h5 = tester.getSize(find.byType(TextField)).height;
      expect(h4, greaterThan(h1));
      expect(h5, h4);
    });
  });

  group('③ 기다리는 중', () {
    testWidgets('점 + "답을 쓰고 있어요…", 보내기 비활성', (tester) async {
      final pending = Completer<ChatReply>();
      await _pump(tester, pending: pending);
      await _send(tester, '안녕', settle: false);
      expect(find.koText(kChatLoadingMessage), findsOneWidget);
      final btn = tester.widget<Semantics>(
        find.byWidgetPredicate((w) => w is Semantics && w.properties.label == '답을 기다리는 중'),
      );
      expect(btn.properties.enabled, isFalse);
      pending.complete(const ChatReply(answer: '안녕하세요!'));
      await tester.pumpAndSettle();
      expect(find.koText(kChatLoadingMessage), findsNothing);
      expect(find.koText('안녕하세요!'), findsOneWidget);
    });

    testWidgets('세이프가 달리기 프레임 4장을 90ms씩 바꾼다', (tester) async {
      final pending = Completer<ChatReply>();
      await _pump(tester, pending: pending);
      await _send(tester, '안녕', settle: false);
      expect(find.byType(SafeRunning), findsOneWidget);
      final seen = <String>{};
      for (int i = 0; i < 4; i++) {
        seen.add(_runFrame(tester));
        await tester.pump(const Duration(milliseconds: 90));
      }
      expect(seen, kSafeRunFrames.toSet());
      pending.complete(const ChatReply(answer: '네'));
      await tester.pumpAndSettle();
    });

    testWidgets('애니메이션 끄기 설정이면 첫 프레임에 멈춘다', (tester) async {
      final pending = Completer<ChatReply>();
      await _pump(tester, pending: pending, disableAnimations: true);
      await _send(tester, '안녕', settle: false);
      final first = _runFrame(tester);
      await tester.pump(const Duration(milliseconds: 90));
      expect(_runFrame(tester), first);
      pending.complete(const ChatReply(answer: '네'));
      await tester.pumpAndSettle();
    });

    test('달리기 프레임 파일이 저장소에 있다', () {
      for (final f in kSafeRunFrames) {
        expect(File(f).existsSync(), isTrue, reason: f);
      }
    });
  });

  group('④ 연결 실패', () {
    testWidgets('안내 + [다시 시도] → 다시 보냄, 경고 아이콘 없음', (tester) async {
      final repo = await _pump(tester, fail: true);
      await _send(tester, '안녕');
      expect(find.koText(kChatFailedMessage), findsOneWidget);
      expect(find.byIcon(Icons.error), findsNothing);
      expect(find.byIcon(Icons.warning_amber), findsNothing);
      repo.fail = false;
      await tester.tap(find.koText('다시 시도'));
      await tester.pumpAndSettle();
      expect(repo.sent.length, 2);
      expect(find.koText('안녕 설명이에요.'), findsOneWidget);
      expect(find.koText(kChatFailedMessage), findsNothing);
    });
  });

  group('글자 배율 1.3', () {
    testWidgets('네 상태 모두 넘치지 않는다', (tester) async {
      // ① 빈 화면
      await _pump(tester, textScale: 1.3);
      expect(tester.takeException(), isNull, reason: '빈 화면');
      // ② 대화
      await _pump(
        tester,
        textScale: 1.3,
        reply: const ChatReply(answer: '등기부등본은 **인터넷등기소**에서 떼요.\n1. 사이트 접속\n· 열람용 700원'),
      );
      await _send(tester, '등기부등본 어떻게 떼요?');
      expect(tester.takeException(), isNull, reason: '대화');
      // ③ 기다리는 중
      final pending = Completer<ChatReply>();
      await _pump(tester, textScale: 1.3, pending: pending);
      await _send(tester, '안녕', settle: false);
      expect(tester.takeException(), isNull, reason: '기다리는 중');
      pending.complete(const ChatReply(answer: '네'));
      await tester.pumpAndSettle();
      // ④ 연결 실패
      await _pump(tester, textScale: 1.3, fail: true);
      await _send(tester, '안녕');
      expect(tester.takeException(), isNull, reason: '연결 실패');
    });
  });
}
