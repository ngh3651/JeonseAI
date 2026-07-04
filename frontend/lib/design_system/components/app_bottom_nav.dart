/// 하단 탭 + 중앙 분석 버튼 (IA.md §2 메인 셸).
///
/// [홈] [여정] (＋분석) [챗봇] [마이] — 중앙 버튼은 탭이 아니라 S-04로 push하는
/// 단일 핵심 행동이므로 크게 띄워 강조한다.
library;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

class AppBottomNav extends StatelessWidget {
  const AppBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTabSelected,
    required this.onAnalyzePressed,
  });

  /// 0=홈, 1=여정, 2=챗봇, 3=마이
  final int currentIndex;
  final ValueChanged<int> onTabSelected;
  final VoidCallback onAnalyzePressed;

  static const _tabs = [
    (icon: Icons.home_outlined, activeIcon: Icons.home, label: '홈'),
    (
      icon: Icons.fact_check_outlined,
      activeIcon: Icons.fact_check,
      label: '여정',
    ),
    (
      icon: Icons.chat_bubble_outline,
      activeIcon: Icons.chat_bubble,
      label: '챗봇',
    ),
    (icon: Icons.person_outline, activeIcon: Icons.person, label: '마이'),
  ];

  @override
  Widget build(BuildContext context) {
    final double bottomInset = MediaQuery.paddingOf(context).bottom;

    return Container(
      height: AppSize.bottomNavHeight + bottomInset,
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          _tabItem(0),
          _tabItem(1),
          _analyzeButton(),
          _tabItem(2),
          _tabItem(3),
        ],
      ),
    );
  }

  Widget _tabItem(int index) {
    final tab = _tabs[index];
    final bool active = index == currentIndex;
    final Color color = active ? AppColors.primary : AppColors.textMuted;

    return Expanded(
      child: Semantics(
        selected: active,
        button: true,
        label: '${tab.label} 탭',
        child: InkWell(
          onTap: () => onTabSelected(index),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                active ? tab.activeIcon : tab.icon,
                color: color,
                size: AppSize.iconMd,
              ),
              const SizedBox(height: 2),
              Text(
                tab.label,
                style: AppTypography.label.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _analyzeButton() {
    // 중앙 강조: 56dp 원형을 바 위로 살짝 띄워 일반 탭보다 크게 (IA §2)
    return Expanded(
      child: Center(
        child: Transform.translate(
          offset: const Offset(0, -10),
          child: Semantics(
            button: true,
            label: '매물 분석 시작',
            child: Material(
              color: AppColors.primary,
              shape: const CircleBorder(),
              elevation: 4,
              child: InkWell(
                onTap: onAnalyzePressed,
                customBorder: const CircleBorder(),
                child: const SizedBox(
                  width: 56,
                  height: 56,
                  child: Icon(Icons.add, color: Colors.white, size: 28),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
