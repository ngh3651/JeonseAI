/// 날짜를 저장한 **바로 그 순간** — 알림을 걸고, 꺼져 있으면 이유를 말한 뒤 권한을 묻는다 (2026-10-22, P1-2).
///
/// 왜 앱을 켤 때가 아니라 이때인가: 이유 없이 뜬 권한 창은 대개 거절된다. 잔금일·이사일을 넣은 순간이
/// "그날 알려 드릴게요"가 가장 자연스럽게 들리는 때다.
/// 거절해도 앱은 그대로 돈다 — 그날 앱을 열면 여정·홈 화면 맨 위 배너가 같은 말을 한다.
library;

import 'package:flutter/material.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../services/journey_reminder_service.dart';
import '../../services/journey_reminders.dart';
import '../../state/journey_schedule_store.dart';

/// 알림 권한을 묻기 전에 말하는 이유 (2026-10-23 지수 #5·#6 · 서연 #5).
const String kReminderPermissionReason =
    '잔금을 보내기 직전에 집주인이 이 집을 담보로 새 빚(근저당)을 지는 일이 있어요. '
    '전입신고 효력은 다음 날 0시부터라 그 하루가 빈틈이에요. '
    '돈 보내기 전에 등기부를 다시 떼 보라고 그날 알려 드릴게요.';

/// 알림이 꺼져 있을 때의 한 줄 — 앱 안 배너가 무엇을 대신하는지 말한다.
const String kReminderFallbackMessage = '알림이 꺼져 있어요. 그날 앱을 열면 맨 위 배너로 알려 드려요';

/// 알림 종류 → 사람이 읽는 때 (권한 안내 목록에 쓴다).
String reminderMomentLabel(JourneyReminderKind kind) => switch (kind) {
  JourneyReminderKind.balanceEve => '잔금 하루 전',
  JourneyReminderKind.balanceDay => '잔금 당일 아침',
  JourneyReminderKind.moveInNext => '입주 다음 날',
};

/// 일정 시트에서 저장한 뒤 부른다. 알림 예약 → (꺼져 있으면) 이유 + 권한 → 결과 한 줄.
Future<void> applyJourneyReminders(
  BuildContext context, {
  required String propertyKey,
  required String alias,
  required JourneySchedule schedule,
  JourneyReminderService? service,
}) async {
  final svc = service ?? JourneyReminderService.instance;
  // 권한과 상관없이 먼저 건다 — 나중에 설정에서 알림을 켜면 걸어 둔 알림이 그대로 울린다.
  final plan = await svc.sync(
    propertyKey: propertyKey,
    alias: alias,
    schedule: schedule,
  );
  if (!context.mounted) return;
  if (plan.isEmpty) return; // 걸 알림이 없으면(잔금일·이사일 없음·지난 날) 묻지 않는다

  bool? enabled = await svc.notificationsEnabled();
  if (!context.mounted) return;
  if (enabled == false) {
    final bool want = await showReminderPermissionSheet(context, plan) ?? false;
    if (!context.mounted) return;
    if (want) {
      enabled = await svc.requestPermission();
      if (!context.mounted) return;
    }
  }

  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  if (enabled == true) {
    messenger.showSnackBar(
      SnackBar(
        content: AppText(
          '알림을 맞춰 뒀어요 · 첫 알림 ${describeReminderTime(plan.first.fireAt)}',
        ),
      ),
    );
  } else if (enabled == false) {
    messenger.showSnackBar(
      SnackBar(
        content: const AppText(kReminderFallbackMessage),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(label: '알림 켜기', onPressed: svc.openSettings),
      ),
    );
  } else {
    // 이 휴대폰에서 알림 기능 자체를 쓸 수 없다(초기화 실패 등) — 알림을 약속하지 않는다.
    messenger.showSnackBar(
      const SnackBar(
        content: AppText('이 휴대폰에서는 알림을 맞추지 못했어요. 그날 앱을 열면 맨 위 배너로 알려 드려요'),
      ),
    );
  }
}

/// 권한을 묻기 전에 **왜** 필요한지 말하는 시트. [알림 받기] = true, 그 밖 = false/null.
Future<bool?> showReminderPermissionSheet(
  BuildContext context,
  List<JourneyReminder> plan,
) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
    ),
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenPadding,
          AppSpacing.xl,
          AppSpacing.screenPadding,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(
              Icons.notifications_active_outlined,
              size: AppSize.iconLg,
              color: AppColors.primary,
            ),
            const SizedBox(height: AppSpacing.md),
            const AppText('그날 알림을 보내 드릴까요?', style: AppTypography.headline),
            const SizedBox(height: AppSpacing.sm),
            // 이유 — 여정 데이터(journey_stages.json '잔금 보내는 날')와 같은 사실 + 법 조문(전입신고 효력은
            // 다음 날 0시 — 주택임대차보호법 제3조)만 쓴다(새 수치 없음). 판례는 검수 대기라 넣지 않는다.
            AppText(kReminderPermissionReason, style: AppTypography.body),
            const SizedBox(height: AppSpacing.lg),
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (int i = 0; i < plan.length; i++) ...[
                    if (i > 0) const SizedBox(height: AppSpacing.sm),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.alarm,
                          size: AppSize.iconSm,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: AppText(
                            '${describeReminderTime(plan[i].fireAt)} · '
                            '${reminderMomentLabel(plan[i].kind)}',
                            style: AppTypography.bodyStrong,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            AppText(
              '알림은 이 휴대폰 안에서만 울려요. 날짜는 서버로 보내지 않아요. '
              '몇 분 늦게 울릴 수 있어요.',
              style: AppTypography.caption,
            ),
            const SizedBox(height: AppSpacing.xl),
            AppPrimaryButton(
              label: '알림 받기',
              icon: Icons.notifications_outlined,
              onPressed: () => Navigator.of(sheetContext).pop(true),
            ),
            const SizedBox(height: AppSpacing.xs),
            TextButton(
              onPressed: () => Navigator.of(sheetContext).pop(false),
              style: TextButton.styleFrom(foregroundColor: AppColors.textMuted),
              child: const AppText('괜찮아요 (앱 안 배너로만 볼게요)'),
            ),
          ],
        ),
      ),
    ),
  );
}
