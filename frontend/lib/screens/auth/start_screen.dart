/// S-02 시작 (랜딩) — IA.md §6 · 2026-10-22 카카오 로그인.
///
/// - 카카오 키가 있는 빌드: [카카오로 시작하기] + [로그인 없이 둘러보기].
/// - 키가 없는 빌드: [로그인 없이 둘러보기]만 (가짜 버튼 금지 — 카카오 개발자 앱 등록 전).
/// - 이미 로그인돼 있으면(시연 폰은 미리 로그인해 둔다): "카카오로 로그인되어 있어요" + [시작하기].
/// 둘러보기 = 기기 id로 쓴다 — 분석도 된다(부스에서 카카오가 막혀도).
///
/// NOTE: 목업 초안(docs/draft)은 딥그린 히어로 배경이지만, 앱은 라이트 테마 일관성을
/// 택했다(2026-07-09 디자인 라운드 확정 — decisions.md). 딥그린 히어로는 재도입 안 함.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/mascot_safe.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../state/app_session.dart';
import 'kakao_login_button.dart';

class StartScreen extends StatelessWidget {
  const StartScreen({super.key});

  static const String guestLabel = '로그인 없이 둘러보기';

  void _browse(BuildContext context) {
    context.read<AppSession>().continueAsGuest();
    context.go('/home');
  }

  Future<void> _kakao(BuildContext context) async {
    final ok = await runKakaoLogin(context);
    if (!context.mounted || !ok) return;
    context.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Center(
                child: MascotSafe(size: 120, state: MascotState.home),
              ),
              const SizedBox(height: AppSpacing.xl),
              const AppText(
                '전세AI프',
                style: AppTypography.conclusion,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              AppText(
                'AI가 지켜주는 안전한 전세 계약',
                style: AppTypography.body,
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              if (session.isLoggedIn) ...[
                AppText(
                  '카카오로 로그인되어 있어요',
                  style: AppTypography.caption,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.sm),
                AppPrimaryButton(
                  label: '시작하기',
                  onPressed: () => context.go('/home'),
                ),
              ] else if (session.kakaoAvailable) ...[
                KakaoLoginButton(
                  busy: session.busy,
                  onPressed: () => _kakao(context),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  onPressed: session.busy ? null : () => _browse(context),
                  child: const AppText(guestLabel),
                ),
                const SizedBox(height: AppSpacing.xs),
                const LoginPrivacyNote(),
              ] else ...[
                AppPrimaryButton(
                  label: guestLabel,
                  onPressed: () => _browse(context),
                ),
                const SizedBox(height: AppSpacing.sm),
                Center(
                  child: TextButton(
                    onPressed: () => context.push('/privacy'),
                    child: const AppText('개인정보 처리방침'),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
            ],
          ),
        ),
      ),
    );
  }
}
