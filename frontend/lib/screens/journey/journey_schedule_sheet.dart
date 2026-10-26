/// 계약 일정 입력 시트 (S-11 화면 3).
///
/// 네 칸 **전부 선택 입력**이다. 아직 안 정해진 날이 있는 것이 정상이라, 필수로 두면
/// 사용자는 아무 날짜나 넣게 되고 그 순간 D-1 알림이 거짓말이 된다.
///
/// 잔금일만 한 단계 격상돼 있다 — 이 앱이 그 하루에 모든 것을 건다(잔금 직전 근저당
/// 설정이 실제 수법). 입주 다음 날은 이사일에서 계산하므로 **묻지 않는다.**
///
/// 저장 위치는 **이 휴대폰뿐**이다 (state/journey_schedule_store.dart 참고).
library;

import 'package:flutter/material.dart';

import '../../design_system/components/app_pill.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/content_models.dart';
import '../../state/journey_schedule_store.dart';
import '../../utils/korean_date.dart';
import '../report/registry_mark_sheet.dart'
    show kSheetEnterDuration, kSheetExitDuration;

/// 잔금 칸 아래 약속 — **실제 알림 시각과 같아야 한다** (journey_reminders.dart 의 ①②).
const String kBalanceReminderPromise =
    '잔금 하루 전과 당일 오전 8시에 등기부를 다시 떼라고 알림을 보내 드려요';

/// 이사 칸 아래 약속 — journey_reminders.dart 의 ③.
const String kMoveInReminderPromise = '이사 날과 입주 다음 날 오전 8시에도 알려 드려요';

/// 일정 시트를 연다. 저장하면 새 일정을, 그냥 닫으면 null을 돌려준다.
///
/// 진입 260ms / 퇴장 200ms — 앱의 다른 시트(등기부 표시 시트)와 같은 곡선이다.
Future<JourneySchedule?> showJourneyScheduleSheet(
  BuildContext context, {
  required JourneySchedule initial,
}) {
  return showModalBottomSheet<JourneySchedule>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false, // 그랩바(32×4)를 시안 규격으로 직접 그린다
    backgroundColor: AppColors.surface,
    barrierColor: AppColors.dim,
    sheetAnimationStyle: AnimationStyle(
      duration: kSheetEnterDuration,
      reverseDuration: kSheetExitDuration,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
    ),
    builder: (_) => _JourneyScheduleSheet(initial: initial),
  );
}

class _JourneyScheduleSheet extends StatefulWidget {
  const _JourneyScheduleSheet({required this.initial});

  final JourneySchedule initial;

  @override
  State<_JourneyScheduleSheet> createState() => _JourneyScheduleSheetState();
}

class _JourneyScheduleSheetState extends State<_JourneyScheduleSheet> {
  late JourneySchedule _draft = widget.initial;

  Future<void> _pick(JourneyDateKey key) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _draft[key] ?? now,
      // 이미 지난 계약서 날짜를 넣는 경우가 있어 과거도 연다(1년 전까지).
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
      helpText: key.label,
      confirmText: '선택',
      cancelText: '취소',
    );
    if (picked == null) return;
    setState(() => _draft = _draft.copyWith(key, picked));
  }

  void _clear(JourneyDateKey key) =>
      setState(() => _draft = _draft.copyWith(key, null));

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenPadding,
            AppSpacing.sm,
            AppSpacing.screenPadding,
            AppSpacing.xxl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.line,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              const AppText('계약 일정을 알려주세요', style: AppTypography.headline),
              const SizedBox(height: AppSpacing.xs),
              AppText('아직 안 정해진 날은 비워 두셔도 돼요', style: AppTypography.caption),
              const SizedBox(height: AppSpacing.lg),
              for (final key in JourneyDateKey.editable) ...[
                if (key == JourneyDateKey.balance)
                  _balanceField()
                else
                  _plainField(key),
                const SizedBox(height: AppSpacing.md),
              ],
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  const Icon(
                    Icons.lock_outline,
                    size: 18,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: AppText(
                      '이 날짜는 이 휴대폰에만 저장돼요',
                      style: AppTypography.caption,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(_draft),
                  child: const AppText('저장하기'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 일반 칸 — 높이 48, 테두리 1px
  Widget _plainField(JourneyDateKey key) {
    final value = _draft[key];
    final bool moveIn = key == JourneyDateKey.moveIn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          key.label,
          style: AppTypography.caption.copyWith(
            color: AppColors.textBody,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        InkWell(
          onTap: () => _pick(key),
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                Expanded(
                  child: AppText(
                    value == null ? '아직 안 정했어요' : formatMonthDayWeekday(value),
                    style: AppTypography.body.copyWith(
                      color: value == null
                          ? AppColors.textMuted
                          : AppColors.textStrong,
                    ),
                  ),
                ),
                if (value != null) _clearButton(key),
                const Icon(
                  Icons.calendar_month_outlined,
                  size: AppSize.iconSm,
                  color: AppColors.textMuted,
                ),
              ],
            ),
          ),
        ),
        if (moveIn) ...[
          const SizedBox(height: 6),
          AppText(kMoveInReminderPromise, style: AppTypography.caption),
        ],
      ],
    );
  }

  /// 잔금 칸 — 높이 56, 테두리 1.5px primary. **이 앱이 가장 크게 다루는 날짜.**
  Widget _balanceField() {
    final value = _draft[JourneyDateKey.balance];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            AppText(
              JourneyDateKey.balance.label,
              style: AppTypography.caption.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            const AppPill(
              label: '이 날짜가 가장 중요해요',
              color: AppColors.primary,
              background: AppColors.primarySoft,
            ),
          ],
        ),
        const SizedBox(height: 6),
        InkWell(
          onTap: () => _pick(JourneyDateKey.balance),
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.primary, width: 1.5),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                Expanded(
                  child: AppText(
                    value == null ? '아직 안 정했어요' : formatMonthDayWeekday(value),
                    style: value == null
                        ? AppTypography.body.copyWith(
                            color: AppColors.textMuted,
                          )
                        : AppTypography.title,
                  ),
                ),
                if (value != null) _clearButton(JourneyDateKey.balance),
                const Icon(
                  Icons.calendar_month_outlined,
                  size: 22,
                  color: AppColors.primary,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        // 실제 동작과 같은 말 (2026-10-26): 휴대폰 알림 = 모두 오전 8시 (하루 전 + 당일).
        // 알림을 끄면 그날 앱 맨 위 배너로 같은 말을 한다(journey_reminders.dart).
        AppText(kBalanceReminderPromise, style: AppTypography.caption),
      ],
    );
  }

  /// 넣은 날짜를 지우는 자리 — 시안에 없지만 "비워 두셔도 돼요"를 되돌릴 길이 필요하다.
  /// (값이 있을 때만 나타나므로 빈 칸의 모양은 시안 그대로다)
  ///
  /// D10(2026-10-23): 예전 터치 영역은 24dp라 빗나가면 바로 옆 날짜 칸(달력)이 열렸다 → 48dp IconButton.
  Widget _clearButton(JourneyDateKey key) {
    return IconButton(
      onPressed: () => _clear(key),
      tooltip: '${key.label} 지우기',
      constraints: const BoxConstraints(
        minWidth: AppSize.minTouchTarget,
        minHeight: AppSize.minTouchTarget,
      ),
      padding: EdgeInsets.zero,
      icon: const Icon(
        Icons.close,
        size: AppSize.iconXs + 2,
        color: AppColors.textMuted,
      ),
    );
  }
}
