/// 챗봇 v2 단위 테스트 — 대화 저장/불러오기/이름 바꾸기/삭제 · 검색 · 묶음 이름 · 인용 전송 글.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/models/chat_history.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/repositories/chat_history_repository.dart';
import 'package:jeonse_ai/screens/chatbot/chat_history_logic.dart';
import 'package:shared_preferences/shared_preferences.dart';

ChatConversation _conv(
  String id, {
  String title = '근저당권이 뭐예요?',
  DateTime? at,
  List<ChatEntry>? entries,
}) {
  final t = at ?? DateTime(2026, 10, 24, 17, 43);
  return ChatConversation(
    id: id,
    title: title,
    createdAt: t,
    updatedAt: t,
    entries: entries ??
        const [
          ChatEntry(id: 'u1', isUser: true, text: '근저당권이 뭐예요?'),
          ChatEntry(id: 'b1', isUser: false, text: '집을 담보로 돈을 빌렸다는 **표시**예요.\n은행이 먼저 받아 가요.'),
        ],
  );
}

void main() {
  group('저장소 — 저장 · 불러오기 · 이름 바꾸기 · 삭제', () {
    for (final make in <String, ChatHistoryRepository Function()>{
      '메모리': MemoryChatHistoryRepository.new,
      '폰 저장': PrefsChatHistoryRepository.new,
    }.entries) {
      test('${make.key}: 최근 것이 위 · 같은 id는 바꿈 · 이름 바꾸기 · 삭제', () async {
        SharedPreferences.setMockInitialValues({});
        final repo = make.value();
        await repo.save(_conv('a', at: DateTime(2026, 10, 20)));
        await repo.save(_conv('b', at: DateTime(2026, 10, 22)));
        expect((await repo.list()).map((c) => c.id), ['b', 'a']);

        // 이어 물으면 마지막 시각이 바뀌어 맨 위로
        final a = (await repo.list()).last;
        await repo.save(a.copyWith(updatedAt: DateTime(2026, 10, 24)));
        expect((await repo.list()).map((c) => c.id), ['a', 'b']);
        expect((await repo.list()).length, 2);

        await repo.rename('b', '보증금 질문');
        expect((await repo.list()).firstWhere((c) => c.id == 'b').title, '보증금 질문');

        await repo.delete('a');
        expect((await repo.list()).map((c) => c.id), ['b']);
      });
    }

    test('폰 저장: 앱을 다시 켜도(새 저장소) 대화·인용·안내 표시가 남는다', () async {
      SharedPreferences.setMockInitialValues({});
      final first = PrefsChatHistoryRepository();
      await first.save(_conv('a', entries: const [
        ChatEntry(id: 'u1', isUser: true, text: '이게 뭐예요?', quote: ChatQuote(text: '은행이 먼저 받아 가요.', sourceId: 'b0')),
        ChatEntry(id: 'b1', isUser: false, text: '먼저 받아 간다는 뜻이에요.'),
      ]));
      await first.markHint(ChatHint.swipe);

      final again = PrefsChatHistoryRepository();
      final list = await again.list();
      expect(list.single.entries.first.quote?.text, '은행이 먼저 받아 가요.');
      expect(list.single.entries.first.quote?.sourceId, 'b0');
      expect(list.single.createdAt, DateTime(2026, 10, 24, 17, 43));
      expect(await again.hintSeen(ChatHint.swipe), isTrue);
      expect(await again.hintSeen(ChatHint.drawerDot), isFalse);
    });

    test('망가진 기록은 건너뛰고 앱은 멀쩡하다', () async {
      SharedPreferences.setMockInitialValues({'chat.history.v1': '[{"id":1},"x",{"id":"a"}]'});
      expect(await PrefsChatHistoryRepository().list(), isEmpty);
      SharedPreferences.setMockInitialValues({'chat.history.v1': '이건 JSON이 아님'});
      expect(await PrefsChatHistoryRepository().list(), isEmpty);
    });

    test('상한: 대화 $kChatHistoryMaxConversations개, 말 $kChatHistoryMaxEntries개 — 오래된 것부터 지움', () async {
      final repo = MemoryChatHistoryRepository();
      for (var i = 0; i < kChatHistoryMaxConversations + 3; i++) {
        await repo.save(_conv('c$i', at: DateTime(2026, 1, 1).add(Duration(hours: i))));
      }
      final list = await repo.list();
      expect(list.length, kChatHistoryMaxConversations);
      expect(list.any((c) => c.id == 'c0'), isFalse, reason: '가장 오래된 것이 지워진다');
      expect(list.first.id, 'c${kChatHistoryMaxConversations + 2}');

      final long = [
        for (var i = 0; i < kChatHistoryMaxEntries + 10; i++) ChatEntry(id: 'm$i', isUser: i.isEven, text: '$i'),
      ];
      await repo.save(_conv('long', at: DateTime(2027), entries: long));
      final saved = (await repo.list()).first;
      expect(saved.entries.length, kChatHistoryMaxEntries);
      expect(saved.entries.last.id, 'm${kChatHistoryMaxEntries + 9}');
    });
  });

  group('묶음 이름 · 시각 글', () {
    final now = DateTime(2026, 10, 24, 21, 0);
    test('오늘 · 어제 · 지난 7일 · 달 · 다른 해', () {
      expect(chatGroupLabel(DateTime(2026, 10, 24, 0, 1), now), '오늘');
      expect(chatGroupLabel(DateTime(2026, 10, 23, 23, 59), now), '어제');
      expect(chatGroupLabel(DateTime(2026, 10, 18), now), '지난 7일');
      expect(chatGroupLabel(DateTime(2026, 10, 17), now), '10월');
      expect(chatGroupLabel(DateTime(2026, 9, 3), now), '9월');
      expect(chatGroupLabel(DateTime(2025, 12, 31), now), '2025년 12월');
    });

    test('시각 — 오후 5:43 · 오전 12:05 · 날짜', () {
      expect(koreanClock(DateTime(2026, 10, 24, 17, 43)), '오후 5:43');
      expect(koreanClock(DateTime(2026, 10, 24, 0, 5)), '오전 12:05');
      expect(koreanClock(DateTime(2026, 10, 24, 12, 0)), '오후 12:00');
      expect(chatRowTime(DateTime(2026, 10, 24, 17, 43), now), '오후 5:43');
      expect(chatRowTime(DateTime(2026, 10, 20, 9, 0), now), '10월 20일');
      expect(chatSheetTime(DateTime(2026, 10, 24, 17, 43), now), '오늘 오후 5:43');
      expect(chatSheetTime(DateTime(2026, 10, 23, 8, 2), now), '어제 오전 8:02');
      expect(chatSheetTime(DateTime(2026, 9, 3, 13, 0), now), '9월 3일 오후 1:00');
    });
  });

  group('검색 — 제목 + 대화 속 모든 글', () {
    final all = [
      _conv('old', title: '확정일자 언제?', at: DateTime(2026, 10, 1), entries: const [
        ChatEntry(id: 'u', isUser: true, text: '확정일자 언제?'),
        ChatEntry(id: 'b', isUser: false, text: '이사 전에 받아요.\n주민센터에 가서 계약서를 내밀면 근저당이 아니라 **확정일자**를 받아요.'),
      ]),
      _conv('new', title: '근저당권이 뭐예요?', at: DateTime(2026, 10, 24)),
      _conv('none', title: '전입신고', at: DateTime(2026, 10, 23), entries: const [
        ChatEntry(id: 'u', isUser: true, text: '전입신고'),
        ChatEntry(id: 'b', isUser: false, text: '14일 안에 해요.'),
      ]),
    ];

    test('제목·본문 둘 다 찾고, 최근 대화가 앞', () {
      final hits = searchChats(all, '근저당');
      expect(hits.map((h) => h.conversation.id), ['new', 'old']);
      expect(hits.first.titleMatches, [const ChatMatch(0, 3)]);
      expect(hits.last.titleMatches, isEmpty);
    });

    test('아래 줄은 맞은 문장 주변 — 앞이 잘리면 "…", 맞은 위치 표시', () {
      final hit = searchChats(all, '근저당').last;
      expect(hit.snippet, startsWith('…'));
      expect(hit.snippet, contains('근저당이 아니라 확정일자를'));
      expect(hit.snippet!.contains('**'), isFalse, reason: '굵게 표시는 빼고 찾는다');
      final m = hit.snippetMatches.single;
      expect(hit.snippet!.substring(m.start, m.end), '근저당');
      expect(m.start, kSnippetLead + 1, reason: "'…' 한 글자 + 앞 글자 $kSnippetLead개");
    });

    test('짧은 문장은 자르지 않는다 · 대소문자 무시 · 여러 번 나오면 전부', () {
      final c = _conv('x', title: 'LH 전세임대', entries: const [
        ChatEntry(id: 'u', isUser: true, text: 'lh랑 LH 차이?'),
        ChatEntry(id: 'b', isUser: false, text: '같아요.'),
      ]);
      final hit = searchChats([c], 'lh').single;
      expect(hit.snippet, 'lh랑 LH 차이?');
      expect(hit.snippetMatches.length, 2);
      expect(hit.titleMatches, [const ChatMatch(0, 2)]);
    });

    test('없으면 빈 목록, 빈 검색어도 빈 목록', () {
      expect(searchChats(all, '가압류'), isEmpty);
      expect(searchChats(all, '   '), isEmpty);
    });

    test('머리글 — 받침 따라 이/가', () {
      expect(searchHeader('근저당', 2), "'근저당'이 들어간 대화 2개");
      expect(searchHeader('보증보험', 1), "'보증보험'이 들어간 대화 1개");
      expect(searchHeader('전세가', 1), "'전세가'가 들어간 대화 1개");
      expect(searchEmptyMessage('가압류'), "'가압류'가 들어간 대화가 없어요");
      expect(searchEmptyMessage('HUG'), "'HUG'이(가) 들어간 대화가 없어요");
    });
  });

  group('인용 전송 글 — 질문은 절대 안 잘리고 인용은 AI에게 간다', () {
    /// 서버(_clean_turns)가 하는 일을 그대로: 최근 8개, 사람 말 500자 · 답 800자 자르기, 앞이 답이면 버림
    String cut(String s, int limit) => s.length > limit ? s.substring(0, limit) : s;

    List<ChatTurn> serverView(List<ChatTurn> turns) {
      var out = [
        for (final t in turns)
          t.isUser ? ChatTurn.user(cut(t.content.trim(), kServerUserLimit)) : ChatTurn.bot(cut(t.content.trim(), kServerBotLimit)),
      ];
      if (out.length > kServerMaxTurns) out = out.sublist(out.length - kServerMaxTurns);
      while (out.isNotEmpty && !out.first.isUser) {
        out.removeAt(0);
      }
      return out;
    }

    String everything(List<ChatTurn> turns) => turns.map((t) => t.content).join('\n');

    test('인용 없는 대화는 그대로', () {
      final turns = buildChatTurns(const [
        ChatEntry(id: '1', isUser: true, text: '가압류 알려줘'),
        ChatEntry(id: '2', isUser: false, text: '집을 묶어 두는 거예요.'),
        ChatEntry(id: '3', isUser: true, text: '더 쉽게'),
      ]);
      expect(turns.map((t) => t.content), ['가압류 알려줘', '집을 묶어 두는 거예요.', '더 쉽게']);
    });

    test('바로 앞 답 전체를 인용 → 답은 그대로 두고 질문 앞에 짧은 안내만', () {
      const answer = '근저당권은 **담보** 표시예요.\n은행이 먼저 받아 가요.';
      final turns = buildChatTurns(const [
        ChatEntry(id: '1', isUser: true, text: '근저당권?'),
        ChatEntry(id: '2', isUser: false, text: answer),
        ChatEntry(id: '3', isUser: true, text: '먼저 받아 간다는 게 뭐야?', quote: ChatQuote(text: answer, sourceId: '2')),
      ]);
      expect(turns.length, 3);
      expect(turns.last.content, '$kQuoteLeadWhole\n먼저 받아 간다는 게 뭐야?');
    });

    test('일부를 인용 → 안내 + 「인용」 + 질문을 한 말로', () {
      final turns = buildChatTurns(const [
        ChatEntry(id: '1', isUser: true, text: '근저당권?'),
        ChatEntry(id: '2', isUser: false, text: '담보 표시예요.\n은행이 먼저 받아 가요.'),
        ChatEntry(id: '3', isUser: true, text: '왜요?', quote: ChatQuote(text: '은행이 먼저 받아 가요.', sourceId: '2')),
      ]);
      expect(turns.last.content, '$kQuoteLeadPart\n「은행이 먼저 받아 가요.」\n왜요?');
      expect(turns.where((t) => !t.isUser).length, 1, reason: '답 자리를 따로 만들지 않는다');
    });

    test('긴 인용(450자) + 가장 긴 질문(300자) → 인용은 답 자리로, 질문은 안 잘림', () {
      final longAnswer = '가' * 450;
      final question = '나' * 300;
      final turns = buildChatTurns([
        const ChatEntry(id: '1', isUser: true, text: '처음 질문'),
        ChatEntry(id: '2', isUser: false, text: longAnswer),
        const ChatEntry(id: '3', isUser: true, text: '다른 질문'),
        const ChatEntry(id: '4', isUser: false, text: '다른 답'),
        ChatEntry(id: '5', isUser: true, text: question, quote: ChatQuote(text: longAnswer, sourceId: '2')),
      ]);
      final seen = serverView(turns);
      expect(seen.last.isUser, isTrue);
      expect(seen.last.content, endsWith(question), reason: '질문이 통째로 남는다');
      expect(seen[seen.length - 2].content, longAnswer, reason: '인용이 질문 바로 앞 답 자리에 통째로');
    });

    test('어떤 길이 조합에서도 질문·인용 모두 서버에 그대로 닿는다', () {
      for (final quoteLen in [1, 50, 150, 170, 200, 449, 450]) {
        for (final qLen in [1, 30, 150, 299, 300]) {
          final quote = '인' * quoteLen;
          final question = '질' * qLen;
          final entries = <ChatEntry>[
            for (var i = 0; i < 10; i++) ChatEntry(id: 'h$i', isUser: i.isEven, text: '앞 대화 $i'),
            ChatEntry(id: 'src', isUser: false, text: quote),
            const ChatEntry(id: 'u', isUser: true, text: '사이 질문'),
            const ChatEntry(id: 'b', isUser: false, text: '사이 답'),
            ChatEntry(id: 'q', isUser: true, text: question, quote: ChatQuote(text: quote, sourceId: 'src')),
          ];
          final turns = buildChatTurns(entries);
          expect(turns.length, lessThanOrEqualTo(kServerMaxTurns));
          final seen = serverView(turns);
          expect(seen.last.content, endsWith(question), reason: '인용 $quoteLen자 + 질문 $qLen자: 질문 잘림');
          expect(everything(seen), contains(quote), reason: '인용 $quoteLen자 + 질문 $qLen자: 인용 빠짐');
        }
      }
    });
  });

  group('글 다듬기', () {
    test('굵게 표시 빼고 첫 줄 · 제목은 한 줄', () {
      expect(firstChatLine('\n**근저당권**은 담보예요.\n둘째 줄'), '근저당권은 담보예요.');
      expect(chatTitleFrom('  등기부등본은\n어떻게   떼요?'), '등기부등본은');
      expect(chatTitleFrom('전세가율   계산'), '전세가율 계산');
    });
  });

  group('디자인 토큰만 (완료 조건 grep)', () {
    const files = [
      'lib/screens/chatbot/glossary_chatbot_screen.dart',
      'lib/screens/chatbot/chat_mascot.dart',
      'lib/screens/chatbot/chat_answer_parser.dart',
      'lib/screens/chatbot/chat_history_drawer.dart',
      'lib/screens/chatbot/chat_history_logic.dart',
      'lib/screens/chatbot/chat_quote.dart',
      'lib/screens/chatbot/chat_selection.dart',
      'lib/screens/chatbot/chat_swipe.dart',
      'lib/models/chat_history.dart',
      'lib/repositories/chat_history_repository.dart',
    ];
    test('하드코딩 색(Color(0x…)·Colors.xxx)·글자 크기(fontSize:) 없음 — 그림자 색만 예외', () {
      for (final f in files) {
        final lines = File(f).readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('///') || line.trimLeft().startsWith('//')) continue;
          final shadow = line.contains('BoxShadow(');
          expect(line.contains('Color(0x') && !shadow, isFalse, reason: '$f:${i + 1} $line');
          expect(RegExp(r'(?<![A-Za-z])Colors\.').hasMatch(line), isFalse, reason: '$f:${i + 1} $line');
          expect(RegExp(r'fontSize\s*:').hasMatch(line), isFalse, reason: '$f:${i + 1} $line');
        }
      }
    });
  });
}
