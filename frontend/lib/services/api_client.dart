/// 서버 통신 공용 클라이언트 (api-contract.md §1).
///
/// - Base URL: app/config.dart의 baseUrl (실기기 adb reverse → 127.0.0.1:8000)
/// - 에러: 계약 §1.3의 `{"detail": "..."}` 를 [ApiException.message]로 올린다.
/// - **더미 폴백 없음**: 서버가 꺼져 있으면 예외가 그대로 화면 에러 UI로 이어진다
///   (연결이 진짜인지 확인하기 위한 D-3 원칙).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../app/config.dart';

/// 서버 호출 실패. [message]는 사용자에게 보여줄 한국어 문구.
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 15);

  /// 분석(멀티파트) 전용 상한 — Upstage 추출이 실측 수십 초 + E-2 LLM 생성 예정이라
  /// 일반 타임아웃(15초)으로는 항상 실패한다. 서버 측 Upstage 호출 상한(300초)보다
  /// 짧게 두어 앱이 무한정 기다리지 않게 한다. (E-1c, 2026-07-06)
  static const Duration _analyzeTimeout = Duration(seconds: 180);

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  /// GET → 디코딩된 JSON(dynamic). 404는 [onNotFound]가 있으면 그 값을 반환.
  Future<dynamic> getJson(
    String path, {
    Map<String, String>? query,
    dynamic Function()? onNotFound,
  }) async {
    final http.Response res;
    try {
      res = await _client.get(_uri(path, query)).timeout(_timeout);
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
    final http.Response res;
    try {
      res = await _client.delete(_uri(path)).timeout(_timeout);
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
      ..files.addAll(files)
      ..fields.addAll(fields);
    // 개발모드 인증(계약 §1.2): 서버가 항상 통과시키지만, 실인증 전환을 대비해
    // Authorization 헤더 자리는 D-3에서 만들지 않는다(실로그인 도입 시 여기에 추가).

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
    String message = '잠깐 문제가 생겼어요. 다시 시도해 주세요';
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is Map && body['detail'] is String) {
        message = body['detail'] as String;
      }
    } catch (_) {
      /* 본문이 JSON이 아니면 기본 문구 유지 */
    }
    throw ApiException(message, statusCode: res.statusCode);
  }
}
