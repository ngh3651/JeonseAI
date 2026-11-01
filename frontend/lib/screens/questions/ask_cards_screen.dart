/// 4장 상세 '중개사에게 물어볼 질문' — 라우트는 예전 그대로 `/questions/:id`.
///
/// 2026-11-01 리디자인 (캔버스 '중개사 질문' V-1·V-2 확정 — 규혁):
/// "N가지만 확인하면 돼요" + 한 줄 안내 → 질문 카드(접고 펴기, **여러 개 동시에 펼칠 수 있다**) → [중개사에게 미리 보내기].
/// 카드 안: 왜 물어봐요 → 이렇게 물어보세요(큰 따옴표 상자) → 중개사 답에 따라([통과][조심] 탭)
/// → 꼭 받아 오세요(서류 큰 칸) → [리포트에서 근거 보기]. 칸 사이마다 가는 줄. 소제목 모양은 앱 전체 같다(AppSection).
/// '이 집에서 본 것'은 리포트·사진에서 보기에 이미 있어 여기선 뺐다 — 세 군데는 많다(2026-11-01 규혁). 대신 리포트 근거로 바로 간다.
///
/// 뺀 것 (규혁 — "여정 체크리스트만 해도 번잡한데 굳이"): 확인한 것 N/M 막대 · 현장 한마디 띠(고정 문구, 위 안내와 같은 말) ·
/// 중개사 답은?(글로 받음/말로만/거절) 버튼과 기록 · 합격선 칸(통과 탭 머리와 같은 말이라 합쳤다) · 말풍선 대화 · 용어 밑줄.
///
/// 글자는 꾹 눌러 [챗봇에 묻기]. 문구는 전부 서버(규칙 + 정해 둔 문구). '왜 물어봐요'만 AI가 다시 쓸 수 있고,
/// 그때만(`whyByAi`) "✦ AI가 썼어요"를 붙인다.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:go_router/go_router.dart';

import '../../design_system/components/app_link_chip.dart';
import '../../design_system/components/app_section.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/text/phrase_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/ask_cards.dart';
import '../../repositories/content_repository.dart';
import '../../services/api_client.dart';
import '../common/ask_selection.dart';
import '../common/share_feedback.dart';
import '../report/ask_chapter.dart' show AskChip, AskQuote;

/// 중개사 답 탭 — 통과 / 조심
enum AskTab { pass, careful }

/// 조심 탭 머리 한 줄 — 합격선의 빨간 풀이(이 집 손해 금액)가 있으면 그것, 없으면 정해 둔 '멈춤' 풀이.
String askCarefulLine(AskCard c) {
  final p = c.passLine;
  if (p.danger && (p.sub ?? '').trim().isNotEmpty) return p.sub!.trim();
  return c.stopSub.trim();
}

class AskCardsScreen extends StatefulWidget {
  const AskCardsScreen({super.key, required this.reportId});

  final String reportId;

  @override
  State<AskCardsScreen> createState() => _AskCardsScreenState();
}

class _AskCardsScreenState extends State<AskCardsScreen> {
  late Future<AskCards> _future;

  /// 펼친 카드 — 처음엔 1번만. 다른 카드를 펼쳐도 닫히지 않는다(2026-11-01 규혁 "자유롭게").
  final Set<String> _open = {};
  bool _seeded = false;

