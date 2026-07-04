/// 분석 리포트 더미 데이터 구조 (골격).
///
/// **이 구조는 향후 docs/data-contract.md의 API 응답 계약과 항상 동일한 형태를
/// 유지해야 한다** (CLAUDE.md 4절 더미↔실제 교체 규칙).
/// 상세 필드(근거 카드 목록·판례·시뮬레이터 입력값 등)는 C-2에서 리포트 화면과 함께 확정한다.
library;

import 'risk_grade.dart';

class AnalysisReport {
  const AnalysisReport({
    required this.id,
    required this.alias,
    required this.address,
    required this.analyzedAt,
    required this.grade,
    required this.headline,
    required this.nextAction,
    required this.topRiskSummary,
  });

  final String id;

  /// 매물 별칭 — 미입력 시 표제부 추출 소재지 주소가 기본값 (IA.md S-04)
  final String alias;

  /// 표제부 소재지 주소
  final String address;

  final DateTime analyzedAt;

  final RiskGrade grade;

  /// 결론 한 줄 (결론 헤더에 크게)
  final String headline;

  /// "지금 해야 할 일" 한 문장 (등급별 문구 방향은 IA.md §6 표 참조)
  final String nextAction;

  /// 최대 위험 요인 한 줄 — 홈 이력 카드의 비교용 노출 (IA.md S-03)
  final String topRiskSummary;
}
