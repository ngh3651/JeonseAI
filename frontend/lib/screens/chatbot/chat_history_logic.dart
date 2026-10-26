/// 챗봇 v2 — 위젯 없는 규칙들 (2026-10-24): 서버에 보낼 글 만들기 · 묶음 이름 · 시각 글 · 검색.
///
/// 순수 Dart라 단위 테스트로 바로 확인한다(`test/chat_history_test.dart`).
library;

import '../../design_system/text/keep_all.dart';
import '../../models/chat_history.dart';
import '../../models/content_models.dart';

// ══════════════════════════════════════════════════════════════════════════════
// 서버에 보낼 글 — 화면 모양(인용 칩 + 질문)과 보내는 모양을 나눈다
// ══════════════════════════════════════════════════════════════════════════════

/// 서버가 쓰는 최근 말 개수 (`backend/app/services/chat.py` MAX_TURNS)
const int kServerMaxTurns = 8;

/// 서버가 사람 말을 자르는 길이 (MAX_USER_CHARS) — 앞에서부터 이 길이만 남긴다
const int kServerUserLimit = 500;

/// 서버가 앞선 답을 자르는 길이 (MAX_HISTORY_CHARS)
const int kServerBotLimit = 800;

/// 바로 앞 답 **전체**를 인용했을 때 — 답은 이미 대화에 있으니 가리키기만 한다
const String kQuoteLeadWhole = '바로 위 답에 이어서 물어요.';

/// 답의 **일부**(또는 더 앞의 답)를 인용했을 때 — 인용을 질문 앞에 붙인다
const String kQuoteLeadPart = '앞 답의 이 부분에 이어서 물어요.';

/// 화면에 쌓인 말 → 서버에 보낼 대화 (최근 [kServerMaxTurns]개).
///
/// 서버는 사람 말을 앞에서부터 500자만 남긴다. 그래서 인용을 그냥 질문 앞에 붙이면 질문이 잘릴 수 있다.
/// - 바로 앞 답 전체를 인용 → 질문 앞에 짧은 안내만 (답은 이미 앞 말로 들어 있다)
/// - 그 밖 → `안내 + 「인용」 + 질문`이 500자 안이면 한 말로
/// - 넘치면 → 인용을 **질문 바로 앞의 답 자리**(800자까지)에 넣고, 질문엔 짧은 안내만
///
/// 어느 경우든 **질문은 잘리지 않고**(질문 ≤ 300자 + 안내 < 500) 인용은 AI에게 간다.
List<ChatTurn> buildChatTurns(List<ChatEntry> entries) {
  final out = <ChatTurn>[];
  for (final e in entries) {
    if (!e.isUser) {
      out.add(ChatTurn.bot(e.text));
      continue;
    }
    final q = e.text.trim();
    final quote = stripWordJoiner(e.quote?.text ?? '').trim();
    if (quote.isEmpty) {
      out.add(ChatTurn.user(q));
      continue;
    }
    final prevBot = out.isNotEmpty && !out.last.isUser ? out.last.content.trim() : null;
    if (prevBot != null && prevBot == quote) {
      out.add(ChatTurn.user('$kQuoteLeadWhole\n$q'));
      continue;
    }
    final inline = '$kQuoteLeadPart\n「$quote」\n$q';
    if (inline.length <= kServerUserLimit) {
      out.add(ChatTurn.user(inline));
      continue;
    }
    out.add(ChatTurn.bot(quote.length > kServerBotLimit ? quote.substring(0, kServerBotLimit) : quote));
    out.add(ChatTurn.user('$kQuoteLeadWhole\n$q'));
  }
  return out.length > kServerMaxTurns ? out.sublist(out.length - kServerMaxTurns) : out;
}

// ══════════════════════════════════════════════════════════════════════════════
// 글 다듬기
// ══════════════════════════════════════════════════════════════════════════════

/// `**굵게**` 표시·줄바꿈 금지 부호를 뺀 글
String plainChatText(String text) => stripWordJoiner(text).replaceAll('**', '');

/// 첫 줄(빈 줄 건너뜀) — 인용 띠·인용 칩·서랍 아래 줄에 쓴다
String firstChatLine(String text) {
  for (final line in plainChatText(text).split('\n')) {
    final t = line.trim();
    if (t.isNotEmpty) return t;
  }
  return '';
}

/// 대화 제목 = 첫 질문 한 줄 (공백 정리)
String chatTitleFrom(String question) => firstChatLine(question).replaceAll(RegExp(r'\s+'), ' ');

// ══════════════════════════════════════════════════════════════════════════════
// 시각 글 · 묶음 이름
// ══════════════════════════════════════════════════════════════════════════════

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

int _daysAgo(DateTime t, DateTime now) => _day(now).difference(_day(t)).inHours ~/ 24;

/// '오후 5:43'
String koreanClock(DateTime t) {
  final ampm = t.hour < 12 ? '오전' : '오후';
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$ampm $h:${t.minute.toString().padLeft(2, '0')}';
}

