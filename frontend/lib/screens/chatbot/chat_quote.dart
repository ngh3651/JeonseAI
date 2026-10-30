/// 챗봇 v2 — 인용 띠(입력칸 위) · 인용 칩(보낸 내 말풍선 위) · "복사했어요" 알림 (2026-10-24).
library;

import 'package:flutter/material.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography_next.dart';
import 'chat_history_logic.dart';

/// 인용 띠 라벨
const String kQuoteBandLabel = '세이프 답에 이어 물어요';

/// 인용 중 입력칸 힌트
const String kQuoteHint = '이 답에 대해 더 물어보세요';

/// 복사 알림
const String kCopiedMessage = '복사했어요';

/// 인용 띠 — 바탕 surface · 테두리 line 1 · radius 12 · 왼쪽 막대 primaryBright 3 · 오른쪽 [X] 48
class QuoteBand extends StatelessWidget {
  const QuoteBand({super.key, required this.quote, required this.onCancel});

  final String quote;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('quote-band'),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3, color: AppColors.primaryBright),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, 0, AppSpacing.xs),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      kQuoteBandLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypographyNext.caption.copyWith(color: AppColors.primary),
                    ),
                    Text(
                      firstChatLine(quote),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypographyNext.caption.copyWith(color: AppColorsNext.textMuted),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: '인용 취소',
              constraints: const BoxConstraints(minWidth: AppSize.minTouchTarget, minHeight: AppSize.minTouchTarget),
              icon: Icon(Icons.close, size: AppSize.iconSm, color: AppColorsNext.textMuted),
              onPressed: onCancel,
            ),
          ],
        ),
      ),
    );
  }
}

/// 인용 칩 — 보낸 내 말풍선 맨 위. 바탕 primaryDeep · 글자·화살표 onPrimaryDeep(밝게 연초록 · 어둡게 밝은 초록) · radius 12 · 안쪽 8/12.
/// 누르면 원래 답으로 스크롤. 누를 곳이라 높이는 최소 48(터치 기준).
class QuoteChip extends StatelessWidget {
  const QuoteChip({super.key, required this.quote, required this.onTap});

  final String quote;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final line = firstChatLine(quote);
    return Semantics(
      button: true,
      label: '인용한 답 보기: $line',
      excludeSemantics: true,
      child: Material(
        color: AppColors.primaryDeep,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppSize.minTouchTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.subdirectory_arrow_right, size: AppSize.iconXs, color: AppColors.onPrimaryDeep),
                  const SizedBox(width: AppSpacing.xs),
                  Flexible(
                    child: Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypographyNext.caption.copyWith(color: AppColors.onPrimaryDeep),
                    ),
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

/// "복사했어요" — 입력 줄 위 8, 아래서 8 올라오며 나타나고 2초 뒤 사라진다(화면이 시간을 잰다)
class CopiedToast extends StatelessWidget {
  const CopiedToast({super.key, required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    const duration = Duration(milliseconds: 200);
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: visible ? 0 : AppSpacing.sm),
        duration: duration,
        curve: Curves.easeOut,
        builder: (context, dy, child) => Transform.translate(offset: Offset(0, dy), child: child),
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: duration,
          child: Semantics(
            liveRegion: visible,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.md),
              decoration: BoxDecoration(
                color: AppColorsNext.textStrong,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle, size: AppSize.iconSm, color: AppColors.primaryBright),
                  const SizedBox(width: AppSpacing.sm),
                  Flexible(
                    child: AppText(kCopiedMessage, style: AppTypographyNext.caption.copyWith(color: AppColors.surface)),
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
