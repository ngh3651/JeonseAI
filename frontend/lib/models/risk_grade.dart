/// 안전도 등급 (가칭 3단계).
///
/// 명칭·판정 기준·임계값은 Phase E-1에서 권위 출처 확보 후 확정한다
/// (docs/IA.md §6 S-07 등급 슬롯 표). 여기서는 화면·컴포넌트가 쓸 슬롯만 정의한다.
/// 등급별 색은 디자인 시스템(AppColors)에서 매핑한다 — 모델은 색을 모른다.
enum RiskGrade {
  /// 위험 — 의사결정 대응: 회피 권고
  danger('위험', '계약을 피하는 것을 권해요'),

  /// 확인 필요 — 의사결정 대응: 보류·추가 확인
  caution('확인 필요', '아래부터 먼저 확인하세요'),

  /// 양호 — 의사결정 대응: 문제 없음을 분명하게, 범위는 등기부로 (2026-10-31 규혁 — 애매한 말은 불안하게 한다, decisions.md)
  ok('양호', '등기부에 문제가 없어요');

  const RiskGrade(this.label, this.decisionLabel);

  final String label;

  /// 의사결정 대응 한 줄 (IA.md §6 등급 슬롯 표) — 명칭과 함께 E-1에서 확정
  final String decisionLabel;

  /// 서버 계약(api-contract.md §1.4)의 등급 문자열 → enum.
  /// 모르는 값이면 보수적 편향에 따라 '확인 필요'로 처리한다(안전 단정 금지).
  static RiskGrade fromLabel(String label) {
    for (final g in RiskGrade.values) {
      if (g.label == label) return g;
    }
    return RiskGrade.caution;
  }
}
