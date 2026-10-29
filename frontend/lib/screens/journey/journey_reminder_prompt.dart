/// 날짜를 저장한 **바로 그 순간** — 알림을 걸고, 꺼져 있으면 이유를 말한 뒤 권한을 묻는다 (2026-10-22, P1-2).
///
/// 왜 앱을 켤 때가 아니라 이때인가: 이유 없이 뜬 권한 창은 대개 거절된다. 잔금일·이사일을 넣은 순간이
/// "그날 알려 드릴게요"가 가장 자연스럽게 들리는 때다.
/// 거절하면 시트만 닫는다 — '알림이 꺼져 있어요' 같은 안내는 어디에도 띄우지 않는다(2026-10-26 확정).
library;

import 'package:flutter/material.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../services/journey_reminder_service.dart';
import '../../services/journey_reminders.dart';
import '../../state/journey_progress_store.dart';
import '../../state/journey_schedule_store.dart';

/// 알림 권한을 묻기 전에 말하는 이유 (2026-10-23 지수 #5·#6 · 서연 #5).
const String kReminderPermissionReason =
    '잔금을 보내기 직전에 집주인이 이 집을 담보로 새 빚(근저당)을 지는 일이 있어요. '
    '전입신고 효력은 다음 날 0시부터라 그 하루가 빈틈이에요. '
    '돈 보내기 전에 등기부를 다시 떼 보라고 그날 알려 드릴게요.';

/// 권한 시트의 거절 버튼 — 누르면 시트만 닫는다(안내 문구·배너·토스트 없음, 2026-10-26).
const String kReminderDeclineLabel = '괜찮아요';

/// 알림 종류 → 사람이 읽는 때 (권한 안내 목록에 쓴다).
String reminderMomentLabel(JourneyReminderKind kind) => switch (kind) {
  JourneyReminderKind.balanceEve => '잔금 하루 전',
  JourneyReminderKind.balanceDay => '잔금 당일 아침',
  JourneyReminderKind.moveInNext => '입주 다음 날',
  JourneyReminderKind.downPaymentDay => '가계약금 보내는 날',
  JourneyReminderKind.contractDay => '계약서 쓰는 날',
  JourneyReminderKind.moveInDay => '이사 날',
};

/// 일정 시트에서 저장한 뒤 부른다. 알림 예약 → (꺼져 있으면) 이유 + 권한 → 켜졌을 때만 한 줄.
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

  // '일정마다 오전 8시에 알려 드려요' 줄은 알림이 켜져 있을 때만 보인다(여정 화면).
  await JourneyProgressStore.instance.setNotificationsOn(enabled);
  if (!context.mounted || enabled != true)
    return; // 꺼져 있으면 아무 안내도 띄우지 않는다(2026-10-26)
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: AppText(
          '알림을 맞춰 뒀어요 · 첫 알림 ${describeReminderTime(plan.first.fireAt)}',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
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
            Icon(
              Icons.notifications_active_outlined,
              size: AppSize.iconLg,
              color: AppColors.primary,
            ),
            const SizedBox(height: AppSpacing.md),
            AppText('그날 알림을 보내 드릴까요?', style: AppTypography.headline),
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
                        Icon(
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
              '일정마다 오전 8시에 울려요. 알림은 이 휴대폰 안에서만 울리고, 날짜는 서버로 보내지 않아요. '
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
              child: const AppText(kReminderDeclineLabel),
            ),
          ],
        ),
      ),
    ),
  );
}
