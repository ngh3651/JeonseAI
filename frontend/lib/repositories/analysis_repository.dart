/// 분석 저장소 인터페이스 — **화면(위젯)은 이 인터페이스에만 의존한다** (CLAUDE.md 4절).
///
/// Phase C: DummyAnalysisRepository (로컬 더미)
/// Phase D~: ApiAnalysisRepository (서버 호출) 로 구현만 교체한다.
library;

import '../models/analysis_report.dart';

abstract class AnalysisRepository {
  /// 등기부 이미지 + 입력값(보증금 등)으로 분석을 실행한다.
  /// 상세 요청 파라미터는 C-2에서 화면과 함께 확정.
  Future<AnalysisReport> analyze();

  /// 최근 분석 이력 (최신순).
  Future<List<AnalysisReport>> getHistory();

  /// 이력 삭제.
  Future<void> deleteReport(String id);
}

/// C-2에서 더미 리포트 2세트(위험 vs 확인 필요)로 채운다.
class DummyAnalysisRepository implements AnalysisRepository {
  @override
  Future<AnalysisReport> analyze() {
    throw UnimplementedError('C-2에서 구현');
  }

  @override
  Future<List<AnalysisReport>> getHistory() async => const [];

  @override
  Future<void> deleteReport(String id) async {}
}
