/// 콘텐츠 저장소 — **서버 구현** (Phase D-3, api-contract.md §3.5~§3.9).
///
/// 판례·질문은 서버가 리포트 id에서 위험 패턴을 파생해 만든다(계약 §2.2 note).
/// 서버가 꺼져 있으면 예외가 화면 에러 UI로 이어진다(더미 폴백 없음).
library;

import '../models/content_models.dart';
import '../services/api_client.dart';
import 'content_repository.dart';

class ApiContentRepository implements ContentRepository {
  ApiContentRepository({ApiClient? client}) : _api = client ?? ApiClient();

  final ApiClient _api;

  @override
  Future<List<CaseMatch>> matchedCases(String reportId) async {
    final json = await _api.getJson('/api/reports/$reportId/cases') as List;
    return [
      for (final c in json) CaseMatch.fromJson(c as Map<String, dynamic>),
    ];
  }

  @override
  Future<List<QuestionGroup>> questionGroups(String reportId) async {
    final json = await _api.getJson('/api/reports/$reportId/questions') as List;
    return [
      for (final g in json) QuestionGroup.fromJson(g as Map<String, dynamic>),
    ];
  }

  @override
  Future<List<GlossaryTerm>> glossaryTerms() async {
    final json = await _api.getJson('/api/glossary') as List;
    return [
      for (final t in json) GlossaryTerm.fromJson(t as Map<String, dynamic>),
    ];
  }

  @override
  Future<GlossaryTerm?> lookupTerm(String query) async {
    // 404 = 범위 밖 → null (앱이 가드레일 거절 문구 표시)
    final json = await _api.getJson(
      '/api/glossary/lookup',
      query: {'q': query},
      onNotFound: () => null,
    );
    if (json == null) return null;
    return GlossaryTerm.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<JourneyStage>> journeyStages() async {
    final json = await _api.getJson('/api/journey-stages') as List;
    return [
      for (final s in json) JourneyStage.fromJson(s as Map<String, dynamic>),
    ];
  }
}
