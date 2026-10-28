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
import '../models/compare_result.dart';
import '../models/loss_estimate.dart';
import '../services/api_client.dart';
import '../services/registry_upload_service.dart';
import '../state/journey_progress_store.dart';
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
        if (request.replacesReportId != null)
          'replaces': request.replacesReportId!,
      },
    );
    final body = json as Map<String, dynamic>;
    // 같은 사진 캐시 적중이면 서버는 **기록에 남긴 가린 사본**(`홍○○`)을 준다(api-contract §9.10·§9.11).
    // 이 폰에 그 리포트의 원본(실명)이 있으면 원본을 쓴다 — 서버가 바꿨을 수 있는 것은 별칭뿐이라 별칭만 새 것으로.
    final original = await RegistryPhotoStore.instance.originalReport(
      body['id'] as String,
    );
    final keepJson = original == null
        ? body
        : <String, dynamic>{...original, 'alias': body['alias']};
    final report = AnalysisReport.fromJson(keepJson);
    // 먼저 메모리에 올려 이 세션에서 즉시 쓸 수 있게 한다.
    RegistryPhotoStore.instance.register(report.id, sentJpegPaths);
    // 이어서 **폰 원본 보관** — 보낸 사진 + 원본 리포트(실명)를 이 폰에만 남긴다
    // (keepOriginalsOnPhone이 false면 아무 일도 안 한다). 서버 기록은 가린 사본이다.
    await RegistryPhotoStore.instance.keep(
      report.id,
      sentJpegPaths,
      reportJson: jsonEncode(keepJson),
    );
    debugPrint(
      '[하이라이트] 리포트 ${report.id} — 좌표 ${report.highlights.length}건 수신, '
      '전송 사진 ${sentJpegPaths.length}장 (뷰어는 이 JPEG를 그대로 띄운다)',
    );
    await _afterReplace(request.replacesReportId, report.id);
    notifyListeners(); // 이력이 바뀜 → 홈 갱신
    return report;
  }

  /// [oldId]를 [newId]가 대신했다 — 이 폰의 옛 사진·원본을 지우고, 그 리포트를 가리키던 여정 기록을 새 리포트로 옮긴다.
  /// (서버는 같은 집일 때만 옛 리포트를 지운다 — 다른 집이면 서버에 남은 옛 리포트를 폰에서도 지우지 않는다.)
  Future<void> _afterReplace(String? oldId, String? newId) async {
    if (oldId == null || newId == null || oldId == newId) return;
    try {
      final stillThere = await _api.getJson(
        '/api/reports/$oldId',
        onNotFound: () => null,
      );
      if (stillThere != null) return; // 서버가 안 지웠다(다른 집 등) — 그대로 둔다
      await RegistryPhotoStore.instance.forget(oldId);
      await JourneyProgressStore.instance.replaceReportId(oldId, newId);
    } catch (e) {
      debugPrint('[이력] 대신한 리포트 정리 실패 ($oldId → $newId, ${e.runtimeType}) — 다음에 다시 열면 맞춰져요');
    }
  }

  /// 기록 목록 — 서버 목록(순서·어떤 리포트가 있는지)에, 이 폰에 원본이 있는 것은 **원본**으로 바꿔 끼운다.
  /// 서버 기록은 이름을 가린 사본이라, 원본이 없는 것(오래돼 지워졌거나 다른 앱 설치)은 가린 이름으로 보인다.
  @override
  Future<List<AnalysisReport>> getHistory() async {
    final json = await _api.getJson('/api/reports') as List;
    return [
      for (final r in json)
        await _originalOr(r as Map<String, dynamic>),
    ];
  }

  /// 리포트 단건 — **이 폰의 원본이 먼저다**(실명 — 실제 만난 계약자와 대조). 없을 때만 서버 사본(가린 이름).
  ///
  /// 원본이 있으면 서버에 묻지 않는다 — 서버가 나중에 바꾸는 것은 별칭뿐이고, 그건 분석 응답을 받으며 원본에
  /// 이미 반영했다([analyze]). 서버가 꺼져 있어도 이 폰에서 분석한 리포트는 열린다.
  @override
  Future<AnalysisReport?> getReport(String id) async {
    final original = await _original(id);
    if (original != null) return original;
    final json = await _api.getJson('/api/reports/$id', onNotFound: () => null);
    if (json == null) return null;
    return AnalysisReport.fromJson(json as Map<String, dynamic>);
  }

  Future<AnalysisReport> _originalOr(Map<String, dynamic> serverCopy) async =>
      await _original(serverCopy['id'] as String? ?? '') ??
      AnalysisReport.fromJson(serverCopy);

  Future<AnalysisReport?> _original(String id) async {
    if (id.isEmpty) return null;
    final json = await RegistryPhotoStore.instance.originalReport(id);
    if (json == null) return null;
    try {
      return AnalysisReport.fromJson(json);
    } catch (e) {
      debugPrint('[폰원본] $id — 원본을 읽었지만 해석 실패 → 서버 사본을 씁니다 (${e.runtimeType})');
      return null;
    }
  }

  /// 기록 삭제 — 서버 기록과 **이 폰의 사진·원본 리포트**를 함께 지운다.
  /// 서버에 이미 없으면(404) 폰 사본만 지우고 404는 그대로 화면에 알린다. 403(예시)은 아무것도 지우지 않는다.
  @override
  Future<void> deleteReport(String id) async {
    try {
      await _api.delete('/api/reports/$id');
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        await RegistryPhotoStore.instance.forget(id);
        notifyListeners();
      }
      rethrow;
    }
    await RegistryPhotoStore.instance.forget(id);
    notifyListeners();
  }

  /// 손실 예상 — 부를 때마다 서버가 계산한다(매각가율 자료를 새로 넣으면 예전 리포트도 새 숫자). 없는 리포트면 null.
  @override
  Future<LossEstimate?> getLossEstimate(String reportId) async {
    final json = await _api.getJson(
      '/api/reports/$reportId/loss-estimate',
      onNotFound: () => null,
    );
    if (json == null) return null;
    return LossEstimate.fromJson(json as Map<String, dynamic>);
  }

  /// 등기부 대조 (계약 §3.10). 사진이 없으면 **사진 없이** 부른다 —
  /// 기준이 없는 리포트는 서버가 촬영 전에 "기준 없음"으로 답하기 때문이다.
  @override
  Future<CompareResult> compareRegistry(
    String reportId,
    List<String> imagePaths,
  ) => _compare(reportId, imagePaths, replaces: null);

  @override
  Future<CompareResult> recompareRegistry(
    String reportId,
    List<String> imagePaths, {
    required String replaces,
  }) => _compare(reportId, imagePaths, replaces: replaces);

  Future<CompareResult> _compare(
    String reportId,
    List<String> imagePaths, {
    required String? replaces,
  }) async {
    final files = <http.MultipartFile>[];
    final sentJpegPaths = <String>[];
    for (int i = 0; i < imagePaths.length; i++) {
      final jpeg = await _uploader.convertToJpeg(imagePaths[i], tag: 'c$i');
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
      '/api/reports/$reportId/compare',
      files: files,
      fields: {if (replaces != null) 'replaces': replaces},
    );
    final result = CompareResult.fromJson(json as Map<String, dynamic>);

    // 대조는 **새 분석 1건을 만든다**(같은 보증금으로 다시 판정한 결과다).
    // 그 리포트의 원본 사진을 남겨 둬야 새 리포트에서도 '원본에서 보기'가 열린다.
    final newId = result.newReportId;
    if (newId != null && sentJpegPaths.isNotEmpty) {
      RegistryPhotoStore.instance.register(newId, sentJpegPaths);
      await RegistryPhotoStore.instance.keep(newId, sentJpegPaths);
    }
    await _afterReplace(replaces, newId);
    // 이력이 바뀌었다(새 분석 추가 또는 다른 집이라 취소) → 홈·여정 갱신
    notifyListeners();
    debugPrint(
      '[대조] 리포트 $reportId — 결과 ${result.outcome.name}, '
      '올린 사진 ${sentJpegPaths.length}장, 새 리포트 ${newId ?? '없음'}',
    );
    return result;
  }
}
