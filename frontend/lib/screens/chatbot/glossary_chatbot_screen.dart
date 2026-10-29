/// S-12 챗봇 (탭) — **대화는 AI(Solar)가, 판정은 리포트만** (2026-10-24 대화형 → 같은 날 화면 리디자인 → 같은 날 v2).
///
/// 앱이 지키는 것:
/// ⑴ **문구를 지어내지 않는다.** 답·기본 문장 모두 서버가 준다. 앱은 최근 대화를 통째로 보내고 그리기만 한다.
/// ⑵ **챗봇만 둔다** — 말풍선 밑 출처 라벨·리포트 버튼·용어 밑줄 없음. AI가 답한다는 사실은 빈 화면 한 줄로 알린다.
/// ⑶ 디자인 시스템 토큰만 쓴다(새 색·크기 없음). 리디자인 스펙: Claude Design 협의안(2026-10-24).
///    - 내 말풍선 primary 바탕 · AI 말풍선 흰 바탕 + 세이프가 위에서 "답을 들고" 있음
///    - 답 글은 덩어리로 나눠 그린다(문단 · 번호 목록 · 점 목록 · **굵게** · 기관 주소 칸) — `chat_answer_parser.dart`
///    - 기다리는 중엔 세이프가 달린다(`chat_mascot.dart`)
/// ⑷ v2 (2026-10-24):
///    - 꾹 누르기 = 바로 글자 선택 + 칩 [복사][답글] — `chat_selection.dart` (메뉴 카드 없음)
///    - AI 말풍선을 왼쪽으로 밀면 그 답을 인용해 이어 묻기 — `chat_swipe.dart`, 인용 띠·칩 — `chat_quote.dart`
///    - 지난 대화 서랍(이 폰에만 저장) — `chat_history_drawer.dart`, 저장소 `ChatHistoryRepository`
///    - 화면 모양(인용 칩 + 질문)과 서버에 보내는 글은 나눈다 — `chat_history_logic.dart`의 `buildChatTurns`
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/mascot_safe.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/chat_history.dart';
import '../../repositories/analysis_repository.dart';
import '../../repositories/chat_history_repository.dart';
import '../../repositories/content_repository.dart';
import '../../services/api_client.dart';
import '../../state/chat_handoff.dart';
import '../../state/report_focus.dart';
import 'chat_answer_parser.dart';
import 'chat_history_drawer.dart';
import 'chat_history_logic.dart';
import 'chat_mascot.dart';
import 'chat_quote.dart';
import 'chat_selection.dart';
import 'chat_swipe.dart';

/// 답을 기다리는 동안 띄우는 한 줄 — **상수로 둔다**(촬영 중에 바꿀 수 있게).
const String kChatLoadingMessage = '답을 쓰고 있어요…';

/// 빈 화면 안내 — AI가 답한다는 사실을 숨기지 않는다.
/// 빈 화면 안내 줄 — 앞에 Upstage 로고 이미지가 붙는다(회사 이름은 로고로, 2026-10-24)
const String kChatAiNotice = 'Solar Pro 2가 쉬운 말로 답해요';
const String kUpstageLogoAsset = 'assets/brand/upstage_logo.png';

/// 연결 실패 안내 (경고색·에러 아이콘 없이)
const String kChatFailedMessage = '연결이 잠깐 끊겼어요.';

/// 한 번에 보낼 수 있는 글자 수 (서버 상한 500보다 넉넉히 안쪽 — 인용 안내를 붙여도 500 안)
const int kChatMaxChars = 300;

/// 말풍선 최대 폭 — 화면 폭의 비율
const double kBubbleWidthFactor = 0.75;

/// 평소 입력칸 힌트
const String kChatHint = '궁금한 걸 물어보세요';

/// 빈 화면 추천 질문 — 누르면 그 문장을 바로 보낸다 (리디자인 2026-10-24: 단어 칩 → 질문 문장 4개)
const List<String> kSuggestedQuestions = [
  '등기부등본은 어떻게 떼요?',
  '근저당권이 뭔지 알려 주세요',
  '전세가율은 어떻게 계산해요?',
  '확정일자는 언제 받아요?',
];

/// 미는 동안 말풍선 그림자 (그림자 색만 하드코딩 예외 — 검정 10%)
const List<BoxShadow> kLiftedShadow = [
  BoxShadow(color: Color(0x1A000000), offset: Offset(0, 6), blurRadius: 16),
];

enum _Kind { user, bot, loading, failed }

