/// 리포트 맨 위 **결론 카드** (2026-10-31 리디자인 — 캔버스 '리포트 결론' B3 확정안).
///
/// 반원 게이지를 뺐다 — 채운 길이가 무엇을 뜻하는지 알 수 없었다('위험'인데 1/3만 차 있으면 덜 위험해 보인다).
/// 카드 하나에 위에서 아래로:
/// 1. 📍 주소 한 줄 (시·도 이름은 빼서 동·호수까지 보이게, 그래도 길면 …)
/// 2. 큰 등급(40) + 권하는 말 알약 · 오른쪽에 등급별 세이프
/// 3. 3칸 눈금 — 양호 · 확인 필요 · 위험 중 이 집 칸만 굵게
/// 4. 큰 문장 — **한 줄**(넘치면 글자만 줄임, 16 아래로는 안 줄이고 두 줄)
/// 5. 회색 상자 — "8월 14일자 등기부" + 시계 칩 "N일 전"(홈 집 카드와 같은 모양) · 보증금·시세
///
/// 위가 등급 색으로 은은하게 물드는 것도 홈 '내 집' 카드와 같다.
library;

import 'package:flutter/material.dart';

import '../../design_system/components/mascot_safe.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/analysis_report.dart';
import '../../models/risk_grade.dart';
import '../../utils/korean_date.dart';
import '../../utils/money_format.dart';
import '../common/house_card.dart'
    show RegistryAgeChip, TopTintGradient, houseTintColor;

/// 주소 앞의 시·도 이름 — 결론 카드에서는 빼고 동·호수까지 한 줄에 보이게 한다.
final RegExp _sido = RegExp(
  r'^(서울특별시|서울시|서울|부산광역시|대구광역시|인천광역시|광주광역시|대전광역시|울산광역시|'
  r'세종특별자치시|경기도|강원특별자치도|강원도|충청북도|충청남도|전북특별자치도|전라북도|'
  r'전라남도|경상북도|경상남도|제주특별자치도)\s+',
);

/// "서울특별시 영등포구 신길동 274-1 제3층 제301호" → "영등포구 신길동 274-1 제3층 제301호"
String shortAddress(String address) {
  final a = address.trim();
  final s = a.replaceFirst(_sido, '');
  return s.isEmpty ? a : s;
}

/// 큰 문장의 기본 크기와, 한 줄에 맞추려고 줄일 수 있는 가장 작은 크기
const double kHeadlineSize = 19;
const double kHeadlineMinSize = 16;

class ReportConclusionCard extends StatelessWidget {
  const ReportConclusionCard({super.key, required this.report});

  final AnalysisReport report;

