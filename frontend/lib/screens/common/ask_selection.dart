/// 글자를 꾹 눌러 **챗봇에 묻기** (2026-10-26) — 계약 여정·판례·리포트 화면을 감싼다.
///
/// 꾹 누르면 누른 어절이 골라지고(손잡이로 넓힌다) 칩 [복사][챗봇에 묻기]가 뜬다.
/// [챗봇에 묻기] → 고른 글이 챗봇 입력칸 위 인용 띠로 가고, 챗봇 탭이 열린다(사용자가 이어서 묻는다).
/// 손잡이·칩 모양은 챗봇 말풍선과 같다(`chat_selection.dart`).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../design_system/text/keep_all.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../state/chat_handoff.dart';
import '../chatbot/chat_selection.dart';

class AskSelectionArea extends StatefulWidget {
  const AskSelectionArea({super.key, required this.child, this.beforeAsk});

  static const String askLabel = '챗봇에 묻기';

  final Widget child;

  /// [챗봇에 묻기] 직전에 할 일 — 하단 시트 안에서 쓰면 시트를 닫는다(2026-10-31).
  final VoidCallback? beforeAsk;

  @override
  State<AskSelectionArea> createState() => _AskSelectionAreaState();
}

class _AskSelectionAreaState extends State<AskSelectionArea> {
  final ChatSelectionControls _controls = ChatSelectionControls();
  String _selected = '';

  void _act(SelectableRegionState region, void Function(String text) action) {
    final text = _selected.trim();
    region.hideToolbar();
    region.clearSelection();
    if (text.isNotEmpty) action(text);
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      selectionControls: _controls,
      onSelectionChanged: (content) =>
          _selected = stripWordJoiner(content?.plainText ?? ''),
      contextMenuBuilder: (context, region) => ChatSelectionChip(
        anchors: region.contextMenuAnchors,
        onCopy: () => _act(region, (t) {
          Clipboard.setData(ClipboardData(text: t));
          ScaffoldMessenger.maybeOf(context)
            ?..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(
                content: Text('복사했어요'),
                duration: Duration(seconds: 2),
              ),
            );
        }),
        onReply: () => _act(region, (t) {
          final router = GoRouter.of(context);
          widget.beforeAsk?.call();
          ChatHandoff.send(t);
          router.go('/chatbot');
        }),
        replyLabel: AskSelectionArea.askLabel,
        replyIcon: Icons.chat_bubble_outline,
      ),
      child: DefaultSelectionStyle(
        selectionColor: AppColors.primarySoft,
        cursorColor: AppColors.primary,
        child: widget.child,
      ),
    );
  }
}
