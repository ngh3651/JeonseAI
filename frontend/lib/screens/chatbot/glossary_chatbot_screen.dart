/// S-12 용어 챗봇 (탭) — **어려운 부동산 말을 쉬운 말로** (2026-08-14 AI 연결).
///
/// 무엇이 달라졌나:
/// 예전에는 서버가 사전에서 **부분 문자열**로 용어를 찾아 주는 것이 전부라, 사전에 없는
/// 자연어 질문("집주인이 빚이 많으면 세입자는 어떻게 되나요?")이 **전부 거절**됐다.
/// 이제 서버가 규칙(판정 요구 차단 → 사전 → 도메인 게이트)을 먼저 통과시키고, 그 뒤에만
/// Solar가 문장을 쓴다. 앱은 **그 결과를 그리기만 한다.**
///
/// 앱이 지키는 것 셋:
/// ⑴ **문구를 지어내지 않는다.** 거절 문구까지 서버가 준다(`GlossaryAnswer.answer`).
/// ⑵ **출처를 숨기지 않는다.** 답변 아래 회색 한 줄에 "검수된 용어 사전"/모델명/"준비된 문구".
/// ⑶ **거절이 실패처럼 보이지 않게** 한다 — 경고색·에러 아이콘 없이 평범한 답변 톤 +
///    유도 버튼(이력 있으면 리포트, 없으면 분석).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/mascot_safe.dart';
import '../../design_system/components/term_tooltip_sheet.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/content_models.dart';
import '../../repositories/analysis_repository.dart';
import '../../repositories/content_repository.dart';
import '../common/analyze_gate.dart';

/// 답을 기다리는 동안 띄우는 한 줄 — **상수로 둔다**(촬영 중에 바꿀 수 있게).
const String kChatLoadingMessage = '쉬운 말로 풀어보고 있어요';

