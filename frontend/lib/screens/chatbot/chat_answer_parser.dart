/// 챗봇 답 글 → 화면 덩어리 (2026-10-24 챗봇 리디자인).
///
/// 서버 답은 줄바꿈(`\n`) + `**굵게**` + 가끔 번호 목록(`1. `)·점 목록(`· `)·기관 주소(`iros.go.kr`)로 온다.
/// 이 파일은 **순수 Dart**다(위젯 없음) — 글을 덩어리로 나누고, 한 줄 안을 조각(글·굵게·주소)으로 나눈다.
/// 그리는 일은 화면(`glossary_chatbot_screen.dart`)이 한다.
///
/// 규칙:
/// - 빈 줄, 또는 글 ↔ 번호 목록 ↔ 점 목록이 바뀌는 곳에서 덩어리를 나눈다.
/// - 모르는 마크다운(`#` 제목, 표 등)은 그냥 일반 문장으로 둔다(깨지지 않게).
library;

/// 덩어리 종류
enum ChatBlockKind { paragraph, numbered, bullets }

/// 덩어리 하나 — 문단이면 줄들, 목록이면 항목들.
class ChatBlock {
  const ChatBlock(this.kind, this.lines, {this.numbers = const []});

  final ChatBlockKind kind;

  /// 문단: 줄 / 목록: 항목 글(번호·점 기호는 뗀 것)
  final List<String> lines;

  /// 번호 목록일 때 각 항목의 번호(답에 적힌 그대로)
  final List<int> numbers;

  @override
  String toString() => '$kind$lines${numbers.isEmpty ? '' : numbers}';
}

final RegExp _numberedRe = RegExp(r'^(\d{1,2})[.)]\s+(.*)$');
final RegExp _bulletRe = RegExp(r'^[·\-•*]\s+(.*)$');

/// 답 글 → 덩어리 목록
List<ChatBlock> parseChatAnswer(String text) {
  final blocks = <ChatBlock>[];
  ChatBlockKind? kind;
  var lines = <String>[];
  var numbers = <int>[];

  void flush() {
    if (kind != null && lines.isNotEmpty) {
      blocks.add(ChatBlock(kind!, List.of(lines), numbers: List.of(numbers)));
    }
    kind = null;
    lines = [];
    numbers = [];
  }

  for (final raw in text.replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) {
      flush();
      continue;
    }
    final n = _numberedRe.firstMatch(line);
    final b = n == null ? _bulletRe.firstMatch(line) : null;
    final ChatBlockKind lineKind = n != null
        ? ChatBlockKind.numbered
        : b != null
            ? ChatBlockKind.bullets
            : ChatBlockKind.paragraph;
    if (kind != lineKind) flush();
    kind = lineKind;
    if (n != null) {
      numbers.add(int.parse(n.group(1)!));
      lines.add(n.group(2)!.trim());
    } else if (b != null) {
      lines.add(b.group(1)!.trim());
    } else {
      lines.add(line);
    }
  }
  flush();
  return blocks;
}

/// 한 줄 안의 조각 종류
enum ChatInlineKind { text, bold, address }

class ChatInline {
  const ChatInline(this.kind, this.text);

  final ChatInlineKind kind;
  final String text;

  @override
  bool operator ==(Object other) => other is ChatInline && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => '$kind($text)';
}

final RegExp _boldRe = RegExp(r'\*\*(.+?)\*\*');

/// 기관 주소 모양 — `iros.go.kr`, `www.xxx.go.kr`, `https://…` (누를 수 없는 글자 칸으로 그린다)
final RegExp _addressRe = RegExp(
  r'(?:https?://)?(?:www\.)?[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*\.(?:go\.kr|or\.kr|co\.kr|kr|com|net|org)(?:/[^\s)]*)?',
);

/// 한 줄 → 조각들 (`**굵게**` 먼저, 그다음 굵지 않은 글에서 주소)
List<ChatInline> parseChatInline(String line) {
  final out = <ChatInline>[];
  void addPlain(String s) {
    var cursor = 0;
    for (final m in _addressRe.allMatches(s)) {
      if (m.start > cursor) out.add(ChatInline(ChatInlineKind.text, s.substring(cursor, m.start)));
      out.add(ChatInline(ChatInlineKind.address, m.group(0)!));
      cursor = m.end;
    }
    if (cursor < s.length) out.add(ChatInline(ChatInlineKind.text, s.substring(cursor)));
  }

  var cursor = 0;
  for (final m in _boldRe.allMatches(line)) {
    if (m.start > cursor) addPlain(line.substring(cursor, m.start));
    out.add(ChatInline(ChatInlineKind.bold, m.group(1)!));
    cursor = m.end;
  }
  if (cursor < line.length) addPlain(line.substring(cursor));
  return out;
}
