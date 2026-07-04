/// 버튼 — 주(Primary)/보조(Secondary) 2종.
///
/// 높이·라운드·타이포는 테마(theme.dart)에서 일괄 적용되므로,
/// 여기서는 의미 있는 변형(아이콘·로딩)만 감싼다.
library;

import 'package:flutter/material.dart';

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

/// 소형 인라인 액션 버튼 — 배너 [재분석], 근거 카드 안의 행동 버튼 등
/// 전폭 버튼(52dp·무한폭)이 과한 자리에 쓴다. 높이 44dp, 내용 폭만 차지.
class AppCompactButton extends StatelessWidget {
  const AppCompactButton({
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
    final ButtonStyle style = OutlinedButton.styleFrom(
      minimumSize: const Size(0, AppSize.compactButtonHeight),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      textStyle: AppTypography.button.copyWith(fontSize: 14),
    );
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
