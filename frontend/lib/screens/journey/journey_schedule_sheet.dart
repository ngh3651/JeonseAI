/// 계약 일정 입력 시트 (S-11 화면 3) — 2026-10-27 시안(`일정입력_시안.png` ①·②)으로 다시 그렸다.
///
/// 네 칸 **전부 선택 입력**이다. 아직 안 정해진 날이 있는 것이 정상이라, 필수로 두면
/// 사용자는 아무 날짜나 넣게 되고 그 순간 D-1 알림이 거짓말이 된다.
///
/// - 칸 이름은 여정 날짜 원과 똑같이: 가계약금 · 계약서 · 잔금 · 이사
/// - 왼쪽 원은 여정 날짜 원과 같은 뜻: 비어 있음(회색 +) · 앞으로(흰 바탕 초록 테두리 ✓) · 지남(초록 꽉 찬 ✓)
/// - 잔금 칸만 **모양으로** 강조한다(연초록 바탕 · 초록 테두리 · 큰 원) — 글로 "가장 중요해요"라고 하지 않는다
/// - 칸 어디를 눌러도 날짜 고르기, 오른쪽 ×만 그 칸을 지운다
///
/// 화면만 바뀌었다. 저장 위치(**이 휴대폰뿐** — state/journey_schedule_store.dart)·알림 예약(모든 일정 오전 8시,
/// 잔금 하루 전 포함 — journey_reminders.dart)·입주 다음 날(이사 날짜 + 1일, 묻지 않음)은 그대로다.
library;

import 'package:flutter/material.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/content_models.dart';
import '../../state/journey_schedule_store.dart';
import '../../utils/korean_date.dart';
import '../report/registry_mark_sheet.dart'
    show kSheetEnterDuration, kSheetExitDuration;
import 'journey_logic.dart' show circleLabel;

/// 저장 버튼 — 날짜가 하나도 없고 바뀐 것도 없을 때의 회색
const Color _kSaveIdleBg = Color(0xFFECEFED);
const Color _kSaveIdleFg = Color(0xFF5E6B64);

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
    showDragHandle: false, // 손잡이를 직접 그린다
    backgroundColor: AppColors.surface,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    sheetAnimationStyle: AnimationStyle(
      duration: kSheetEnterDuration,
      reverseDuration: kSheetExitDuration,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
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

  bool get _changed {
    for (final key in JourneyDateKey.editable) {
      if (_draft[key] != widget.initial[key]) return true;
    }
    return false;
  }

  Future<void> _pick(JourneyDateKey key) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _draft[key] ?? now,
      // 이미 지난 계약서 날짜를 넣는 경우가 있어 과거도 연다(1년 전까지).
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
      helpText: circleLabel(key),
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
    // 날짜가 하나라도 있거나 바뀐 게 있으면 초록 — 아무것도 없으면 회색(누를 것이 없다)
    final bool active = !_draft.isEmpty || _changed;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            AppText(
              '계약 일정',
              key: const ValueKey('schedule-sheet-title'),
              style: AppTypographyNext.headline.copyWith(
                color: AppColorsNext.textStrong,
              ),
            ),
            const SizedBox(height: 16),
            for (int i = 0; i < JourneyDateKey.editable.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              _DateField(
                dateKey: JourneyDateKey.editable[i],
                value: _draft[JourneyDateKey.editable[i]],
                onPick: () => _pick(JourneyDateKey.editable[i]),
                onClear: () => _clear(JourneyDateKey.editable[i]),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              height: 56,
              child: FilledButton(
                key: const ValueKey('schedule-sheet-save'),
                onPressed: active
                    ? () => Navigator.of(context).pop(_draft)
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: _kSaveIdleBg,
                  disabledForegroundColor: _kSaveIdleFg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: AppText(
                  '저장',
                  style: AppTypographyNext.button.copyWith(
                    color: active ? Colors.white : _kSaveIdleFg,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 날짜 칸 한 개 — [왼쪽 원] + [이름 / 날짜 두 줄] + [오른쪽 버튼(달력 또는 ×)].
class _DateField extends StatelessWidget {
  const _DateField({
    required this.dateKey,
    required this.value,
    required this.onPick,
    required this.onClear,
  });

  final JourneyDateKey dateKey;
  final DateTime? value;
  final VoidCallback onPick;
  final VoidCallback onClear;

  bool get _balance => dateKey == JourneyDateKey.balance;

  @override
  Widget build(BuildContext context) {
    final String name = circleLabel(dateKey);
    final DateTime? v = value;
    return Material(
      color: _balance ? AppColors.primarySoft : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: _balance
            ? const BorderSide(color: AppColors.primary, width: 1.5)
            : const BorderSide(color: AppColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('schedule-field-${dateKey.name}'),
        onTap: onPick,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                _Circle(balance: _balance, value: v),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppText(
                        name,
                        style: AppTypographyNext.caption.copyWith(
                          fontWeight: _balance
                              ? FontWeight.w700
                              : FontWeight.w600,
                          color: _balance
                              ? AppColors.primaryDeep
                              : AppColorsNext.textStrong,
                        ),
                      ),
                      // 130% 글자에서도 날짜는 한 줄 — 넘치면 줄바꿈하지 않고 살짝 작게
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: AppText(
                          v == null ? '날짜 선택' : formatMonthDayWeekday(v),
                          key: ValueKey('schedule-date-${dateKey.name}'),
                          maxLines: 1,
                          style: v == null
                              ? AppTypographyNext.body.copyWith(
                                  color: AppColorsNext.textMuted,
                                )
                              : AppTypographyNext.bodyStrong.copyWith(
                                  color: AppColors.primary,
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (v == null)
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(
                      Icons.calendar_today_outlined,
                      size: 22,
                      color: _balance
                          ? AppColors.primary
                          : AppColorsNext.textMuted,
                    ),
                  )
                else
                  IconButton(
                    key: ValueKey('schedule-clear-${dateKey.name}'),
                    onPressed: onClear,
                    tooltip: '$name 날짜 지우기',
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    padding: EdgeInsets.zero,
                    icon: const Icon(
                      Icons.close,
                      size: 22,
                      color: AppColorsNext.textMuted,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 왼쪽 원 — 여정 날짜 원과 같은 뜻. 잔금은 56, 나머지는 44.
class _Circle extends StatelessWidget {
  const _Circle({required this.balance, required this.value});

  final bool balance;
  final DateTime? value;

  @override
  Widget build(BuildContext context) {
    final double size = balance ? 56 : 44;
    final DateTime? v = value;
    if (v == null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: balance ? Colors.white : AppColors.background,
          shape: BoxShape.circle,
          border: balance ? null : Border.all(color: AppColors.line),
        ),
        child: Icon(
          Icons.add,
          size: 22,
          color: balance ? AppColors.primary : AppColorsNext.textMuted,
        ),
      );
    }
    final bool passed = daysUntil(v) < 0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: passed ? AppColors.primary : Colors.white,
        shape: BoxShape.circle,
        border: passed
            ? null
            : Border.all(color: AppColors.primary, width: 1.5),
      ),
      child: Icon(
        Icons.check,
        size: 22,
        color: passed ? Colors.white : AppColors.primary,
      ),
    );
  }
}
