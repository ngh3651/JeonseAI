/// 분석 저장소 — **서버 구현** (Phase D-3, api-contract.md §3.1~§3.4).
///
/// DummyAnalysisRepository를 대체한다. 화면은 AnalysisRepository 인터페이스만 알기 때문에
/// main.dart의 주입 한 줄로 교체됐다. **서버가 꺼져 있으면 예외가 화면 에러 UI로 이어진다**
/// (더미 폴백 없음 — 연결이 진짜임을 확인하기 위한 원칙).
library;

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/analysis_report.dart';
import '../services/api_client.dart';
import '../services/registry_upload_service.dart';
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
    for (int i = 0; i < request.imagePaths.length; i++) {
      final jpeg = await _uploader.convertToJpeg(request.imagePaths[i]);
      if (jpeg == null) {
        throw const ApiException('이미지를 변환하지 못했어요. 다른 사진으로 다시 시도해 주세요');
      }
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

  @override
  Future<AnalysisReport?> getReport(String id) async {
    final json = await _api.getJson('/api/reports/$id', onNotFound: () => null);
    if (json == null) return null;
    return AnalysisReport.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<void> deleteReport(String id) async {
    await _api.delete('/api/reports/$id'); // 403(예시)·404는 ApiException으로 화면에 전달
    notifyListeners();
  }
}
