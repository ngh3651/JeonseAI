/// S-12 챗봇 (탭) — **대화는 AI(Solar)가, 판정은 리포트만** (2026-10-24 대화형으로).
///
/// 무엇이 달라졌나 (2026-08-14 '용어 챗봇' → '챗봇'):
/// 예전엔 서버 규칙이 '안녕'·'더 쉽게'까지 막아 "준비된 문구"가 나왔고, 질문 하나 = 답 하나라 앞 대화를
/// 몰랐다. 이제 **최근 대화를 통째로 보내고**(서버는 저장하지 않는다) AI가 이어서 답한다.
///
/// 앱이 지키는 것:
/// ⑴ **문구를 지어내지 않는다.** 답·기본 문장 모두 서버가 준다.
/// ⑵ **챗봇만 둔다**(규혁: "여기선 딱 챗봇만") — 말풍선 밑 출처 라벨·'내 리포트 보기' 버튼·용어 밑줄 없음.
///    AI가 답한다는 사실은 빈 화면 한 줄로 알린다(인공지능 기본법 'AI 결과물 고지').
/// ⑶ 말풍선 폭을 화면의 75%로 묶는다 — 긴 글이 가로로 끝없이 늘어지지 않게. `**굵게**`는 굵게 그린다.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/mascot_safe.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/content_models.dart';
import '../../repositories/content_repository.dart';
import '../../services/api_client.dart';

/// 답을 기다리는 동안 띄우는 한 줄 — **상수로 둔다**(촬영 중에 바꿀 수 있게).
const String kChatLoadingMessage = '답을 쓰고 있어요…';

/// 빈 화면 안내 — AI가 답한다는 사실을 숨기지 않는다.
const String kChatAiNotice = 'Upstage Solar AI가 쉬운 말로 답해요';

/// 한 번에 보낼 수 있는 글자 수 (서버 상한 500보다 넉넉히 안쪽)
const int kChatMaxChars = 300;

/// 말풍선 최대 폭 — 화면 폭의 비율
const double kBubbleWidthFactor = 0.75;

/// 빈 화면에 먼저 보여줄 추천 칩 — **촬영 대본에 쓰는 순서 그대로**.
///
/// ⚠ 서버가 실제로 내려준 것만 보여준다. `대항력`은 지금 **검수 대기**라 서버 응답에
///   없다 — 그 자리는 남은 용어로 채운다. 검수가 끝나 응답에 들어오면 이 순서대로 앞에 선다.
const List<String> kFeaturedChips = [
  '근저당권',
  '선순위 채권',
  '전세가율',
  '확정일자',
  '대항력',
  '신탁등기',
];

/// 접힌 상태에서 보여줄 칩 개수 (2열 × 3행)
const int kFeaturedChipCount = 6;

class _Msg {
  const _Msg.user(this.text) : reply = null, isUser = true, isLoading = false, retryQuery = null;

  const _Msg.bot(ChatReply this.reply)
    : text = '',
      isUser = false,
      isLoading = false,
      retryQuery = null;

  const _Msg.loading() : text = '', reply = null, isUser = false, isLoading = true, retryQuery = null;

  /// 네트워크 오류 — [다시 시도]가 재질문할 원문을 들고 있다
  const _Msg.failed(this.text, this.retryQuery) : reply = null, isUser = false, isLoading = false;

  final String text;
  final ChatReply? reply;
  final bool isUser;
  final bool isLoading;
  final String? retryQuery;
}

class GlossaryChatbotScreen extends StatefulWidget {
  const GlossaryChatbotScreen({super.key});

  @override
  State<GlossaryChatbotScreen> createState() => _GlossaryChatbotScreenState();
}

