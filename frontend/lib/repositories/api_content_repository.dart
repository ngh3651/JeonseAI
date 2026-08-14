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

  /// 챗봇 질문 (계약 §3.9). 답·거절이 **같은 200 응답**으로 온다.
  ///
  /// ⚠ 타임아웃을 따로 준다: 자연어 질문은 Solar 생성을 타므로 일반 GET(15초)으로는
  ///   정상 응답도 끊긴다. 서버가 실패하면 스스로 '준비된 문구'로 답하므로 여기서
  ///   기다리는 시간은 **생성이 성공할 시간**이면 충분하다.
  ///
  /// ⚠ `onNotFound` 분기를 **남겨 둔다** — 옛 서버(404=범위 밖)에 붙어도 화면이 살아야
  ///   한다. 지금 서버는 404를 주지 않는다(빈 질문 제외).
  @override
  Future<GlossaryAnswer> askGlossary(String query) async {
    final json = await _api.getJson(
      '/api/glossary/lookup',
      query: {'q': query},
      timeout: const Duration(seconds: 60),
      onNotFound: () => null,
    );
    if (json == null) return GlossaryAnswer.fallback;
    return GlossaryAnswer.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<JourneyStage>> journeyStages() async {
    final json = await _api.getJson('/api/journey-stages') as List;
    return [
      for (final s in json) JourneyStage.fromJson(s as Map<String, dynamic>),
    ];
  }
}
