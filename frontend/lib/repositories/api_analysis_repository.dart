/// 분석 저장소 — **서버 구현** (Phase D-3, api-contract.md §3.1~§3.4).
///
/// DummyAnalysisRepository를 대체한다. 화면은 AnalysisRepository 인터페이스만 알기 때문에
/// main.dart의 주입 한 줄로 교체됐다. **서버가 꺼져 있으면 예외가 화면 에러 UI로 이어진다**
/// (더미 폴백 없음 — 연결이 진짜임을 확인하기 위한 원칙).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/analysis_report.dart';
import '../services/api_client.dart';
import '../services/registry_upload_service.dart';
import '../state/registry_photo_store.dart';
import 'analysis_repository.dart';

class ApiAnalysisRepository extends AnalysisRepository {
  ApiAnalysisRepository({ApiClient? client, RegistryUploadService? uploader})
    : _api = client ?? ApiClient(),
      _uploader = uploader ?? RegistryUploadService();

  final ApiClient _api;
  final RegistryUploadService _uploader;

  @override
  Future<AnalysisReport> analyze(AnalysisRequest request) async {
    // 검증 자산 재사용: 어떤 형식(HEIC 등)이 와도 JPEG로 변환해 전송 (decisions.md 2026-07-01)
    final files = <http.MultipartFile>[];
    // 하이라이트 좌표는 **서버로 보낸 이 JPEG의 픽셀 기준**이다. 뷰어가 갤러리 원본이 아니라
    // 이 파일을 그대로 띄워야 좌표가 맞는다 → 경로를 세션 저장소에 남긴다.
    final sentJpegPaths = <String>[];
    for (int i = 0; i < request.imagePaths.length; i++) {
      final jpeg = await _uploader.convertToJpeg(
        request.imagePaths[i],
        tag: 'p$i', // 같은 밀리초에 두 장이 변환돼 덮어써지는 것을 막는다
      );
      if (jpeg == null) {
        throw const ApiException('이미지를 변환하지 못했어요. 다른 사진으로 다시 시도해 주세요');
      }
      sentJpegPaths.add(jpeg.path);
      files.add(
        await http.MultipartFile.fromPath(
          'files',
          jpeg.path,
          filename: 'page_${i + 1}.jpg',
          contentType: MediaType('image', 'jpeg'),
        ),
      );
    }

    final json = await _api.postMultipart(
      '/api/analyze',
      files: files,
      fields: {
        'deposit': '${request.deposit}',
        if (request.marketPrice != null)
          'marketPrice': '${request.marketPrice}',
        if (request.alias != null && request.alias!.trim().isNotEmpty)
          'alias': request.alias!.trim(),
      },
    );
    final report = AnalysisReport.fromJson(json as Map<String, dynamic>);
    // 먼저 메모리에 올려 이 세션에서 즉시 쓸 수 있게 한다.
    RegistryPhotoStore.instance.register(report.id, sentJpegPaths);
    // 이어서 영구 저장소로 복사한다 (devKeepRegistryPhotos가 false면 아무 일도 안 한다).
    // 리포트 JSON도 함께 남긴다 — 사진만 살려 두면 백엔드를 재시작했을 때
    // getReport()가 404가 되어 뷰어에 들어가지도 못한다(리포트는 서버 메모리에만 있다).
    await RegistryPhotoStore.instance.keep(
      report.id,
      sentJpegPaths,
      reportJson: jsonEncode(json),
    );
    debugPrint(
      '[하이라이트] 리포트 ${report.id} — 좌표 ${report.highlights.length}건 수신, '
      '전송 사진 ${sentJpegPaths.length}장 (뷰어는 이 JPEG를 그대로 띄운다)',
    );
    notifyListeners(); // 이력이 바뀜 → 홈 갱신
    return report;
  }

  @override
  Future<List<AnalysisReport>> getHistory() async {
    final json = await _api.getJson('/api/reports') as List;
    return [
      for (final r in json) AnalysisReport.fromJson(r as Map<String, dynamic>),
    ];
  }

  /// 리포트 단건 조회 — **서버가 먼저다.** 서버가 답하지 못할 때만 로컬 캐시를 본다.
  ///
  /// 캐시가 필요한 이유: 리포트는 서버 메모리에만 있어서, 백엔드를 재시작하는 순간
  /// 404가 된다. 사진을 영구 저장해 둬도 리포트를 못 읽으면 뷰어에 들어가지 못한다.
  /// 캐시는 분석 당시의 스냅샷이라 서버가 살아 있으면 절대 쓰지 않는다.
  @override
  Future<AnalysisReport?> getReport(String id) async {
    try {
      final json = await _api.getJson('/api/reports/$id', onNotFound: () => null);
      if (json != null) return AnalysisReport.fromJson(json as Map<String, dynamic>);
    } catch (e) {
      // 서버가 꺼져 있거나 연결 실패 — 캐시가 있으면 그것으로 화면을 살린다.
      final cached = await _cachedReport(id, '서버 연결 실패(${e.runtimeType})');
      if (cached != null) return cached;
      rethrow; // 캐시도 없으면 기존대로 에러 화면
    }
    // 서버는 살아 있지만 이 리포트를 모른다(404) — 재시작으로 메모리에서 사라진 경우다.
    return await _cachedReport(id, '서버에 없음(404)');
  }

  Future<AnalysisReport?> _cachedReport(String id, String why) async {
    final raw = await RegistryPhotoStore.instance.cachedReportJson(id);
    if (raw == null) return null;
    try {
      final report = AnalysisReport.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      debugPrint('[리포트캐시] $id — $why → 로컬 캐시로 대체 (개발용 보관본)');
      return report;
    } catch (e) {
      debugPrint('[리포트캐시] $id — 캐시를 읽었지만 해석 실패 (${e.runtimeType})');
      return null;
    }
  }

  @override
  Future<void> deleteReport(String id) async {
    await _api.delete('/api/reports/$id'); // 403(예시)·404는 ApiException으로 화면에 전달
    notifyListeners();
  }
}
