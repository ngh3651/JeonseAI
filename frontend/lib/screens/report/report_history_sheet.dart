/// 리포트 화면의 **이전 리포트** (그림 ⑮·⑯, 2026-10-26).
///
/// 같은 집(주소가 같은) 리포트는 화면에 최신 1개만 보인다. 지난 리포트는 앱바의 시계 버튼 → 이 시트에서 고른다.
/// - 한 줄: [등급 알약] + "2026.09.30 분석" + "등기부 9월 30일자 · 변동 없음" (맨 처음 리포트는 "첫 분석")
/// - 지금 보는 리포트: 회색 바탕 + "보는 중"
/// - 맨 아래: "이 휴대폰에 최근 5건까지만 남아요"
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/analysis_report.dart';
import '../../models/property_reports.dart';
import '../../state/journey_progress_store.dart';
import '../../utils/korean_date.dart';
import '../journey/journey_parts.dart';

/// "2026.09.30"
String dottedDate(DateTime d) =>
    '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';

/// 지난 리포트 줄의 아랫줄 — "등기부 9월 30일자 · 변동 없음" / "… · 첫 분석"
String versionSubline(
  AnalysisReport report, {
  required bool isFirst,
  JourneyProgressStore? progress,
}) {
  final viewed = parseRegistryViewedAt(report.registryViewedAt);
  final String doc = viewed == null
      ? '등기부 날짜 못 읽음'
      : '등기부 ${formatMonthDay(viewed)}자';
  if (isFirst) return '$doc · 첫 분석';
  final log = (progress ?? JourneyProgressStore.instance).logForReport(
    report.id,
  );
  if (log == null) return doc;
  return log.changed ? '$doc · 변동 ${log.changedCount}건' : '$doc · 변동 없음';
}

Future<void> showReportHistorySheet(
  BuildContext context, {
  required AnalysisReport current,
  required List<AnalysisReport> versions,
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
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenPadding,
          12,
          AppSpacing.screenPadding,
          20,
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
            AppText('이전 리포트', style: AppTypographyNext.title),
            AppText('새 등기부로 분석할 때마다 위에 쌓여요', style: AppTypographyNext.caption),
            const SizedBox(height: 12),
            for (int i = 0; i < versions.length; i++)
              _VersionRow(
                report: versions[i],
                isFirst: i == versions.length - 1,
                viewing: versions[i].id == current.id,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  // 쌓지 않고 바꿔 끼운다 — 뒤로 가기가 리포트를 여러 번 거치지 않게
                  GoRouter.of(
                    context,
                  ).pushReplacement('/report/${versions[i].id}');
                },
              ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(kRadiusMd),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.lock_outline,
                    size: 20,
                    color: AppColorsNext.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: AppText.rich(
                      TextSpan(
                        style: AppTypographyNext.caption,
                        children: [
                          const TextSpan(text: '이 휴대폰에 '),
                          TextSpan(
                            text: '최근 $kKeepReportVersions건',
                            style: AppTypographyNext.caption.copyWith(
                              fontWeight: FontWeight.w700,
                              color: AppColorsNext.textStrong,
                            ),
                          ),
                          const TextSpan(text: '까지만 남아요'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _VersionRow extends StatelessWidget {
  const _VersionRow({
    required this.report,
    required this.isFirst,
    required this.viewing,
    required this.onTap,
  });

  final AnalysisReport report;
  final bool isFirst;
  final bool viewing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: viewing ? AppColors.background : Colors.transparent,
        borderRadius: BorderRadius.circular(kRadiusMd),
        child: InkWell(
          key: ValueKey('report-version-${report.id}'),
          onTap: viewing ? null : onTap,
          borderRadius: BorderRadius.circular(kRadiusMd),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  GradePill(grade: report.grade),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppText(
                          '${dottedDate(report.analyzedAt)} 분석',
                          style: AppTypographyNext.bodyStrong.copyWith(
                            color: AppColorsNext.textStrong,
                          ),
                        ),
                        AppText(
                          versionSubline(report, isFirst: isFirst),
                          style: AppTypographyNext.caption,
                        ),
                      ],
                    ),
                  ),
                  if (viewing)
                    Container(
                      // 높이 28 = 글자 18 + 위아래 5 (alignment를 주면 알약이 줄 폭만큼 늘어난다)
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primarySoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: AppText(
                        '보는 중',
                        style: AppTypographyNext.caption.copyWith(
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    )
                  else
                    const Icon(
                      Icons.chevron_right,
                      color: AppColorsNext.textMuted,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 지난 리포트를 열었을 때 앱바 아래 진한 띠 — 시계 + "**9월 30일자** 지난 리포트" + 흰 [최신 보기]
class PastReportBand extends StatelessWidget {
  const PastReportBand({
    super.key,
    required this.report,
    required this.onLatest,
  });

  final AnalysisReport report;
  final VoidCallback onLatest;

  @override
  Widget build(BuildContext context) {
    final viewed =
        parseRegistryViewedAt(report.registryViewedAt) ?? report.analyzedAt;
    final style = AppTypographyNext.caption.copyWith(color: Colors.white);
    return Container(
      key: const ValueKey('past-report-band'),
      margin: const EdgeInsets.only(bottom: AppSpacing.lg),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: AppColorsNext.textStrong,
        borderRadius: BorderRadius.circular(kRadiusLg),
      ),
      child: Row(
        children: [
          const Icon(Icons.history, size: 20, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: AppText.rich(
              TextSpan(
                style: style,
                children: [
                  TextSpan(
                    text: '${formatMonthDay(viewed)}자',
                    style: style.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const TextSpan(text: ' 지난 리포트'),
                ],
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('past-report-latest'),
            onPressed: onLatest,
            style: TextButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: AppColorsNext.textStrong,
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kRadiusMd),
              ),
            ),
            child: AppText(
              '최신 보기',
              style: AppTypographyNext.caption.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColorsNext.textStrong,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
