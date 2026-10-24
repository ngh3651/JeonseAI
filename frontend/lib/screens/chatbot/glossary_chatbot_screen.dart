/// S-12 챗봇 (탭) — **대화는 AI(Solar)가, 판정은 리포트만** (2026-10-24 대화형 → 같은 날 화면 리디자인).
///
/// 앱이 지키는 것:
/// ⑴ **문구를 지어내지 않는다.** 답·기본 문장 모두 서버가 준다. 앱은 최근 대화를 통째로 보내고 그리기만 한다.
/// ⑵ **챗봇만 둔다** — 말풍선 밑 출처 라벨·리포트 버튼·용어 밑줄 없음. AI가 답한다는 사실은 빈 화면 한 줄로 알린다.
/// ⑶ 디자인 시스템 토큰만 쓴다(새 색·크기 없음). 리디자인 스펙: Claude Design 협의안(2026-10-24).
///    - 내 말풍선 primary 바탕 · AI 말풍선 흰 바탕 + 세이프가 위에서 "답을 들고" 있음
///    - 답 글은 덩어리로 나눠 그린다(문단 · 번호 목록 · 점 목록 · **굵게** · 기관 주소 칸) — `chat_answer_parser.dart`
///    - 기다리는 중엔 세이프가 달린다(`chat_mascot.dart`)
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/mascot_safe.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/content_models.dart';
import '../../repositories/content_repository.dart';
import '../../services/api_client.dart';
import 'chat_answer_parser.dart';
import 'chat_mascot.dart';

/// 답을 기다리는 동안 띄우는 한 줄 — **상수로 둔다**(촬영 중에 바꿀 수 있게).
const String kChatLoadingMessage = '답을 쓰고 있어요…';

/// 빈 화면 안내 — AI가 답한다는 사실을 숨기지 않는다.
/// 빈 화면 안내 줄 — 앞에 Upstage 로고 이미지가 붙는다(회사 이름은 로고로, 2026-10-24)
const String kChatAiNotice = 'Solar Pro 2가 쉬운 말로 답해요';
const String kUpstageLogoAsset = 'assets/brand/upstage_logo.png';

/// 연결 실패 안내 (경고색·에러 아이콘 없이)
const String kChatFailedMessage = '연결이 잠깐 끊겼어요.';

/// 한 번에 보낼 수 있는 글자 수 (서버 상한 500보다 넉넉히 안쪽)
const int kChatMaxChars = 300;

/// 말풍선 최대 폭 — 화면 폭의 비율
const double kBubbleWidthFactor = 0.75;

/// 빈 화면 추천 질문 — 누르면 그 문장을 바로 보낸다 (리디자인 2026-10-24: 단어 칩 → 질문 문장 4개)
const List<String> kSuggestedQuestions = [
  '등기부등본은 어떻게 떼요?',
  '근저당권이 뭔지 알려 주세요',
  '전세가율은 어떻게 계산해요?',
  '확정일자는 언제 받아요?',
];

class _Msg {
  const _Msg.user(this.text) : reply = null, isUser = true, isLoading = false, retryQuery = null;

  const _Msg.bot(ChatReply this.reply)
    : text = '',
      isUser = false,
      isLoading = false,
      retryQuery = null;

  const _Msg.loading() : text = '', reply = null, isUser = false, isLoading = true, retryQuery = null;

  /// 연결 실패 — [다시 시도]가 재질문할 원문을 들고 있다
  const _Msg.failed(this.text, this.retryQuery) : reply = null, isUser = false, isLoading = false;

  final String text;
  final ChatReply? reply;
  final bool isUser;
  final bool isLoading;
  final String? retryQuery;

  bool get isFailed => !isUser && !isLoading && reply == null;
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

  /// 키보드 높이 — 키보드가 올라오면 마지막 답이 가려지지 않게 맨 아래로 내린다.
  double _lastInset = 0;

