/// 챗봇 지난 대화 — **이 휴대폰에만** 저장한다 (챗봇 v2, 2026-10-24).
///
/// 서버로 보내지 않는다. 서버는 지금처럼 "최근 대화 몇 개"만 받아 답을 쓰고, 대화를 모아 두지 않는다.
/// 대화 하나 = id · 제목(첫 질문, 이름 바꾸기 가능) · 만든 시각 · 마지막 시각 · 말 목록.
library;

import 'package:flutter/foundation.dart';

/// 인용 — "세이프 답에 이어 물어요"로 붙인 글
@immutable
class ChatQuote {
  const ChatQuote({required this.text, required this.sourceId});

  /// 인용한 글 (답 전체, 또는 꾹 눌러 고른 부분)
  final String text;

  /// 인용한 답 말풍선의 id — 인용 칩을 누르면 그 답으로 스크롤한다
  final String sourceId;

  Map<String, dynamic> toJson() => {'text': text, 'sourceId': sourceId};

  static ChatQuote? fromJson(Object? json) {
    if (json is! Map) return null;
    final text = json['text'];
    final source = json['sourceId'];
    if (text is! String || text.trim().isEmpty) return null;
    return ChatQuote(text: text, sourceId: source is String ? source : '');
  }
}

/// 말 하나 — 내 질문 또는 세이프 답
@immutable
class ChatEntry {
  const ChatEntry({required this.id, required this.isUser, required this.text, this.quote});

  final String id;
  final bool isUser;

  /// 화면에 보이는 글 그대로 (질문은 인용 없이 질문만, 답은 `**굵게**` 표시 포함)
  final String text;

  /// 내 질문에만 — 인용해서 물었으면 그 인용
  final ChatQuote? quote;

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': isUser ? 'user' : 'bot',
    'text': text,
    if (quote != null) 'quote': quote!.toJson(),
  };

  static ChatEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final role = json['role'];
    final text = json['text'];
    if (id is! String || text is! String || (role != 'user' && role != 'bot')) return null;
    final isUser = role == 'user';
    return ChatEntry(id: id, isUser: isUser, text: text, quote: isUser ? ChatQuote.fromJson(json['quote']) : null);
  }
}

/// 대화 하나
@immutable
class ChatConversation {
  const ChatConversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.entries,
  });

  final String id;

  /// 첫 질문(한 줄로) — 이름 바꾸기로 바꿀 수 있다
  final String title;
  final DateTime createdAt;

  /// 마지막으로 말이 오간 시각 — 목록은 이 순서(최근이 위)
  final DateTime updatedAt;
  final List<ChatEntry> entries;

  /// 말 개수 (질문 + 답)
  int get messageCount => entries.length;

  /// 마지막 답 (없으면 null)
  ChatEntry? get lastAnswer {
    for (var i = entries.length - 1; i >= 0; i--) {
      if (!entries[i].isUser) return entries[i];
    }
    return null;
  }

  ChatConversation copyWith({String? title, DateTime? updatedAt, List<ChatEntry>? entries}) => ChatConversation(
    id: id,
    title: title ?? this.title,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    entries: entries ?? this.entries,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'entries': [for (final e in entries) e.toJson()],
  };

  /// 망가진 기록은 버린다(null) — 앱이 깨지지 않게
  static ChatConversation? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final title = json['title'];
    final created = DateTime.tryParse(json['createdAt'] as String? ?? '');
    final updated = DateTime.tryParse(json['updatedAt'] as String? ?? '');
    final rawEntries = json['entries'];
    if (id is! String || title is! String || created == null || updated == null || rawEntries is! List) {
      return null;
    }
    final entries = [for (final e in rawEntries) ChatEntry.fromJson(e)].whereType<ChatEntry>().toList();
    if (entries.isEmpty) return null;
    return ChatConversation(id: id, title: title, createdAt: created, updatedAt: updated, entries: entries);
  }
}
