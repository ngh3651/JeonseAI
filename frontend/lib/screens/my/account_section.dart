/// 마이 화면의 **계정** — 맨 위 프로필 + 설정 묶음의 계정 줄(로그아웃 · 회원 탈퇴 · 개인정보 처리방침) (2026-10-22, P2-1).
/// 회원 탈퇴는 확인 대화상자를 거친다 → 서버 `DELETE /api/me`(기록·세션·패스 전부 삭제) → 카카오 연결 끊기.
/// **부스 모드**(2026-10-23)에서는 로그아웃·회원 탈퇴를 숨긴다 — 관람객이 시연 계정의 기록을 지우지 않게.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/mascot_safe.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../state/app_session.dart';
import '../../state/booth_mode.dart';
import '../auth/kakao_login_button.dart';
import 'my_settings.dart';

/// 탈퇴 확인 대화상자의 설명 — **실제로 지우는 것 그대로** (테스트가 문장을 함께 본다).
const String kWithdrawExplanation =
    '이 계정의 분석 기록·대조 기준·계약 지킴이 패스를 서버에서 바로 지우고, 카카오와의 연결도 끊어요. '
    '되돌릴 수 없어요.\n\n이 폰에 남은 사진과 계약 날짜는 앱을 지우면 함께 지워져요.';

/// 마이 맨 위 **프로필** — 세이프 + 이름 한 줄 (+ 둘러보는 중이면 카카오 로그인 버튼).
///
/// 2026-10-30 마이 다시 그림: 설명 문장("기록이 계정에 남아요" 등)을 뺐다. 로그아웃·회원 탈퇴·개인정보 처리방침은
/// 아래 **설정 묶음**([AccountSettingsRows])으로 옮겼다.
class AccountSection extends StatelessWidget {
  const AccountSection({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    final String title;
    if (!session.isLoggedIn) {
      title = '로그인 없이 둘러보는 중';
    } else if (session.displayName case final String name) {
      title = '$name님';
    } else {
      title = '카카오로 로그인했어요';
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 14, 18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  shape: BoxShape.circle,
                ),
                child: const MascotSafe(size: 44, state: MascotState.home),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      title,
                      key: const ValueKey('account-title'),
                      style: AppTypographyNext.title,
                    ),
                    if (session.isLoggedIn) ...[
                      const SizedBox(height: 2),
                      AppText(
                        '카카오 계정',
                        style: AppTypographyNext.caption.copyWith(
                          color: AppColorsNext.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // 이름 정하기 (2026-10-24) — 홈 인사말 "○○님 안녕하세요". 카카오에서 이름을 받지 않으니 여기서 직접.
              if (session.isLoggedIn)
                IconButton(
                  key: const ValueKey('account-edit-name'),
                  tooltip: session.displayName == null ? '이름 정하기' : '이름 바꾸기',
                  onPressed: () => editDisplayName(context),
                  icon: Icon(
                    Icons.edit_outlined,
                    size: 22,
                    color: AppColorsNext.textMuted,
                  ),
                ),
            ],
          ),
          if (!session.isLoggedIn && session.kakaoAvailable) ...[
            const SizedBox(height: 16),
            KakaoLoginButton(
              busy: session.busy,
              onPressed: () => runKakaoLogin(context),
            ),
          ],
        ],
      ),
    );
  }
}

/// 설정 묶음 안의 계정 줄 — 개인정보 처리방침 · 로그아웃 · 회원 탈퇴 (줄 사이 구분선은 스스로 그린다).
/// **부스 모드**(2026-10-23)에서는 로그아웃·회원 탈퇴를 숨긴다 — 관람객이 시연 계정의 기록을 지우지 않게.
class AccountSettingsRows extends StatelessWidget {
  const AccountSettingsRows({super.key});

  Future<void> _signOut(BuildContext context) async {
    final router = GoRouter.of(context);
    await context.read<AppSession>().signOut();
    // 로그아웃하면 시작 화면으로 — 다시 로그인하거나 둘러보기를 고른다 (2026-10-26, 안내 문구 없음)
    router.go('/start');
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    return ListenableBuilder(
      listenable: BoothMode.instance,
      builder: (context, _) {
        final rows = [
          SettingsRow(
            icon: Icons.privacy_tip_outlined,
            title: '개인정보 처리방침',
            onTap: () => context.push('/privacy'),
          ),
          if (session.isLoggedIn && !BoothMode.instance.on) ...[
            SettingsRow(
              key: const ValueKey('account-sign-out'),
              icon: Icons.logout_rounded,
              title: '로그아웃',
              onTap: session.busy ? null : () => _signOut(context),
              trailing: const SizedBox.shrink(),
            ),
            SettingsRow(
              key: const ValueKey('account-withdraw'),
              icon: Icons.person_remove_outlined,
              title: '회원 탈퇴',
              danger: true,
              onTap: session.busy
                  ? null
                  : () => confirmAndDeleteAccount(context),
              trailing: const SizedBox.shrink(),
            ),
          ],
        ];
        return Column(
          children: [
            for (int i = 0; i < rows.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 56,
                  color: AppColorsNext.divider,
                ),
              rows[i],
            ],
          ],
        );
      },
    );
  }
}

/// 회원 탈퇴 — 확인을 받은 뒤 서버 기록을 지우고 카카오 연결을 끊는다. 결과를 한 줄로 알린다.
Future<void> confirmAndDeleteAccount(BuildContext context) async {
  final session = context.read<AppSession>();
  final messenger = ScaffoldMessenger.of(context);
  final router = GoRouter.of(context);
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
  // 탈퇴했으면 시작 화면으로 (로그아웃과 같다 — 2026-10-26)
  if (result.deleted) router.go('/start');
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: AppText(message)));
}

/// 이름 정하기 창 — 12자까지, 비우면 이름을 지운다. 결과를 한 줄로 알린다.
Future<void> editDisplayName(BuildContext context) async {
  final session = context.read<AppSession>();
  final messenger = ScaffoldMessenger.of(context);
  // 입력칸은 창이 **스스로** 갖고 치운다 — 창이 닫히는 애니메이션 중에 치우면 오류가 난다(2026-10-24 CI)
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(initial: session.displayName ?? ''),
  );
  if (name == null) return;
  final error = await session.setDisplayName(name);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: AppText(
          error ??
              (name.trim().isEmpty ? '이름을 지웠어요' : '이제 "${name.trim()}님"으로 불러요'),
        ),
      ),
    );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial});

  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const AppText('이름 정하기'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 12,
        decoration: const InputDecoration(hintText: '예: 동크크 1'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const AppText('취소'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const AppText('저장'),
        ),
      ],
    );
  }
}
