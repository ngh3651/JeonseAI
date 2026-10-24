/// 챗봇 v2 — 꾹 누르기 = 바로 글자 선택 + 칩 (메뉴 없음) (2026-10-24).
///
/// - 말풍선을 꾹 누르면(안드로이드 기본 0.5초) 진동 1번 + **누른 줄(문장) 전체**가 선택된 채로 시작한다.
///   Flutter 기본은 낱말 하나를 고르지만, [_LinePickDelegate]가 "낱말 고르기"를 "그 줄 고르기"로 바꾼다.
///   (답은 서버가 문장마다 줄을 바꿔 보내고, 화면은 줄마다 글자 칸을 따로 그린다 → 한 줄 = 한 문장)
/// - 손잡이(14×14 물방울, primary)로 늘이고 줄인다.
/// - 안드로이드 기본 메뉴(전체 선택·공유 등) 대신 [ChatSelectionChip]: AI 답 [복사][답글], 내 말 [복사].
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/text/keep_all.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography_next.dart';

/// 손잡이 크기
const double kChatHandleSize = 14;

/// 칩 아이콘 크기
const double kChatChipIcon = 18;

/// 꾹 누르면 낱말 대신 그 줄(문단) 전체를 고른다
class _LinePickDelegate extends StaticSelectionContainerDelegate {
  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    if (event is SelectWordSelectionEvent) {
      return super.dispatchSelectionEvent(SelectParagraphSelectionEvent(globalPosition: event.globalPosition));
    }
    return super.dispatchSelectionEvent(event);
  }
}

/// 손잡이만 바꾼 선택 도구 — 14×14 물방울, primary. (메뉴는 [ChatSelectionChip]이 그린다)
class ChatSelectionControls extends MaterialTextSelectionControls {
  @override
  Size getHandleSize(double textLineHeight) => const Size(kChatHandleSize, kChatHandleSize);

  @override
  Widget buildHandle(
    BuildContext context,
    TextSelectionHandleType type,
    double textLineHeight, [
    VoidCallback? onTap,
  ]) {
    if (type == TextSelectionHandleType.collapsed) return const SizedBox.shrink();
    return CustomPaint(
      size: const Size(kChatHandleSize, kChatHandleSize),
      painter: _DropHandlePainter(left: type == TextSelectionHandleType.left),
    );
  }

  @override
  Offset getHandleAnchor(TextSelectionHandleType type, double textLineHeight) => switch (type) {
    TextSelectionHandleType.left => const Offset(kChatHandleSize, 0),
    TextSelectionHandleType.right => Offset.zero,
    TextSelectionHandleType.collapsed => const Offset(kChatHandleSize / 2, 0),
  };
}

/// 물방울 — 동그라미에 글자 쪽 모서리 하나만 뾰족
class _DropHandlePainter extends CustomPainter {
  const _DropHandlePainter({required this.left});

  final bool left;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.width / 2);
    final rect = Offset.zero & size;
    final rrect = left
        ? RRect.fromRectAndCorners(rect, topLeft: r, topRight: Radius.zero, bottomLeft: r, bottomRight: r)
        : RRect.fromRectAndCorners(rect, topLeft: Radius.zero, topRight: r, bottomLeft: r, bottomRight: r);
    canvas.drawRRect(rrect, Paint()..color = AppColors.primary);
  }

  @override
  bool shouldRepaint(_DropHandlePainter oldDelegate) => oldDelegate.left != left;
}

/// 고를 수 있는 말풍선 글 — 꾹 누르면 줄 선택 + 칩.
///
/// [onReply]가 null이면(내 말) 칩에 [복사]만.
class ChatSelectableText extends StatefulWidget {
  const ChatSelectableText({
    super.key,
    required this.child,
    required this.onCopy,
    this.onReply,
    this.selectionColor = AppColors.primarySoft,
  });

  final Widget child;

  /// 고른 글 (줄바꿈 금지 부호를 뺀 것)
  final ValueChanged<String> onCopy;
  final ValueChanged<String>? onReply;

  /// 선택 바탕 — AI 답은 primarySoft. 내 말은 primary 바탕 + 흰 글자라 화면이 primaryDeep을 넘긴다
  final Color selectionColor;

  @override
  State<ChatSelectableText> createState() => _ChatSelectableTextState();
}

class _ChatSelectableTextState extends State<ChatSelectableText> {
  final _LinePickDelegate _delegate = _LinePickDelegate();
  final ChatSelectionControls _controls = ChatSelectionControls();
  String _selected = '';

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  void _act(SelectableRegionState region, ValueChanged<String> action) {
    final text = _selected.trim();
    region.hideToolbar();
    region.clearSelection();
    if (text.isNotEmpty) action(text);
  }

  @override
  Widget build(BuildContext context) {
    final onReply = widget.onReply;
    return SelectionArea(
      selectionControls: _controls,
      onSelectionChanged: (content) => _selected = stripWordJoiner(content?.plainText ?? ''),
      contextMenuBuilder: (context, region) => ChatSelectionChip(
        anchors: region.contextMenuAnchors,
        onCopy: () => _act(region, widget.onCopy),
        onReply: onReply == null ? null : () => _act(region, onReply),
      ),
      child: DefaultSelectionStyle(
        selectionColor: widget.selectionColor,
        cursorColor: AppColors.primary,
        child: SelectionContainer(delegate: _delegate, child: widget.child),
      ),
    );
  }
}

/// 선택한 줄 위 8에 뜨는 칩 — 바탕 textStrong · 글자 surface · pill · 칸 높이 최소 48
class ChatSelectionChip extends StatelessWidget {
  const ChatSelectionChip({super.key, required this.anchors, required this.onCopy, this.onReply});

  final TextSelectionToolbarAnchors anchors;
  final VoidCallback onCopy;
  final VoidCallback? onReply;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + AppSpacing.sm;
    final adjust = Offset(AppSpacing.sm, top);
    final below = anchors.secondaryAnchor ?? anchors.primaryAnchor;
    return Padding(
      padding: EdgeInsets.fromLTRB(AppSpacing.sm, top, AppSpacing.sm, AppSpacing.sm),
      child: CustomSingleChildLayout(
        delegate: TextSelectionToolbarLayoutDelegate(
          anchorAbove: anchors.primaryAnchor - const Offset(0, AppSpacing.sm) - adjust,
          anchorBelow: below + const Offset(0, AppSpacing.sm + kChatHandleSize) - adjust,
        ),
        child: Material(
          color: AppColorsNext.textStrong,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: IntrinsicHeight(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ChipButton(icon: Icons.content_copy, label: '복사', onTap: onCopy),
                if (onReply != null) ...[
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                    color: AppColorsNext.textMuted,
                  ),
                  _ChipButton(icon: Icons.reply, label: '답글', onTap: onReply!),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChipButton extends StatelessWidget {
  const _ChipButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSize.minTouchTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: kChatChipIcon, color: AppColors.surface),
                const SizedBox(width: AppSpacing.xs),
                AppText(label, style: AppTypographyNext.bodyStrong.copyWith(color: AppColors.surface)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