  @override
  Widget build(BuildContext context) {
    final grade = report.grade;
    return Container(
      key: const ValueKey('report-conclusion'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: TopTintGradient(
          houseTintColor(grade),
          AppColors.surface,
          band: 150,
        ),
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
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _addressLine(),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: AppText(
                        grade.label,
                        key: const ValueKey('report-grade'),
                        maxLines: 1,
                        style: TextStyle(
                          fontFamily: AppTypographyNext.headline.fontFamily,
                          fontSize: 40,
                          height: 48 / 40,
                          letterSpacing: -1.2,
                          fontWeight: FontWeight.w800,
                          color: gradeTextColor(grade),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    _decisionPill(grade),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 세로로 긴 세이프 — 정사각(96×96) 대신 그림 비율대로 좁게 잡아 왼쪽 글자 자리를 넓힌다
              SizedBox(
                width: 66,
                height: 96,
                child: Image.asset(
                  'assets/mascot/mascot_${_mascotFor(grade).name}.png',
                  key: const ValueKey('report-mascot'),
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GradeScale(grade: grade),
          const SizedBox(height: 16),
          ReportHeadline(text: report.headline),
          const SizedBox(height: 14),
          _registryBox(),
        ],
      ),
    );
  }

  Widget _addressLine() {
    return Row(
      children: [
        Icon(Icons.place_outlined, size: 16, color: AppColorsNext.textMuted),
        const SizedBox(width: 4),
        Expanded(
          child: AppText(
            shortAddress(report.address),
            key: const ValueKey('report-address'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypographyNext.caption,
          ),
        ),
      ],
    );
  }

  Widget _decisionPill(RiskGrade grade) {
    return Container(
      key: const ValueKey('report-decision'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      constraints: const BoxConstraints(minHeight: 28),
      decoration: BoxDecoration(
        color: AppColors.gradeSoftColor(grade),
        borderRadius: BorderRadius.circular(999),
      ),
      child: AppText(
        grade.decisionLabel,
        style: AppTypographyNext.caption.copyWith(
          fontWeight: FontWeight.w700,
          color: gradeTextColor(grade),
        ),
      ),
    );
  }

  Widget _registryBox() {
    final viewed = parseRegistryViewedAt(report.registryViewedAt);
    final int? age = viewed == null ? null : daysSince(viewed);
    // 2026-08-03: 시세는 자동 조회에서도 올 수 있다 — 출처를 하드코딩하지 않는다
    final String priceText = report.marketPrice != null
        ? '보증금 ${formatWon(report.deposit)} · 시세 ${formatWon(report.marketPrice!)}'
        : '보증금 ${formatWon(report.deposit)} · 시세를 못 구했어요';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: AppText(
                    // 리포트 전체가 이 등기부 기준이다 — 분석한 날보다 등기부를 뗀 날이 중요하다(2026-10-30)
                    viewed == null
                        ? '${formatMonthDay(report.analyzedAt)} 분석'
                        : '${formatMonthDay(viewed)}자 등기부',
                    key: const ValueKey('report-registry-line'),
                    maxLines: 1,
                    style: AppTypographyNext.bodyStrong.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColorsNext.textStrong,
                    ),
                  ),
                ),
              ),
              if (age != null) ...[
                const SizedBox(width: 8),
                RegistryAgeChip(
                  key: const ValueKey('report-registry-date'),
                  days: age,
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          AppText(
            priceText,
            style: AppTypographyNext.caption.copyWith(
              fontWeight: FontWeight.w600,
              color: AppColorsNext.textBody,
            ),
          ),
        ],
      ),
    );
  }

  MascotState _mascotFor(RiskGrade grade) => switch (grade) {
    RiskGrade.danger => MascotState.danger,
    RiskGrade.caution => MascotState.caution,
    RiskGrade.ok => MascotState.safe,
  };
}

/// 등급 **글자** 색 — 연한 바탕 위에서도 4.5:1 (위험은 진한 빨강 글자 토큰).
Color gradeTextColor(RiskGrade grade) => switch (grade) {
  RiskGrade.danger => AppColorsNext.dangerText,
  RiskGrade.caution => AppColors.caution,
  RiskGrade.ok => AppColors.ok,
};

/// 3칸 눈금 — 양호 · 확인 필요 · 위험. 이 집 칸만 진하고 두껍게(12), 나머지는 연하게(8).
class GradeScale extends StatelessWidget {
  const GradeScale({super.key, required this.grade});

  final RiskGrade grade;

  static const List<RiskGrade> order = [
    RiskGrade.ok,
    RiskGrade.caution,
    RiskGrade.danger,
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('report-grade-scale'),
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < order.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(child: _cell(order[i])),
        ],
      ],
    );
  }

  Widget _cell(RiskGrade g) {
    final bool on = g == grade;
    return Column(
      children: [
        Container(
          key: on ? const ValueKey('report-grade-scale-on') : null,
          height: on ? 12 : 8,
          decoration: BoxDecoration(
            color: on
                ? AppColors.gradeArcColor(g)
                : AppColors.gradeSoftColor(g),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        const SizedBox(height: 6),
        AppText(
          g.label,
          maxLines: 1,
          style: AppTypographyNext.caption.copyWith(
            fontWeight: on ? FontWeight.w800 : FontWeight.w500,
            color: on ? gradeTextColor(g) : AppColorsNext.textMuted,
          ),
        ),
      ],
    );
  }
}

/// 큰 문장 — 한 줄에 맞춘다(19에서 시작해 16까지 줄임). 16으로도 안 들어가면 17로 두 줄.
class ReportHeadline extends StatelessWidget {
  const ReportHeadline({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final scaler = MediaQuery.textScalerOf(context);
        TextStyle style(double size) => AppTypographyNext.title.copyWith(
          fontSize: size,
          height: 30 / size,
          letterSpacing: -0.3,
          color: AppColorsNext.textStrong,
        );
        final painter = TextPainter(
          // 굵게 표시(**)는 화면에 안 그려진다 — 별표를 빼고 잰다(2026-11-01)
          text: TextSpan(text: stripBoldMarkup(text), style: style(kHeadlineSize)),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        final double w = painter.width;
        painter.dispose();
        final double fit = w <= box.maxWidth
            ? kHeadlineSize
            : kHeadlineSize * box.maxWidth / w;
        if (fit >= kHeadlineMinSize) {
          return AppText(
            text,
            key: const ValueKey('report-headline'),
            maxLines: 1,
            softWrap: false,
            style: style(fit.floorToDouble() == fit ? fit : fit - 0.05),
          );
        }
        return AppText(
          text,
          key: const ValueKey('report-headline'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: style(17),
        );
      },
    );
  }
}
