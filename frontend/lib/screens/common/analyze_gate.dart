/// 분석 진입 가드 + 로그인 유도 바텀시트 (IA.md §4 · 2026-10-22 카카오 로그인).
///
/// 로그인 없이 둘러보는 사람이 분석(＋분석·홈 CTA)을 누르면 **로그인 유도** 바텀시트를 띄운다 — 지금까지의 규칙 그대로.
/// 달라진 것: 시트가 **진짜 카카오 로그인**으로 이어지고, 성공하면 원래 하려던 행동(분석)으로 간다
/// (user-scenario.md C5 — next로 연속). 그리고 **막다른 길이 아니다** — [로그인 없이 분석하기]로 그대로 분석한다.
/// 부스에서 카카오가 막혀도 분석은 돼야 하고, 키가 없는 빌드(카카오 개발자 앱 등록 전)에서는 로그인할 길이 없기 때문이다.
/// 키가 없는 빌드에서는 시트를 띄우지 않고 바로 분석으로 간다(누를 수 없는 로그인 안내 = 가짜 버튼).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../state/app_session.dart';
import '../auth/kakao_login_button.dart';

/// 분석 시작 — 로그인했거나 카카오 키가 없는 빌드면 바로 S-04, 둘러보는 중이면 로그인 유도.
void startAnalysis(BuildContext context) {
  final session = context.read<AppSession>();
  if (session.isGuest && session.kakaoAvailable) {
    showLoginSheet(context, next: '/analyze');
  } else {
    context.push('/analyze');
  }
}

/// 로그인 유도 바텀시트 — [카카오로 시작하기] → 로그인되면 [next]로 · [로그인 없이 분석하기] → 바로 [next]로.
void showLoginSheet(BuildContext context, {required String next}) {
  showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.screenPadding,
        right: AppSpacing.screenPadding,
        top: AppSpacing.xl,
        bottom: MediaQuery.paddingOf(sheetContext).bottom + AppSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText(
            '로그인하면 분석 기록이 계정에 남아요',
            style: AppTypography.headline,
          ),
          const SizedBox(height: AppSpacing.xl),
          KakaoLoginButton(
            onPressed: () async {
              Navigator.of(sheetContext).pop();
              final ok = await runKakaoLogin(context);
              if (!context.mounted || !ok) return;
              context.push(next);
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          AppSecondaryButton(
            label: '로그인 없이 분석하기',
            onPressed: () {
              Navigator.of(sheetContext).pop();
              context.push(next);
            },
          ),
          const SizedBox(height: AppSpacing.xs),
          AppText(
            LoginPrivacyNote.text,
            style: AppTypography.caption,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}
