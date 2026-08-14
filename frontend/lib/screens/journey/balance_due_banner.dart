/// 잔금 D-1 배너 — 여정 타임라인 최상단과 홈 최상단에 **같은 모양**으로 뜬다 (S-11).
///
/// 이 배너가 있는 이유: 잔금 직전에 근저당을 새로 설정하는 것이 실제 전세사기 수법이다.
/// 그래서 "내일 큰돈이 나간다"는 사실을 아는 순간(사용자가 잔금일을 넣은 순간) 앱은
/// **가장 크게** 그 하루를 말해야 한다.
///
/// ⚠ 경고 문구 뒤에는 반드시 행동 버튼 (IA.md §0). 이 배너는 항상 [다시 떼서 대조하기]를
///   달고 다닌다 — 문구만 있는 형태로 쓰지 않는다.
library;

import 'package:flutter/material.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';

class BalanceDueBanner extends StatelessWidget {
  const BalanceDueBanner({
    super.key,
    required this.title,
    required this.onCompare,
    this.onGuide,
    this.onEditSchedule,
    this.note,
  });

  /// "잔금일이 내일이에요 · 8월 6일" (홈에서는 앞에 별칭이 붙는다)
  final String title;
  final VoidCallback onCompare;

  /// [떼는 법] — 발급 가이드. null이면 버튼을 그리지 않는다(홈 버전).
  final VoidCallback? onGuide;

  /// [일정 수정] — 일정 시트 재진입. null이면 그리지 않는다(홈 버전).
  final VoidCallback? onEditSchedule;

  /// 배너 아래 한 줄. **지어낸 수치를 적지 않는다** — 우리가 근거를 댈 수 있는 말만.
  final String? note;

  @override
  Widget build(BuildContext context) {
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      title,
                      style: AppTypography.label.copyWith(
                        color: AppColors.caution,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    AppText(
                      '돈을 보내기 직전에 등기부를 다시 떼어 새로 생긴 빚이 없는지 확인하세요',
                      style: AppTypography.body.copyWith(
                        color: AppColors.caution,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            height: AppSize.buttonHeight,
            child: FilledButton.icon(
              onPressed: onCompare,
              icon: const Icon(Icons.compare_arrows, size: AppSize.iconSm),
              label: const AppText('지금 다시 떼서 대조하기'),
            ),
          ),
          if (onGuide != null) ...[
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              height: AppSize.compactButtonHeight,
              child: OutlinedButton(
                onPressed: onGuide,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, AppSize.compactButtonHeight),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.buttonMini),
                  ),
                  textStyle: AppTypography.buttonSmall,
                ),
                child: const AppText('떼는 법'),
              ),
            ),
          ],
          if (note != null || onEditSchedule != null) ...[
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: AppText(
                    note ?? '',
                    style: AppTypography.label.copyWith(
                      color: AppColors.textMuted,
                      fontWeight: FontWeight.w400,
                      height: 1.45,
                    ),
                  ),
                ),
                if (onEditSchedule != null)
                  GestureDetector(
                    onTap: onEditSchedule,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.only(left: AppSpacing.sm),
                      child: AppText(
                        '일정 수정',
                        style: AppTypography.label.copyWith(
                          color: AppColors.caution,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                          decorationColor: AppColors.caution,
                        ),
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
