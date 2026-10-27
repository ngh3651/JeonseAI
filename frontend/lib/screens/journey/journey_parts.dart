/// 계약 여정 화면 조각 — 집 줄 · 리포트 카드 · 내 계약 일정 · 단계 칩 · 단계 카드 · 등기부 변동 기록 (2026-10-26 확정 시안).
///
/// 값은 확정 디자인 규칙 0장(앱 전체 토큰)을 따른다: 글자 `AppTypographyNext`, 색 `AppColors`·`AppColorsNext`.
/// 판정은 하지 않는다 — 등급은 그 집의 **가장 최근 리포트 등급**을 보여 주기만 한다.
library;

import 'package:flutter/material.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/content_models.dart';
import '../../models/property_reports.dart';
import '../../models/risk_grade.dart';
import '../../state/journey_progress_store.dart';
import '../../utils/korean_date.dart';
import 'change_boxes.dart';
import 'journey_logic.dart';

/// 단계 부제·왜 설명의 본문 보조색 (#3C4842)
const Color kJourneyBodySub = AppColors.textBody;

/// 카드 모서리 xl 20 · 큰 버튼 lg 16 · 작은 상자 md 12 · 할 일 번호 sm 8
const double kRadiusCard = 20;
const double kRadiusLg = 16;
const double kRadiusMd = 12;
const double kRadiusSm = 8;

/// `**굵게**` 표시를 굵은 글씨로 바꾼다 — 굵은 부분은 700 textStrong.
InlineSpan boldMarkup(String text, TextStyle base, {Color? boldColor}) {
  final bold = base.copyWith(
    fontWeight: FontWeight.w700,
    color: boldColor ?? AppColorsNext.textStrong,
  );
  final spans = <InlineSpan>[];
  int at = 0;
  for (final m in RegExp(r'\*\*(.+?)\*\*').allMatches(text)) {
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
    spans.add(TextSpan(text: m.group(1), style: bold));
    at = m.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return TextSpan(style: base, children: spans);
}

/// `**` 표시를 뺀 글 (스크린 리더·비교용)
String plainMarkup(String text) => text.replaceAll('**', '');

// ── 등급 알약 ───────────────────────────────────────────────────────────────

/// 등급 알약 — 높이 28 · 좌우 10 · 15/600. 위험 = 빨강, 확인 필요 = 노랑, 양호 = 초록. "주의"라는 말은 쓰지 않는다.
class GradePill extends StatelessWidget {
  const GradePill({super.key, required this.grade});

  final RiskGrade grade;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (grade) {
      RiskGrade.danger => (AppColors.dangerSoft, AppColorsNext.dangerText),
      RiskGrade.caution => (AppColors.cautionSoft, AppColors.caution),
      RiskGrade.ok => (AppColors.okSoft, AppColors.ok),
    };
    return Container(
      // 높이 28 = 글자 18 + 위아래 5 (alignment를 주면 알약이 줄 폭만큼 늘어난다)
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: AppText(
        grade.label,
        maxLines: 1,
        style: AppTypographyNext.caption.copyWith(
          fontWeight: FontWeight.w600,
          color: fg,
          height: 1.2,
        ),
      ),
    );
  }
}

// ── 앱바 ───────────────────────────────────────────────────────────────────

/// ← + 가운데 "계약 여정". 탭 루트면 ← 자리를 비워 둔다(가운데 정렬 유지).
class JourneyAppBar extends StatelessWidget {
  const JourneyAppBar({super.key, required this.showBack});

  final bool showBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.background,
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            SizedBox(
              width: AppSize.minTouchTarget,
              child: showBack
                  ? IconButton(
                      tooltip: '뒤로',
                      icon: const Icon(
                        Icons.arrow_back,
                        color: AppColorsNext.textStrong,
                      ),
                      onPressed: () => Navigator.of(context).maybePop(),
                    )
                  : null,
            ),
            Expanded(
              child: AppText(
                '계약 여정',
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypographyNext.title,
              ),
            ),
            const SizedBox(width: AppSize.minTouchTarget),
          ],
        ),
      ),
    );
  }
}

