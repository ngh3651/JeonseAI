/// 챗봇 v2 — 지난 대화 서랍 (2026-10-24).
///
/// - 왼쪽에서 260ms로 나온다 · 폭 300 · 바탕 surface · 오른쪽 모서리 22 · 바깥 dim
///   (바깥 누르기·왼쪽으로 밀기로 닫힘). 앱 맨 위에 띄워서 상단 바·탭 바까지 덮는다.
/// - 제목 → 검색칸 → [+ 새 대화](검색 중엔 숨김) → 묶음별 목록(오늘·어제·지난 7일·달)
/// - [⋯] → 바닥 시트(이름 바꾸기 · 삭제) → 삭제 확인 창(빨간색 없음)
/// - 기록이 없으면 세이프 + "아직 지난 대화가 없어요", 검색칸은 흐리게.
library;

import 'package:flutter/material.dart';

import '../../design_system/components/mascot_safe.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/chat_history.dart';
import '../../repositories/chat_history_repository.dart';
import 'chat_history_logic.dart';

/// 서랍 폭 (글자 배율과 무관하게 그대로)
const double kChatDrawerWidth = 300;

/// 서랍이 나오는 시간
const Duration kChatDrawerDuration = Duration(milliseconds: 260);

/// 대화 제목 최대 글자 수 (이름 바꾸기)
const int kChatTitleMax = 40;

/// 서랍에서 고른 것
sealed class ChatDrawerResult {
  const ChatDrawerResult();
}

/// 이 대화를 연다
class OpenChat extends ChatDrawerResult {
  const OpenChat(this.conversation);

  final ChatConversation conversation;
}

/// [+ 새 대화]
class StartNewChat extends ChatDrawerResult {
  const StartNewChat();
}

