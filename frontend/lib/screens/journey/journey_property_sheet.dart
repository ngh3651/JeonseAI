/// 집 바꾸기 시트 (그림 ⑥) — 아래에서 올라오고, 집 카드를 옆으로 넘겨 고른다. 맨 끝은 [새로 분석].
///
/// 카드는 홈 '내 집'과 같은 [HouseCard](2026-10-30) — 아랫줄만 "잔금 D-6 · 10/30 (금)" / "잔금일 없음".
/// [새로 분석]은 아래 ＋와 같은 '매물 분석 시작하기' 시트를 연다(여정 화면이 [startAnalysis]를 부른다).
library;

import 'package:flutter/material.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/property_reports.dart';
import '../../state/journey_schedule_store.dart';
import '../common/house_card.dart';

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
            // 홈 '내 집' 카드와 같은 카드(폭 276) — 아랫줄만 잔금일 (2026-10-30 홈 리뉴얼)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenPadding,
                10, // 고른 집의 모서리 체크가 잘리지 않게
                AppSpacing.screenPadding,
                8,
              ),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final p in widget.properties) ...[
                      _card(p),
                      const SizedBox(width: 12),
                    ],
                    NewAnalysisCard(
                      onTap: () =>
                          Navigator.of(context).pop(const HouseNewAnalysis()),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(PropertyReports p) {
    final DateTime? balance = widget.store.scheduleFor(p.key).balance;
    return HouseCard(
      key: ValueKey('house-card-${p.key}'),
      property: p,
      width: kHouseCardWidth,
      selected: p.key == _selected,
      outlined: true,
      subline: houseBalanceLine(balance),
      sublineStrong: balance != null,
      onTap: () => _pick(p.key),
    );
  }
}
