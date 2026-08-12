/// 판정/설명 주체 구분 라벨 — 가드레일 가시화 (IA.md §0).
///
/// 근거 카드 펼침 영역에서 "판정은 규칙 기반(출처), 설명 문장만 AI 생성"임을
/// 사용자·심사위원이 화면에서 인지할 수 있게 한다.
library;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import '../../design_system/text/app_text.dart';

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
          // 2026-07-09 E-2 라벨: 폴백(미리 준비한 문장)일 때도 정확하도록 '자동 생성'.
          // 페르소나 2인 모두 "AI 생성은 폴백에 부정확 → 자동 생성이 더 정직" (앱만, 계약 무변경).
          text: '설명 · 자동 생성',
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: AppSize.iconXs, color: color),
          const SizedBox(width: AppSpacing.xs),
          // Flexible: 출처가 길면 칩 안에서 줄바꿈 — 화면 밖 오버플로 방지
          Flexible(
            child: AppText(
              text,
              style: AppTypography.label.copyWith(color: color),
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }
}
