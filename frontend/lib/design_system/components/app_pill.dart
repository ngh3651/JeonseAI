/// 범용 알약형 칩 — 문자열 라벨 + soft 배경 (design-reviewer C-3 반영).
///
/// RiskBadge는 RiskGrade 전용이라, 위험 패턴 칩·"현재" 뱃지 등 문자열 라벨에는
/// 이 컴포넌트를 쓴다. 색은 토큰만 받는다 (화면에서 hex 지정 금지).
library;

import 'package:flutter/material.dart';

import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

class AppPill extends StatelessWidget {
  const AppPill({
    super.key,
    required this.label,
    required this.color,
    required this.background,
    this.icon,
  });

  final String label;
  final Color color;
  final Color background;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: AppSize.iconXs, color: color),
            const SizedBox(width: AppSpacing.xs),
          ],
          Text(label, style: AppTypography.label.copyWith(color: color)),
        ],
      ),
    );
  }
}
