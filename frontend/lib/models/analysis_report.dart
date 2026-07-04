/// 분석 리포트 더미 데이터 구조.
///
/// **이 구조는 향후 docs/data-contract.md의 API 응답 계약과 항상 동일한 형태를
/// 유지해야 한다** (CLAUDE.md 4절 더미↔실제 교체 규칙).
/// 등급·수치의 판정 기준은 Phase E-1(규칙 엔진)에서 출처 기반으로 확정한다 —
/// 여기 담기는 더미 값은 전부 "예시"다.
library;

import 'risk_grade.dart';

/// 근거 카드 한 항목 (S-07 근거 카드 목록의 원소).
class EvidenceItem {
  const EvidenceItem({
    required this.id,
    required this.title,
    required this.termSubtitle,
    required this.grade,
    this.statusLabel,
    required this.easyExplanation,
    this.detailText,
    this.sourceText,
    this.actionLabel,
    this.termGlossary = const {},
  });

  /// 항목 식별자: jeonse_ratio | senior_debt | ownership | insurance | blacklist
  final String id;

  /// 쉬운 질문형 제목 (IA.md §6 — 전문용어는 부제로)
  final String title;

  /// 전문용어 부제
  final String termSubtitle;

  final RiskGrade grade;

  /// 등급 라벨 대신 표시할 상태 (예: "확인 필요", "페이지 누락")
  final String? statusLabel;

  /// 쉬운 설명 — 실단계에서는 Solar Pro 생성 슬롯 (판정 변경 금지, 문장만)
  final String easyExplanation;

  /// 상세 수치
  final String? detailText;

  /// 판정 출처 (E-1 확정 전에는 슬롯 표기)
  final String? sourceText;

  /// 다음 행동 버튼 라벨 — 보수적 문구에는 반드시 행동을 짝짓는다 (IA.md §0)
  final String? actionLabel;

  /// 쉬운 설명 속 용어 → 툴팁 설명 (용어가 easyExplanation 본문에 등장해야 함)
  final Map<String, String> termGlossary;
}

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
    required this.deposit,
    required this.marketPrice,
    required this.seniorDebtAmount,
    required this.gaugeProgress,
    required this.evidences,
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

  /// 예정 보증금 (원) — S-04에서 사용자 필수 입력
  final int deposit;

  /// 매매 시세 (원) — 선택 입력. null이면 전세가율 카드는 "확인 필요"
  final int? marketPrice;

  /// 선순위 채권 합계 (원) — 손실 시뮬레이터 계산 입력 (더미 단계 예시값)
  final int seniorDebtAmount;

  /// 게이지 시각 슬롯 (0~1, 예시) — 점수 체계는 E-1에서 확정
  final double gaugeProgress;

  /// 근거 카드 목록 (S-07 §2)
  final List<EvidenceItem> evidences;
}