class _Msg {
  const _Msg.user(this.id, this.text, {this.quote})
    : kind = _Kind.user,
      retryQuery = null,
      retryQuote = null;

  const _Msg.bot(this.id, this.text)
    : kind = _Kind.bot,
      quote = null,
      retryQuery = null,
      retryQuote = null;

  const _Msg.loading()
    : id = 'loading',
      text = '',
      kind = _Kind.loading,
      quote = null,
      retryQuery = null,
      retryQuote = null;

  /// 연결 실패 — [다시 시도]가 재질문할 원문(과 인용)을 들고 있다
  const _Msg.failed(this.id, this.text, this.retryQuery, this.retryQuote)
    : kind = _Kind.failed,
      quote = null;

  final String id;
  final _Kind kind;

  /// 내 질문 / 답 글 / 실패 안내
  final String text;

  /// 내 질문에만 — 인용
  final ChatQuote? quote;
  final String? retryQuery;
  final ChatQuote? retryQuote;

  bool get isUser => kind == _Kind.user;
  bool get isLoading => kind == _Kind.loading;
}

class GlossaryChatbotScreen extends StatefulWidget {
  const GlossaryChatbotScreen({super.key});

  @override
  State<GlossaryChatbotScreen> createState() => _GlossaryChatbotScreenState();
}

class _GlossaryChatbotScreenState extends State<GlossaryChatbotScreen> {
  final _inputCtrl = TextEditingController();
  final _inputFocus = FocusNode();
  final _scrollCtrl = ScrollController();
  final List<_Msg> _messages = [];

  /// 말풍선 위치 — 인용 칩을 누르면 원래 답으로 스크롤
  final Map<String, GlobalKey> _keys = {};

  late final ChatHistoryRepository _history;

  bool _sending = false;

  /// 지금 대화 — 첫 질문을 보낼 때 생긴다
  String? _convId;
  String _convTitle = '';
  DateTime? _convCreated;

  /// 아직 저장 안 한 말이 있다
  bool _dirty = false;

  /// 인용 중 (입력칸 위 인용 띠)
  ChatQuote? _quoting;

  /// 인용 칩을 눌러 1초 반짝이는 답
  String? _flashId;
  Timer? _flashTimer;

  /// "복사했어요"
  bool _toast = false;
  Timer? _toastTimer;

  /// 첫 안내 — 밀기(한 번만) · 서랍 점
  bool _swipeHintSeen = true;
  String? _nudgeId;
  bool _drawerDot = false;

  int _seq = 0;

  /// 키보드 높이 — 키보드가 올라오면 마지막 답이 가려지지 않게 맨 아래로 내린다.
  double _lastInset = 0;

  /// 말풍선 최대 폭 — `_conversation`의 LayoutBuilder가 정한다(목록이 실제로 받은 폭 기준).
  double _bubbleMax = 270;

