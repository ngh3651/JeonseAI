/// 홈 — "오늘 중요한 일정" 종 버튼과 시트 (2026-10-27, 홈_종버튼_시안 ①·②).
///
/// 예전에는 잔금 하루 전·당일·입주 다음 날에 홈 맨 위에 큰 노랑 배너를 띄웠다. 이제는
/// - 홈 오른쪽 위 **종 버튼**(오늘 일정이 있는 집이 있으면 빨간 점)만 두고,
/// - 누르면 아래에서 시트가 올라와 **오늘 일정만** 상자로 보여 준다(내일·하루 전은 넣지 않는다).
/// - 상자를 누르면 그 집의 계약 여정이 그날 단계가 선택된 채 열린다([JourneyFocus]).
///
/// 날짜는 이 휴대폰에만 있다([JourneyScheduleStore]) — 서버는 모른다.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/content_models.dart';
import '../../models/property_reports.dart';
import '../../state/journey_focus.dart';
import '../../state/journey_schedule_store.dart';
import '../journey/journey_parts.dart' show kRadiusLg;

/// 오늘 일정 하나 — 어느 집의 어떤 날인가.
class TodayEvent {
  const TodayEvent({required this.property, required this.dateKey});

  final PropertyReports property;
  final JourneyDateKey dateKey;

  /// 상자 아랫줄 끝의 일정 이름 — 가계약금 · 계약서 · 잔금일 · 이사 · 입주 다음 날
  String get label => todayEventLabel(dateKey);
}

String todayEventLabel(JourneyDateKey key) => switch (key) {
  JourneyDateKey.downPayment => '가계약금',
  JourneyDateKey.contract => '계약서',
  JourneyDateKey.balance => '잔금일',
  JourneyDateKey.moveIn => '이사',
  JourneyDateKey.moveInNext => '입주 다음 날',
};

/// 일정 순서(계약 흐름 순) — 같은 집에 같은 날 둘이 겹쳐도 이 순서로 쌓는다.
const List<JourneyDateKey> _order = [
  JourneyDateKey.downPayment,
  JourneyDateKey.contract,
  JourneyDateKey.balance,
  JourneyDateKey.moveIn,
  JourneyDateKey.moveInNext,
];

/// 오늘 날짜인 일정만 (최근 분석한 집부터, 집 안에서는 계약 흐름 순).
List<TodayEvent> todayEvents(
  List<PropertyReports> properties,
  JourneyScheduleStore store, {
  DateTime? now,
}) {
  final t = now ?? DateTime.now();
  bool isToday(DateTime d) =>
      d.year == t.year && d.month == t.month && d.day == t.day;
  return [
    for (final p in properties)
      for (final key in _order)
        if (store.scheduleFor(p.key)[key] case final d? when isToday(d))
          TodayEvent(property: p, dateKey: key),
  ];
}

/// 종 시트에서 **이미 본** 오늘 일정 (2026-10-27) — 본 뒤에는 빨간 점을 끈다. 이 폰에만, 오늘 것만 남긴다.
///
/// 새 일정이 오늘로 들어오면(다른 집·다른 날) 그것은 아직 안 본 것이라 점이 다시 켜진다. 날이 바뀌면 비운다.
class TodayBellSeen extends ChangeNotifier {
  TodayBellSeen._();

  static final TodayBellSeen instance = TodayBellSeen._();

  static const String _key = 'today_bell_seen_v1';

  String _day = '';
  final Set<String> _ids = {};

  static String _dayOf(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  static String idOf(TodayEvent e) => '${e.property.key}:${e.dateKey.name}';

  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final m = (jsonDecode(raw) as Map).cast<String, dynamic>();
      _day = m['day'] as String? ?? '';
      _ids
        ..clear()
        ..addAll([for (final x in (m['ids'] as List? ?? const [])) '$x']);
    } catch (e) {
      debugPrint('[종] 본 일정을 읽지 못했어요 (${e.runtimeType})');
    }
  }

  @visibleForTesting
  void resetForTest() {
    _day = '';
    _ids.clear();
  }

  /// 아직 안 본 오늘 일정이 있나 — 빨간 점
  bool hasUnseen(List<TodayEvent> events, {DateTime? now}) {
    final today = _dayOf(now ?? DateTime.now());
    return events.any((e) => _day != today || !_ids.contains(idOf(e)));
  }

  /// 시트를 열었다 = 지금 있는 오늘 일정을 다 봤다.
  Future<void> markSeen(List<TodayEvent> events, {DateTime? now}) async {
    final today = _dayOf(now ?? DateTime.now());
    if (_day != today) {
      _day = today;
      _ids.clear();
    }
    _ids.addAll(events.map(idOf));
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode({'day': _day, 'ids': _ids.toList()}),
      );
    } catch (e) {
      debugPrint('[종] 본 일정을 저장하지 못했어요 (${e.runtimeType})');
    }
  }
}

/// 홈 오른쪽 위 종 버튼 — 원 48, 흰 바탕 + line 테두리. 오늘 일정이 있으면 빨간 점.
class TodayBellButton extends StatelessWidget {
  const TodayBellButton({
    super.key,
    required this.hasToday,
    required this.onPressed,
    this.open = false,
    this.count = 0,
  });

