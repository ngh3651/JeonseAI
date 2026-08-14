/// 등기부 대조 결과 4갈래 (S-11 화면 6a~6d).
///
/// 이 화면이 지키는 두 가지:
/// - **변한 것과 안 변한 것을 모두 보여준다.** 변한 것만 나열하면 "나머지는 앱이 안
///   봤나?"로 읽힌다. 못 본 것은 못 봤다고 따로 말한다.
/// - **다른 집이면 숫자를 아예 그리지 않는다.** 다른 집끼리 비교한 값은 틀린 결론으로
///   이어지고, 그 결론이 잔금을 보내게 만든다.
///
/// 문구는 서버(규칙 기반)가 준 것을 그대로 쓴다. 앱이 덧붙이는 문장은 딱 하나 —
/// 기기에 저장된 계약 일정과 접수일을 견준 "계약서 쓴 다음 날이에요"뿐이다.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_pill.dart';
import '../../design_system/components/mascot_safe.dart';
import '../../design_system/components/risk_badge.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/compare_result.dart';
import '../../models/content_models.dart';
import '../../state/journey_schedule_store.dart';
import '../../utils/korean_date.dart';

class CompareResultView extends StatelessWidget {
  const CompareResultView({
    super.key,
    required this.result,
    required this.baselineReportId,
    required this.onRetry,
    required this.onRecapture,
    required this.onQuestions,
    required this.onAnalyze,
    required this.onGuide,
    required this.onBackToJourney,
  });

  final CompareResult result;
  final String baselineReportId;

  /// 같은 사진으로 다시 시도
  final VoidCallback onRetry;

  /// 사진을 다시 골라 대조 (빠진 쪽 올리기 · 사진 다시 고르기)
  final VoidCallback onRecapture;

  /// 중개사 질문 생성기로
  final VoidCallback onQuestions;

  /// 새 분석 시작 (기준 만들기 · 다른 집 분석)
  final VoidCallback onAnalyze;

  /// 등기부 발급 가이드
  final VoidCallback onGuide;

  /// 여정 화면으로 되돌아가기
  final VoidCallback onBackToJourney;

  @override
  Widget build(BuildContext context) {
    return switch (result.outcome) {
      CompareOutcome.noBaseline => _noBaseline(context),
      CompareOutcome.differentProperty => _differentProperty(context),
      _ => _compared(context),
    };
  }

  EdgeInsets get _pagePadding => const EdgeInsets.fromLTRB(
    AppSpacing.screenPadding,
    0,
    AppSpacing.screenPadding,
    AppSpacing.xxl + AppSpacing.xs,
  );

  // ══════════════════════════════════════════════════════════════════════════
  // 6a·6b — 대조함 / 일부 대조 불가
  // ══════════════════════════════════════════════════════════════════════════

