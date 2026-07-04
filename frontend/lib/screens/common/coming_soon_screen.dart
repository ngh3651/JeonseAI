/// '준비 중' 스텁 화면 — C-3에서 실화면으로 교체될 진입점 자리.
///
/// 두 용도로 쓴다:
/// - push 스텁 (showBack=true): 리포트의 [판례 보기] 등 아직 없는 화면
/// - 탭 루트 스텁 (showBack=false): 여정/챗봇/마이 탭 자리
library;

import 'package:flutter/material.dart';

import '../../design_system/components/mascot_safe.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';

class ComingSoonScreen extends StatelessWidget {
  const ComingSoonScreen({
    super.key,
    required this.title,
    required this.message,
    this.showBack = true,
  });

  final String title;
  final String message;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title), automaticallyImplyLeading: showBack),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MascotSafe(size: 80),
              const SizedBox(height: AppSpacing.xl),
              Text(
                message,
                style: AppTypography.body,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
