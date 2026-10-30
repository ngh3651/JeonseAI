/// **집 카드 하나** — 홈 '내 집' · 마이 '분석 이력' · 여정 '집 바꾸기' 시트가 같은 카드를 쓴다 (2026-10-30 홈 리뉴얼).
///
/// 같은 집이 화면마다 다르게 생기면 다른 집처럼 보인다(규혁). 그래서 겉모양은 한 곳에서만 그린다:
/// - 맨 위가 등급 색으로 은은하게 물든다(위험 연빨강 · 확인 필요 연노랑 · 양호 연초록 → 64에서 흰색)
/// - 첫 줄: [등급 알약] + 집 이름(한 줄, 말줄임)
/// - 회색 상자: "8월 14일자 등기부" + 시계 칩 "N일 전"(같은 날 뗀 등기부는 "0일 전") / 아랫줄 [subline]
/// - 아래: [footer] (홈·마이는 여정 버튼, 시트는 없음)
///
/// 아랫줄만 화면마다 다르다 — 홈·마이 "10월 28일 분석 · 보증금 1억원", 여정 시트 "잔금 D-6 · 10/30 (금)".
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design_system/components/dashed_border.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/content_models.dart';
import '../../models/property_reports.dart';
import '../../models/risk_grade.dart';
import '../../state/journey_schedule_store.dart';
import '../../utils/korean_date.dart';
import '../../utils/money_format.dart';
import '../journey/journey_logic.dart';
import '../journey/journey_parts.dart' show GradePill;

/// 카드 폭 — 가로로 넘기는 곳(홈·여정 시트)에서. 마이는 화면 폭.
const double kHouseCardWidth = 276;

/// 카드 모서리
const double kHouseCardRadius = 20;

/// 맨 위 등급 물듦 — 등급 연한 색을 표면 쪽으로 조금 섞는다(어둡게 모드에서도 같은 계산).
Color houseTintColor(RiskGrade grade) {
  final Color soft = switch (grade) {
    RiskGrade.danger => AppColors.dangerSoft,
    RiskGrade.caution => AppColors.cautionSoft,
    RiskGrade.ok => AppColors.okSoft,
  };
  return Color.lerp(AppColors.surface, soft, 0.6)!;
}

/// "10월 28일 분석 · 보증금 1억원" — 홈·마이 카드 아랫줄
String houseAnalyzedLine(PropertyReports p) =>
    '${formatMonthDay(p.latest.analyzedAt)} 분석 · 보증금 ${formatWon(p.latest.deposit)}';

/// "잔금 D-6 · 10/30 (금)" / "잔금일 없음" — 여정 시트 카드 아랫줄
String houseBalanceLine(DateTime? balance) => balance == null
    ? '잔금일 없음'
    : '잔금 ${dDayLabel(balance)} · ${slashDateWeekday(balance)}';

class HouseCard extends StatelessWidget {
  const HouseCard({
    super.key,
    required this.property,
    required this.subline,
    this.sublineStrong = false,
    this.width,
    this.onTap,
    this.footer,
    this.trailing,
    this.selected = false,
    this.outlined = false,
  });

  final PropertyReports property;

  /// 회색 상자 아랫줄
  final String subline;

  /// 아랫줄을 초록 굵게 (여정 시트에서 잔금일이 있을 때)
  final bool sublineStrong;

  /// null이면 부모 폭
  final double? width;

  /// 카드(여정 버튼 밖)를 눌렀을 때
  final VoidCallback? onTap;

  /// 카드 아래 칸 — 홈·마이의 여정 버튼. null이면 아래 여백만.
  final Widget? footer;

  /// 첫 줄 오른쪽 끝 (마이의 지우기 버튼)
  final Widget? trailing;

  /// 여정 시트에서 고른 집 — 초록 테두리 + 오른쪽 위 모서리 체크
  final bool selected;

  /// 흰 시트 위처럼 바탕과 카드가 같은 색일 때 — 연회색 테두리
  final bool outlined;

  double get _borderWidth => selected ? 2 : (outlined ? 1.5 : 0);

  @override
  Widget build(BuildContext context) {
    final grade = property.latest.grade;
    final radius = BorderRadius.circular(kHouseCardRadius);
    final card = Container(
      width: width,
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: _TopBandGradient(houseTintColor(grade), AppColors.surface),
        border: selected
            ? Border.all(color: AppColors.primary, width: 2)
            : (outlined ? Border.all(color: AppColors.line, width: 1.5) : null),
        boxShadow: AppColors.isDark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x0D101814),
                  offset: Offset(0, 6),
                  blurRadius: 18,
                ),
              ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            // 테두리 두께만큼 안쪽을 줄여 글자 자리가 테두리와 상관없이 같게
            padding: EdgeInsets.fromLTRB(
              16 - _borderWidth,
              16 - _borderWidth,
              16 - _borderWidth,
              footer == null ? 16 - _borderWidth : 0,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    GradePill(grade: grade),
                    const SizedBox(width: 8),
                    Expanded(
                      child: AppText(
                        property.alias,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypographyNext.bodyStrong.copyWith(
                          color: AppColorsNext.textStrong,
                        ),
                      ),
                    ),
                    ?trailing,
                  ],
                ),
                const SizedBox(height: 10),
                _registryBox(),
                ?footer,
              ],
            ),
          ),
        ),
      ),
    );
    if (!selected) return card;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        card,
        Positioned(
          top: -8,
          right: -8,
          child: Container(
            key: const ValueKey('house-selected-check'),
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.surface, width: 3),
            ),
            child: Icon(Icons.check, size: 14, color: AppColors.onPrimary),
          ),
        ),
      ],
    );
  }

  Widget _registryBox() {
    final viewed = property.registryViewedDate;
    final age = property.registryAgeDays;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                // 날짜는 잘리면 안 된다 — 좁으면 글자만 조금 줄인다
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: AppText(
                    viewed == null
                        ? '등기부 날짜를 읽지 못했어요'
                        : '${formatMonthDay(viewed)}자 등기부',
                    maxLines: 1,
                    style: AppTypographyNext.bodyStrong.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColorsNext.textStrong,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              if (age != null) ...[
                const SizedBox(width: 8),
                RegistryAgeChip(days: age),
              ],
            ],
          ),
          const SizedBox(height: 2),
          AppText(
            subline,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: sublineStrong
                ? AppTypographyNext.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  )
                : AppTypographyNext.caption.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 카드 높이가 달라도 물듦이 늘 위 64에서 끝나는 그라데이션.