  /// 카드별 고른 탭 — 처음엔 [AskTab.careful] (손해 금액·받아치기가 먼저 보이게)
  final Map<String, AskTab> _tab = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = context.read<ContentRepository>().askCards(
      widget.reportId,
      polish: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const AppText('중개사에게 물어볼 질문')),
      body: FutureBuilder<AskCards>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppText(
                      '질문을 불러오지 못했어요\n${apiErrorHint(snap.error, fallback: '서버 연결을 확인해 주세요')}',
                      style: AppTypographyNext.body,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => setState(_load),
                      child: const AppText('다시 시도'),
                    ),
                  ],
                ),
              ),
            );
          }
          final data = snap.data ?? AskCards.empty;
          if (data.stop != null) {
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppColors.dangerSoft,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: AppText(
                    data.stop!,
                    style: AppTypographyNext.title.copyWith(
                      color: AppColorsNext.dangerText,
                    ),
                  ),
                ),
              ],
            );
          }
          if (!_seeded && data.cards.isNotEmpty) {
            _seeded = true;
            _open.add(data.cards.first.id);
          }
          return AskSelectionArea(child: _body(data));
        },
      ),
    );
  }

  Widget _body(AskCards data) {
    final cards = data.cards;
    return ListView(
      key: const ValueKey('ask-detail-list'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(
                '${cards.length}가지만 확인하면 돼요',
                style: AppTypographyNext.headline,
              ),
              const SizedBox(height: 4),
              AppText(
                '하나씩 묻고, 답은 글로 받아 두세요.',
                style: AppTypographyNext.caption,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        for (int i = 0; i < cards.length; i++) ...[
          _card(i, cards[i]),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 8),
        SizedBox(
          height: 56,
          child: FilledButton.icon(
            key: const ValueKey('ask-share'),
            onPressed: () => shareWithFeedback(context, data.shareText),
            icon: const Icon(Icons.send_rounded),
            label: AppText(
              '중개사에게 미리 보내기',
              style: AppTypographyNext.button.copyWith(
                color: AppColors.onPrimary,
              ),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        AppText(
          '받을 서류 목록을 문자로 먼저 보내요',
          textAlign: TextAlign.center,
          style: AppTypographyNext.caption,
        ),
      ],
    );
  }

  Widget _card(int i, AskCard c) {
    final bool open = _open.contains(c.id);
    return Container(
      key: ValueKey('ask-card-${c.id}'),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: ValueKey('ask-toggle-${c.id}'),
            onTap: () =>
                setState(() => open ? _open.remove(c.id) : _open.add(c.id)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: open ? AppColors.primary : AppColorsNext.divider,
                      shape: BoxShape.circle,
                    ),
                    child: AppText(
                      '${i + 1}',
                      textScaler: TextScaler.noScaling,
                      style: AppTypographyNext.caption.copyWith(
                        fontWeight: FontWeight.w800,
                        color: open ? AppColors.onPrimary : AppColors.chipFg,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: AppText(c.title, style: AppTypographyNext.title),
                  ),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      Icons.expand_more,
                      color: AppColorsNext.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (open) _cardBody(c),
        ],
      ),
    );
  }

  Widget _cardBody(AskCard c) {
    final Color accent = AppColors.isDark ? AppColors.primaryStrong : AppColors.primary;
    final String? evidence = askEvidenceFor(c.id);
    final sections = <Widget>[
      if (c.why.trim().isNotEmpty)
        AppSection(
          icon: Icons.question_mark_rounded,
          label: '왜 물어봐요',
          color: accent,
          // 모델이 실제로 썼을 때만 'AI' — 정해 둔 문장이면 붙이지 않는다(과대 표기 금지)
          note: c.whyByAi ? kAiWroteNote : null,
          child: AppText(
            c.why,
            key: ValueKey('ask-why-${c.id}'),
            style: AppTypographyNext.body.copyWith(
              fontSize: 17,
              height: 27 / 17,
              color: AppColorsNext.textBody,
            ),
          ),
        ),
      AppSection(
        icon: Icons.chat_bubble_outline_rounded,
        label: '이렇게 물어보세요',
        color: accent,
        child: AskQuote(key: ValueKey('ask-quote-${c.id}'), text: c.ask),
      ),
      AppSection(
        icon: Icons.hearing_rounded,
        label: '중개사 답에 따라',
        color: accent,
        child: _Answers(
          card: c,
          tab: _tab[c.id] ?? AskTab.careful,
          onTab: (t) => setState(() => _tab[c.id] = t),
        ),
      ),
      if (c.docs.isNotEmpty)
        AppSection(
          icon: Icons.move_to_inbox_rounded,
          label: '꼭 받아 오세요',
          color: accent,
          child: _DocTiles(key: ValueKey('ask-docs-${c.id}'), docs: c.docs),
        ),
      if (evidence != null)
        Align(
          alignment: Alignment.centerLeft,
          child: AppLinkChip(
            key: ValueKey('ask-to-report-${c.id}'),
            label: '리포트에서 근거 보기',
            onTap: () => context.push('/report/${widget.reportId}?evidence=$evidence'),
          ),
        ),
    ];
    return Padding(
      key: ValueKey('ask-body-${c.id}'),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (c.legal) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: AskChip(
                icon: Icons.task_outlined,
                label: '법이 정한 서류 · 집주인이 보여 줘야 해요',
                bg: AppColors.chipBg,
                fg: AppColors.chipFg,
              ),
            ),
            const SizedBox(height: 14),
          ],
          AppSectionList(firstTop: 4, children: sections),
        ],
      ),
    );
  }
}

