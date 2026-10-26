/// 장별 재촬영 안내 — "몇 쪽이 왜 문제인지 + 그 장만 다시 찍기" (2026-10-22, P1-1).
///
/// 서버가 사진 품질을 본다(api-contract §9.9):
/// - **심하면** 분석 전에 거절한다(400 + `captureCheck`) → 촬영 화면이 이 패널을 띄우고, 문제인 장만 다시 찍어
///   바꾼 뒤 다시 보낸다(나머지 장은 그대로).
/// - **가벼우면** 분석하고 리포트에 `captureCheck`를 싣는다 → 리포트가 같은 패널로 "다시 찍으면 더 정확해요"를 알린다.
///
/// ⚠ 가벼운 장에 '(확인 필요)'를 붙이지 않는다(2026-10-23) — 등급 이름과 같은 말이라 판정처럼 읽혔고,
///   "보내라는 거야 말라는 거야"(지수 리뷰 #4)로 막혔다. 대신 **[kSoftIssueNote]** — 보수적이면서 할 일을 말한다.
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

/// 가벼운 문제(분석은 했다)인 장 뒤에 붙는 말 — 촬영 화면·리포트가 같은 말을 쓴다.
const String kSoftIssueNote = '(다시 찍으면 더 정확해요)';

/// 장별 문제 목록 + 장마다 [다시 찍기] 버튼.
///
/// 버튼 글자 = `{쪽}{조사} {retakeLabel}` — "2쪽만 다시 찍기"(거절된 장) · "2쪽도 다시 찍기"(남은 가벼운 장) ·
/// "2쪽 다시 찍기"(리포트). 예전 "2쪽 이 장만 다시 찍기"는 말이 꼬였다(지수 리뷰 #4).
class CaptureIssuePanel extends StatelessWidget {
  const CaptureIssuePanel({
    super.key,
    required this.check,
    required this.title,
    this.message,
    this.onRetake,
    this.retakeParticle = '',
    this.retakeLabel = '다시 찍기',
    this.pageNumberOf,
  });

  /// 업로드 번호(0부터) → 화면에 쓸 **쪽 번호**(1부터). 없으면 올린 순서(+1).
  /// 리포트는 서버가 쪽 번호를 읽어 정한 순서(§9.12)를 넘긴다 — 뷰어의 쪽 번호와 같아지게(2026-10-26).
  final int Function(int index)? pageNumberOf;

  final CaptureCheck check;

  /// 패널 제목 — 거절이면 "사진을 다시 찍어야 분석할 수 있어요", 리포트면 "글자를 잘못 읽었을 수 있는 장이 있어요".
  final String title;

  /// 제목 아래 한 줄 (서버 `detail` 등). 없으면 생략.
  final String? message;

  /// 장 번호(0부터)를 받아 그 장만 다시 찍는다. null이면 버튼 없이 안내만.
  final void Function(CapturePageIssue page)? onRetake;

  /// 쪽 번호 바로 뒤 조사 — '만'(이 장만) · '도'(이 장도) · ''(그냥).
  final String retakeParticle;

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
                  // D8: 연한 앰버 바탕 위 글자는 진한 색 — 앰버는 아이콘·테두리에만
                  style: AppTypography.bodyStrong.copyWith(color: AppColors.textStrong),
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
              pageNumber: pageNumberOf?.call(page.index) ?? page.index + 1,
              onRetake: onRetake == null ? null : () => onRetake!(page),
              retakeLabel: '${pageNumberOf?.call(page.index) ?? page.index + 1}쪽$retakeParticle $retakeLabel',
            ),
          ],
        ],
      ),
    );
  }
}

class _PageRow extends StatelessWidget {
  const _PageRow({required this.page, required this.pageNumber, required this.onRetake, required this.retakeLabel});

  final CapturePageIssue page;
  final int pageNumber;
  final VoidCallback? onRetake;
  final String retakeLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: ValueKey('capture-issue-${page.index}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          '$pageNumber쪽 · ${page.shortLabel}${page.severe ? '' : ' $kSoftIssueNote'}',
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
                foregroundColor: AppColors.textStrong,
                side: const BorderSide(color: AppColors.caution),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.button)),
                textStyle: AppTypography.buttonSmall,
              ),
              icon: const Icon(Icons.photo_camera, size: AppSize.iconSm),
              label: AppText(retakeLabel),
            ),
          ),
        ],
      ],
    );
  }
}
