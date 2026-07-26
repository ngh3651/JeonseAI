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
    this.showAvatar = true,
  });

  final String text;
  final bool isUser;

  /// 봇 응답에 붙는 행동 버튼 (예: 범위 밖 질문 → [매물 분석하러 가기])
  final Widget? action;

  /// 봇 말풍선의 마스코트 아바타 표시 여부. (F10) 연속된 봇 말풍선에서는
  /// 마지막 말풍선에만 아바타를 두고, 나머지는 자리만 비워 정렬을 맞춘다.
  final bool showAvatar;

  static const double _avatarSize = 32;

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
        // F10: 네 모서리 라운딩 통일 (기존 비대칭 꼬리 제거)
        borderRadius: BorderRadius.circular(AppRadius.lg),
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
        // 아바타 자리는 항상 확보 — 연속 말풍선이 좌측으로 정렬되게
        showAvatar
            ? const MascotSafe(size: _avatarSize, state: MascotState.tip)
            : const SizedBox(width: _avatarSize),
        const SizedBox(width: AppSpacing.sm),
        Flexible(child: bubble),
      ],
    );
  }
}