/// 빈 화면에 먼저 보여줄 추천 칩 6개 — **촬영 대본에 쓰는 순서 그대로**.
///
/// ⚠ 서버가 실제로 내려준 것만 보여준다. `대항력`은 지금 **검수 대기**라 서버 응답에
///   없다(`docs/terms-review-queue.md`) — 그 자리는 남은 용어로 채운다. 검수가 끝나
///   응답에 들어오면 이 순서대로 자동으로 앞에 선다.
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
  const _Msg.user(this.text)
    : answer = null,
      isUser = true,
      isLoading = false,
      retryQuery = null;

  const _Msg.bot(GlossaryAnswer this.answer)
    : text = '',
      isUser = false,
      isLoading = false,
      retryQuery = null;

  const _Msg.loading()
    : text = '',
      answer = null,
      isUser = false,
      isLoading = true,
      retryQuery = null;

  /// 네트워크 오류 — [다시 시도]가 재질문할 원문을 들고 있다 (user-scenario §4 S-12)
  const _Msg.failed(this.retryQuery)
    : text = '연결이 불안정해요. 다시 시도해 주세요',
      answer = null,
      isUser = false,
      isLoading = false;

  final String text;
  final GlossaryAnswer? answer;
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

  bool _hasHistory = false;
  bool _sending = false;
  bool _showAllChips = false;
  List<GlossaryTerm> _terms = const [];

  @override
  void initState() {
    super.initState();
    // 범위 밖 유도 버튼 분기용 (이력 있음 → 리포트 / 없음 → 분석).
    context
        .read<AnalysisRepository>()
        .getHistory()
        .then((h) {
          if (mounted) setState(() => _hasHistory = h.isNotEmpty);
        })
        .catchError((_) {});
    _loadTerms();
  }

  Future<void> _loadTerms() async {
    try {
      final terms = await context.read<ContentRepository>().glossaryTerms();
      if (mounted) setState(() => _terms = terms);
    } catch (_) {
      // 추천 칩만 비어 보임 — 입력으로는 계속 질문할 수 있다.
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
      final answer = await context.read<ContentRepository>().askGlossary(q);
      reply = _Msg.bot(answer);
    } catch (_) {
      reply = _Msg.failed(q);
    }
    if (!mounted) return;
    setState(() {
      _messages.removeWhere((m) => m.isLoading);
      _messages.add(reply);
      _sending = false;
    });
    _scrollToBottom();
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

  /// 범위 밖 응답의 유도 — 이력 있으면 [내 리포트 보기], 없으면 분석 시작
  /// (비회원은 startAnalysis가 로그인 유도 시트로 연결 — IA §6 S-12).
  void _onOutOfScopeAction() {
    if (_hasHistory) {
      context.go('/my');
    } else {
      startAnalysis(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const AppText('용어 챗봇'),
        automaticallyImplyLeading: false,
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty ? _emptyState() : _conversation(),
          ),
          _inputBar(),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 빈 상태 — 마스코트 + 인사 + 추천 칩 6개
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
          '어려운 부동산 말,\n제가 쉽게 풀어드릴게요',
          textAlign: TextAlign.center,
          style: AppTypography.headline.copyWith(height: 1.35),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppText(
          '궁금한 걸 눌러보거나 직접 물어보세요',
          textAlign: TextAlign.center,
          style: AppTypography.body.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: AppSpacing.xxxl),
        // 2열 그리드 — 칩이 6개일 때 3행. 글자가 커져도 줄바꿈으로 늘어난다.
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
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
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.xl),
      itemBuilder: (context, i) {
        final m = _messages[i];
        if (m.isUser) return _userBubble(m.text);
        if (m.isLoading) return _loadingLine();
        if (m.answer != null) return _answerBlock(m.answer!);
        return _failedLine(m);
      },
    );
  }

  /// 사용자 말풍선 — 연초록 pill, 우측 정렬.
  Widget _userBubble(String text) {
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(AppRadius.xl),
          ),
          child: AppText(
            text,
            style: AppTypography.body.copyWith(color: AppColors.textStrong),
          ),
        ),
      ),
    );
  }

  /// 답변 — **말풍선 상자를 쓰지 않는다.** 좌측 정렬 본문 + 작은 세이프 아이콘.
  /// 글자를 한 단계 키우고 줄간격을 넓혔다(영상에서 읽혀야 한다).
  Widget _answerBlock(GlossaryAnswer answer) {
    final TextStyle body = AppTypography.body.copyWith(
      fontSize: 17,
      height: 1.65,
      color: AppColors.textStrong,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: MascotSafe(size: 28, state: MascotState.tip),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText.rich(
                buildTermSpan(
                  context,
                  text: answer.answer,
                  glossary: answer.termGlossary,
                  style: body,
                ),
              ),
              if (answer.source.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                AppText(
                  answer.source,
                  style: AppTypography.label.copyWith(
                    fontWeight: FontWeight.w400,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
              if (answer.outOfScope) ...[
                const SizedBox(height: AppSpacing.md),
                AppCompactButton(
                  label: _hasHistory ? '내 리포트 보기' : '매물 분석하러 가기',
                  tonal: true,
                  onPressed: _onOutOfScopeAction,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 로딩 — 스피너 대신 아이콘 + 한 줄.
  Widget _loadingLine() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: MascotSafe(size: 28, state: MascotState.tip),
        ),
        const SizedBox(width: AppSpacing.md),
        const Icon(
          Icons.auto_awesome_outlined,
          size: AppSize.iconSm,
          color: AppColors.primary,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: AppText(
            kChatLoadingMessage,
            style: AppTypography.body.copyWith(color: AppColors.textMuted),
          ),
        ),
      ],
    );
  }

  Widget _failedLine(_Msg m) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: MascotSafe(size: 28, state: MascotState.tip),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(
                m.text,
                style: AppTypography.body.copyWith(
                  fontSize: 17,
                  height: 1.65,
                  color: AppColors.textStrong,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              AppCompactButton(
                label: '다시 시도',
                icon: Icons.refresh,
                tonal: true,
                onPressed: () => _ask(m.retryQuery ?? ''),
              ),
            ],
          ),
        ),
      ],
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
                style: AppTypography.body.copyWith(color: AppColors.textStrong),
                decoration: InputDecoration(
                  hintText: '어려운 부동산 용어를 물어보세요',
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
                    borderSide: const BorderSide(
                      color: AppColors.primary,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            // 전송 중에는 정지 아이콘 — 두 번 눌러 두 번 묻는 일이 없게 잠근다.
            Semantics(
              button: true,
              label: _sending ? '답변을 기다리는 중' : '질문 보내기',
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
                      _sending ? Icons.stop : Icons.arrow_upward,
                      size: AppSize.iconSm,
                      color: _sending
                          ? AppColors.buttonDisabledFg
                          : Colors.white,
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