// ── 집 줄 ──────────────────────────────────────────────────────────────────

/// [등급 알약] + 집 이름(별칭만, 도로명 주소는 넣지 않는다) + [집 바꾸기 ⌄]
class HouseRow extends StatelessWidget {
  const HouseRow({super.key, required this.property, required this.onSwitch});

  final PropertyReports property;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        GradePill(grade: property.latest.grade),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: AppText(
            property.alias,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypographyNext.title,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Material(
          color: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadiusMd),
            side: const BorderSide(color: AppColors.line),
          ),
          child: InkWell(
            key: const ValueKey('journey-switch-house'),
            onTap: onSwitch,
            borderRadius: BorderRadius.circular(kRadiusMd),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppText(
                      '집 바꾸기',
                      style: AppTypographyNext.caption.copyWith(
                        fontWeight: FontWeight.w600,
                        color: AppColorsNext.textStrong,
                      ),
                    ),
                    const Icon(
                      Icons.expand_more,
                      size: 20,
                      color: AppColorsNext.textStrong,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── 흰 카드 ────────────────────────────────────────────────────────────────

class JourneyCard extends StatelessWidget {
  const JourneyCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.flash = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// 회색 띠로 바로 갔을 때 테두리가 primaryBright 3px로 반짝인다
  final bool flash;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(kRadiusCard),
        border: Border.all(
          color: flash ? AppColors.primaryBright : Colors.transparent,
          width: 3,
        ),
      ),
      child: child,
    );
  }
}

// ── 리포트 카드 ────────────────────────────────────────────────────────────

/// 최근 분석 리포트 + 아래 회색 띠(다음에 뗄 날). 띠는 **바로 가기**일 뿐 — 대조는 단계 카드의 버튼으로만 시작한다.
class ReportCard extends StatelessWidget {
  const ReportCard({
    super.key,
    required this.property,
    required this.latestLog,
    required this.recheck,
    required this.onOpen,
    required this.onRecheck,
  });

  final PropertyReports property;

  /// 최신 리포트를 만든 대조 기록(있으면 날짜 줄 꼬리말이 '대조 · 변동 없음'/'변동 1건'으로 바뀐다)
  final CompareLogEntry? latestLog;

  /// 회색 띠 문구 (굵은 부분 포함)
  final InlineSpan recheck;
  final VoidCallback onOpen;

  /// null이면 띠를 누를 수 없다("다시 뗄 일정이 없어요")
  final VoidCallback? onRecheck;