/// 질문 → 같은 이야기를 하는 리포트 근거 카드 (없으면 칩을 달지 않는다 — 밀린 세금·산 지 얼마 안 된 집·공동 소유)
String? askEvidenceFor(String askId) => switch (askId) {
  'debt' => 'senior_debt',
  'lease' || 'seizure' || 'trust' => 'ownership',
  'pending' => 'pending',
  'insurance' => 'insurance',
  'tenants' => 'jeonse_ratio',
  _ => null,
};

/// 중개사 답에 따라 — [✓ 통과] [! 조심] 탭, 한 번에 한 카드.
class _Answers extends StatelessWidget {
  const _Answers({required this.card, required this.tab, required this.onTab});

  final AskCard card;
  final AskTab tab;
  final ValueChanged<AskTab> onTab;

  @override
  Widget build(BuildContext context) {
    final c = card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: AppColors.chipBg,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Expanded(
                child: _tabButton(
                  AskTab.pass,
                  Icons.check_rounded,
                  '통과',
                  AppColors.ok,
                ),
              ),
              Expanded(
                child: _tabButton(
                  AskTab.careful,
                  Icons.priority_high_rounded,
                  '조심',
                  AppColorsNext.dangerText,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (tab == AskTab.pass) _passCard(c) else _carefulCard(c),
      ],
    );
  }

