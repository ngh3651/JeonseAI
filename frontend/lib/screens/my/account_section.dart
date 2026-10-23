/// 마이 화면의 **계정** 칸 — 로그인 상태 · 로그아웃 · 회원 탈퇴 · 개인정보 처리방침 (2026-10-22, P2-1).
///
/// '개인정보' 칸(사진 속 이름 가리기)과 **따로** 둔다 — 그쪽은 다른 작업이 함께 고치는 자리라 섞지 않는다.
/// 회원 탈퇴는 확인 대화상자를 거친다 → 서버 `DELETE /api/me`(기록·세션·패스 전부 삭제) → 카카오 연결 끊기.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/components/mascot_safe.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../state/app_session.dart';
import '../auth/kakao_login_button.dart';

/// 탈퇴 확인 대화상자의 설명 — **실제로 지우는 것 그대로** (테스트가 문장을 함께 본다).
const String kWithdrawExplanation =
    '이 계정의 분석 기록·대조 기준·계약 지킴이 패스를 서버에서 바로 지우고, 카카오와의 연결도 끊어요. '
    '되돌릴 수 없어요.\n\n이 폰에 남은 사진과 계약 날짜는 앱을 지우면 함께 지워져요.';

class AccountSection extends StatelessWidget {
  const AccountSection({super.key});

  Future<void> _signOut(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await context.read<AppSession>().signOut();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: AppText('로그아웃했어요. 이제 로그인 없이 둘러봐요')),
      );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    final String title;
    final String caption;
    if (session.isLoggedIn) {
      title = '카카오로 로그인했어요';
      caption = '분석 기록과 계약 지킴이 패스가 계정에 남아요';
    } else if (session.kakaoAvailable) {
      title = '로그인 없이 둘러보는 중';
      caption = '카카오로 로그인하면 기록이 계정에 남아요(폰을 바꿔도 그대로)';
    } else {
      title = '로그인 없이 둘러보는 중';
      caption = '분석 기록은 이 폰에 묶여 있어요';
    }

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const MascotSafe(size: 48, state: MascotState.home),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(title, style: AppTypography.bodyStrong),
                    const SizedBox(height: AppSpacing.xs),
                    AppText(caption, style: AppTypography.caption),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (session.isLoggedIn) ...[
            AppSecondaryButton(
              label: '로그아웃',
              onPressed: session.busy ? null : () => _signOut(context),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: session.busy
                    ? null
                    : () => confirmAndDeleteAccount(context),
                child: AppText(
                  '회원 탈퇴',
                  style: AppTypography.caption.copyWith(
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            ),
          ] else if (session.kakaoAvailable)
            KakaoLoginButton(
              busy: session.busy,
              onPressed: () => runKakaoLogin(context),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => context.push('/privacy'),
              icon: const Icon(Icons.privacy_tip_outlined, size: AppSize.iconSm),
              label: const AppText('개인정보 처리방침'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 회원 탈퇴 — 확인을 받은 뒤 서버 기록을 지우고 카카오 연결을 끊는다. 결과를 한 줄로 알린다.
Future<void> confirmAndDeleteAccount(BuildContext context) async {
  final session = context.read<AppSession>();
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const AppText('회원 탈퇴할까요?'),
      content: const AppText(kWithdrawExplanation),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const AppText('취소'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: AppText(
            '탈퇴하기',
            style: AppTypography.bodyStrong.copyWith(color: AppColors.danger),
          ),
        ),
      ],
    ),
  );
  if (ok != true) return;
  final result = await session.deleteAccount();
  final String message;
  if (!result.deleted) {
    message = result.message ?? '탈퇴하지 못했어요. 잠시 후 다시 시도해 주세요';
  } else if (result.kakaoUnlinked) {
    message = '탈퇴했어요. 서버의 기록을 모두 지웠어요';
  } else {
    message = '탈퇴했어요. 서버의 기록은 모두 지웠지만 카카오 연결은 끊지 못했어요 — '
        '카카오 계정 설정에서 직접 끊을 수 있어요';
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: AppText(message)));
}
