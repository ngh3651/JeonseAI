/// 장별 재촬영 안내 — "몇 쪽이 왜 문제인지 + 그 장만 다시 찍기" (2026-10-22, P1-1).
///
/// 서버가 사진 품질을 본다(api-contract §9.9):
/// - **심하면** 분석 전에 거절한다(400 + `captureCheck`) → 촬영 화면이 이 패널을 띄우고, 문제인 장만 다시 찍어
///   바꾼 뒤 다시 보낸다(나머지 장은 그대로).
/// - **가벼우면** 분석하고 리포트에 `captureCheck`를 싣는다 → 리포트가 같은 패널로 "확인 필요"를 알린다.
///
/// ⚠ 판정이 아니라 **사진 품질** 안내다. 색은 주의(앰버) 톤이고 위험(빨강)을 쓰지 않는다.
library;

import 'package:flutter/material.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';

/// 분석 화면이 **사진 품질 때문에** 되돌려 보낼 때 넘기는 것.
///
/// 로딩 화면은 서버가 400 + `captureCheck`로 거절하면 실패 화면 대신 `context.pop(CaptureRejection(...))`으로
/// 돌아간다. 받은 화면(촬영 화면·리포트)이 "몇 쪽이 왜 — 그 장만 다시 찍기"를 띄운다.
class CaptureRejection {
  const CaptureRejection({required this.check, required this.message});

  final CaptureCheck check;

  /// 서버 문구 그대로 — "2쪽이 흐려요 — 다시 찍어 주세요 (…)"
  final String message;
}

/// 장별 문제 목록 + 장마다 [다시 찍기] 버튼.
class CaptureIssuePanel extends StatelessWidget {
  const CaptureIssuePanel({
    super.key,
    required this.check,
    required this.title,
    this.message,
    this.onRetake,
    this.retakeLabel = '이 장만 다시 찍기',
  });

  final CaptureCheck check;

  /// 패널 제목 — 거절이면 "사진을 다시 찍어야 분석할 수 있어요", 리포트면 "사진 확인이 필요한 장이 있어요".
  final String title;

  /// 제목 아래 한 줄 (서버 `detail` 등). 없으면 생략.
  final String? message;

  /// 장 번호(0부터)를 받아 그 장만 다시 찍는다. null이면 버튼 없이 안내만.
  final void Function(CapturePageIssue page)? onRetake;

  final String retakeLabel;

  @override
  Widget build(BuildContext context) {
    final pages = check.pages;
    return Container(
      key: const ValueKey('capture-issue-panel'),
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
              const Icon(Icons.photo_camera_outlined, size: AppSize.iconSm, color: AppColors.caution),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppText(
                  title,
                  style: AppTypography.bodyStrong.copyWith(color: AppColors.caution),
                ),
              ),
            ],
          ),
          if ((message ?? '').isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            AppText(message!, style: AppTypography.caption),
          ],
          for (final page in pages) ...[
            const SizedBox(height: AppSpacing.md),
            _PageRow(
              page: page,
              onRetake: onRetake == null ? null : () => onRetake!(page),
              retakeLabel: retakeLabel,
            ),
          ],
        ],
      ),
    );
  }
}

class _PageRow extends StatelessWidget {
  const _PageRow({required this.page, required this.onRetake, required this.retakeLabel});

  final CapturePageIssue page;
  final VoidCallback? onRetake;
  final String retakeLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: ValueKey('capture-issue-${page.index}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          '${page.index + 1}쪽 · ${page.shortLabel}${page.severe ? '' : ' (확인 필요)'}',
          style: AppTypography.label.copyWith(color: AppColors.textStrong),
        ),
        if (page.tip.isNotEmpty) ...[
          const SizedBox(height: 2),
          AppText(page.tip, style: AppTypography.caption),
        ],
        if (onRetake != null) ...[
          const SizedBox(height: AppSpacing.xs),
          SizedBox(
            height: AppSize.minTouchTarget,
            child: OutlinedButton.icon(
              onPressed: onRetake,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.caution,
                side: const BorderSide(color: AppColors.caution),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.button)),
                textStyle: AppTypography.buttonSmall,
              ),
              icon: const Icon(Icons.photo_camera, size: AppSize.iconSm),
              label: AppText('${page.index + 1}쪽 $retakeLabel'),
            ),
          ),
        ],
      ],
    );
  }
}
