/// 챗봇 지난 대화 저장소 — 인터페이스 + 폰 저장(shared_preferences) + 메모리(테스트용) (챗봇 v2, 2026-10-24).
///
/// 화면은 [ChatHistoryRepository]에만 의존한다(CLAUDE.md §6).
/// **서버로 보내지 않는다** — 이 휴대폰 안에만 있다.
///
/// 상한: 대화 [kChatHistoryMaxConversations]개(넘으면 가장 오래 안 쓴 것부터 지움),
/// 대화 하나에 말 [kChatHistoryMaxEntries]개(넘으면 앞쪽부터 지움).
/// 같은 저장소에 "첫 안내를 봤음" 표시도 둔다([hintSeen] / [markHint]).
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_history.dart';

/// 대화 최대 개수 — 부스·일상에서 충분하고, 폰 저장 공간(설정 파일)을 무겁게 하지 않는 선
const int kChatHistoryMaxConversations = 30;

/// 대화 하나의 말 최대 개수 (질문 + 답)
const int kChatHistoryMaxEntries = 100;

abstract class ChatHistoryRepository {
  /// 지난 대화 — 마지막 시각이 최근인 것이 앞
  Future<List<ChatConversation>> list();

  /// 넣거나 바꾼다(같은 id면 바꿈). 상한을 넘으면 오래된 것부터 지운다.
  Future<void> save(ChatConversation conversation);

  Future<void> rename(String id, String title);

  Future<void> delete(String id);

  /// 첫 안내를 이미 봤나 (키: [ChatHint] 참고)
  Future<bool> hintSeen(String key);

  Future<void> markHint(String key);
}

/// 첫 안내 키
abstract final class ChatHint {
  /// 답 말풍선이 한 번 왼쪽으로 밀렸다 돌아오는 안내
  static const String swipe = 'swipe';

  /// [지난 대화] 아이콘 점 — 처음 기록이 생겼을 때 켜짐
  static const String drawerDot = 'drawerDot';

  /// 서랍을 한 번 열었음 — 점이 꺼짐
  static const String drawerOpened = 'drawerOpened';
}

/// 상한·정렬을 한곳에서 — 메모리·폰 저장이 같은 규칙을 쓴다
List<ChatConversation> upsertConversation(
  List<ChatConversation> all,
  ChatConversation c,
) {
  final entries = c.entries.length > kChatHistoryMaxEntries
      ? c.entries.sublist(c.entries.length - kChatHistoryMaxEntries)
      : c.entries;
  final next = [
    for (final x in all)
      if (x.id != c.id) x,
    c.copyWith(entries: entries),
  ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return next.length > kChatHistoryMaxConversations
      ? next.sublist(0, kChatHistoryMaxConversations)
      : next;
}

/// 메모리 — 위젯 테스트, 그리고 폰 저장이 안 될 때의 대신
class MemoryChatHistoryRepository implements ChatHistoryRepository {
  MemoryChatHistoryRepository([List<ChatConversation> initial = const []]) {
    for (final c in initial) {
      _all = upsertConversation(_all, c);
    }
  }

  List<ChatConversation> _all = [];
  final Set<String> _hints = {};

  @override
  Future<List<ChatConversation>> list() async => List.unmodifiable(_all);

  @override
  Future<void> save(ChatConversation conversation) async =>
      _all = upsertConversation(_all, conversation);

  @override
  Future<void> rename(String id, String title) async {
    _all = [for (final c in _all) c.id == id ? c.copyWith(title: title) : c];
  }

  @override
  Future<void> delete(String id) async => _all = [
    for (final c in _all)
      if (c.id != id) c,
  ];

  @override
  Future<bool> hintSeen(String key) async => _hints.contains(key);

  @override
  Future<void> markHint(String key) async => _hints.add(key);
}

/// 폰 저장 — shared_preferences 한 칸에 JSON 목록으로. 읽기·쓰기가 실패하면 메모리로 계속 간다(화면이 깨지지 않게).
class PrefsChatHistoryRepository implements ChatHistoryRepository {
  PrefsChatHistoryRepository();

  static const String _key = 'chat.history.v1';
  static const String _hintPrefix = 'chat.hint.';

  final MemoryChatHistoryRepository _memory = MemoryChatHistoryRepository();
  SharedPreferences? _prefs;
  bool _loaded = false;

  Future<SharedPreferences?> _open() async {
    if (_loaded) return _prefs;
    _loaded = true;
    try {
      _prefs = await SharedPreferences.getInstance();
      final raw = _prefs!.getString(_key);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final j in decoded) {
            final c = ChatConversation.fromJson(j);
            if (c != null) await _memory.save(c);
          }
        }
      }
    } catch (_) {
      // 플러그인이 없거나(테스트) 기록이 망가졌다 — 메모리로만 간다
    }
    return _prefs;
  }

  Future<void> _flush() async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      final all = await _memory.list();
      await prefs.setString(
        _key,
        jsonEncode([for (final c in all) c.toJson()]),
      );
    } catch (_) {
      // 저장 실패 — 이번 실행 동안은 메모리에 남아 있다
    }
  }

  @override
  Future<List<ChatConversation>> list() async {
    await _open();
    return _memory.list();
  }

  @override
  Future<void> save(ChatConversation conversation) async {
    await _open();
    await _memory.save(conversation);
    await _flush();
  }

  @override
  Future<void> rename(String id, String title) async {
    await _open();
    await _memory.rename(id, title);
    await _flush();
  }

  @override
  Future<void> delete(String id) async {
    await _open();
    await _memory.delete(id);
    await _flush();
  }

  @override
  Future<bool> hintSeen(String key) async {
    final prefs = await _open();
    if (await _memory.hintSeen(key)) return true;
    try {
      return prefs?.getBool('$_hintPrefix$key') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> markHint(String key) async {
    final prefs = await _open();
    await _memory.markHint(key);
    try {
      await prefs?.setBool('$_hintPrefix$key', true);
    } catch (_) {
      // 저장 실패 — 이번 실행 동안은 메모리 표시로 충분하다
    }
  }
}
