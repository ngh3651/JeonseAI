/// 분석 진입 가드 + 로그인 유도 바텀시트 (IA.md §4).
///
/// 비회원이 분석(＋분석·홈 CTA)을 누르면 로그인 유도 바텀시트를 띄운다.
/// 로그인/회원가입을 고르면 완료 후 원래 하려던 행동(분석)으로 이어진다
/// (user-scenario.md C5 — next 파라미터로 연속).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../state/app_session.dart';
import '../../design_system/text/app_text.dart';

/// 분석 시작 — 회원이면 바로 S-04, 비회원이면 로그인 유도.
void startAnalysis(BuildContext context) {
  final session = context.read<AppSession>();
  if (session.isGuest) {
    showLoginSheet(context, next: '/analyze');
  } else {
    context.push('/analyze');
  }
}

/// 로그인 유도 바텀시트.
void showLoginSheet(BuildContext context, {required String next}) {
  showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.screenPadding,
        right: AppSpacing.screenPadding,
        bottom: MediaQuery.paddingOf(sheetContext).bottom + AppSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppText('분석하려면 로그인이 필요해요', style: AppTypography.headline),
          const SizedBox(height: AppSpacing.sm),
          AppText('결과도 안전하게 보관해 드려요', style: AppTypography.caption),
          const SizedBox(height: AppSpacing.xl),
          AppPrimaryButton(
            label: '로그인',
            onPressed: () {
              Navigator.of(sheetContext).pop();
              context.push('/login?next=${Uri.encodeComponent(next)}');
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          AppSecondaryButton(
            label: '회원가입',
            onPressed: () {
              Navigator.of(sheetContext).pop();
              context.push(
                '/login?mode=signup&next=${Uri.encodeComponent(next)}',
              );
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            onPressed: () => Navigator.of(sheetContext).pop(),
            child: const AppText('나중에'),
          ),
        ],
      ),
    ),
  );
}