String _date(DateTime t, DateTime now) => t.year == now.year ? '${t.month}월 ${t.day}일' : '${t.year}년 ${t.month}월 ${t.day}일';

/// 서랍 묶음 이름 — 오늘 · 어제 · 지난 7일 · 그 전은 달('9월', 해가 다르면 '2025년 9월')
String chatGroupLabel(DateTime t, DateTime now) {
  final days = _daysAgo(t, now);
  if (days <= 0) return '오늘';
  if (days == 1) return '어제';
  if (days < 7) return '지난 7일';
  return t.year == now.year ? '${t.month}월' : '${t.year}년 ${t.month}월';
}

/// 서랍 한 줄의 시각 — 오늘·어제는 '오후 5:43', 그 전은 '10월 20일'
String chatRowTime(DateTime t, DateTime now) => _daysAgo(t, now) <= 1 ? koreanClock(t) : _date(t, now);

/// [⋯] 시트의 시각 — '오늘 오후 5:43' · '어제 오후 5:43' · '10월 20일 오후 5:43'
String chatSheetTime(DateTime t, DateTime now) {
  final days = _daysAgo(t, now);
  final day = days <= 0 ? '오늘' : (days == 1 ? '어제' : _date(t, now));
  return '$day ${koreanClock(t)}';
}

// ══════════════════════════════════════════════════════════════════════════════
// 검색 — 제목 + 대화 속 모든 글
// ══════════════════════════════════════════════════════════════════════════════

/// 글 안에서 맞은 곳 [start, end)
class ChatMatch {
  const ChatMatch(this.start, this.end);

  final int start;
  final int end;

  @override
  bool operator ==(Object other) => other is ChatMatch && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => '[$start,$end)';
}

/// 검색 결과 한 줄
class ChatSearchHit {
  const ChatSearchHit({
    required this.conversation,
    required this.titleMatches,
    this.snippet,
    this.snippetMatches = const [],
  });

  final ChatConversation conversation;
  final List<ChatMatch> titleMatches;

  /// 본문에서 맞았으면 그 문장 주변(앞이 잘리면 '…'로 시작). 제목에서만 맞았으면 null
  final String? snippet;
  final List<ChatMatch> snippetMatches;
}

/// 맞은 문장 앞에 남길 글자 수 — 그보다 앞은 '…'로 자른다
const int kSnippetLead = 10;

/// 대소문자 무시로 [query]가 나오는 곳 모두
List<ChatMatch> findMatches(String text, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  final lower = text.toLowerCase();
  final out = <ChatMatch>[];
  var from = 0;
  while (true) {
    final i = lower.indexOf(q, from);
    if (i < 0) break;
    out.add(ChatMatch(i, i + q.length));
    from = i + q.length;
  }
  return out;
}

/// 제목 + 본문 검색 — 최근 대화가 앞
List<ChatSearchHit> searchChats(List<ChatConversation> all, String query) {
  final q = query.trim();
  if (q.isEmpty) return const [];
  final hits = <ChatSearchHit>[];
  for (final c in all) {
    final titleMatches = findMatches(c.title, q);
    String? snippet;
    var snippetMatches = const <ChatMatch>[];
    for (final e in c.entries) {
      for (final rawLine in plainChatText(e.text).split('\n')) {
        final line = rawLine.trim();
        final m = findMatches(line, q);
        if (m.isEmpty) continue;
        final cut = m.first.start > kSnippetLead ? m.first.start - kSnippetLead : 0;
        snippet = cut > 0 ? '…${line.substring(cut)}' : line;
        snippetMatches = findMatches(snippet, q);
        break;
      }
      if (snippet != null) break;
    }
    if (titleMatches.isEmpty && snippet == null) continue;
    hits.add(ChatSearchHit(
      conversation: c,
      titleMatches: titleMatches,
      snippet: snippet,
      snippetMatches: snippetMatches,
    ));
  }
  hits.sort((a, b) => b.conversation.updatedAt.compareTo(a.conversation.updatedAt));
  return hits;
}

/// 받침이 있으면 '이', 없으면 '가' — 한글이 아니면 '이(가)'
String subjectJosa(String word) {
  final w = word.trim();
  if (w.isEmpty) return '이';
  final code = w.codeUnitAt(w.length - 1);
  if (code < 0xAC00 || code > 0xD7A3) return '이(가)';
  return (code - 0xAC00) % 28 == 0 ? '가' : '이';
}

/// "'근저당'이 들어간 대화 2개"
String searchHeader(String query, int count) {
  final q = query.trim();
  return "'$q'${subjectJosa(q)} 들어간 대화 $count개";
}

/// "'○○'이 들어간 대화가 없어요"
String searchEmptyMessage(String query) {
  final q = query.trim();
  return "'$q'${subjectJosa(q)} 들어간 대화가 없어요";
}
