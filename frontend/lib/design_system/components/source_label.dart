/// 판정/설명 주체 구분 라벨 — 가드레일 가시화 (IA.md §0).
///
/// 근거 카드 펼침 영역에서 "판정은 규칙 기반(출처), 설명 문장만 AI 생성"임을
/// 사용자·심사위원이 화면에서 인지할 수 있게 한다.
library;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

class VerdictSourceLabel extends StatelessWidget {
  const VerdictSourceLabel({super.key, this.verdictSource});

  /// 판정 근거 출처 (예: "HUG 전세보증 기준"). null이면 출처 미표기.
  final String? verdictSource;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        _chip(
          icon: Icons.rule,
          text: verdictSource == null
              ? '판정 · 규칙 기반'
              : '판정 · 규칙 기반 ($verdictSource)',
          color: AppColors.primary,
          background: AppColors.primarySoft,
        ),
        _chip(
          icon: Icons.auto_awesome,
          text: '설명 · AI 생성',
          color: AppColors.textMuted,
          background: AppColors.background,
        ),
      ],
    );
  }

  Widget _chip({
    required IconData icon,
    required String text,
    required Color color,
    required Color background,
  }) {
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
          Icon(icon, size: AppSize.iconXs, color: color),
          const SizedBox(width: AppSpacing.xs),
          Text(text, style: AppTypography.label.copyWith(color: color)),
        ],
      ),
    );
  }
}