class _GlossaryChatbotScreenState extends State<GlossaryChatbotScreen> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<_Msg> _messages = [];

  bool _sending = false;
  bool _showAllChips = false;
  List<GlossaryTerm> _terms = const [];

  @override
  void initState() {
    super.initState();
    _loadTerms();
  }

  Future<void> _loadTerms() async {
    try {
      final terms = await context.read<ContentRepository>().glossaryTerms();
      if (mounted) setState(() => _terms = terms);
    } catch (_) {
      // 추천 칩만 비어 보임 — 입력으로는 계속 물어볼 수 있다.
    }
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 화면에 보여줄 칩 순서 — 대본 순서를 앞에 두고, 나머지는 서버 순서대로.
  List<String> get _orderedChips {
    final all = _terms.map((t) => t.term).toList();
    final featured = [for (final t in kFeaturedChips) if (all.contains(t)) t];
    return [...featured, ...all.where((t) => !featured.contains(t))];
  }

  /// 서버에 보낼 대화 — 질문과 답만(로딩·실패 줄은 빼고).
  List<ChatTurn> get _history => [
    for (final m in _messages)
      if (m.isUser)
        ChatTurn.user(m.text)
      else if (m.reply != null)
        ChatTurn.bot(m.reply!.answer),
  ];

  Future<void> _ask(String query) async {
    final q = query.trim();
    if (q.isEmpty || _sending) return;
    setState(() {
      _messages.add(_Msg.user(q));
      _messages.add(const _Msg.loading());
      _inputCtrl.clear();
      _sending = true;
    });
    _scrollToBottom();

    late final _Msg reply;
    try {
      final answer = await context.read<ContentRepository>().chat(_history);
      reply = _Msg.bot(answer);
    } on ApiException catch (e) {
      // 429(질문 너무 많음)는 서버 문장 그대로, 그 밖은 연결 문제로 본다
      reply = _Msg.failed(
        e.statusCode == 429 ? e.message : '연결이 불안정해요. 다시 시도해 주세요',
        q,
      );
    } catch (_) {
      reply = _Msg.failed('연결이 불안정해요. 다시 시도해 주세요', q);
    }
    if (!mounted) return;
    setState(() {
      _messages.removeWhere((m) => m.isLoading);
      _messages.add(reply);
      _sending = false;
    });
    _scrollToBottom();
  }

  /// [다시 시도] — 실패 줄과 그 질문을 지우고 같은 질문을 다시 보낸다(대화에 같은 질문이 두 번 남지 않게).
  void _retry(_Msg failed) {
    final q = failed.retryQuery ?? '';
    setState(() {
      final at = _messages.indexOf(failed);
      if (at >= 0) {
        _messages.removeAt(at);
        if (at > 0 && _messages[at - 1].isUser && _messages[at - 1].text == q) {
          _messages.removeAt(at - 1);
        }
      }
    });
    _ask(q);
  }

  /// 새 대화 — 부스에서 다음 사람이 오면 지운다.
  void _reset() {
    setState(() {
      _messages.clear();
      _inputCtrl.clear();
      _showAllChips = false;
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const AppText('챗봇'),
        automaticallyImplyLeading: false,
        actions: [
          if (_messages.isNotEmpty && !_sending)
            IconButton(
              tooltip: '새 대화',
              icon: const Icon(Icons.refresh),
              onPressed: _reset,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _messages.isEmpty ? _emptyState() : _conversation()),
          _inputBar(),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 빈 상태 — 마스코트 + 인사 + AI 안내 + 추천 칩
  // ══════════════════════════════════════════════════════════════════════════

  Widget _emptyState() {
    final chips = _orderedChips;
    final visible = _showAllChips ? chips : chips.take(kFeaturedChipCount).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        AppSpacing.xxl,
        AppSpacing.screenPadding,
        AppSpacing.xxl,
      ),
      children: [
        const Center(child: MascotSafe(size: 96, state: MascotState.tip)),
        const SizedBox(height: AppSpacing.xl),
        AppText(
          '전세·부동산,\n뭐든 물어보세요',
          textAlign: TextAlign.center,
          style: AppTypography.headline.copyWith(height: 1.35),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppText(
          kChatAiNotice,
          textAlign: TextAlign.center,
          style: AppTypography.body.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: AppSpacing.xxxl),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [for (final term in visible) _chip(term)],
        ),
        if (chips.length > kFeaturedChipCount && !_showAllChips) ...[
          const SizedBox(height: AppSpacing.md),
          Center(
            child: TextButton.icon(
              onPressed: () => setState(() => _showAllChips = true),
              icon: const Icon(Icons.expand_more, size: AppSize.iconSm),
              label: AppText('더 보기 (${chips.length - kFeaturedChipCount}개)'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _chip(String term) {
    return ActionChip(
      label: AppText(term),
      onPressed: _sending ? null : () => _ask(term),
      backgroundColor: AppColors.primarySoft,
      side: BorderSide.none,
      labelStyle: AppTypography.buttonSmall.copyWith(color: AppColors.primary),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 대화
  // ══════════════════════════════════════════════════════════════════════════

  Widget _conversation() {
    return ListView.separated(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        AppSpacing.lg,
        AppSpacing.screenPadding,
        AppSpacing.xl,
      ),
      itemCount: _messages.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.lg),
      itemBuilder: (context, i) {
        final m = _messages[i];
        if (m.isUser) return _userBubble(m.text);
        if (m.isLoading) return _botRow(_bubbleText(kChatLoadingMessage, muted: true));
        if (m.reply != null) return _botRow(_answerText(m.reply!.answer));
        return _failedRow(m);
      },
    );
  }

  double get _maxBubbleWidth => MediaQuery.sizeOf(context).width * kBubbleWidthFactor;

  TextStyle get _bodyStyle =>
      AppTypography.body.copyWith(fontSize: 17, height: 1.6, color: AppColors.textStrong);

  /// 사용자 말풍선 — 연초록, 오른쪽.
  Widget _userBubble(String text) {
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _maxBubbleWidth),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(AppRadius.xl),
          ),
          child: AppText(text, style: _bodyStyle),
        ),
      ),
    );
  }

  /// 챗봇 줄 — 작은 세이프 + 흰 말풍선(왼쪽). 폭은 사용자 말풍선과 같은 비율로 묶는다.
  Widget _botRow(Widget content) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: MascotSafe(size: 28, state: MascotState.tip),
        ),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: _maxBubbleWidth),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: AppColors.line),
                borderRadius: BorderRadius.circular(AppRadius.xl),
              ),
              child: content,
            ),
          ),
        ),
      ],
    );
  }

  Widget _bubbleText(String text, {bool muted = false}) => AppText(
    text,
    style: muted ? _bodyStyle.copyWith(color: AppColors.textMuted) : _bodyStyle,
  );

  /// 답 — `**굵게**`만 굵게 그린다(밑줄·링크 없음).
  Widget _answerText(String answer) {
    final base = _bodyStyle;
    final bold = base.copyWith(fontWeight: FontWeight.w700);
    return AppText.rich(TextSpan(style: base, children: boldSpans(answer, base: base, bold: bold)));
  }

  Widget _failedRow(_Msg m) {
    return _botRow(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _bubbleText(m.text),
          const SizedBox(height: AppSpacing.md),
          AppCompactButton(
            label: '다시 시도',
            icon: Icons.refresh,
            tonal: true,
            onPressed: _sending ? null : () => _retry(m),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 입력창 — 하단 고정 pill + 원형 전송 버튼
  // ══════════════════════════════════════════════════════════════════════════

  Widget _inputBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenPadding,
          AppSpacing.sm,
          AppSpacing.screenPadding,
          AppSpacing.md,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputCtrl,
                textInputAction: TextInputAction.send,
                onSubmitted: _ask,
                maxLength: kChatMaxChars,
                minLines: 1,
                maxLines: 4,
                style: AppTypography.body.copyWith(color: AppColors.textStrong),
                decoration: InputDecoration(
                  hintText: '궁금한 걸 물어보세요',
                  counterText: '',
                  filled: true,
                  fillColor: AppColors.surface,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xl,
                    vertical: AppSpacing.md,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    borderSide: const BorderSide(color: AppColors.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            // 전송 중에는 잠근다 — 두 번 눌러 두 번 묻는 일이 없게.
            Semantics(
              button: true,
              label: _sending ? '답을 기다리는 중' : '질문 보내기',
              child: Material(
                color: _sending ? AppColors.buttonDisabledBg : AppColors.primary,
                shape: const CircleBorder(),
                child: InkWell(
                  onTap: _sending ? null : () => _ask(_inputCtrl.text),
                  customBorder: const CircleBorder(),
                  child: SizedBox(
                    width: AppSize.minTouchTarget,
                    height: AppSize.minTouchTarget,
                    child: Icon(
                      _sending ? Icons.more_horiz : Icons.arrow_upward,
                      size: AppSize.iconSm,
                      color: _sending ? AppColors.buttonDisabledFg : Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `**굵게**` 표시 → 글 조각들. 짝이 안 맞는 `**`는 그냥 글자로 둔다(서버가 이미 정리하지만 한 번 더).
List<InlineSpan> boldSpans(String text, {required TextStyle base, required TextStyle bold}) {
  final spans = <InlineSpan>[];
  final re = RegExp(r'\*\*(.+?)\*\*', dotAll: true);
  int cursor = 0;
  for (final m in re.allMatches(text)) {
    if (m.start > cursor) spans.add(TextSpan(text: text.substring(cursor, m.start), style: base));
    spans.add(TextSpan(text: m.group(1), style: bold));
    cursor = m.end;
  }
  if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor), style: base));
  return spans;
}
