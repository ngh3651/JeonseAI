/// 서버 통신 공용 클라이언트 (api-contract.md §1).
///
/// - Base URL: app/config.dart의 [apiBaseUrl] (빌드 때 `--dart-define=API_BASE_URL=…`,
///   안 넣으면 실기기 adb reverse → 127.0.0.1:8000)
/// - **헤더는 여기 한 곳에서만 붙인다** (2026-10-22, 앱 1단계 — 계약 §1.1-1):
///   모든 요청(JSON·멀티파트·삭제)에 `X-Device-Id`, 앱 키가 있으면 `X-App-Key`.
///   화면·저장소 코드는 헤더를 모른다 — 새 API를 붙여도 빠뜨릴 수 없게.
/// - 에러: 계약 §1.3의 `{"detail": "..."}` 를 [ApiException.message]로 올린다.
///   기기 정보(400)·앱 인증(401)·횟수 제한(429)은 쉬운 말로 바꿔 올린다([apiExceptionFor]).
/// - **더미 폴백 없음**: 서버가 꺼져 있으면 예외가 그대로 화면 에러 UI로 이어진다
///   (연결이 진짜인지 확인하기 위한 D-3 원칙).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app/config.dart';
import 'device_id.dart';

/// 서버 호출 실패. [message]는 사용자에게 보여줄 한국어 문구.
class ApiException implements Exception {
  const ApiException(
    this.message, {
    this.statusCode,
    this.needsAppUpdate = false,
  });

  final String message;
  final int? statusCode;

  /// 기기 정보(400)·앱 인증(401) 문제 — **다시 시도해도, 사진을 바꿔도 풀리지 않는다.**
  /// 화면은 이때 '다시 시도'·'사진 다시 고르기'를 내밀지 않는다(헛걸음만 시킨다).
  final bool needsAppUpdate;

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

/// 429 — 기기 × IP별 최근 1시간 분석·대조 횟수 상한(서버 `RATE_LIMIT_ANALYZE_PER_HOUR`).
const String kRateLimitedMessage =
    '잠시 후 다시 시도해 주세요. 분석은 1시간에 정해진 횟수까지만 할 수 있어요';

/// 상태 코드 + 서버가 준 문구 → 화면에 보여 줄 예외. (순수 함수 — 위젯 없이 테스트한다)
///
/// - **400은 기기 정보 문제일 때만** 바꾼다. 다른 400(요약본 거부·형식 오류·사진 없음)은
///   서버 문구가 이미 정확한 행동을 말하므로 그대로 둔다 — 덮으면 "사진 다시 고르기" 안내가 사라진다.
/// - **429는 우리 서버의 횟수 제한일 때만** 바꾼다. Upstage 쪽 한도(같은 429)는 서버 문구
///   ("요청이 몰려 잠시 제한됐어요…")가 더 정확하다 — "1시간 횟수"라고 하면 틀린 말이 된다.
@visibleForTesting
ApiException apiExceptionFor(int statusCode, String? serverDetail) {
  final detail = (serverDetail ?? '').trim();
  switch (statusCode) {
    case 401:
      return const ApiException(
        kAppAuthFailedMessage,
        statusCode: 401,
        needsAppUpdate: true,
      );
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
/// 앱 인증·기기 정보 문제는 **서버 연결 문제가 아니다** — "연결을 확인하라"고 하면 와이파이만 껐다 켜다
/// 끝난다. 그때만 쉬운 말 문구로 바꾸고, 나머지는 화면이 원래 쓰던 문구([fallback]) 그대로 둔다.
String apiErrorHint(Object? error, {required String fallback}) =>
    error is ApiException && error.needsAppUpdate ? error.message : fallback;

/// 모든 서버 요청에 붙는 공통 헤더 — 계약 §1.1-1.
///
/// [appKey]가 비어 있으면 `X-App-Key`를 **아예 싣지 않는다**(빈 헤더를 보내면 서버 로그만 지저분해진다).
@visibleForTesting
Map<String, String> buildApiHeaders({
  required String deviceId,
  String appKey = '',
}) => {
  'X-Device-Id': deviceId,
  if (appKey.isNotEmpty) 'X-App-Key': appKey,
};

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
  /// 이 클라이언트를 거치지 않는 옛 경로(`RegistryUploadService.uploadImage`)도 이것을 쓴다 —
  /// 헤더의 정의는 이 한 곳뿐이다.
  static Future<Map<String, String>> commonHeaders() async =>
      buildApiHeaders(deviceId: await DeviceId.instance.get(), appKey: appKey);

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
    _ensureOk(res);
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
    _ensureOk(res); // 403·404 등의 detail을 ApiException으로
  }

  /// multipart POST → 디코딩된 JSON. (분석 요청용 — 계약 §3.1)
  Future<dynamic> postMultipart(
    String path, {
    required List<http.MultipartFile> files,
    required Map<String, String> fields,
  }) async {
    final request = http.MultipartRequest('POST', _uri(path))
      ..headers.addAll(await commonHeaders())
      ..files.addAll(files)
      ..fields.addAll(fields);
    // 로그인 토큰(Authorization)은 아직 싣지 않는다 — 서버가 검사하지 않는다(계약 §1.2).
    // 실로그인 도입 시 [commonHeaders]에 추가한다(여기가 아니라).

    final http.Response res;
    try {
      final streamed = await _client.send(request).timeout(_analyzeTimeout);
      res = await http.Response.fromStream(streamed).timeout(_analyzeTimeout);
    } catch (_) {
      throw const ApiException('서버에 연결하지 못했어요. 네트워크를 확인해 주세요');
    }
    _ensureOk(res);
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  void _ensureOk(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    String? detail;
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is Map && body['detail'] is String) {
        detail = body['detail'] as String;
      }
    } catch (_) {
      /* 본문이 JSON이 아니면 서버 문구 없음 → 기본 문구 */
    }
    throw apiExceptionFor(res.statusCode, detail);
  }
}