  /// 아직 안 본 오늘 일정이 있나 — 빨간 숫자 (시트를 열어 보면 꺼진다, [TodayBellSeen])
  final bool hasToday;
  final VoidCallback onPressed;

  /// 시트가 열려 있나 — 진한 원 + 흰 종
  final bool open;

  /// 오늘 일정 수 — 빨간 동그라미 안 숫자 (0이면 점만)
  final int count;

  @override
  Widget build(BuildContext context) {
    // 2026-10-30 홈 리뉴얼(종 C): 테두리 원 없이 채운 종 + 빨간 숫자. 인사 줄 오른쪽에 붙는다.
    return Semantics(
      button: true,
      label: hasToday ? '오늘 중요한 일정 있음' : '오늘 중요한 일정',
      child: SizedBox(
        width: 48,
        height: 48,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Material(
              key: const ValueKey('home-bell'),
              color: open ? AppColorsNext.textStrong : Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onPressed,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Icon(
                    Icons.notifications_rounded,
                    size: 26,
                    color: open
                        ? AppColors.onInverse
                        : AppColorsNext.textStrong,
                  ),
                ),
              ),
            ),
            if (hasToday && !open)
              Positioned(
                right: 2,
                top: 3,
                child: IgnorePointer(
                  child: Container(
                    key: const ValueKey('home-bell-dot'),
                    constraints: BoxConstraints(
                      minWidth: count > 0 ? 24 : 13,
                      minHeight: count > 0 ? 24 : 13,
                    ),
                    padding: EdgeInsets.symmetric(
                      horizontal: count > 0 ? 5 : 0,
                    ),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.danger,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: AppColors.background, width: 2),
                    ),
                    child: count > 0
                        ? AppText(
                            count > 9 ? '9+' : '$count',
                            maxLines: 1,
                            style: AppTypographyNext.caption.copyWith(
                              fontSize: 13,
                              height: 1.2,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          )
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 종을 눌렀을 때의 시트 — 손잡이 → "오늘 중요한 일정" → 일정 상자들(사이 14). 없으면 한 줄.
Future<void> showTodayScheduleSheet(
  BuildContext context, {
  required List<TodayEvent> events,
}) {
  return showModalBottomSheet<void>(
    showDragHandle: false, // 손잡이는 직접 그린다 — 테마 손잡이와 겹쳐 두 개로 보였다 (2026-10-27)
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetContext).size.height * 0.8,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenPadding,
            12,
            AppSpacing.screenPadding,
            24,
          ),
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
              AppText('오늘 중요한 일정', style: AppTypographyNext.title),
              const SizedBox(height: 16),
              if (events.isEmpty)
                AppText(
                  '오늘은 중요한 일정이 없어요',
                  key: const ValueKey('today-empty'),
                  style: AppTypographyNext.body.copyWith(
                    color: AppColorsNext.textBody,
                  ),
                )
              else
                for (int i = 0; i < events.length; i++) ...[
                  if (i > 0) const SizedBox(height: 14),
                  TodayEventTile(
                    event: events[i],
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      openJourneyAt(
                        context,
                        propertyKey: events[i].property.key,
                        dateKey: events[i].dateKey,
                      );
                    },
                  ),
                ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// 그 집의 계약 여정을 그날 단계가 선택된 채 연다.
void openJourneyAt(
  BuildContext context, {
  required String propertyKey,
  required JourneyDateKey dateKey,
}) {
  JourneyScheduleStore.instance.select(propertyKey);
  JourneyFocus.request(dateKey);
  GoRouter.of(context).go('/journey');
}

/// 일정 상자 — 높이 72 이상, cautionSoft, 흰 원 40 + ⚠, 두 줄, ›.
class TodayEventTile extends StatelessWidget {
  const TodayEventTile({super.key, required this.event, required this.onTap});

  final TodayEvent event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sub = AppTypographyNext.caption.copyWith(
      fontWeight: FontWeight.w600,
      color: AppColors.caution,
    );
    return Material(
      color: AppColors.cautionSoft,
      borderRadius: BorderRadius.circular(kRadiusLg),
      child: InkWell(
        key: ValueKey(
          'today-event-${event.property.key}-${event.dateKey.name}',
        ),
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadiusLg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    size: 22,
                    color: AppColors.caution,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppText(
                        '오늘 중요한 일정이 있어요',
                        style: AppTypographyNext.bodyStrong.copyWith(
                          color: AppColorsNext.textStrong,
                        ),
                      ),
                      const SizedBox(height: 2),
                      // 집 이름이 길면 이름만 … — "· 잔금일"은 늘 끝에 보인다
                      Row(
                        children: [
                          Flexible(
                            // 글자 폭만큼만 차지한다(줄인 이름 뒤에 빈칸이 생기지 않게)
                            child: Text(
                              event.property.alias,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              textWidthBasis: TextWidthBasis.longestLine,
                              style: sub,
                            ),
                          ),
                          AppText(' · ${event.label}', maxLines: 1, style: sub),
                        ],
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: AppColors.caution),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
