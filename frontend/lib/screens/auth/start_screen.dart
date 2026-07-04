/// S-02 로그인/시작 (랜딩) — IA.md §6.
///
/// [로그인] · [회원가입] · [비회원으로 시작하기]. 로그인은 로컬 목업.
/// 비회원 시작 → 세션을 게스트로 두고 홈으로.
///
/// NOTE(팀 피드백 대비): 목업 초안(docs/draft)은 딥그린 히어로 배경이다. 지금은 표준
/// 라이트 테마로 두고, 배경·버튼 색 커스터마이즈는 내일 디자인 피드백 때 토큰으로 반영.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/mascot_safe.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../state/app_session.dart';

class StartScreen extends StatelessWidget {
  const StartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          child: Column(
            children: [
              const Spacer(),
              const MascotSafe(size: 120),
              const SizedBox(height: AppSpacing.xl),
              const Text('전세AI프', style: AppTypography.conclusion),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'AI가 지켜주는 안전한 전세 계약',
                style: AppTypography.body,
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              AppPrimaryButton(
                label: '로그인',
                onPressed: () => context.push('/login?mode=login'),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppSecondaryButton(
                label: '회원가입',
                onPressed: () => context.push('/login?mode=signup'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: () {
                  context.read<AppSession>().continueAsGuest();
                  context.go('/home');
                },
                child: const Text('비회원으로 시작하기'),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
          ),
        ),
      ),
    );
  }
}
