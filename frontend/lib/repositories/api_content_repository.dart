/// 콘텐츠 저장소 — **서버 구현** (Phase D-3, api-contract.md §3.5~§3.9).
///
/// 판례·질문은 서버가 리포트 id에서 위험 패턴을 파생해 만든다(계약 §2.2 note).
/// 서버가 꺼져 있으면 예외가 화면 에러 UI로 이어진다(더미 폴백 없음).
library;

import '../models/ask_cards.dart';
import '../models/content_models.dart';
import '../services/api_client.dart';
import 'content_repository.dart';

class ApiContentRepository implements ContentRepository {
  ApiContentRepository({ApiClient? client}) : _api = client ?? ApiClient();

  final ApiClient _api;

  /// 판례 창고 상태 — 실패(옛 서버 404·연결 끊김)해도 화면을 막지 않고 null(날짜만 빠진다).
  @override
  Future<PrecedentStatus?> precedentStatus() async {
    try {
      final json = await _api.getJson(
        '/api/precedents/status',
        onNotFound: () => null,
      );
      if (json == null) return null;
      return PrecedentStatus.fromJson(json as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

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

  /// 4장 질문 (계약 §3.6-2). 옛 서버(404)면 빈 묶음 — 4장이 조용히 빠진다.
  /// 상세 화면(polish)은 AI가 why를 다시 쓰는 시간까지 기다린다.
  @override
  Future<AskCards> askCards(String reportId, {bool polish = false}) async {
    final json = await _api.getJson(
      '/api/reports/$reportId/ask-cards',
      query: polish ? const {'polish': 'true'} : null,
      onNotFound: () => null,
      timeout: polish ? const Duration(seconds: 60) : null,
    );
    if (json == null) return AskCards.empty;
    return AskCards.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<GlossaryTerm>> glossaryTerms() async {
    final json = await _api.getJson('/api/glossary') as List;
    return [
      for (final t in json) GlossaryTerm.fromJson(t as Map<String, dynamic>),
    ];
  }

  /// 챗봇 (계약 §3.21). 최근 8개만 보낸다(서버도 8개만 쓴다).
  ///
  /// 기다리는 시간 30초 — 서버는 실패하면 스스로 기본 문장으로 답하므로, 여기서 기다리는 시간은
  /// **AI가 답을 쓰고 한 번 고쳐 쓸 시간**이면 충분하다.
  @override
  Future<ChatReply> chat(List<ChatTurn> messages, {String? reportId}) async {
    final recent = messages.length > 8
        ? messages.sublist(messages.length - 8)
        : messages;
    final json = await _api.postJson('/api/chat', {
      'messages': [for (final m in recent) m.toJson()],
      'reportId': ?reportId,
    }, timeout: const Duration(seconds: 30));
    return ChatReply.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<JourneyStage>> journeyStages() async {
    final json = await _api.getJson('/api/journey-stages') as List;
    return [
      for (final s in json) JourneyStage.fromJson(s as Map<String, dynamic>),
    ];
  }
}