  @override
  void initState() {
    super.initState();
    try {
      _history = context.read<ChatHistoryRepository>();
    } on ProviderNotFoundException {
      _history = MemoryChatHistoryRepository();
    }
    _loadHints();
    _fillReportFocus();
    // 다른 화면에서 꾹 눌러 [챗봇에 묻기]로 넘긴 글 (2026-10-26) — 인용 띠로 받아 이어 묻게 한다
    ChatHandoff.pending.addListener(_takeHandoff);
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeHandoff());
  }

  void _takeHandoff() {
    final text = ChatHandoff.pending.value;
    if (text == null || !mounted) return;
    ChatHandoff.pending.value = null;
    _startQuote('', text);
  }

  /// 리포트를 아직 안 열었으면 **가장 최근 리포트**를 챗봇이 알게 한다 (2026-10-26). 실패하면 리포트 없이 답한다.
  Future<void> _fillReportFocus() async {
    if (ReportFocus.current.value != null) return;
    try {
      final history = await context.read<AnalysisRepository>().getHistory();
      if (history.isNotEmpty && ReportFocus.current.value == null) {
        ReportFocus.current.value = ReportRef(
          history.first.id,
          history.first.alias,
        );
      }
    } catch (_) {
      // 기록을 못 불러와도 챗봇은 일반 답으로 동작한다
    }
  }

  Future<void> _loadHints() async {
    final swipe = await _history.hintSeen(ChatHint.swipe);
    final dot = await _history.hintSeen(ChatHint.drawerDot);
    final opened = await _history.hintSeen(ChatHint.drawerOpened);
    if (!mounted) return;
    setState(() {
      _swipeHintSeen = swipe;
      _drawerDot = dot && !opened;
    });
  }

  @override
  void dispose() {
    ChatHandoff.pending.removeListener(_takeHandoff);
    _flashTimer?.cancel();
    _toastTimer?.cancel();
    _inputCtrl.dispose();
    _inputFocus.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${_seq++}';

  GlobalKey _keyFor(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  /// 저장할 말 — 질문과 답만(로딩·실패 줄은 빼고)
  List<ChatEntry> get _entries => [
    for (final m in _messages)
      if (m.kind == _Kind.user)
        ChatEntry(id: m.id, isUser: true, text: m.text, quote: m.quote)
      else if (m.kind == _Kind.bot)
        ChatEntry(id: m.id, isUser: false, text: m.text),
  ];

  // ══════════════════════════════════════════════════════════════════════════
  // 묻기 · 다시 시도 · 저장
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _ask(String query, {ChatQuote? quote}) async {
    final q = query.trim();
    if (q.isEmpty || _sending) return;
    setState(() {
      _convId ??= _newId();
      _convCreated ??= DateTime.now();
      if (_convTitle.isEmpty) _convTitle = chatTitleFrom(q);
      _messages.add(_Msg.user(_newId(), q, quote: quote));
      _messages.add(const _Msg.loading());
      _inputCtrl.clear();
      _quoting = null;
      _sending = true;
      _dirty = true;
    });
    _scrollToBottom();

    final convAtSend = _convId;
    late final _Msg reply;
    var ok = false;
    try {
      // 지금 보는(또는 가장 최근) 리포트를 함께 보낸다 — 서버가 그 리포트를 알고 답한다(판정은 바꾸지 않음)
      final answer = await context.read<ContentRepository>().chat(
        buildChatTurns(_entries),
        reportId: ReportFocus.current.value?.id,
      );
      reply = _Msg.bot(_newId(), answer.answer);
      ok = true;
    } on ApiException catch (e) {
      // 429(질문 너무 많음)는 서버 문장 그대로, 그 밖은 연결 문제로 본다
      reply = _Msg.failed(
        _newId(),
        e.statusCode == 429 ? e.message : kChatFailedMessage,
        q,
        quote,
      );
    } catch (_) {
      reply = _Msg.failed(_newId(), kChatFailedMessage, q, quote);
    }
    if (!mounted) return;
    if (convAtSend != _convId) {
      // 기다리는 사이 다른 대화로 바뀌었다(지금은 막혀 있지만 혹시) — 답은 버리고 보내기만 다시 켠다
      setState(() => _sending = false);
      return;
    }
    final nudge =
        ok && !_swipeHintSeen && !MediaQuery.disableAnimationsOf(context);
    setState(() {
      _messages.removeWhere((m) => m.isLoading);
      _messages.add(reply);
      _sending = false;
      if (nudge) _nudgeId = reply.id;
    });
    if (ok && !_swipeHintSeen) {
      _swipeHintSeen = true;
      unawaited(_history.markHint(ChatHint.swipe));
    }
    _scrollToBottom();
    await _persist();
  }

  /// [다시 시도] — 실패 줄과 그 질문을 지우고 같은 질문(과 인용)을 다시 보낸다(대화에 같은 질문이 두 번 남지 않게).
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
    _ask(q, quote: failed.retryQuote);
  }

  /// 지금 대화를 지난 대화로 저장 (이어 물으면 마지막 시각이 바뀌어 목록 맨 위로)
  Future<void> _persist() async {
    final id = _convId;
    // 답을 못 받은 마지막 질문은 저장하지 않는다 — 나중에 열면 [다시 시도] 없이 질문만 덩그러니 남는다
    final entries = List.of(_entries);
    while (entries.isNotEmpty && entries.last.isUser) {
      entries.removeLast();
    }
    if (id == null || entries.isEmpty || !_dirty) return;
    _dirty = false;
    final now = DateTime.now();
    await _history.save(
      ChatConversation(
        id: id,
        title: _convTitle.isEmpty
            ? chatTitleFrom(entries.first.text)
            : _convTitle,
        createdAt: _convCreated ?? now,
        updatedAt: now,
        entries: entries,
      ),
    );
  }

  void _clearScreen() {
    _messages.clear();
    _keys.clear();
    _inputCtrl.clear();
    _quoting = null;
    _flashId = null;
    _convId = null;
    _convTitle = '';
    _convCreated = null;
    _dirty = false;
  }

  /// [새 대화] — 지금 대화는 지난 대화로 넘기고 빈 화면으로.
  Future<void> _newChat() async {
    final hadChat = _entries.isNotEmpty;
    await _persist();
    if (!mounted) return;
    setState(_clearScreen);
    if (hadChat && !await _history.hintSeen(ChatHint.drawerDot)) {
      await _history.markHint(ChatHint.drawerDot);
      if (mounted) setState(() => _drawerDot = true);
    }
  }

  /// 지난 대화를 연다 — 그대로 다시 그리고, 이어 물으면 그 대화 끝에 붙는다
  void _openConversation(ChatConversation c) {
    setState(() {
      _clearScreen();
      _convId = c.id;
      _convTitle = c.title;
      _convCreated = c.createdAt;
      for (final e in c.entries) {
        _messages.add(
          e.isUser
              ? _Msg.user(e.id, e.text, quote: e.quote)
              : _Msg.bot(e.id, e.text),
        );
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients)
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
    });
  }

  Future<void> _openDrawer() async {
    if (_drawerDot) {
      setState(() => _drawerDot = false);
      unawaited(_history.markHint(ChatHint.drawerOpened));
    }
    await _persist();
    if (!mounted) return;
    final result = await showChatHistoryDrawer(
      context,
      repository: _history,
      currentId: _convId,
      onRenamed: (id, title) {
        if (mounted && id == _convId) setState(() => _convTitle = title);
      },
      onDeleted: (id) {
        if (mounted && id == _convId) setState(_clearScreen);
      },
    );
    if (!mounted) return;
    switch (result) {
      case OpenChat(:final conversation):
        _openConversation(conversation);
      case StartNewChat():
        await _newChat();
      case null:
        break;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 인용 · 복사 · 반짝
  // ══════════════════════════════════════════════════════════════════════════

  void _startQuote(String sourceId, String text) {
    setState(() => _quoting = ChatQuote(text: text, sourceId: sourceId));
    _inputFocus.requestFocus();
  }

  void _cancelQuote() => setState(() => _quoting = null);

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _toastTimer?.cancel();
    setState(() => _toast = true);
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toast = false);
    });
  }

  /// 인용 칩 → 원래 답으로 스크롤 + 그 답 테두리 1초 반짝
  void _jumpTo(String id) {
    final ctx = _keys[id]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      alignment: 0.1,
    );
    _flashTimer?.cancel();
    setState(() => _flashId = id);
    _flashTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _flashId = null);
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

  // ══════════════════════════════════════════════════════════════════════════
  // 화면
  // ══════════════════════════════════════════════════════════════════════════

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
        leading: _historyButton(),
        actions: [
          if (_messages.isNotEmpty && !_sending)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: IconButton(
                tooltip: '새 대화',
                icon: Icon(
                  Icons.refresh,
                  size: AppSize.iconMd,
                  color: AppColorsNext.textStrong,
                ),
                onPressed: _newChat,
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: _messages.isEmpty ? _emptyState() : _conversation(),
                ),
                // "복사했어요" — 입력 줄 위 8
                Positioned(
                  left: AppSpacing.screenPadding,
                  right: AppSpacing.screenPadding,
                  bottom: AppSpacing.sm,
                  child: Center(child: CopiedToast(visible: _toast)),
                ),
              ],
            ),
          ),
          _inputBar(),
        ],
      ),
    );
  }

  /// [지난 대화] — 시계 + 되감기 화살표. 처음 기록이 생기면 오른쪽 위 점 8.
  Widget _historyButton() {
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.sm),
      child: IconButton(
        tooltip: '지난 대화',
        color: AppColorsNext.textStrong,
        disabledColor: AppColorsNext.textMuted,
        onPressed: _sending ? null : _openDrawer,
        icon: Stack(
          clipBehavior: Clip.none,
          children: [
            const Icon(Icons.history, size: AppSize.iconMd),
            if (_drawerDot)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  key: const ValueKey('drawer-dot'),
                  width: AppSpacing.sm,
                  height: AppSpacing.sm,
                  decoration: BoxDecoration(
                    color: AppColors.primaryBright,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ① 빈 화면 — 세이프 + 제목 + AI 안내 + 추천 질문 4개
  // ══════════════════════════════════════════════════════════════════════════

  Widget _emptyState() {
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenPadding,
          vertical: AppSpacing.xxl,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: (box.maxHeight - AppSpacing.xxl * 2)
                .clamp(0.0, double.infinity)
                .toDouble(),
          ),
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
                '전세 · 부동산 · 리포트, 뭐든 물어보세요!',
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
                  AppText(
                    kChatAiNotice,
                    textAlign: TextAlign.center,
                    style: AppTypographyNext.caption,
                  ),
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
        side: BorderSide(color: AppColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _sending ? null : () => _ask(q),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSize.minTouchTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: AppText(
                    q,
                    style: AppTypographyNext.body.copyWith(
                      color: AppColorsNext.textStrong,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Icon(
                  Icons.north_east,
                  size: AppSize.iconSm,
                  color: AppColors.primary,
                ),
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

  /// 말풍선 전부를 한 번에 그린다(대화당 최대 100개) — 인용 칩이 화면 밖의 답으로도 스크롤할 수 있게.
  Widget _conversation() {
    return LayoutBuilder(
      builder: (context, box) {
        _bubbleMax = box.maxWidth * kBubbleWidthFactor;
        return SingleChildScrollView(
          controller: _scrollCtrl,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenPadding,
            AppSpacing.lg,
            AppSpacing.screenPadding,
            AppSpacing.xl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < _messages.length; i++)
                KeyedSubtree(
                  key: _keyFor(_messages[i].id),
                  child: Padding(
                    // 말하는 사람이 바뀌면 24, 같은 사람이 이어지면 8
                    padding: EdgeInsets.only(
                      top: i == 0
                          ? 0.0
                          : (_messages[i - 1].isUser == _messages[i].isUser
                                ? AppSpacing.sm
                                : AppSpacing.xxl),
                    ),
                    child: _message(
                      _messages[i],
                      last: i == _messages.length - 1,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _message(_Msg m, {required bool last}) => switch (m.kind) {
    _Kind.user => _userBubble(m),
    _Kind.loading => Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _bubbleMax),
        child: _botFrame(running: true, content: _typingLine()),
      ),
    ),
    _Kind.bot => Semantics(liveRegion: last, child: _botMessage(m)),
    _Kind.failed => _failedNotice(m),
  };

  /// 내 말풍선 — primary 바탕, 흰 글자, 오른쪽 아래 모서리만 작게. 인용해서 물었으면 맨 위에 인용 칩.
  /// 꾹 누르면 [복사]만 (밀기 없음).
  Widget _userBubble(_Msg m) {
    final quote = m.quote;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _bubbleMax),
        child: Container(
          key: ValueKey('user-bubble-${m.id}'),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(AppRadius.xl),
              topRight: Radius.circular(AppRadius.xl),
              bottomLeft: Radius.circular(AppRadius.xl),
              bottomRight: Radius.circular(AppRadius.sm),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (quote != null) ...[
                QuoteChip(
                  quote: quote.text,
                  onTap: () => _jumpTo(quote.sourceId),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              ChatSelectableText(
                onCopy: _copy,
                // 흰 글자가 묻히지 않게 내 말풍선 선택 바탕은 primaryDeep
                selectionColor: AppColors.primaryDeep,
                child: AppText(
                  m.text,
                  style: AppTypographyNext.body.copyWith(
                    color: AppColors.surface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// AI 답 말풍선 — 꾹 누르면 줄 선택 + [복사][답글], 왼쪽으로 밀면 답 전체 인용.
  Widget _botMessage(_Msg m) {
    final highlighted = _quoting?.sourceId == m.id || _flashId == m.id;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _bubbleMax),
        child: SwipeToQuote(
          key: ValueKey('bot-swipe-${m.id}'),
          topInset: kSafeRise,
          nudge: _nudgeId == m.id,
          onQuote: () => _startQuote(m.id, m.text),
          builder: (context, lifted) => _botFrame(
            running: false,
            lifted: lifted,
            highlighted: highlighted,
            content: ChatSelectableText(
              onCopy: _copy,
              onReply: (text) => _startQuote(m.id, text),
              child: _answer(m.text),
            ),
          ),
        ),
      ),
    );
  }

  /// AI 말풍선 틀 — 흰 바탕 + 위에 세이프(답 들기 / 달리기). 인용 중·반짝일 땐 테두리 primaryBright 2.
  Widget _botFrame({
    required bool running,
    required Widget content,
    bool lifted = false,
    bool highlighted = false,
  }) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: kSafeRise),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: running
                ? const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.md,
                  )
                : const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: highlighted
                  ? Border.all(color: AppColors.primaryBright, width: 2)
                  : Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(AppRadius.xl),
              boxShadow: lifted ? kLiftedShadow : null,
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
            child: running
                ? const SafeRunning(key: ValueKey('run'))
                : const SafeHold(key: ValueKey('hold')),
          ),
        ),
        // 이름 줄 '세이프'는 뺐다(2026-10-24, 규혁) — 마스코트만으로 누가 답하는지 보인다
      ],
    );
  }

  /// ③ 점 3개 + "답을 쓰고 있어요…"
  Widget _typingLine() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _TypingDots(),
        const SizedBox(width: AppSpacing.md),
        Flexible(
          child: AppText(kChatLoadingMessage, style: AppTypographyNext.caption),
        ),
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
              children: [
                for (final line in blocks[b].lines) _inlineText(line, body),
              ],
            ),
            ChatBlockKind.numbered => _listBlock(
              blocks[b].lines,
              (i) => _NumberBadge(number: blocks[b].numbers[i]),
              body,
            ),
            ChatBlockKind.bullets => _listBlock(
              blocks[b].lines,
              (_) => const _BulletDot(),
              body,
            ),
          },
        ],
      ],
    );
  }

  Widget _listBlock(
    List<String> items,
    Widget Function(int) marker,
    TextStyle body,
  ) {
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
    final bold = AppTypographyNext.bodyStrong.copyWith(
      color: AppColors.primaryDeep,
    );
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

  /// ④ 연결 실패 — 세이프 말풍선이 아니라 가운데 알림. 경고색·에러 아이콘 없음. 꾹 누르기·밀기 없음.
  Widget _failedNotice(_Msg m) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppText(
            m.text,
            textAlign: TextAlign.center,
            style: AppTypographyNext.body,
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            height: AppSize.minTouchTarget,
            child: OutlinedButton(
              onPressed: _sending ? null : () => _retry(m),
              style: OutlinedButton.styleFrom(
                backgroundColor: AppColors.surface,
                foregroundColor: AppColors.primary,
                side: BorderSide(color: AppColors.primary),
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
  // 입력 줄 — (인용 띠) + pill 입력칸(엔터=줄바꿈, 4줄까지) + 원형 ↑ 보내기
  // ══════════════════════════════════════════════════════════════════════════

  Widget _inputBar() {
    final quoting = _quoting;
    final enabledSide = quoting != null
        ? BorderSide(color: AppColors.primary, width: 2)
        : BorderSide(color: AppColors.line);
    return Container(
      color: AppColors.background,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenPadding,
            vertical: AppSpacing.md,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (quoting != null) ...[
                QuoteBand(quote: quoting.text, onCancel: _cancelQuote),
                const SizedBox(height: AppSpacing.sm),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputCtrl,
                      focusNode: _inputFocus,
                      // 엔터 = 줄바꿈. 보내기는 오른쪽 ↑ 버튼으로만.
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      maxLength: kChatMaxChars,
                      minLines: 1,
                      maxLines: 4,
                      style: AppTypographyNext.body,
                      decoration: InputDecoration(
                        hintText: quoting != null ? kQuoteHint : kChatHint,
                        hintStyle: AppTypographyNext.body.copyWith(
                          color: AppColorsNext.textMuted,
                        ),
                        counterText: '',
                        filled: true,
                        fillColor: AppColors.surface,
                        isDense: true,
                        constraints: const BoxConstraints(minHeight: 52),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xl,
                          vertical: AppSpacing.md,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                          borderSide: enabledSide,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                          borderSide: BorderSide(
                            color: AppColors.primary,
                            width: 2,
                          ),
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
                          onTap: _sending
                              ? null
                              : () => _ask(_inputCtrl.text, quote: _quoting),
                          customBorder: const CircleBorder(),
                          child: SizedBox(
                            width: AppSize.minTouchTarget,
                            height: AppSize.minTouchTarget,
                            child: Icon(
                              Icons.arrow_upward,
                              size: AppSize.iconMd,
                              color: _sending
                                  ? AppColorsNext.textMuted
                                  : AppColors.surface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
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
        decoration: BoxDecoration(
          color: AppColors.primarySoft,
          shape: BoxShape.circle,
        ),
        child: Text(
          '$number',
          style: AppTypographyNext.caption.copyWith(
            color: AppColors.primary,
            height: 1,
          ),
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
    final lineHeight =
        MediaQuery.textScalerOf(context).scale(body.fontSize!) *
        (body.height ?? 1);
    return SizedBox(
      width: 24,
      height: lineHeight,
      child: Center(
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: AppColors.primaryBright,
            shape: BoxShape.circle,
          ),
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
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
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

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
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
                  decoration: BoxDecoration(
                    color: AppColors.primaryBright,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
