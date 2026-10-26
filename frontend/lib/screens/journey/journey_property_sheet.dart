/// 집 바꾸기 시트 (그림 ⑥) — 아래에서 올라오고, 집 카드를 옆으로 넘겨 고른다. 맨 끝은 [새로 분석].
library;

import 'package:flutter/material.dart';

import '../../design_system/components/dashed_border.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/property_reports.dart';
import '../../state/journey_schedule_store.dart';
import '../../utils/korean_date.dart';
import 'journey_parts.dart';

/// 시트 결과 — 고른 집 키, 또는 [새로 분석].
sealed class HousePick {
  const HousePick();
}

class HousePicked extends HousePick {
  const HousePicked(this.key);
  final String key;
}

class HouseNewAnalysis extends HousePick {
  const HouseNewAnalysis();
}

Future<HousePick?> showHouseSwitchSheet(
  BuildContext context, {
  required List<PropertyReports> properties,
  required String selectedKey,
  required JourneyScheduleStore store,
}) {
  return showModalBottomSheet<HousePick>(
    showDragHandle: false, // 손잡이는 직접 그린다 — 테마 손잡이와 겹쳐 두 개로 보였다 (2026-10-27)
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) => _HouseSheet(
      properties: properties,
      selectedKey: selectedKey,
      store: store,
    ),
  );
}

class _HouseSheet extends StatefulWidget {
  const _HouseSheet({
    required this.properties,
    required this.selectedKey,
    required this.store,
  });

  final List<PropertyReports> properties;
  final String selectedKey;
  final JourneyScheduleStore store;

  @override
  State<_HouseSheet> createState() => _HouseSheetState();
}

class _HouseSheetState extends State<_HouseSheet> {
  late String _selected = widget.selectedKey;

  Future<void> _pick(String key) async {
    setState(() => _selected = key);
    // 선택된 모습을 0.2초 보여 준 뒤 닫는다
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (mounted) Navigator.of(context).pop(HousePicked(key));
  }

  @override
  Widget build(BuildContext context) {
    final double scale = MediaQuery.textScalerOf(
      context,
    ).scale(1).clamp(1.0, 1.4);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 20),
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
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenPadding,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText('어느 집의 여정을 볼까요?', style: AppTypographyNext.title),
                  AppText('옆으로 넘겨서 골라요', style: AppTypographyNext.caption),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 152 * scale + 8,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.screenPadding,
                ),
                children: [
                  for (final p in widget.properties) ...[
                    _card(p),
                    const SizedBox(width: 12),
                  ],
                  _newCard(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(PropertyReports p) {
    final bool on = p.key == _selected;
    final viewed = p.registryViewedDate;
    final balance = widget.store.scheduleFor(p.key).balance;
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusCard),
        side: BorderSide(
          color: on ? AppColors.primary : AppColors.line,
          width: 2,
        ),
      ),
      child: InkWell(
        key: ValueKey('house-card-${p.key}'),
        onTap: () => _pick(p.key),
        borderRadius: BorderRadius.circular(kRadiusCard),
        child: Container(
          width: 220,
          constraints: const BoxConstraints(minHeight: 152),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  GradePill(grade: p.latest.grade),
                  const Spacer(),
                  if (on)
                    Container(
                      width: 24,
                      height: 24,
                      decoration: const BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.check,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              AppText(
                p.alias,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypographyNext.bodyStrong.copyWith(
                  color: AppColorsNext.textStrong,
                ),
              ),
              AppText(
                viewed == null
                    ? '등기부 날짜를 읽지 못했어요'
                    : '등기부 ${formatMonthDay(viewed)}자',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypographyNext.caption,
              ),
              const SizedBox(height: 4),
              AppText(
                balance == null
                    ? '잔금일 없음'
                    : '잔금 ${formatMonthDay(balance)} · ${_dLabel(balance)}',
                maxLines: 1,
                style: balance == null
                    ? AppTypographyNext.caption
                    : AppTypographyNext.caption.copyWith(
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _dLabel(DateTime d) {
    final days = daysUntil(d);
    if (days == 0) return 'D-DAY';
    return days > 0 ? 'D-$days' : 'D+${-days}';
  }

  Widget _newCard() {
    return DashedBorder(
      color: AppColors.line,
      radius: kRadiusCard,
      child: Material(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(kRadiusCard),
        child: InkWell(
          key: const ValueKey('house-card-new'),
          onTap: () => Navigator.of(context).pop(const HouseNewAnalysis()),
          borderRadius: BorderRadius.circular(kRadiusCard),
          child: SizedBox(
            width: 140,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(
                    color: AppColors.primarySoft,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.add, color: AppColors.primary),
                ),
                const SizedBox(height: 8),
                AppText(
                  '새로 분석',
                  style: AppTypographyNext.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
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