  Widget _compared(BuildContext context) {
    final bool partial = result.outcome == CompareOutcome.partial;
    final bool hasDanger = result.rows.any((r) => r.tone == CompareTone.danger);
    final Color tone = partial
        ? AppColors.caution
        : hasDanger
        ? AppColors.danger
        : AppColors.primary;
    final Color soft = partial
        ? AppColors.cautionSoft
        : hasDanger
        ? AppColors.dangerSoft
        : AppColors.primarySoft;

    return ListView(
      padding: _pagePadding,
      children: [
        _headerCard(tone: tone, soft: soft),
        const SizedBox(height: AppSpacing.lg),
        for (final row in result.rows) ...[
          _rowCard(context, row),
          const SizedBox(height: AppSpacing.lg),
        ],
        if (partial) ...[
          _partialCallout(context),
          const SizedBox(height: AppSpacing.lg),
        ],
        _ruleBasedNotice(),
        const SizedBox(height: AppSpacing.lg),
        if (!partial) ...[
          AppPrimaryButton(
            label: '잔금 보내기 전에 확인할 것 보기',
            onPressed: onBackToJourney,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppSecondaryButton(
            label: '중개사에게 물어볼 질문 만들기',
            onPressed: onQuestions,
          ),
        ],
      ],
    );
  }

  Widget _headerCard({required Color tone, required Color soft}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: soft,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(
            result.headline,
            style: AppTypography.headline.copyWith(color: tone),
          ),
          if (_documentLine != null) ...[
            const SizedBox(height: 6),
            AppText(
              _documentLine!,
              style: AppTypography.caption.copyWith(color: tone),
            ),
          ],
          if (result.subline != null) ...[
            const SizedBox(height: 2),
            AppText(
              result.subline!,
              style: AppTypography.caption.copyWith(color: tone),
            ),
          ],
        ],
      ),
    );
  }

  /// "7월 9일자 서류 ↔ 8월 5일자 서류" — 두 서류를 뗀 날. 못 읽은 쪽이 있으면 안 그린다.
  String? get _documentLine {
    final base = parseRegistryViewedAt(result.baseline.viewedAt);
    final now = parseRegistryViewedAt(result.current.viewedAt);
    if (base == null && now == null) return null;
    final left = base == null ? '기준 서류' : '${formatMonthDay(base)}자 서류';
    final right = now == null ? '이번 서류' : '${formatMonthDay(now)}자 서류';
    return '$left ↔ $right';
  }

  Widget _rowCard(BuildContext context, CompareRow row) {
    final Color markerColor = switch (row.tone) {
      CompareTone.danger => AppColors.danger,
      CompareTone.caution => AppColors.caution,
      CompareTone.neutral => AppColors.textMuted,
    };
    final Color markerBg = switch (row.tone) {
      CompareTone.danger => AppColors.dangerSoft,
      CompareTone.caution => AppColors.cautionSoft,
      CompareTone.neutral => AppColors.background,
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: 18,
        vertical: AppSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: markerBg,
                  shape: BoxShape.circle,
                ),
                child: AppText(
                  row.marker,
                  textScaler: TextScaler.noScaling,
                  style: AppTypography.body.copyWith(
                    color: markerColor,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(row.title, style: AppTypography.title),
                    if (row.subtitle != null) ...[
                      const SizedBox(height: 6),
                      AppText(
                        row.subtitle!,
                        style: row.kind == CompareRowKind.unknown
                            ? AppTypography.body
                            : AppTypography.caption,
                      ),
                    ],
                    if (row.gradeBefore != null && row.gradeAfter != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: [
                          RiskBadge(grade: row.gradeBefore!),
                          const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm,
                            ),
                            child: Icon(
                              Icons.arrow_forward,
                              size: AppSize.iconSm,
                              color: AppColors.textMuted,
                            ),
                          ),
                          RiskBadge(grade: row.gradeAfter!),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (row.detail != null) ...[
            const SizedBox(height: AppSpacing.md),
            _detailBox(context, row),
          ],
          if (row.action != null) ...[
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: AppCompactButton(
                label: row.actionLabel ?? '빠진 쪽 찍어서 올리기',
                icon: row.action == CompareAction.recapture
                    ? Icons.photo_camera
                    : Icons.search,
                tonal: true,
                onPressed: row.action == CompareAction.recapture
                    ? onRecapture
                    : onAnalyze,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailBox(BuildContext context, CompareRow row) {
    final lines = row.detail!.split('\n');
    final String? scheduleNote = _scheduleNote(context, row.receiptDate);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < lines.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.xs),
            AppText(
              lines[i],
              style: i == 0
                  ? AppTypography.bodyStrong
                  : AppTypography.caption,
            ),
          ],
          if (scheduleNote != null) ...[
            const SizedBox(height: AppSpacing.xs),
            AppText(
              scheduleNote,
              style: AppTypography.caption.copyWith(color: AppColors.caution),
            ),
          ],
        ],
      ),
    );
  }

  /// 접수일 ↔ **기기에 저장된 계약 일정**. 서버는 이 날짜를 모르므로 여기서만 붙는다.
  String? _scheduleNote(BuildContext context, DateTime? receipt) {
    if (receipt == null) return null;
    final address = result.baseline.address;
    if (address == null) return null;

    final schedule = context
        .read<JourneyScheduleStore>()
        .scheduleFor(journeyPropertyKey(address));
    for (final key in const [
      JourneyDateKey.contract,
      JourneyDateKey.downPayment,
    ]) {
      final date = schedule[key];
      if (date == null || !receipt.isAfter(date)) continue;
      final int days = receipt.difference(date).inDays;
      final String when = days == 1 ? '다음 날' : '$days일 뒤';
      return key == JourneyDateKey.contract
          ? '계약서 쓴 $when에 생긴 기록이에요'
          : '가계약금 보낸 $when에 생긴 기록이에요';
    }
    return null;
  }

  /// 못 본 것을 '이상 없음'으로 읽지 않게 못 박는 자리 (6b).
  Widget _partialCallout(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.cautionSoft,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.warning_amber,
                size: AppSize.iconSm,
                color: AppColors.caution,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppText(
                  "대조하지 못한 항목은 '달라진 게 없다'는 뜻이 아니에요",
                  style: AppTypography.bodyStrong.copyWith(
                    color: AppColors.caution,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          AppPrimaryButton(
            label: '빠진 쪽 찍어서 올리기',
            icon: Icons.photo_camera,
            onPressed: onRecapture,
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            width: double.infinity,
            child: AppCompactButton(
              label: '중개사에게 물어볼 질문 만들기',
              onPressed: onQuestions,
            ),
          ),
        ],
      ),
    );
  }

  /// 회색 고지 카드 — 이 결과가 **어떻게** 나왔는지. 마스코트는 경고보다 작게.
  Widget _ruleBasedNotice() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const MascotSafe(size: 36, state: MascotState.analyzing),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final notice in result.notices) ...[
                  AppText(notice, style: AppTypography.caption),
                  const SizedBox(height: AppSpacing.xs),
                ],
                AppText(
                  '대조 · 규칙 기반 — 두 등기부의 항목을 그대로 맞춰본 결과예요. '
                  'AI가 판단하지 않았어요.',
                  style: AppTypography.caption,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 6c — 기준 없음 (**비난이 아니라 초대 톤. 경고색 금지**)
  // ══════════════════════════════════════════════════════════════════════════

  Widget _noBaseline(BuildContext context) {
    return ListView(
      padding: _pagePadding,
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Row(
            children: [
              const MascotSafe(size: 44, state: MascotState.info),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: AppText(
                  result.headline,
                  style: AppTypography.headline.copyWith(
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: AppSpacing.lg,
          ),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (result.subline != null)
                AppText(result.subline!, style: AppTypography.body),
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Column(
                  children: [
                    _step(1, '오늘 뗀 등기부가 기준이 돼요'),
                    const SizedBox(height: AppSpacing.sm),
                    _step(2, '잔금 직전에 한 번 더 떼면 달라진 점을 알려드려요'),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Opacity(
          opacity: 0.7,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: AppSpacing.lg,
            ),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppText(
                        result.baseline.alias ?? '분석한 집',
                        style: AppTypography.title,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      AppText(
                        _baselineHistoryLine,
                        style: AppTypography.caption,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                const AppPill(
                  label: '기준 없음',
                  color: AppColors.textMuted,
                  background: AppColors.background,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        AppPrimaryButton(
          label: '지금 떼어 기준 만들기',
          icon: Icons.photo_camera_outlined,
          onPressed: onAnalyze,
        ),
        const SizedBox(height: AppSpacing.xs),
        SizedBox(
          height: AppSize.compactButtonHeight,
          child: TextButton(
            onPressed: onGuide,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textMuted,
              textStyle: AppTypography.buttonSmall,
            ),
            child: const AppText('떼는 법 보기'),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        _grayNote(
          icon: Icons.info_outline,
          text: '기준을 만들어도 전에 받은 리포트는 그대로 볼 수 있어요',
        ),
      ],
    );
  }

  String get _baselineHistoryLine {
    final viewed = parseRegistryViewedAt(result.baseline.viewedAt);
    return viewed == null
        ? '이전 분석 · 기준으로 쓸 수 없음'
        : '${formatMonthDay(viewed)}자 등기부 · 기준으로 쓸 수 없음';
  }

  Widget _step(int number, String text) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: AppColors.primarySoft,
            shape: BoxShape.circle,
          ),
          child: AppText(
            '$number',
            textScaler: TextScaler.noScaling,
            style: AppTypography.label.copyWith(
              color: AppColors.primary,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: AppText(
            text,
            style: AppTypography.caption.copyWith(color: AppColors.textBody),
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 6d — 다른 집 차단 (**수치를 아예 렌더하지 않는다**)
  // ══════════════════════════════════════════════════════════════════════════

  Widget _differentProperty(BuildContext context) {
    return ListView(
      padding: _pagePadding,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: AppColors.cautionSoft,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(
                result.headline,
                style: AppTypography.headline.copyWith(
                  color: AppColors.caution,
                ),
              ),
              if (result.subline != null) ...[
                const SizedBox(height: 6),
                AppText(
                  result.subline!,
                  style: AppTypography.body.copyWith(color: AppColors.caution),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: AppSpacing.lg,
          ),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sideLabel('기준', AppColors.primary),
              const SizedBox(height: 6),
              AppText(
                result.baseline.alias ?? '기준 매물',
                style: AppTypography.title,
              ),
              const SizedBox(height: 6),
              AppText(_baselineAddressLine, style: AppTypography.caption),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: Divider(height: 1),
              ),
              _sideLabel('이번', AppColors.caution),
              const SizedBox(height: 6),
              const AppText('확인되지 않은 다른 집', style: AppTypography.title),
              const SizedBox(height: 6),
              AppText(_currentUnknownLine, style: AppTypography.caption),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        for (final notice in result.notices) ...[
          _grayNote(icon: Icons.block, text: notice),
          const SizedBox(height: AppSpacing.sm),
        ],
        const SizedBox(height: AppSpacing.sm),
        AppPrimaryButton(
          label: '사진 다시 고르기',
          icon: Icons.photo_library_outlined,
          onPressed: onRecapture,
        ),
        const SizedBox(height: AppSpacing.sm),
        AppSecondaryButton(label: '이 집을 새로 분석하기', onPressed: onAnalyze),
      ],
    );
  }

  String get _baselineAddressLine {
    final viewed = parseRegistryViewedAt(result.baseline.viewedAt);
    final address = result.baseline.address ?? '주소 확인 필요';
    return viewed == null ? address : '$address · ${formatMonthDay(viewed)}자 서류';
  }

  String get _currentUnknownLine {
    final viewed = parseRegistryViewedAt(result.current.viewedAt);
    final basis = result.identityBasis ?? '고유번호·소재지';
    final head = '$basis가 기준과 달라요';
    return viewed == null ? head : '$head · ${formatMonthDay(viewed)}자 서류';
  }

  Widget _sideLabel(String label, Color color) => AppText(
    label,
    style: AppTypography.label.copyWith(color: color, fontWeight: FontWeight.w700),
  );

  Widget _grayNote({required IconData icon, required String text}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: AppSize.iconSm, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: AppText(text, style: AppTypography.caption)),
        ],
      ),
    );
  }
}
