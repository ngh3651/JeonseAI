/// 메인 셸 — 하단 탭 4개 + 중앙 (＋분석) 버튼 (IA.md §2).
///
/// 뒤로가기 정책 (IA.md §7): 홈 외 탭 루트 → 홈 탭으로 이동.
/// 홈 탭 루트 → "한 번 더 누르면 종료" (2초 내 재백 시 종료).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../design_system/components/app_bottom_nav.dart';
import '../common/analyze_gate.dart';
import '../../design_system/text/app_text.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  DateTime? _lastBackAt;

  void _onPop() {
    // 홈이 아니면 홈 탭으로
    if (widget.navigationShell.currentIndex != 0) {
      widget.navigationShell.goBranch(0);
      return;
    }
    // 홈이면 double-back으로 종료
    final now = DateTime.now();
    if (_lastBackAt == null ||
        now.difference(_lastBackAt!) > const Duration(seconds: 2)) {
      _lastBackAt = now;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: AppText('한 번 더 누르면 종료돼요')));
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onPop();
      },
      child: Scaffold(
        body: widget.navigationShell,
        bottomNavigationBar: AppBottomNav(
          currentIndex: widget.navigationShell.currentIndex,
          onTabSelected: (index) => widget.navigationShell.goBranch(
            index,
            initialLocation: index == widget.navigationShell.currentIndex,
          ),
          onAnalyzePressed: () => startAnalysis(context),
        ),
      ),
    );
  }
}