  /// 말풍선 최대 폭 — `_conversation`의 LayoutBuilder가 정한다(목록이 실제로 받은 폭 기준).
  double _bubbleMax = 270;

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
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
      reply = _Msg.failed(e.statusCode == 429 ? e.message : kChatFailedMessage, q);
    } catch (_) {
      reply = _Msg.failed(kChatFailedMessage, q);
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
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset > _lastInset && _messages.isNotEmpty) _scrollToBottom();
    _lastInset = inset;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: AppText('챗봇', style: AppTypographyNext.title),
        centerTitle: true,
        automaticallyImplyLeading: false,
        actions: [
          if (_messages.isNotEmpty && !_sending)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: IconButton(
                tooltip: '새 대화',
                icon: const Icon(Icons.refresh, size: AppSize.iconMd, color: AppColorsNext.textStrong),
                onPressed: _reset,
              ),
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
  // ① 빈 화면 — 세이프 + 제목 + AI 안내 + 추천 질문 4개
  // ══════════════════════════════════════════════════════════════════════════

  Widget _emptyState() {
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding, vertical: AppSpacing.xxl),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: (box.maxHeight - AppSpacing.xxl * 2).clamp(0.0, double.infinity).toDouble()),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 96,
                  height: 96,
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppColors.primarySoft,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.line),
                  ),
                  child: const MascotSafe(size: 80, state: MascotState.tip),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppText(
                '전세·부동산, 뭐든 물어보세요',
                textAlign: TextAlign.center,
                style: AppTypographyNext.title,
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  Image.asset(
                    kUpstageLogoAsset,
                    height: MediaQuery.textScalerOf(context).scale(18),
                    semanticLabel: 'Upstage',
                  ),
                  AppText(kChatAiNotice, textAlign: TextAlign.center, style: AppTypographyNext.caption),
                ],
              ),
              const SizedBox(height: AppSpacing.xxl),
              for (int i = 0; i < kSuggestedQuestions.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpacing.sm),
                _questionCard(kSuggestedQuestions[i]),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _questionCard(String q) {
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: const BorderSide(color: AppColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _sending ? null : () => _ask(q),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSize.minTouchTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
            child: Row(
              children: [
                Expanded(child: AppText(q, style: AppTypographyNext.body.copyWith(color: AppColorsNext.textStrong))),
                const SizedBox(width: AppSpacing.sm),
                const Icon(Icons.north_east, size: AppSize.iconSm, color: AppColors.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ② 대화 · ③ 기다리는 중 · ④ 연결 실패
  // ══════════════════════════════════════════════════════════════════════════

  Widget _conversation() {
    return LayoutBuilder(
      builder: (context, box) {
        _bubbleMax = box.maxWidth * kBubbleWidthFactor;
        return ListView.builder(
          controller: _scrollCtrl,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenPadding,
            AppSpacing.lg,
            AppSpacing.screenPadding,
            AppSpacing.xl,
          ),
          itemCount: _messages.length,
          itemBuilder: (context, i) {
            final m = _messages[i];
            // 말하는 사람이 바뀌면 24, 같은 사람이 이어지면 8
            final gap = i == 0 ? 0.0 : (_messages[i - 1].isUser == m.isUser ? AppSpacing.sm : AppSpacing.xxl);
            final Widget child;
            if (m.isUser) {
              child = _userBubble(m.text);
            } else if (m.isLoading) {
              child = _botBubble(running: true, content: _typingLine());
            } else if (m.reply != null) {
              child = Semantics(
                liveRegion: i == _messages.length - 1,
                child: _botBubble(running: false, content: _answer(m.reply!.answer)),
              );
            } else {
              child = _failedNotice(m);
            }
            return Padding(padding: EdgeInsets.only(top: gap), child: child);
          },
        );
      },
    );
  }

  /// 내 말풍선 — primary 바탕, 흰 글자, 오른쪽 아래 모서리만 작게
  Widget _userBubble(String text) {
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _bubbleMax),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          decoration: const BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(AppRadius.xl),
              topRight: Radius.circular(AppRadius.xl),
              bottomLeft: Radius.circular(AppRadius.xl),
              bottomRight: Radius.circular(AppRadius.sm),
            ),
          ),
          child: AppText(text, style: AppTypographyNext.body.copyWith(color: AppColors.surface)),
        ),
      ),
    );
  }

  /// AI 말풍선 — 흰 바탕 + 위에 세이프(답 들기 / 달리기)
  Widget _botBubble({required bool running, required Widget content}) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _bubbleMax),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: kSafeRise),
              child: Container(
                padding: running
                    ? const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md)
                    : const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.line),
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                ),
                child: content,
              ),
            ),
            // 세이프 — 말풍선 왼쪽 끝에서 16 안쪽, 아래 끝이 말풍선 윗선에 걸친다(답 들기는 앞발이 테두리를 덮는다)
            Positioned(
              left: AppSpacing.lg,
              top: 0,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: running ? const SafeRunning(key: ValueKey('run')) : const SafeHold(key: ValueKey('hold')),
              ),
            ),
            // 이름 줄 '세이프'는 뺐다(2026-10-24, 규혁) — 마스코트만으로 누가 답하는지 보인다
          ],
        ),
      ),
    );
  }

  /// ③ 점 3개 + "답을 쓰고 있어요…"
  Widget _typingLine() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _TypingDots(),
        const SizedBox(width: AppSpacing.md),
        Flexible(child: AppText(kChatLoadingMessage, style: AppTypographyNext.caption)),
      ],
    );
  }

  /// 답 글 → 덩어리(문단·번호·점) → 위젯. 덩어리 사이 12.
  Widget _answer(String answer) {
    final blocks = parseChatAnswer(answer);
    final body = AppTypographyNext.body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int b = 0; b < blocks.length; b++) ...[
          if (b > 0) const SizedBox(height: AppSpacing.md),
          switch (blocks[b].kind) {
            ChatBlockKind.paragraph => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final line in blocks[b].lines) _inlineText(line, body)],
            ),
            ChatBlockKind.numbered => _listBlock(
              blocks[b].lines,
              (i) => _NumberBadge(number: blocks[b].numbers[i]),
              body,
            ),
            ChatBlockKind.bullets => _listBlock(blocks[b].lines, (_) => const _BulletDot(), body),
          },
        ],
      ],
    );
  }

  Widget _listBlock(List<String> items, Widget Function(int) marker, TextStyle body) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              marker(i),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: _inlineText(items[i], body)),
            ],
          ),
        ],
      ],
    );
  }

  /// 한 줄 — 글 · **굵게**(primaryDeep) · 주소 칸(누를 수 없음, 밑줄 없음)
  Widget _inlineText(String line, TextStyle body) {
    final bold = AppTypographyNext.bodyStrong.copyWith(color: AppColors.primaryDeep);
    return AppText.rich(
      TextSpan(
        style: body,
        children: [
          for (final part in parseChatInline(line))
            switch (part.kind) {
              ChatInlineKind.text => TextSpan(text: part.text, style: body),
              ChatInlineKind.bold => TextSpan(text: part.text, style: bold),
              ChatInlineKind.address => WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: _AddressChip(text: part.text),
              ),
            },
        ],
      ),
    );
  }

  /// ④ 연결 실패 — 세이프 말풍선이 아니라 가운데 알림. 경고색·에러 아이콘 없음.
  Widget _failedNotice(_Msg m) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppText(m.text, textAlign: TextAlign.center, style: AppTypographyNext.body),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            height: AppSize.minTouchTarget,
            child: OutlinedButton(
              onPressed: _sending ? null : () => _retry(m),
              style: OutlinedButton.styleFrom(
                backgroundColor: AppColors.surface,
                foregroundColor: AppColors.primary,
                side: const BorderSide(color: AppColors.primary),
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
                textStyle: AppTypographyNext.button,
              ),
              child: const AppText('다시 시도'),
            ),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 입력 줄 — pill 입력칸(엔터=줄바꿈, 4줄까지) + 원형 ↑ 보내기
  // ══════════════════════════════════════════════════════════════════════════

  Widget _inputBar() {
    return Container(
      color: AppColors.background,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding, vertical: AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _inputCtrl,
                  // 엔터 = 줄바꿈. 보내기는 오른쪽 ↑ 버튼으로만.
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  maxLength: kChatMaxChars,
                  minLines: 1,
                  maxLines: 4,
                  style: AppTypographyNext.body,
                  decoration: InputDecoration(
                    hintText: '궁금한 걸 물어보세요',
                    hintStyle: AppTypographyNext.body.copyWith(color: AppColorsNext.textMuted),
                    counterText: '',
                    filled: true,
                    fillColor: AppColors.surface,
                    isDense: true,
                    constraints: const BoxConstraints(minHeight: 52),
                    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.md),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      borderSide: const BorderSide(color: AppColors.line),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      borderSide: const BorderSide(color: AppColors.primary, width: 2),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              // 입력칸이 한 줄일 때 세로 가운데에 오도록 아래 2 (52 - 48)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Semantics(
                  button: true,
                  enabled: !_sending,
                  label: _sending ? '답을 기다리는 중' : '질문 보내기',
                  child: Material(
                    color: _sending ? AppColors.line : AppColors.primary,
                    shape: const CircleBorder(),
                    child: InkWell(
                      onTap: _sending ? null : () => _ask(_inputCtrl.text),
                      customBorder: const CircleBorder(),
                      child: SizedBox(
                        width: AppSize.minTouchTarget,
                        height: AppSize.minTouchTarget,
                        child: Icon(
                          Icons.arrow_upward,
                          size: AppSize.iconMd,
                          color: _sending ? AppColorsNext.textMuted : AppColors.surface,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 번호 배지 — 원 24(글자 배율 따라 커짐), primarySoft 바탕, 숫자 primary
class _NumberBadge extends StatelessWidget {
  const _NumberBadge({required this.number});

  final int number;

  @override
  Widget build(BuildContext context) {
    final d = MediaQuery.textScalerOf(context).scale(24);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Container(
        width: d,
        height: d,
        alignment: Alignment.center,
        decoration: const BoxDecoration(color: AppColors.primarySoft, shape: BoxShape.circle),
        child: Text(
          '$number',
          style: AppTypographyNext.caption.copyWith(color: AppColors.primary, height: 1),
        ),
      ),
    );
  }
}

/// 점 — 폭 24 칸 가운데 6×6, 칸 높이는 본문 첫 줄 높이
class _BulletDot extends StatelessWidget {
  const _BulletDot();

  @override
  Widget build(BuildContext context) {
    final body = AppTypographyNext.body;
    final lineHeight = MediaQuery.textScalerOf(context).scale(body.fontSize!) * (body.height ?? 1);
    return SizedBox(
      width: 24,
      height: lineHeight,
      child: Center(
        child: Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(color: AppColors.primaryBright, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

/// 기관 주소 칸 — 누를 수 없는 글자(링크처럼 보이지 않게)
class _AddressChip extends StatelessWidget {
  const _AddressChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(AppRadius.sm)),
      child: Text(text, style: AppTypographyNext.caption),
    );
  }
}

/// 기다리는 중 점 3개 — 8×8, 투명도 0.3 → 1 → 0.3, 1.2초 반복, 점마다 0.16초 늦게
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _ctrl.stop();
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double _opacity(int i) {
    final t = (_ctrl.value - i * (160 / 1200)) % 1.0; // 점마다 0.16초 늦게
    final wave = t < 0.5 ? t * 2 : (1 - t) * 2; // 0 → 1 → 0
    return 0.3 + 0.7 * wave;
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: AppSpacing.xs),
              Opacity(
                opacity: _opacity(i),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(color: AppColors.primaryBright, shape: BoxShape.circle),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
