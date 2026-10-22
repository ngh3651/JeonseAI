/// 로그인 세션을 **폰에 안전하게** 남긴다 — `flutter_secure_storage` (2026-10-22 카카오 로그인).
///
/// 세션 토큰은 서버에서 내 계정 기록을 여는 열쇠다 → 일반 저장소(SharedPreferences)가 아니라 안드로이드 키스토어로
/// 암호화되는 보안 저장소에 둔다. 남기는 것은 [SavedSession] 하나(세션 토큰·만료 시각·결제 customerKey)뿐이다 —
/// 카카오 회원번호·이름·이메일은 앱도 모른다(서버도 회원번호 원문을 남기지 않는다).
///
/// - 읽다가 깨졌으면(백업 복원 뒤 키스토어 키가 없어 못 푸는 경우 등) **지우고 로그아웃 상태**로 시작한다.
/// - 위젯 테스트는 [MemorySessionStorage]를 넣는다(플러그인이 없다).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 폰에 남기는 로그인 세션 한 건.
@immutable
class SavedSession {
  const SavedSession({
    required this.token,
    required this.expiresAt,
    required this.customerKey,
  });

  /// 서버 세션 토큰 — 모든 요청의 `Authorization: Bearer`.
  final String token;

  /// 서버가 정한 만료 시각(UTC). 지나면 서버가 401을 준다 — 앱도 켤 때 미리 지운다.
  final DateTime expiresAt;

  /// 토스 결제위젯 `customerKey`(계정에서 만든 값, 회원번호와 무관).
  final String customerKey;

  bool isExpiredAt(DateTime now) => !expiresAt.isAfter(now);

  Map<String, dynamic> toJson() => {
    'token': token,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'customerKey': customerKey,
  };

  /// 서버 응답(`POST /api/auth/kakao`) 또는 저장본 → 세션. 모양이 틀리면 null.
  static SavedSession? fromJson(Object? json) {
    if (json is! Map) return null;
    final token = json['sessionToken'] ?? json['token'];
    final expires = json['expiresAt'];
    final customerKey = json['customerKey'];
    if (token is! String || token.isEmpty || expires is! String) return null;
    final at = DateTime.tryParse(expires);
    if (at == null) return null;
    return SavedSession(
      token: token,
      expiresAt: at.toUtc(),
      customerKey: customerKey is String ? customerKey : '',
    );
  }
}

abstract class SessionStorage {
  Future<SavedSession?> read();
  Future<void> write(SavedSession session);
  Future<void> clear();
}

/// 진짜 — 안드로이드 키스토어로 암호화되는 보안 저장소.
class SecureSessionStorage implements SessionStorage {
  SecureSessionStorage({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// 키 이름을 바꾸면 모든 폰이 로그아웃된다.
  static const String key = 'jeonseai_session_v1';

  /// 저장소가 끝내 답하지 않아도 앱 시작이 멈추지 않게.
  static const Duration _timeout = Duration(seconds: 5);

  @override
  Future<SavedSession?> read() async {
    try {
      final raw = await _storage.read(key: key).timeout(_timeout);
      if (raw == null || raw.isEmpty) return null;
      final session = SavedSession.fromJson(jsonDecode(raw));
      if (session == null) await clear();
      return session;
    } catch (e) {
      // 키스토어 키를 잃은 백업 복원본 등 — 풀 수 없는 세션은 버리고 로그아웃 상태로 시작한다.
      debugPrint('[로그인] 저장된 세션을 읽지 못해 지웁니다 (${e.runtimeType})');
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(SavedSession session) async {
    try {
      await _storage
          .write(key: key, value: jsonEncode(session.toJson()))
          .timeout(_timeout);
    } catch (e) {
      // 못 남기면 이번 실행 동안만 로그인 상태다(다음에 켜면 다시 로그인).
      debugPrint('[로그인] 세션을 폰에 남기지 못했어요 (${e.runtimeType})');
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: key).timeout(_timeout);
    } catch (e) {
      debugPrint('[로그인] 저장된 세션을 지우지 못했어요 (${e.runtimeType})');
    }
  }
}

/// 테스트·플러그인 없는 환경용 — 메모리에만.
class MemorySessionStorage implements SessionStorage {
  MemorySessionStorage([this.saved]);

  SavedSession? saved;

  @override
  Future<SavedSession?> read() async => saved;

  @override
  Future<void> write(SavedSession session) async => saved = session;

  @override
  Future<void> clear() async => saved = null;
}