  Widget _tabButton(AskTab t, IconData icon, String label, Color color) {
    final bool on = tab == t;
    return Semantics(
      selected: on,
      button: true,
      child: GestureDetector(
        key: ValueKey('ask-tab-${card.id}-${t.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onTab(t),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? AppColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: on && !AppColors.isDark
                ? const [
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 4,
                      offset: Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: on ? color : AppColorsNext.textMuted),
              const SizedBox(width: 4),
              AppText(
                label,
                style: AppTypographyNext.bodyStrong.copyWith(
                  fontSize: 16,
                  fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                  color: on ? color : AppColorsNext.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 통과 — 머리: 합격선(크게 '0원' + 조건), 풀이(빨강이 아닐 때만) / 몸: 좋은 답
  Widget _passCard(AskCard c) {
    final p = c.passLine;
    final String? big = (p.big ?? '').trim().isEmpty ? null : p.big!.trim();
    final String text = p.text.trim();
    final String? sub = !p.danger && (p.sub ?? '').trim().isNotEmpty ? p.sub!.trim() : null;
    return _AnswerCard(
      key: ValueKey('ask-pass-${c.id}'),
      border: AppColors.ok.withValues(alpha: 0.35),
      headBg: AppColors.okSoft,
      head: [
        if (big != null || text.isNotEmpty)
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              if (big != null)
                AppText(
                  big,
                  style: _headStyle(AppColors.ok).copyWith(fontSize: 22, height: 28 / 22),
                ),
              // '특약 2줄: … · …'처럼 ' · '로 이은 글 — 덩어리 사이에서만 줄을 바꾼다(2026-11-01)
              if (text.isNotEmpty) PhraseText(text, style: _headStyle(AppColors.ok)),
            ],
          ),
        if (sub != null) ...[
          const SizedBox(height: 2),
          AppText(sub, style: AppTypographyNext.caption.copyWith(fontWeight: FontWeight.w600, color: AppColorsNext.textBody)),
        ],
      ],
      body: [AppText('“${c.okReply}”', style: _replyStyle)],
    );
  }

  /// 조심 — 머리: 이 집 손해(또는 멈춤 풀이) / 몸: 핑계 → 받아치기
  Widget _carefulCard(AskCard c) {
    final line = askCarefulLine(c);
    final counter = c.counter
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return _AnswerCard(
      key: ValueKey('ask-careful-${c.id}'),
      border: AppColorsNext.dangerText.withValues(alpha: 0.3),
      headBg: AppColors.dangerSoft,
      head: [
        if (line.isNotEmpty)
          AppText(line, style: _headStyle(AppColorsNext.dangerText)),
      ],
      body: [
        AppText('“${c.badReply}”', style: _replyStyle),
        if (counter.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.only(top: 12),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: AppColorsNext.dangerText.withValues(alpha: 0.25),
                ),
              ),
            ),
            child: Column(
              key: ValueKey('ask-counter-${c.id}'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  '↳ 이렇게 받아치세요',
                  style: AppTypographyNext.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColorsNext.dangerText,
                  ),
                ),
                const SizedBox(height: 4),
                for (final line in counter)
                  // "(주택임대차보호법 제3조의7)" 같은 근거 줄은 작고 흐리게
                  line.startsWith('(')
                      ? AppText(
                          line,
                          style: AppTypographyNext.caption.copyWith(
                            color: AppColorsNext.textMuted,
                          ),
                        )
                      : AppText(
                          '“$line”',
                          style: AppTypographyNext.body.copyWith(
                            fontSize: 17,
                            height: 26 / 17,
                            fontWeight: FontWeight.w700,
                            color: AppColorsNext.textStrong,
                          ),
                        ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static TextStyle _headStyle(Color color) =>
      AppTypographyNext.bodyStrong.copyWith(
        fontSize: 17,
        height: 25 / 17,
        fontWeight: FontWeight.w800,
        color: color,
      );

  static TextStyle get _replyStyle => AppTypographyNext.body.copyWith(
    fontSize: 17,
    height: 26 / 17,
    color: AppColorsNext.textBody,
  );
}

class _AnswerCard extends StatelessWidget {
  const _AnswerCard({
    super.key,
    required this.border,
    required this.headBg,
    required this.head,
    required this.body,
  });

  final Color border;
  final Color headBg;
  final List<Widget> head;
  final List<Widget> body;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppColors.surface,
      border: Border.all(color: border, width: 1.5),
      borderRadius: BorderRadius.circular(16),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (head.isNotEmpty)
          Container(
            color: headBg,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: head,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: body,
          ),
        ),
      ],
    ),
  );
}

/// 꼭 받아 오세요 — 서류 이름을 초록 테두리 큰 칸으로(두 칸씩).
class _DocTiles extends StatelessWidget {
  const _DocTiles({super.key, required this.docs});

  final List<String> docs;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final double w = docs.length == 1
                ? box.maxWidth
                : (box.maxWidth - 8) / 2;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final d in docs)
                  Container(
                    width: w,
                    padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      border: Border.all(color: AppColors.primary, width: 2),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.primarySoft,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.description_outlined,
                            size: 20,
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        AppText(
                          d,
                          style: AppTypographyNext.bodyStrong.copyWith(
                            fontSize: 17,
                            height: 24 / 17,
                            fontWeight: FontWeight.w800,
                            color: AppColorsNext.textStrong,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        AppText(
          '말로 한 약속은 증거가 안 돼요. 종이로 받아요.',
          style: AppTypographyNext.caption.copyWith(
            color: AppColorsNext.textMuted,
          ),
        ),
      ],
    );
  }
}
