/// 분석 저장소 — **서버 구현** (Phase D-3, api-contract.md §3.1~§3.4).
///
/// DummyAnalysisRepository를 대체한다. 화면은 AnalysisRepository 인터페이스만 알기 때문에
/// main.dart의 주입 한 줄로 교체됐다. **서버가 꺼져 있으면 예외가 화면 에러 UI로 이어진다**
/// (더미 폴백 없음 — 연결이 진짜임을 확인하기 위한 원칙).
library;

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
    // 이 세션에서만 유효 — 앱을 껐다 켜면 사라지고, 그러면 '원본에서 보기'도 사라진다
    // (사진 영구 저장은 이번 범위 밖. 등기부 사진에는 실명·주소가 있다).
    RegistryPhotoStore.instance.register(report.id, sentJpegPaths);
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
