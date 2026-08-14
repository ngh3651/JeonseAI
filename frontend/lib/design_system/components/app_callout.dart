/// 공용 콜아웃(안내/경고 박스) — soft 배경 + 아이콘 + 본문 + 선택 행동 (design-reviewer C-3 반영).
///
/// 화면마다 인라인으로 반경(sm/md/lg)이 제각각이던 안내/경고 박스를 하나로 통일한다.
/// 반경은 lg 고정, 색은 톤(info/caution/ok/neutral)으로만 선택.
library;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import '../../design_system/text/app_text.dart';

enum CalloutTone { info, caution, ok, neutral }

class AppCallout extends StatelessWidget {
  const AppCallout({
    super.key,
    required this.text,
    this.tone = CalloutTone.info,
    this.icon,
    this.action,
    this.title,
  });

  final String text;
  final CalloutTone tone;
  final IconData? icon;

  /// 하단 행동 버튼 (보수적 문구 + 행동 짝짓기 — IA §0)
  final Widget? action;

  /// 강조 제목 (선택)
  final String? title;

  ({Color fg, Color bg}) get _colors => switch (tone) {
    CalloutTone.info => (fg: AppColors.primary, bg: AppColors.primarySoft),
    CalloutTone.caution => (fg: AppColors.caution, bg: AppColors.cautionSoft),
    CalloutTone.ok => (fg: AppColors.ok, bg: AppColors.okSoft),
    CalloutTone.neutral => (fg: AppColors.textMuted, bg: AppColors.background),
  };

  @override
  Widget build(BuildContext context) {
    final c = _colors;
    final bool bordered = tone == CalloutTone.neutral;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: bordered ? Border.all(color: AppColors.line) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (icon != null) ...[
                Icon(icon, size: AppSize.iconSm, color: c.fg),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null) ...[
                      AppText(
                        title!,
                        style: AppTypography.label.copyWith(color: c.fg),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                    ],
                    AppText(
                      text,
                      style: tone == CalloutTone.neutral
                          ? AppTypography.caption
                          : AppTypography.body.copyWith(color: c.fg),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (action != null) ...[
            const SizedBox(height: AppSpacing.md),
            action!,
          ],
        ],
      ),
    );
  }
}