  @override
  Widget build(BuildContext context) {
    final viewed = property.registryViewedDate;
    final age = property.registryAgeDays;
    final base = AppTypographyNext.caption;
    final InlineSpan dateLine;
    if (viewed == null) {
      dateLine = TextSpan(text: '등기부 날짜를 읽지 못했어요', style: base);
    } else {
      final log = latestLog;
      final InlineSpan tail;
      if (log != null && log.changed) {
        tail = TextSpan(
          text: '변동 ${log.changedCount}건',
          style: base.copyWith(
            fontWeight: FontWeight.w700,
            color: AppColorsNext.dangerText,
          ),
        );
      } else if (log != null) {
        tail = TextSpan(
          text: '대조 · 변동 없음',
          style: base.copyWith(
            fontWeight: FontWeight.w700,
            color: AppColors.ok,
          ),
        );
      } else {
        // 지난 날수 — caution 굵게. **날수에 따라 색을 바꾸지 않는다**
        tail = TextSpan(
          text: '${age ?? 0}일 전',
          style: base.copyWith(
            fontWeight: FontWeight.w700,
            color: AppColors.caution,
          ),
        );
      }
      dateLine = TextSpan(
        style: base,
        children: [
          TextSpan(text: '등기부 ${formatMonthDay(viewed)}자 · '),
          tail,
        ],
      );
    }

    return JourneyCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const ValueKey('journey-report-card'),
            onTap: onOpen,
            borderRadius: BorderRadius.circular(kRadiusMd),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.cautionSoft,
                    borderRadius: BorderRadius.circular(kRadiusMd),
                  ),
                  child: const Icon(
                    Icons.description_outlined,
                    color: AppColors.caution,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: AppText(
                              '최근 분석 리포트',
                              maxLines: 1,
                              style: AppTypographyNext.bodyStrong.copyWith(
                                color: AppColorsNext.textStrong,
                              ),
                            ),
                          ),
                          AppText(
                            '보기 ›',
                            style: AppTypographyNext.caption.copyWith(
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary,
                            ),
                          ),
                        ],
                      ),
                      AppText.rich(dateLine),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Material(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(kRadiusMd),
            child: InkWell(
              key: const ValueKey('journey-recheck-strip'),
              onTap: onRecheck,
              borderRadius: BorderRadius.circular(kRadiusMd),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.refresh,
                        size: 20,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: AppText.rich(recheck)),
                      if (onRecheck != null)
                        const Icon(
                          Icons.chevron_right,
                          size: 20,
                          color: AppColorsNext.textMuted,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 내 계약 일정 ───────────────────────────────────────────────────────────

class ScheduleCard extends StatelessWidget {
  const ScheduleCard({
    super.key,
    required this.progress,
    required this.onEdit,
    required this.showNotifyLine,
  });

  final JourneyProgress progress;
  final VoidCallback onEdit;

  /// 알림이 켜져 있을 때만 "일정마다 오전 8시에 알려 드려요"
  final bool showNotifyLine;

  @override
  Widget build(BuildContext context) {
    final bool hasAny = !progress.schedule.isEmpty;
    final String? next = progress.nextLine;
    return JourneyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText('내 계약 일정', style: AppTypographyNext.headline),
          const SizedBox(height: 4),
          if (!hasAny)
            AppText('날짜를 넣으면 이 화면이 내 일정표가 돼요', style: AppTypographyNext.caption)
          else if (next != null)
            AppText(
              next,
              style: AppTypographyNext.caption.copyWith(
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            )
          else
            AppText('넣은 일정이 모두 지났어요', style: AppTypographyNext.caption),
          const SizedBox(height: 20),
          _Circles(progress: progress, onTap: onEdit),
          const SizedBox(height: 20),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              key: const ValueKey('journey-edit-schedule'),
              onPressed: onEdit,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(kRadiusLg),
                ),
              ),
              icon: const Icon(Icons.calendar_month_outlined, size: 22),
              label: AppText(
                hasAny ? '일정 수정' : '일정 넣기',
                style: AppTypographyNext.button.copyWith(color: Colors.white),
              ),
            ),
          ),
          if (showNotifyLine && hasAny) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: const BoxDecoration(
                    color: AppColors.primarySoft,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.notifications_none,
                    size: 18,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppText.rich(
                    TextSpan(
                      style: AppTypographyNext.body,
                      children: [
                        const TextSpan(text: '일정마다 '),
                        TextSpan(
                          text: '오전 8시',
                          style: AppTypographyNext.body.copyWith(
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                        const TextSpan(text: '에 알려 드려요'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 날짜 원 4개 + 사이 선. 잔금만 56(가장 큰 돈이 나가는 날), 나머지 44.
class _Circles extends StatelessWidget {
  const _Circles({required this.progress, required this.onTap});

  final JourneyProgress progress;

  /// 원을 누르면(특히 빈 [+] 원) 일정 넣기 시트 — [일정 넣기] 버튼과 같다 (2026-10-27)
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const int n = 4;
    return LayoutBuilder(
      builder: (context, box) {
        final double cell = box.maxWidth / n;
        return Stack(
          children: [
            // 원 가운데 높이(56 칸의 가운데 = 28)에 선
            for (int c = 0; c < n - 1; c++)
              Positioned(
                left: cell * c + cell / 2,
                width: cell,
                top: 28 - (progress.segmentFilled(c) ? 2 : 1),
                child: AnimatedContainer(
                  duration: Duration(milliseconds: 400 + 180 * c),
                  height: progress.segmentFilled(c) ? 4 : 2,
                  color: progress.segmentFilled(c)
                      ? AppColors.primary
                      : AppColors.line,
                ),
              ),
            Row(
              children: [
                for (int c = 0; c < n; c++)
                  SizedBox(
                    width: cell,
                    child: Column(
                      children: [
                        SizedBox(
                          height: 56,
                          child: Center(
                            child: Semantics(
                              button: true,
                              label: '${circleLabel(kScheduleCircleKeys[c])} 날짜 넣기',
                              child: GestureDetector(
                                key: ValueKey('journey-circle-tap-$c'),
                                behavior: HitTestBehavior.opaque,
                                onTap: onTap,
                                // 누를 자리는 56×56 이상 (원 44라도)
                                child: SizedBox(
                                  width: 56,
                                  height: 56,
                                  child: Center(child: _circle(c)),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: AppText(
                            circleLabel(kScheduleCircleKeys[c]),
                            maxLines: 1,
                            textAlign: TextAlign.center,
                            style: AppTypographyNext.caption.copyWith(
                              color: AppColorsNext.textBody,
                            ),
                          ),
                        ),
                        _dateText(c),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _dateText(int c) {
    final key = kScheduleCircleKeys[c];
    final d = progress.schedule[key];
    return SizedBox(
      height: 22 * 1.0,
      child: d == null
          ? null
          : AppText(
              slashDate(d),
              maxLines: 1,
              style: AppTypographyNext.caption.copyWith(
                fontWeight: FontWeight.w600,
                color: AppColorsNext.textStrong,
              ),
            ),
    );
  }

  Widget _circle(int c) {
    final key = kScheduleCircleKeys[c];
    final bool balance = key == JourneyDateKey.balance;
    final double size = balance ? 56 : 44;
    final state = progress.circleState(c);
    final DateTime? d = progress.schedule[key];

    Color bg;
    Border? border;
    List<BoxShadow>? glow;
    Widget? child;
    double scale = 1;
    switch (state) {
      case CircleState.empty:
        bg = balance ? AppColors.primarySoft : AppColors.background;
        child = Icon(
          Icons.add,
          size: 20,
          color: balance ? AppColors.primary : AppColorsNext.textMuted,
        );
      case CircleState.passed:
        bg = AppColors.primary;
        child = const Icon(Icons.check, size: 22, color: Colors.white);
      case CircleState.current:
        bg = AppColors.primarySoft;
        scale = 1.14;
        border = Border.all(color: AppColors.primaryBright, width: 2);
        glow = [
          BoxShadow(
            color: AppColors.primaryBright.withValues(alpha: 0.28),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ];
        child = _dText(dDayLabel(d!), AppColors.primaryDeep);
      case CircleState.future:
        bg = AppColors.surface;
        border = Border.all(color: AppColors.primary, width: 1);
        child = _dText(dDayLabel(d!), AppColors.primary);
    }
    return AnimatedScale(
      duration: Duration(milliseconds: 400 + 180 * c),
      scale: scale,
      child: AnimatedContainer(
        key: ValueKey('journey-circle-$c'),
        duration: Duration(milliseconds: 400 + 180 * c),
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border: border,
          boxShadow: glow,
        ),
        child: child,
      ),
    );
  }

  Widget _dText(String label, Color color) => Padding(
    padding: const EdgeInsets.all(4),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: AppText(
        label,
        maxLines: 1,
        textScaler: TextScaler.noScaling,
        style: AppTypographyNext.caption.copyWith(
          fontWeight: FontWeight.w700,
          color: color,
          height: 1,
        ),
      ),
    ),
  );
}

// ── 단계별 할 일 — 칩 줄 ─────────────────────────────────────────────────

class StageChipsRow extends StatelessWidget {
  const StageChipsRow({
    super.key,
    required this.progress,
    required this.selected,
    required this.onTap,
    this.controller,
  });

  final JourneyProgress progress;
  final int selected;
  final ValueChanged<int> onTap;
  final ScrollController? controller;

  static const double cellWidth = 64;

  @override
  Widget build(BuildContext context) {
    final double scale = MediaQuery.textScalerOf(
      context,
    ).scale(1).clamp(1.0, 1.4);
    final int current = progress.currentIndex ?? -1;
    return SizedBox(
      height: 8 + 36 + 6 + 22 * scale + 10,
      child: ListView.builder(
        controller: controller,
        scrollDirection: Axis.horizontal,
        itemCount: progress.stages.length,
        itemBuilder: (context, i) {
          final bool on = i == selected;
          final bool done = progress.isDone(i);
          final bool cur = i == current && !done;
          return Semantics(
            button: true,
            selected: on,
            label:
                '${i + 1}단계 ${progress.stages[i].chipLabel}${done ? ' 완료' : ''}',
            excludeSemantics: true,
            child: GestureDetector(
              key: ValueKey('journey-chip-$i'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onTap(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: cellWidth,
                padding: const EdgeInsets.only(top: 8, bottom: 6),
                decoration: BoxDecoration(
                  color: on ? AppColors.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(kRadiusLg),
                ),
                child: Column(
                  children: [
                    _chipCircle(i + 1, done: done, current: cur),
                    const SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: AppText(
                        progress.stages[i].chipLabel,
                        maxLines: 1,
                        style: AppTypographyNext.caption.copyWith(
                          fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                          color: on
                              ? AppColorsNext.textStrong
                              : AppColorsNext.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _chipCircle(int number, {required bool done, required bool current}) {
    if (done) {
      return Container(
        width: 36,
        height: 36,
        decoration: const BoxDecoration(
          color: AppColors.primary,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.check, size: 20, color: Colors.white),
      );
    }
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: current ? AppColors.primarySoft : AppColors.surface,
        shape: BoxShape.circle,
        border: Border.all(
          color: current ? AppColors.primaryBright : AppColors.line,
          width: current ? 2 : 1,
        ),
        boxShadow: current
            ? [
                BoxShadow(
                  color: AppColors.primaryBright.withValues(alpha: 0.28),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: AppText(
        '$number',
        textScaler: TextScaler.noScaling,
        style: AppTypographyNext.caption.copyWith(
          fontWeight: FontWeight.w700,
          height: 1,
          color: current ? AppColors.primaryDeep : AppColorsNext.textMuted,
        ),
      ),
    );
  }
}

// ── 단계 카드 ──────────────────────────────────────────────────────────────

class StageCard extends StatelessWidget {
  const StageCard({
    super.key,
    required this.index,
    required this.progress,
    required this.openItems,
    required this.onToggleItem,
    required this.compareSubtitle,
    required this.onCompare,
    this.flash = false,
  });

  final int index;
  final JourneyProgress progress;

  /// 펼친 [자세히] (할 일 번호)
  final Set<int> openItems;
  final ValueChanged<int> onToggleItem;

  /// "8월 14일자 리포트와 비교"
  final String compareSubtitle;

  /// null이면 대조 버튼을 그리지 않는다(집이 없을 때는 분석으로 보낸다 — 부르는 쪽이 정한다)
  final VoidCallback? onCompare;
  final bool flash;

  JourneyStage get stage => progress.stages[index];

  @override
  Widget build(BuildContext context) {
    final DateTime? date = progress.dateOf(index);
    final Widget? chip = _statusChip(date);
    return JourneyCard(
      flash: flash,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (chip != null || date != null || stage.agency != null) ...[
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ?chip,
                if (date != null)
                  AppText(
                    slashDateWeekday(date),
                    style: AppTypographyNext.caption.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (stage.agency != null) _agencyTag(stage.agency!),
              ],
            ),
            const SizedBox(height: 10),
          ],
          AppText(stage.title, style: AppTypographyNext.title),
          const SizedBox(height: 4),
          AppText.rich(
            boldMarkup(
              stage.subtitle,
              AppTypographyNext.body.copyWith(color: kJourneyBodySub),
            ),
            semanticsLabel: plainMarkup(stage.subtitle),
          ),
          const SizedBox(height: 16),
          const Divider(height: 1, thickness: 1, color: AppColorsNext.divider),
          const SizedBox(height: 14),
          AppText(
            '더 챙기면 좋은 것',
            style: AppTypographyNext.caption.copyWith(
              fontWeight: FontWeight.w700,
              color: AppColors.caution,
            ),
          ),
          for (int i = 0; i < stage.items.length; i++) ...[
            if (i > 0)
              const Divider(
                height: 1,
                thickness: 1,
                color: AppColorsNext.divider,
              ),
            _ItemRow(
              number: i + 1,
              item: stage.items[i],
              open: openItems.contains(i),
              onToggle: () => onToggleItem(i),
            ),
          ],
          if (onCompare != null && progress.showsCompare(index)) ...[
            const SizedBox(height: 12),
            CompareButton(subtitle: compareSubtitle, onPressed: onCompare!),
          ],
        ],
      ),
    );
  }

  Widget? _statusChip(DateTime? date) {
    final bool done = progress.isDone(index);
    final bool current = progress.currentIndex == index && !done;
    if (done) {
      final bool dateDone = date != null && daysUntil(date) < 0;
      return _pill(
        dateDone ? '완료 · ${dDayLabel(date)}' : '완료',
        AppColors.primarySoft,
        AppColors.primary,
      );
    }
    if (current && date != null)
      return _pill(dDayLabel(date), AppColors.primary, Colors.white);
    if (date != null)
      return _pill(
        dDayLabel(date),
        AppColors.surface,
        AppColors.primary,
        outline: true,
      );
    // 2~5단계(사용자가 날짜를 넣는 단계)만 "날짜 없음". 6~9단계는 칩을 숨긴다.
    final key = stage.dateKey;
    if (key != null && key != JourneyDateKey.moveInNext) {
      return _pill('날짜 없음', AppColors.background, AppColorsNext.textMuted);
    }
    return null;
  }

  Widget _pill(String label, Color bg, Color fg, {bool outline = false}) =>
      Container(
        key: ValueKey('stage-status-$index'),
        // 높이 28 = 글자 18 + 위아래 5 (alignment를 주면 알약이 줄 폭만큼 늘어난다)
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: outline ? Border.all(color: AppColors.primary) : null,
        ),
        child: AppText(
          label,
          maxLines: 1,
          style: AppTypographyNext.caption.copyWith(
            fontWeight: FontWeight.w600,
            color: fg,
            height: 1.2,
          ),
        ),
      );

  Widget _agencyTag(String label) => Container(
    // 높이 28 = 글자 18 + 위아래 5 (alignment를 주면 알약이 줄 폭만큼 늘어난다)
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(999),
    ),
    child: AppText(
      label,
      maxLines: 1,
      style: AppTypographyNext.caption.copyWith(
        fontWeight: FontWeight.w600,
        color: kJourneyBodySub,
        height: 1.2,
      ),
    ),
  );
}

/// 할 일 한 줄 — 번호 네모(caution) + 제목 + [자세히 ⌄]. 펼치면 "왜 ·" / "어디서 ·".
class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.number,
    required this.item,
    required this.open,
    required this.onToggle,
  });

  final int number;
  final JourneyItem item;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final detail = AppTypographyNext.caption.copyWith(color: kJourneyBodySub);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.caution,
                  borderRadius: BorderRadius.circular(kRadiusSm),
                ),
                child: AppText(
                  '$number',
                  textScaler: TextScaler.noScaling,
                  style: AppTypographyNext.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppText(
                  item.text,
                  style: AppTypographyNext.bodyStrong.copyWith(
                    color: AppColorsNext.textStrong,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _DetailButton(open: open, onTap: onToggle),
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: !open
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(left: 32, top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppText.rich(
                          TextSpan(
                            style: detail,
                            children: [
                              TextSpan(
                                text: '왜 · ',
                                style: detail.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.caution,
                                ),
                              ),
                              boldMarkup(item.why, detail),
                            ],
                          ),
                          semanticsLabel: '왜 · ${plainMarkup(item.why)}',
                        ),
                        if (item.where != null) ...[
                          const SizedBox(height: 4),
                          AppText.rich(
                            TextSpan(
                              style: detail,
                              children: [
                                TextSpan(
                                  text: '어디서 · ',
                                  style: detail.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primary,
                                  ),
                                ),
                                TextSpan(text: item.where),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _DetailButton extends StatelessWidget {
  const _DetailButton({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color fg = open ? Colors.white : kJourneyBodySub;
    return Semantics(
      button: true,
      expanded: open,
      label: '자세히',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          // 보이는 높이 32, 누르는 곳은 위아래로 넓힌다
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            height: 32,
            padding: const EdgeInsets.only(left: 12, right: 8),
            decoration: BoxDecoration(
              color: open ? kJourneyBodySub : AppColors.background,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppText(
                  '자세히',
                  textScaler: TextScaler.noScaling,
                  style: AppTypographyNext.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: fg,
                    height: 1,
                  ),
                ),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 250),
                  child: Icon(Icons.expand_more, size: 18, color: fg),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [최근 분석과 대조하기] — 높이 64 · lg · primary · 왼쪽 흰 16% 원 36 + 비교 아이콘.
class CompareButton extends StatelessWidget {
  const CompareButton({
    super.key,
    required this.subtitle,
    required this.onPressed,
  });

  static const String label = '최근 분석과 대조하기';

  final String subtitle;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.primary,
      borderRadius: BorderRadius.circular(kRadiusLg),
      child: InkWell(
        key: const ValueKey('journey-compare-button'),
        onTap: onPressed,
        borderRadius: BorderRadius.circular(kRadiusLg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.compare_arrows,
                    size: 20,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppText(
                        label,
                        style: AppTypographyNext.button.copyWith(
                          color: Colors.white,
                        ),
                      ),
                      AppText(
                        subtitle,
                        style: AppTypographyNext.caption.copyWith(
                          color: AppColors.primarySoft,
                        ),
                      ),
                    ],
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

// ── 등기부 변동 기록 ───────────────────────────────────────────────────────

/// 세로 타임라인. 펼칠 수 있는 줄은 **맨 위(최신) 줄**과 **변동 있는 줄**뿐.
class ChangeLogCard extends StatefulWidget {
  const ChangeLogCard({
    super.key,
    required this.entries,
    required this.firstAnalysis,
    required this.onOpenLatest,
  });

  /// 대조 기록 (최신이 앞)
  final List<CompareLogEntry> entries;

  /// 첫 분석 날짜 (맨 아래 "첫 분석" 줄)
  final DateTime firstAnalysis;

  /// "이 리포트 보기 ›" — 최신 줄을 펼쳤을 때만
  final VoidCallback onOpenLatest;

  @override
  State<ChangeLogCard> createState() => _ChangeLogCardState();
}

class _ChangeLogCardState extends State<ChangeLogCard> {
  late Set<int> _open = _initialOpen();

  Set<int> _initialOpen() =>
      widget.entries.isNotEmpty && widget.entries.first.changed ? {0} : <int>{};

  @override
  void didUpdateWidget(covariant ChangeLogCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entries.length != widget.entries.length)
      _open = _initialOpen();
  }

  @override
  Widget build(BuildContext context) {
    final int total = widget.entries.length + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: AppText('등기부 변동 기록', style: AppTypographyNext.title),
            ),
            AppText(
              '$total건',
              style: AppTypographyNext.caption.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        JourneyCard(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Stack(
            children: [
              // 왼쪽 연한 세로선 (점 원 24의 가운데)
              const Positioned(
                left: 11,
                top: 24,
                bottom: 24,
                width: 2,
                child: ColoredBox(color: AppColors.line),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (int i = 0; i < widget.entries.length; i++) _entryRow(i),
                  _row(
                    dot: _dot(changed: false),
                    date: slashDateWeekday(widget.firstAnalysis),
                    title: '첫 분석',
                    tag: null,
                    expandable: false,
                    open: false,
                    onTap: null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _entryRow(int i) {
    final e = widget.entries[i];
    final bool latest = i == 0;
    final bool expandable = latest || e.changed;
    final bool open = _open.contains(i);
    final String title = e.reanalysis
        ? '다시 분석'
        : e.stageTitle == null
        ? '등기부 대조'
        : '${e.stageTitle} 대조';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _row(
          // 없어진 것만 있는 대조(위험이 줄어든 경우)는 초록 ✓ · "없어짐 N건"(초록) — 빨강으로 칠하지 않는다 (2026-10-27)
          dot: _dot(changed: e.changed && !e.onlyRemoved),
          date: slashDateWeekday(e.at),
          title: title,
          tag: !e.compared
              ? null
              : e.onlyRemoved
              ? ('없어짐 ${e.removedCount}건', false)
              : e.changed
              ? ('변동 ${e.changedCount}건', true)
              : ('변동 없음', false),
          expandable: expandable,
          open: open,
          onTap: expandable
              ? () => setState(() => open ? _open.remove(i) : _open.add(i))
              : null,
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topCenter,
          child: !open
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(left: 36, bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (e.changed && e.items.isNotEmpty)
                        ChangeBoxes(items: e.items, padding: 12, gap: 8)
                      else if (e.changed && e.lines.isNotEmpty)
                        // 옛 기록(항목이 없던 때) — 서버 문구 그대로, "— 변동" 꼬리는 붙이지 않는다
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.dangerSoft,
                            borderRadius: BorderRadius.circular(kRadiusLg),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final l in e.lines) ...[
                                AppText(
                                  l.title,
                                  style: AppTypographyNext.caption.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: AppColorsNext.dangerText,
                                  ),
                                ),
                                if (l.detail.isNotEmpty)
                                  AppText(
                                    l.detail,
                                    style: AppTypographyNext.caption.copyWith(
                                      color: kJourneyBodySub,
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      // "이 리포트 보기 ›"는 변동 상자 **밖** 아래에, 최신 줄에서만
                      if (latest)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            key: const ValueKey('journey-log-open-report'),
                            onPressed: widget.onOpenLatest,
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.primary,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 0,
                              ),
                              minimumSize: const Size(0, 44),
                            ),
                            child: AppText(
                              '이 리포트 보기 ›',
                              style: AppTypographyNext.caption.copyWith(
                                fontWeight: FontWeight.w700,
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _row({
    required Widget dot,
    required String date,
    required String title,
    required (String, bool)? tag,
    required bool expandable,
    required bool open,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              dot,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      date,
                      style: AppTypographyNext.caption.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    AppText(
                      title,
                      style: AppTypographyNext.bodyStrong.copyWith(
                        color: AppColorsNext.textStrong,
                      ),
                    ),
                  ],
                ),
              ),
              if (tag != null)
                Container(
                  margin: const EdgeInsets.only(left: 8, top: 2),
                  // 높이 28 = 글자 18 + 위아래 5 (alignment를 주면 알약이 줄 폭만큼 늘어난다)
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: tag.$2 ? AppColors.dangerSoft : AppColors.okSoft,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: AppText(
                    tag.$1,
                    style: AppTypographyNext.caption.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                      color: tag.$2 ? AppColorsNext.dangerText : AppColors.ok,
                    ),
                  ),
                ),
              if (expandable)
                Padding(
                  padding: const EdgeInsets.only(left: 4, top: 2),
                  child: AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 250),
                    child: const Icon(
                      Icons.expand_more,
                      color: AppColorsNext.textMuted,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot({required bool changed}) => Container(
    width: 24,
    height: 24,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: changed ? AppColorsNext.dangerText : AppColors.primary,
      shape: BoxShape.circle,
    ),
    child: changed
        ? AppText(
            '!',
            textScaler: TextScaler.noScaling,
            style: AppTypographyNext.caption.copyWith(
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1,
            ),
          )
        : const Icon(Icons.check, size: 16, color: Colors.white),
  );
}
