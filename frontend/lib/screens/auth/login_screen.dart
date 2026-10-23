/// 로그인 화면 (홈·마이·"다시 로그인해 주세요" 안내에서 push) — 2026-10-22 카카오 로그인.
///
/// 예전에는 이메일·비밀번호 목업 폼이었다(아무 값이나 통과). 이제 [카카오로 시작하기] 하나 + [로그인 없이 둘러보기].
/// 키가 없는 빌드에서는 카카오 버튼을 그리지 않는다(이 화면으로 오는 입구도 감춘다).
/// [next]가 있으면 로그인(또는 둘러보기) 뒤 그 경로로 이어 간다 — 원래 하려던 행동을 잃지 않게.
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
import 'start_screen.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key, this.next});

  /// 끝난 뒤 이동할 경로 (없으면 원래 화면으로 돌아간다)
  final String? next;

  /// 로그인했든 둘러보기를 골랐든 — 원래 하려던 곳으로.
  void _continue(BuildContext context) {
    final next = this.next;
    if (next != null && next.isNotEmpty) {
      // 홈으로 리셋해 셸(하단 탭·홈)을 백스택에 두고, 그 위에 push.
      // (next를 바로 go하면 셸이 스택에서 사라져 홈으로 돌아갈 길이 없어짐 — gap-checker)
      context.go('/home');
      context.push(next);
    } else if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }

  Future<void> _kakao(BuildContext context) async {
    final ok = await runKakaoLogin(context);
    if (!context.mounted || !ok) return;
    _continue(context);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    return Scaffold(
      appBar: AppBar(title: const AppText('로그인')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          const SizedBox(height: AppSpacing.xl),
          const Center(child: MascotSafe(size: 96, state: MascotState.home)),
          const SizedBox(height: AppSpacing.xl),
          const AppText(
            '카카오로 로그인하면\n기록이 계정에 남아요',
            style: AppTypography.headline,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppText(
            '폰을 바꾸거나 앱을 다시 깔아도 카카오로 로그인하면 분석 기록과 '
            '계약 지킴이 패스를 다시 볼 수 있어요. 지금 이 폰에 있는 기록도 계정으로 옮겨져요.',
            style: AppTypography.body,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xxl),
          if (session.isLoggedIn) ...[
            AppText(
              '이미 카카오로 로그인되어 있어요',
              style: AppTypography.caption,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            AppPrimaryButton(
              label: '계속하기',
              onPressed: () => _continue(context),
            ),
          ] else ...[
            if (session.kakaoAvailable) ...[
              KakaoLoginButton(
                busy: session.busy,
                onPressed: () => _kakao(context),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            TextButton(
              onPressed: session.busy ? null : () => _continue(context),
              child: const AppText(StartScreen.guestLabel),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          const LoginPrivacyNote(),
        ],
      ),
    );
  }
}
