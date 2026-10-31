/// 다른 화면으로 바로 가는 작은 칩 — "등기부에서 위치 보기 ›" · "리포트에서 근거 보기 ›" (2026-11-01).
///
/// 리포트 근거 카드와 중개사 질문이 같은 모양을 쓴다(하나의 앱).
library;

import 'package:flutter/material.dart';

import '../text/app_text.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_typography_next.dart';

class AppLinkChip extends StatelessWidget {
  const AppLinkChip({super.key, required this.label, required this.onTap, this.icon});

  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.surface,
    shape: StadiumBorder(side: BorderSide(color: AppColors.line)),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 17, color: AppColorsNext.textBody),
                const SizedBox(width: 6),
              ],
              AppText(
                label,
                style: AppTypographyNext.caption.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColorsNext.textStrong,
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.chevron_right_rounded, size: 18, color: AppColorsNext.textMuted),
            ],
          ),
        ),
      ),
    ),
  );
}