/// 서랍을 띄운다. 이름 바꾸기·삭제는 서랍 안에서 바로 저장소에 쓰고 [onRenamed]·[onDeleted]로 알린다.
Future<ChatDrawerResult?> showChatHistoryDrawer(
  BuildContext context, {
  required ChatHistoryRepository repository,
  required String? currentId,
  required void Function(String id, String title) onRenamed,
  required ValueChanged<String> onDeleted,
  DateTime Function() clock = DateTime.now,
}) {
  return showGeneralDialog<ChatDrawerResult>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    barrierLabel: '지난 대화 닫기',
    barrierColor: AppColors.dim,
    transitionDuration: kChatDrawerDuration,
    pageBuilder: (context, animation, secondary) => ChatHistoryDrawer(
      repository: repository,
      currentId: currentId,
      onRenamed: onRenamed,
      onDeleted: onDeleted,
      clock: clock,
    ),
    transitionBuilder: (context, animation, secondary, child) => SlideTransition(
      position: Tween<Offset>(begin: const Offset(-1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
      child: child,
    ),
  );
}

class ChatHistoryDrawer extends StatefulWidget {
  const ChatHistoryDrawer({
    super.key,
    required this.repository,
    required this.currentId,
    required this.onRenamed,
    required this.onDeleted,
    this.clock = DateTime.now,
  });

  final ChatHistoryRepository repository;
  final String? currentId;
  final void Function(String id, String title) onRenamed;
  final ValueChanged<String> onDeleted;
  final DateTime Function() clock;

  @override
  State<ChatHistoryDrawer> createState() => _ChatHistoryDrawerState();
}

class _ChatHistoryDrawerState extends State<ChatHistoryDrawer> {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  List<ChatConversation>? _all;
  String? _currentId;
  double _drag = 0;

  String get _query => _searchCtrl.text.trim();
  bool get _searching => _query.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _currentId = widget.currentId;
    _searchFocus.addListener(() {
      if (mounted) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final all = await widget.repository.list();
    if (mounted) setState(() => _all = all);
  }

  void _close([ChatDrawerResult? result]) => Navigator.of(context).pop(result);

  // ── [⋯] 시트 → 이름 바꾸기 / 삭제 ─────────────────────────────────────────

  Future<void> _openMenu(ChatConversation c) async {
    final action = await showModalBottomSheet<_SheetAction>(
      showDragHandle: false, // 손잡이는 직접 그린다 — 테마 손잡이와 겹쳐 두 개로 보였다 (2026-10-27)
      context: context,
      useRootNavigator: true,
      backgroundColor: AppColors.surface,
      barrierColor: AppColors.dim,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet))),
      builder: (context) => _ConversationSheet(conversation: c, now: widget.clock()),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _SheetAction.rename:
        final title = await showDialog<String>(
          context: context,
          useRootNavigator: true,
          barrierColor: AppColors.dim,
          builder: (context) => _RenameDialog(initial: c.title),
        );
        if (title == null || title.trim().isEmpty || title.trim() == c.title) return;
        await widget.repository.rename(c.id, title.trim());
        widget.onRenamed(c.id, title.trim());
        await _load();
      case _SheetAction.delete:
        final ok = await showDialog<bool>(
          context: context,
          useRootNavigator: true,
          barrierColor: AppColors.dim,
          builder: (context) => _DeleteDialog(title: c.title),
        );
        if (ok != true) return;
        await widget.repository.delete(c.id);
        widget.onDeleted(c.id);
        if (_currentId == c.id) _currentId = null;
        await _load();
    }
  }

  // ── 그리기 ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final all = _all;
    final empty = all != null && all.isEmpty;
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        // 왼쪽으로 밀면 닫힘
        onHorizontalDragStart: (_) => _drag = 0,
        onHorizontalDragUpdate: (d) => _drag += d.delta.dx,
        onHorizontalDragEnd: (d) {
          if (_drag < -AppSize.minTouchTarget || (d.primaryVelocity ?? 0) < -300) _close();
        },
        child: Material(
          key: const ValueKey('chat-drawer'),
          color: AppColors.surface,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.horizontal(right: Radius.circular(AppRadius.sheet)),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: kChatDrawerWidth,
            height: double.infinity,
            child: SafeArea(
              right: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.screenPadding,
                      AppSpacing.lg,
                      AppSpacing.screenPadding,
                      AppSpacing.md,
                    ),
                    child: AppText('지난 대화', style: AppTypographyNext.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
                    child: _searchField(enabled: !empty),
                  ),
                  if (!_searching) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _newChatButton(),
                  ],
                  Expanded(
                    child: all == null
                        ? const SizedBox.shrink()
                        : empty
                        ? _emptyState()
                        : _searching
                        ? _searchResults(all)
                        : _groupedList(all),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchField({required bool enabled}) {
    final focused = _searchFocus.hasFocus;
    final pill = BorderRadius.circular(AppRadius.pill);
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: TextField(
        controller: _searchCtrl,
        focusNode: _searchFocus,
        enabled: enabled,
        textInputAction: TextInputAction.search,
        onChanged: (_) => setState(() {}),
        style: AppTypographyNext.body,
        decoration: InputDecoration(
          hintText: '대화 검색',
          hintStyle: AppTypographyNext.body.copyWith(color: AppColorsNext.textMuted),
          filled: true,
          fillColor: focused ? AppColors.surface : AppColors.background,
          isDense: true,
          constraints: const BoxConstraints(minHeight: AppSize.minTouchTarget),
          contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          prefixIcon: const Icon(Icons.search, size: AppSize.iconSm, color: AppColorsNext.textMuted),
          prefixIconConstraints: const BoxConstraints(minWidth: AppSize.minTouchTarget, minHeight: AppSize.minTouchTarget),
          suffixIcon: _searchCtrl.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '검색어 지우기',
                  icon: const Icon(Icons.close, size: AppSize.iconSm, color: AppColorsNext.textMuted),
                  onPressed: () => setState(_searchCtrl.clear),
                ),
          suffixIconConstraints: const BoxConstraints(minWidth: AppSize.minTouchTarget, minHeight: AppSize.minTouchTarget),
          enabledBorder: OutlineInputBorder(borderRadius: pill, borderSide: BorderSide.none),
          disabledBorder: OutlineInputBorder(borderRadius: pill, borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
            borderRadius: pill,
            borderSide: const BorderSide(color: AppColors.primary, width: 2),
          ),
        ),
      ),
    );
  }

  Widget _newChatButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => _close(const StartNewChat()),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSize.minTouchTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                const Icon(Icons.add, size: AppSize.iconSm, color: AppColors.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: AppText(
                    '새 대화',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypographyNext.bodyStrong.copyWith(color: AppColors.primary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _groupHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screenPadding, AppSpacing.lg, AppSpacing.screenPadding, AppSpacing.xs),
      child: AppText(label, style: AppTypographyNext.caption, maxLines: 2),
    );
  }

  Widget _groupedList(List<ChatConversation> all) {
    final now = widget.clock();
    final children = <Widget>[];
    String? last;
    for (final c in all) {
      final label = chatGroupLabel(c.updatedAt, now);
      if (label != last) {
        children.add(_groupHeader(label));
        last = label;
      }
      children.add(_row(c, subtitle: _defaultSub(c, now)));
    }
    return ListView(padding: const EdgeInsets.only(bottom: AppSpacing.lg), children: children);
  }

  Widget _searchResults(List<ChatConversation> all) {
    final hits = searchChats(all, _query);
    if (hits.isEmpty) {
      return ListView(children: [_groupHeader(searchEmptyMessage(_query))]);
    }
    final now = widget.clock();
    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      children: [
        _groupHeader(searchHeader(_query, hits.length)),
        for (final h in hits)
          _row(
            h.conversation,
            titleMatches: h.titleMatches,
            subtitle: h.snippet == null ? _defaultSub(h.conversation, now) : _highlight(h.snippet!, h.snippetMatches, _subStyle),
          ),
      ],
    );
  }

  static final TextStyle _subStyle = AppTypographyNext.caption.copyWith(color: AppColorsNext.textMuted);
  static final TextStyle _titleStyle = AppTypographyNext.bodyStrong.copyWith(color: AppColorsNext.textStrong);

  InlineSpan _defaultSub(ChatConversation c, DateTime now) {
    final answer = c.lastAnswer;
    final time = chatRowTime(c.updatedAt, now);
    return TextSpan(text: answer == null ? time : '$time · ${firstChatLine(answer.text)}', style: _subStyle);
  }

  /// 맞은 글자 — 바탕 primarySoft + 글자 primaryDeep 600
  InlineSpan _highlight(String text, List<ChatMatch> matches, TextStyle base) {
    if (matches.isEmpty) return TextSpan(text: text, style: base);
    final hit = base.copyWith(
      backgroundColor: AppColors.primarySoft,
      color: AppColors.primaryDeep,
      fontWeight: FontWeight.w600,
    );
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final m in matches) {
      if (m.start > cursor) spans.add(TextSpan(text: text.substring(cursor, m.start)));
      spans.add(TextSpan(text: text.substring(m.start, m.end), style: hit));
      cursor = m.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return TextSpan(style: base, children: spans);
  }

  Widget _row(ChatConversation c, {required InlineSpan subtitle, List<ChatMatch> titleMatches = const []}) {
    final current = c.id == _currentId;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: Material(
        key: ValueKey('chat-row-${c.id}'),
        color: current ? AppColors.primarySoft : AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _close(OpenChat(c)),
          child: Padding(
            padding: const EdgeInsets.only(left: AppSpacing.md, top: AppSpacing.md, bottom: AppSpacing.md),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text.rich(
                        _highlight(c.title, titleMatches, _titleStyle),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text.rich(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '대화 메뉴',
                  constraints: const BoxConstraints(minWidth: AppSize.minTouchTarget, minHeight: AppSize.minTouchTarget),
                  icon: const Icon(Icons.more_horiz, size: AppSize.iconMd, color: AppColorsNext.textMuted),
                  onPressed: () => _openMenu(c),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 96,
                height: 96,
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.line),
                ),
                child: const MascotSafe(size: 80, state: MascotState.info),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppText(
                '아직 지난 대화가 없어요',
                textAlign: TextAlign.center,
                style: AppTypographyNext.bodyStrong.copyWith(color: AppColorsNext.textStrong),
              ),
              const SizedBox(height: AppSpacing.xs),
              AppText('물어본 내용이 여기에 차곡차곡 쌓여요', textAlign: TextAlign.center, style: AppTypographyNext.caption),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// [⋯] 바닥 시트 · 이름 바꾸기 · 삭제 확인
// ══════════════════════════════════════════════════════════════════════════════

enum _SheetAction { rename, delete }

class _ConversationSheet extends StatelessWidget {
  const _ConversationSheet({required this.conversation, required this.now});

  final ChatConversation conversation;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: AppSpacing.sm),
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(AppRadius.pill)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenPadding,
              AppSpacing.lg,
              AppSpacing.screenPadding,
              AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conversation.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypographyNext.bodyStrong.copyWith(color: AppColorsNext.textStrong),
                ),
                AppText(
                  '${chatSheetTime(conversation.updatedAt, now)} · 말 ${conversation.messageCount}개',
                  style: AppTypographyNext.caption,
                ),
              ],
            ),
          ),
          _item(context, Icons.edit_outlined, '이름 바꾸기', _SheetAction.rename),
          _item(context, Icons.delete_outline, '삭제', _SheetAction.delete),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    );
  }

  Widget _item(BuildContext context, IconData icon, String label, _SheetAction action) {
    return InkWell(
      onTap: () => Navigator.of(context).pop(action),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
          child: Row(
            children: [
              Icon(icon, size: AppSize.iconMd, color: AppColorsNext.textMuted),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: AppText(label, style: AppTypographyNext.body.copyWith(color: AppColorsNext.textStrong)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 가운데 창 — radius 20 · 안쪽 24 · 버튼 [취소](surface + line 1) [확인](primary 채움) 높이 48 pill 반반, 사이 8
class _CenterDialog extends StatelessWidget {
  const _CenterDialog({
    required this.title,
    required this.body,
    required this.confirmLabel,
    required this.onConfirm,
  });

  final String title;
  final Widget body;
  final String confirmLabel;

  /// null이면 [확인] 비활성
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    const pill = StadiumBorder();
    return Dialog(
      backgroundColor: AppColors.surface,
      surfaceTintColor: AppColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding, vertical: AppSpacing.xxl),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppText(title, style: AppTypographyNext.title),
            const SizedBox(height: AppSpacing.sm),
            body,
            const SizedBox(height: AppSpacing.xxl),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(AppSize.minTouchTarget),
                      backgroundColor: AppColors.surface,
                      foregroundColor: AppColorsNext.textStrong,
                      side: const BorderSide(color: AppColors.line),
                      shape: pill,
                      textStyle: AppTypographyNext.button,
                    ),
                    child: const AppText('취소'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: FilledButton(
                    onPressed: onConfirm,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(AppSize.minTouchTarget),
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.surface,
                      disabledBackgroundColor: AppColors.line,
                      disabledForegroundColor: AppColorsNext.textMuted,
                      shape: pill,
                      textStyle: AppTypographyNext.button,
                    ),
                    child: AppText(confirmLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DeleteDialog extends StatelessWidget {
  const _DeleteDialog({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return _CenterDialog(
      title: '이 대화를 지울까요?',
      body: AppText(
        "'$title' 대화가 이 폰에서 지워져요. 지운 대화는 다시 볼 수 없어요.",
        style: AppTypographyNext.body.copyWith(color: AppColorsNext.textBody),
      ),
      confirmLabel: '지우기',
      onConfirm: () => Navigator.of(context).pop(true),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _ctrl.text.trim();
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      borderSide: const BorderSide(color: AppColors.line),
    );
    return _CenterDialog(
      title: '이름 바꾸기',
      body: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLength: kChatTitleMax,
        maxLines: 1,
        style: AppTypographyNext.body,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          counterText: '',
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          enabledBorder: border,
          focusedBorder: border.copyWith(borderSide: const BorderSide(color: AppColors.primary, width: 2)),
        ),
      ),
      confirmLabel: '바꾸기',
      onConfirm: text.isEmpty ? null : () => Navigator.of(context).pop(text),
    );
  }
}
