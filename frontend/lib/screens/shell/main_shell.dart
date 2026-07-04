/// 메인 셸 — 하단 탭 4개 + 중앙 (＋분석) 버튼 (IA.md §2).
///
/// 뒤로가기 정책 (IA.md §7): 홈 외 탭 루트에서 시스템 백 → 홈 탭으로 이동.
/// (홈 루트의 "한 번 더 누르면 종료" 확인은 C-3에서)
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design_system/components/app_bottom_nav.dart';

class MainShell extends StatelessWidget {
  const MainShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final bool onHome = navigationShell.currentIndex == 0;

    return PopScope(
      canPop: onHome,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) navigationShell.goBranch(0); // 홈 외 탭 → 홈으로
      },
      child: Scaffold(
        body: navigationShell,
        bottomNavigationBar: AppBottomNav(
          currentIndex: navigationShell.currentIndex,
          onTabSelected: (index) => navigationShell.goBranch(
            index,
            initialLocation: index == navigationShell.currentIndex,
          ),
          onAnalyzePressed: () => context.push('/analyze'),
        ),
      ),
    );
  }
}
