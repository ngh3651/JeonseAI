/// 위험도 뱃지 — 등급(RiskGrade)을 알약형으로 표시.
///
/// 홈 이력 카드·리포트 헤더·근거 카드 상태 등에서 공용으로 쓴다.
/// 등급 명칭은 가칭 (E-1 확정 — models/risk_grade.dart 참조).
library;

import 'package:flutter/material.dart';

import '../../models/risk_grade.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

class RiskBadge extends StatelessWidget {
  const RiskBadge({
    super.key,
    required this.grade,
    this.labelOverride,
    this.large = false,
  });

  final RiskGrade grade;

  /// 등급 외 상태 표기가 필요할 때 (예: "페이지 누락"). 색은 grade를 따른다.
  final String? labelOverride;

  final bool large;

  @override
  Widget build(BuildContext context) {
    final Color color = AppColors.gradeColor(grade);
    final Color soft = AppColors.gradeSoftColor(grade);
    final double fontSize = large
        ? AppTypography.body.fontSize!
        : AppTypography.label.fontSize!;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: large ? AppSpacing.lg : AppSpacing.md,
        vertical: large ? AppSpacing.sm : AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: soft,
        borderRadius: BorderRadius.circular(large ? AppRadius.md : AppRadius.pill),
      ),
      // F4: 긴 labelOverride(예: "보류하고 아래 항목을 먼저 확인하세요")도 넘치지 않게 —
      // large일 땐 여러 줄 허용, 작은 뱃지는 한 줄 말줄임.
      child: Text(
        labelOverride ?? grade.label,
        softWrap: large,
        maxLines: large ? 3 : 1,
        overflow: large ? TextOverflow.ellipsis : TextOverflow.fade,
        style: AppTypography.label.copyWith(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
