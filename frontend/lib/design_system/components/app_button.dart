/// 버튼 — 주(Primary)/보조(Secondary) 2종.
///
/// 높이·라운드·타이포는 테마(theme.dart)에서 일괄 적용되므로,
/// 여기서는 의미 있는 변형(아이콘·로딩)만 감싼다.
library;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

class AppPrimaryButton extends StatelessWidget {
  const AppPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  /// true면 스피너 표시 + 비활성화
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final Widget child = loading
        ? const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: Colors.white,
            ),
          )
        : Text(label);

    if (icon != null && !loading) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
      );
    }
    return FilledButton(onPressed: loading ? null : onPressed, child: child);
  }
}

/// 전폭 톤(tonal) 버튼 — 연초록 filled. (2026-07-09 F3/F8)
///
/// **사용 규칙**: 흰 카드(surface) 위의 강조 액션은 라인(outline) 대신 이 톤 버튼을 쓴다
/// (흰 배경에서 라인 버튼은 대비가 튀어 보임). 회색 배경 위에서는 라인 버튼도 무방.
/// 대표 예: 근거 카드의 '시세 입력하기'. 주(primary) 버튼보다 위계가 한 단계 낮다.
class AppTonalButton extends StatelessWidget {
  const AppTonalButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ButtonStyle style = FilledButton.styleFrom(
      backgroundColor: AppColors.primarySoft,
      foregroundColor: AppColors.primary,
      minimumSize: const Size.fromHeight(AppSize.buttonHeight),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      textStyle: AppTypography.button,
    );
    if (icon != null) {
      return FilledButton.icon(
        onPressed: onPressed,
        style: style,
        icon: Icon(icon),
        label: Text(label),
      );
    }
    return FilledButton(onPressed: onPressed, style: style, child: Text(label));
  }
}

/// 소형 인라인 액션 버튼 — 배너 [재분석], 근거 카드 안의 행동 버튼 등
/// 전폭 버튼(52dp·무한폭)이 과한 자리에 쓴다. 높이 44dp, 내용 폭만 차지.
///
/// [tonal]=true면 흰 카드 위 라인 버튼 회피용 연초록 filled로 렌더 (F3).
class AppCompactButton extends StatelessWidget {
  const AppCompactButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.tonal = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool tonal;

  @override
  Widget build(BuildContext context) {
    final ButtonStyle style = tonal
        ? FilledButton.styleFrom(
            backgroundColor: AppColors.primarySoft,
            foregroundColor: AppColors.primary,
            minimumSize: const Size(0, AppSize.compactButtonHeight),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.buttonMini),
            ),
            textStyle: AppTypography.buttonSmall,
          )
        : OutlinedButton.styleFrom(
            minimumSize: const Size(0, AppSize.compactButtonHeight),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            textStyle: AppTypography.buttonSmall,
          );
    if (tonal) {
      return icon != null
          ? FilledButton.icon(
              onPressed: onPressed,
              style: style,
              icon: Icon(icon, size: AppSize.iconSm),
              label: Text(label),
            )
          : FilledButton(onPressed: onPressed, style: style, child: Text(label));
    }
    if (icon != null) {
      return OutlinedButton.icon(
        onPressed: onPressed,
        style: style,
        icon: Icon(icon, size: AppSize.iconSm),
        label: Text(label),
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      style: style,
      child: Text(label),
    );
  }
}

class AppSecondaryButton extends StatelessWidget {
  const AppSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    if (icon != null) {
      return OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
      );
    }
    return OutlinedButton(onPressed: onPressed, child: Text(label));
  }
}
