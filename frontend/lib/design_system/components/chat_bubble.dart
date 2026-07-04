/// 챗 말풍선 — 용어 챗봇(S-12)용.
///
/// 봇 말풍선에는 마스코트 '세이프' 아바타(플레이스홀더)를 붙인다.
library;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'mascot_safe.dart';

class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.text,
    required this.isUser,
    this.action,
  });

  final String text;
  final bool isUser;

  /// 봇 응답에 붙는 행동 버튼 (예: 범위 밖 질문 → [매물 분석하러 가기])
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    // 말풍선 최대 폭은 화면 폭 비율로 — 소형/대형 기기 모두 자연스럽게
    final double maxBubbleWidth = MediaQuery.sizeOf(context).width * 0.72;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxBubbleWidth),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: isUser ? AppColors.primary : AppColors.surface,
        border: isUser ? null : Border.all(color: AppColors.line),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(AppRadius.lg),
          topRight: const Radius.circular(AppRadius.lg),
          bottomLeft: Radius.circular(isUser ? AppRadius.lg : AppRadius.sm),
          bottomRight: Radius.circular(isUser ? AppRadius.sm : AppRadius.lg),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: AppTypography.body.copyWith(
              color: isUser ? Colors.white : AppColors.textBody,
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: AppSpacing.md),
            action!,
          ],
        ],
      ),
    );

    if (isUser) {
      return Align(alignment: Alignment.centerRight, child: bubble);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const MascotSafe(size: 32),
        const SizedBox(width: AppSpacing.sm),
        Flexible(child: bubble),
      ],
    );
  }
}