class _TopBandGradient extends LinearGradient {
  _TopBandGradient(this.tint, this.surface)
    : super(
        colors: [tint, surface],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      );

  final Color tint;
  final Color surface;

  @override
  Shader createShader(Rect rect, {TextDirection? textDirection}) {
    final double stop = rect.height <= 0
        ? 1
        : (64 / rect.height).clamp(0.0, 1.0);
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [tint, surface, surface],
      stops: [0, stop, 1],
    ).createShader(rect, textDirection: textDirection);
  }
}

/// 시계 칩 "71일 전" — 연노랑 바탕 · 진노랑 글자. 날수에 따라 색을 바꾸지 않는다(여정과 같은 규칙).
class RegistryAgeChip extends StatelessWidget {
  const RegistryAgeChip({super.key, required this.days});

  final int days;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      constraints: const BoxConstraints(minHeight: 24),
      decoration: BoxDecoration(
        color: AppColors.cautionSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule_rounded, size: 15, color: AppColors.caution),
          const SizedBox(width: 4),
          AppText(
            '${days < 0 ? 0 : days}일 전',
            maxLines: 1,
            style: AppTypographyNext.caption.copyWith(
              fontWeight: FontWeight.w700,
              color: AppColors.caution,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// 홈·마이 카드 아래 연초록 버튼 — 그 집의 계약 여정으로 간다(카드의 나머지는 리포트로).
///
/// - 다음 단계에 날짜가 있으면 "📅 잔금 D-6 · 10/30 (금)"
/// - 없으면 "🧭 2단계 · 가계약금 보내기 전"
/// 단계 계산은 여정 화면·리포트 5장과 같은 [JourneyProgress] 하나다.
class HouseJourneyButton extends StatelessWidget {
  const HouseJourneyButton({
    super.key,
    required this.property,
    required this.stages,
  });

  final PropertyReports property;

  /// 여정 단계 (아직 못 받았으면 빈 목록 — 그때는 "계약 여정 보기")
  final List<JourneyStage> stages;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String label) = houseJourneyLabel(property, stages);
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 14),
      child: Material(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: ValueKey('house-journey-${property.key}'),
          borderRadius: BorderRadius.circular(14),
          onTap: () => openPropertyJourney(context, property.key),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 10, 0),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: AppColors.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: AppText(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypographyNext.caption.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 20, color: AppColors.primary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 여정 버튼의 아이콘·글자 — 위젯 없이 테스트할 수 있게 뺐다.
(IconData, String) houseJourneyLabel(
  PropertyReports property,
  List<JourneyStage> stages, {
  JourneyScheduleStore? scheduleStore,
}) {
  if (stages.isEmpty) return (Icons.route_outlined, '계약 여정 보기');
  final progress = JourneyProgress.forProperty(
    stages,
    property.key,
    scheduleStore: scheduleStore,
  );
  final int? i = progress.headlineIndex;
  if (i == null) return (Icons.route_outlined, '계약 여정 보기');
  // 아직 안 끝난 단계 중 날짜가 오늘 이후인 가장 가까운 일정 — 있으면 그 날짜를 보여 준다
  // (다음 단계에 날짜가 없어도 잔금일을 넣어 뒀으면 "잔금 D-6"이 더 쓸모 있다)
  for (int s = progress.currentIndex ?? stages.length; s < stages.length; s++) {
    final JourneyDateKey? key = stages[s].dateKey;
    final DateTime? date = progress.dateOf(s);
    if (key != null && date != null && daysUntil(date) >= 0) {
      return (
        Icons.calendar_today_outlined,
        '${circleLabel(key)} ${dDayLabel(date)} · ${slashDateWeekday(date)}',
      );
    }
  }
  return (Icons.route_outlined, '${i + 1}단계 · ${stages[i].title}');
}

/// 그 집의 계약 여정을 연다 — 지금 단계가 골라진 채로.
void openPropertyJourney(BuildContext context, String propertyKey) {
  JourneyScheduleStore.instance.select(propertyKey);
  GoRouter.of(context).go('/journey');
}

/// 가로 목록 끝의 [새로 분석] — 점선 · 연초록 원 + ＋ · 초록 굵은 글자 (홈 · 여정 시트 같은 모양).
class NewAnalysisCard extends StatelessWidget {
  const NewAnalysisCard({super.key, required this.onTap, this.width = 112});

  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    return DashedBorder(
      color: AppColors.line,
      radius: kHouseCardRadius,
      strokeWidth: 2,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const ValueKey('house-card-new'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(kHouseCardRadius),
          child: SizedBox(
            width: width,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primarySoft,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.add, color: AppColors.primary),
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
