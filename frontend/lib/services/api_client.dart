/// 서버 통신 공용 클라이언트 (api-contract.md §1).
///
/// - Base URL: app/config.dart의 [apiBaseUrl] (빌드 때 `--dart-define=API_BASE_URL=…`,
///   안 넣으면 실기기 adb reverse → 127.0.0.1:8000)
/// - **헤더는 여기 한 곳에서만 붙인다** (2026-10-22, 앱 1단계 — 계약 §1.1-1):
///   모든 요청(JSON·멀티파트·삭제)에 `X-Device-Id`, 앱 키가 있으면 `X-App-Key`,
///   카카오로 로그인했으면 `Authorization: Bearer <세션>`([SessionCredentials] — 2026-10-22 카카오 로그인).
///   화면·저장소 코드는 헤더를 모른다 — 새 API를 붙여도 빠뜨릴 수 없게.
/// - 에러: 계약 §1.3의 `{"detail": "..."}` 를 [ApiException.message]로 올린다.
///   기기 정보(400)·앱 인증(401)·횟수 제한(429)은 쉬운 말로 바꿔 올린다([apiExceptionFor]).
///   **세션 401**(서버가 `WWW-Authenticate: Bearer error="invalid_token"`을 붙인 401)이면 세션을 지우고
///   ([SessionCredentials.reject] → `AppSession`이 로그인을 안내) "다시 로그인해 주세요"로 올린다.
/// - **더미 폴백 없음**: 서버가 꺼져 있으면 예외가 그대로 화면 에러 UI로 이어진다
///   (연결이 진짜인지 확인하기 위한 D-3 원칙).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app/config.dart';
import '../models/analysis_report.dart' show CaptureCheck;
import 'device_id.dart';
import 'session_credentials.dart';

/// 서버 호출 실패. [message]는 사용자에게 보여줄 한국어 문구.
class ApiException implements Exception {
  const ApiException(
    this.message, {
    this.statusCode,
    this.needsAppUpdate = false,
    this.needsLogin = false,
    this.captureCheck,
  });

  final String message;
  final int? statusCode;

  /// 기기 정보(400)·앱 인증(401) 문제 — **다시 시도해도, 사진을 바꿔도 풀리지 않는다.**
  /// 화면은 이때 '다시 시도'·'사진 다시 고르기'를 내밀지 않는다(헛걸음만 시킨다).
  final bool needsAppUpdate;

  /// 로그인 세션이 끝났다(만료·로그아웃·탈퇴 — 세션 401). 세션은 이미 지워졌다 → 다시 로그인하거나 둘러보기로 계속.
  final bool needsLogin;

