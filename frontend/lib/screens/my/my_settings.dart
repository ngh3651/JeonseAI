/// 마이 화면 설정 묶음 (2026-10-30 마이 다시 그림) — 한 카드 안에 줄(아이콘 · 이름 · 오른쪽 조작)만.
///
/// 규혁: "글씨 많은 걸 싫어해" — 줄마다 **이름 하나와 조작 하나**만 둔다. 설명 문장은 개인정보 처리방침으로 옮겼다.
library;

import 'package:flutter/material.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../state/theme_settings.dart';

/// 묶음 카드 — 줄 사이에 얇은 구분선(아이콘 뒤부터)
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (int i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: 56,
                color: AppColorsNext.divider,
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// 설정 한 줄 — 아이콘 · 이름 · (오른쪽 조작 또는 꺾쇠)
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.trailing,
    this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 회원 탈퇴처럼 되돌릴 수 없는 줄 — 빨간 글자
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color fg = danger ? AppColors.danger : AppColorsNext.textStrong;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 58),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 14, 6),
          child: Row(
            children: [
              Icon(
                icon,
                size: 22,
                color: danger ? AppColors.danger : AppColorsNext.textMuted,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: AppText(
                  title,
                  style: AppTypographyNext.body.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (trailing != null)
                trailing!
              else if (onTap != null)
                Icon(Icons.chevron_right, color: AppColorsNext.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// 화면 모드 — 시스템 · 밝게 · 어둡게 (알약 3칸)
class ThemeModeSelector extends StatelessWidget {
  const ThemeModeSelector({super.key, this.settings});

  /// 테스트가 넣는다. 없으면 앱 전체의 [ThemeSettings.instance].
  final ThemeSettings? settings;

  static const _options = [
    (ThemeMode.system, '시스템'),
    (ThemeMode.light, '밝게'),
    (ThemeMode.dark, '어둡게'),
  ];

  @override
  Widget build(BuildContext context) {
    final s = settings ?? ThemeSettings.instance;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppColors.chipBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (mode, label) in _options)
              _segment(context, s, mode, label, selected: s.mode == mode),
          ],
        ),
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    ThemeSettings s,
    ThemeMode mode,
    String label, {
    required bool selected,
  }) {
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        key: ValueKey('theme-mode-${mode.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => s.setMode(mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          constraints: const BoxConstraints(minHeight: 36),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            color: selected ? AppColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: AppColors.viewerShadowInk,
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: AppText(
            label,
            // 큰 글씨에서도 한 줄에 들어가게 조금만 키운다
            textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.15),
            style: AppTypographyNext.caption.copyWith(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected
                  ? AppColorsNext.textStrong
                  : AppColorsNext.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}