  /// 서버가 **사진 품질 때문에 분석 전에 거절**했을 때(400 + `captureCheck`, api-contract §9.9) 장별 안내.
  /// 있으면 화면은 "몇 쪽이 왜 — 그 장만 다시 찍기"를 보여 준다.
  final CaptureCheck? captureCheck;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

// ── 쉬운 말 에러 문구 (2026-10-22) ────────────────────────────────────────────
// 서버 문구(api-contract §1.3)는 맞는 말이지만 "무엇을 하면 되는지"가 흐리다.
// 사용자가 할 수 있는 일(최신 앱 설치 / 기다리기)로 끝나게 바꾼다.

/// 400 — 서버가 이 폰의 기기 정보를 받지 않았다. 앱이 만든 값이라 사용자가 고칠 수 없다.
const String kDeviceProblemMessage =
    '기기 정보에 문제가 있어 서버가 요청을 받지 않았어요. 최신 앱을 설치해 주세요';

/// 401 — 앱 키가 서버와 다르다(옛 APK이거나 잘못 빌드한 APK).
const String kAppAuthFailedMessage = '앱 인증에 실패했어요. 최신 앱을 설치해 주세요';

/// 401(세션) — 로그인 세션이 끝났다(만료·다른 폰에서 탈퇴 등). 서버 문구와 같다(api-contract §1.3).
const String kSessionExpiredMessage = '로그인이 끝났어요. 다시 로그인해 주세요';

/// 429 — 기기 × IP별 최근 1시간 분석·대조 횟수 상한(서버 `RATE_LIMIT_ANALYZE_PER_HOUR`).
const String kRateLimitedMessage =
    '잠시 후 다시 시도해 주세요. 분석은 1시간에 정해진 횟수까지만 할 수 있어요';

/// 상태 코드 + 서버가 준 문구 → 화면에 보여 줄 예외. (순수 함수 — 위젯 없이 테스트한다)
///
/// - **400은 기기 정보 문제일 때만** 바꾼다. 다른 400(요약본 거부·형식 오류·사진 없음)은
///   서버 문구가 이미 정확한 행동을 말하므로 그대로 둔다 — 덮으면 "사진 다시 고르기" 안내가 사라진다.
/// - **429는 우리 서버의 횟수 제한일 때만** 바꾼다. Upstage 쪽 한도(같은 429)는 서버 문구
///   ("요청이 몰려 잠시 제한됐어요…")가 더 정확하다 — "1시간 횟수"라고 하면 틀린 말이 된다.
/// - **401은 셋으로 가른다** (2026-10-22 카카오 로그인): 세션 401([sessionRejected] — 서버가 `invalid_token`을 붙임)
///   → 다시 로그인 · 앱 키 401(서버 문구에 '앱 인증' 또는 문구 없음) → 최신 앱 설치 · 그 밖의 401(카카오 토큰 거절 등) → 서버 문구 그대로.
@visibleForTesting
ApiException apiExceptionFor(
  int statusCode,
  String? serverDetail, {
  CaptureCheck? captureCheck,
  bool sessionRejected = false,
}) {
  final detail = (serverDetail ?? '').trim();
  // 사진 품질 거절(§9.9) — 서버 문구("2쪽이 흐려요 — 다시 찍어 주세요 (…)")가 이미 할 일을 말한다.
  if (statusCode == 400 && captureCheck != null) {
    return ApiException(
      detail.isEmpty ? '사진을 다시 찍어 주세요' : detail,
      statusCode: 400,
      captureCheck: captureCheck,
    );
  }
  switch (statusCode) {
    case 401:
      if (sessionRejected) {
        return const ApiException(
          kSessionExpiredMessage,
          statusCode: 401,
          needsLogin: true,
        );
      }
      if (detail.isEmpty || detail.contains('앱 인증')) {
        return const ApiException(
          kAppAuthFailedMessage,
          statusCode: 401,
          needsAppUpdate: true,
        );
      }
    case 400:
      if (detail.contains('기기 정보')) {
        return const ApiException(
          kDeviceProblemMessage,
          statusCode: 400,
          needsAppUpdate: true,
        );
      }
    case 429:
      if (detail.isEmpty || detail.contains('너무 자주')) {
        return const ApiException(kRateLimitedMessage, statusCode: 429);
      }
  }
  return ApiException(
    detail.isEmpty ? '잠깐 문제가 생겼어요. 다시 시도해 주세요' : detail,
    statusCode: statusCode,
  );
}

/// 목록·여정처럼 "불러오지 못했어요 + 서버 연결을 확인해 주세요"를 띄우는 화면용 한 줄.
///
/// 앱 인증·기기 정보·로그인 세션 문제는 **서버 연결 문제가 아니다** — "연결을 확인하라"고 하면 와이파이만 껐다 켜다
/// 끝난다. 그때만 쉬운 말 문구로 바꾸고, 나머지는 화면이 원래 쓰던 문구([fallback]) 그대로 둔다.
String apiErrorHint(Object? error, {required String fallback}) =>
    error is ApiException && (error.needsAppUpdate || error.needsLogin)
    ? error.message
    : fallback;

/// 모든 서버 요청에 붙는 공통 헤더 — 계약 §1.1-1.
///
/// [appKey]가 비어 있으면 `X-App-Key`를 **아예 싣지 않는다**(빈 헤더를 보내면 서버 로그만 지저분해진다).
/// [sessionToken]이 있으면(카카오로 로그인) `Authorization: Bearer <세션>` — 서버는 이때 기록의 주인을 **계정**으로 본다.
/// 기기 id는 로그인해도 늘 싣는다(로그인하는 순간 이 기기의 기록을 계정으로 옮길 때 쓴다).
@visibleForTesting
Map<String, String> buildApiHeaders({
  required String deviceId,
  String appKey = '',
  String? sessionToken,
}) => {
  'X-Device-Id': deviceId,
  if (appKey.isNotEmpty) 'X-App-Key': appKey,
  if (sessionToken != null && sessionToken.isNotEmpty)
    'Authorization': 'Bearer $sessionToken',
};

/// 이 요청에 실었던 세션 토큰(없으면 null) — 세션 401을 받았을 때 **그 토큰일 때만** 지우려고 꺼낸다.
String? _sentSessionToken(Map<String, String> headers) {
  final auth = headers['Authorization'];
  return (auth != null && auth.startsWith('Bearer ')) ? auth.substring(7) : null;
}

class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 15);

  /// 분석(멀티파트) 전용 상한 — Upstage 추출이 실측 수십 초 + E-2 LLM 생성 예정이라
  /// 일반 타임아웃(15초)으로는 항상 실패한다. 서버 측 Upstage 호출 상한(300초)보다
  /// 짧게 두어 앱이 무한정 기다리지 않게 한다. (E-1c, 2026-07-06)
  static const Duration _analyzeTimeout = Duration(seconds: 180);

  /// 이 앱이 보내는 모든 요청의 공통 헤더 (기기 id + 빌드 때 넣은 앱 키).
  ///
  /// 헤더의 정의는 이 한 곳뿐이다.
  static Future<Map<String, String>> commonHeaders() async => buildApiHeaders(
    deviceId: await DeviceId.instance.get(),
    appKey: appKey,
    sessionToken: SessionCredentials.instance.token,
  );

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$apiBaseUrl$path').replace(queryParameters: query);

  /// GET → 디코딩된 JSON(dynamic). 404는 [onNotFound]가 있으면 그 값을 반환.
  ///
  /// [timeout]을 주면 그만큼 기다린다 — LLM 생성을 타는 요청(용어 챗봇)은 기본 15초로는
  /// **정상 응답도 끊긴다.** 끊긴 요청은 화면에서 '연결 실패'로 보이므로, 서버가 스스로
  /// 폴백할 시간을 주는 편이 낫다.
  Future<dynamic> getJson(
    String path, {
    Map<String, String>? query,
    dynamic Function()? onNotFound,
    Duration? timeout,
  }) async {
    final headers = await commonHeaders();
    final http.Response res;
    try {
      res = await _client
          .get(_uri(path, query), headers: headers)
          .timeout(timeout ?? _timeout);
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException('서버에 연결하지 못했어요. 네트워크를 확인해 주세요');
    }
    if (res.statusCode == 404 && onNotFound != null) return onNotFound();
    _ensureOk(res, headers);
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  /// JSON POST → 디코딩된 JSON. (결제 승인 — 계약 §3.13, 2026-10-22 · 로그인 §3.15~)
  ///
  /// [timeout]: 결제 승인은 서버가 토스를 기다리므로(최대 30초) 기본 15초보다 길게 준다.
  /// [extraHeaders]: 공통 헤더 위에 덧씌운다(로그아웃이 **방금 지운 세션**을 실어 보낼 때).
  /// 본문 없는 성공(204)은 null.
  Future<dynamic> postJson(
    String path,
    Map<String, dynamic> body, {
    Duration? timeout,
    Map<String, String>? extraHeaders,
  }) async {
    final headers = {
      ...await commonHeaders(),
      'Content-Type': 'application/json',
      ...?extraHeaders,
    };
    final http.Response res;
    try {
      res = await _client
          .post(_uri(path), headers: headers, body: jsonEncode(body))
          .timeout(timeout ?? _timeout);
    } catch (_) {
      throw const ApiException('서버에 연결하지 못했어요. 네트워크를 확인해 주세요');
    }
    _ensureOk(res, headers);
    if (res.statusCode == 204 || res.bodyBytes.isEmpty) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  /// DELETE → 204 기대.
  Future<void> delete(String path) async {
    final headers = await commonHeaders();
    final http.Response res;
    try {
      res = await _client.delete(_uri(path), headers: headers).timeout(_timeout);
    } catch (_) {
      throw const ApiException('서버에 연결하지 못했어요. 네트워크를 확인해 주세요');
    }
    if (res.statusCode == 204) return;
    _ensureOk(res, headers); // 403·404 등의 detail을 ApiException으로
  }

  /// multipart POST → 디코딩된 JSON. (분석 요청용 — 계약 §3.1)
  ///
  /// [abortTrigger]가 끝나면(분석 중 [중단] — 2026-10-29) 보내던 요청을 **끊는다** → 서버가 알아채고 남은 단계를
  /// 건너뛴다(계약 §3.1). 끊긴 요청은 연결 실패와 같은 [ApiException]으로 올라온다 — 저장소가 중단으로 바꿔 읽는다.
  Future<dynamic> postMultipart(
    String path, {
    required List<http.MultipartFile> files,
    required Map<String, String> fields,
    Future<void>? abortTrigger,
  }) async {
    final headers = await commonHeaders(); // 로그인했으면 Authorization도 여기서 실린다
    final request =
        http.AbortableMultipartRequest(
            'POST',
            _uri(path),
            abortTrigger: abortTrigger,
          )
          ..headers.addAll(headers)
          ..files.addAll(files)
          ..fields.addAll(fields);

    final http.Response res;
    try {
      final streamed = await _client.send(request).timeout(_analyzeTimeout);
      res = await http.Response.fromStream(streamed).timeout(_analyzeTimeout);
    } catch (_) {
      throw const ApiException('서버에 연결하지 못했어요. 네트워크를 확인해 주세요');
    }
    _ensureOk(res, headers);
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  /// [sent]는 이 요청에 실은 헤더 — 세션 401이면 **그때 실은 세션**만 지운다.
  void _ensureOk(http.Response res, Map<String, String> sent) {
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    // 세션 401 — 서버가 RFC 6750 표시를 붙인다(앱 키 401·카카오 토큰 거절 401과 가른다).
    final sessionRejected =
        res.statusCode == 401 &&
        (res.headers['www-authenticate'] ?? '').contains('invalid_token');
    if (sessionRejected) {
      final token = _sentSessionToken(sent);
      if (token != null) SessionCredentials.instance.reject(token);
    }
    String? detail;
    CaptureCheck? capture;
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is Map && body['detail'] is String) {
        detail = body['detail'] as String;
      }
      if (body is Map && body['captureCheck'] is Map<String, dynamic>) {
        capture = CaptureCheck.fromJson(
          body['captureCheck'] as Map<String, dynamic>,
        );
      }
    } catch (_) {
      /* 본문이 JSON이 아니면 서버 문구 없음 → 기본 문구 */
    }
    throw apiExceptionFor(
      res.statusCode,
      detail,
      captureCheck: capture,
      sessionRejected: sessionRejected,
    );
  }
}
