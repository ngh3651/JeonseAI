/// 4장 상세 '중개사에게 물어볼 질문' (2026-10-29 확정안 — 대본 화면). 라우트는 예전 그대로 `/questions/:id`.
///
/// 위에서부터: "N가지만 확인하면 돼요" → 확인한 것 N / M 막대 → 현장 한마디(괜찮아요 → 적어 주세요)
/// → 질문 카드(접고 펴기, 처음엔 1번만 펼침): 이 집 등기부에서 본 것 · ✦ 왜(AI) · 대본(내 질문 / 좋은 답 /
/// 이럴 땐 조심 / 받아치기) · 합격선 · 받을 것 · 중개사 답은?(글로 받음/말로만/거절) → [중개사에게 미리 보내기].
///
/// 답 기록은 **이 앱이 켜져 있는 동안만** 이 폰에 둔다(서버로 보내지 않는다).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/ask_cards.dart';
import '../../repositories/content_repository.dart';
import '../../services/api_client.dart';
import '../common/share_feedback.dart';
import '../report/ask_chapter.dart';

/// 중개사 답 — 글로 받음 / 말로만 / 거절
enum AskAnswer { written, verbal, refused }

/// 답 기록 (리포트 id → 카드 id → 답). 앱이 켜져 있는 동안만.
class AskAnswerStore {
  AskAnswerStore._();
  static final Map<String, Map<String, AskAnswer>> _byReport = {};

  static Map<String, AskAnswer> of(String reportId) =>
      _byReport.putIfAbsent(reportId, () => {});
}

class AskCardsScreen extends StatefulWidget {
  const AskCardsScreen({super.key, required this.reportId});

  final String reportId;

  @override
  State<AskCardsScreen> createState() => _AskCardsScreenState();
}

class _AskCardsScreenState extends State<AskCardsScreen> {
  late Future<AskCards> _future;
  int _open = 0;
  String? _copied;

  Map<String, AskAnswer> get _answers => AskAnswerStore.of(widget.reportId);

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = context.read<ContentRepository>().askCards(widget.reportId, polish: true);
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
                    style: AppTypographyNext.title.copyWith(color: AppColorsNext.dangerText),
                  ),
                ),
              ],
            );
          }
          return _body(data);
        },
      ),
    );
  }

  Widget _body(AskCards data) {
    final cards = data.cards;
    final int done = cards.where((c) => _answers[c.id] != null).length;
    return ListView(
      key: const ValueKey('ask-detail-list'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText('${cards.length}가지만 확인하면 돼요', style: AppTypographyNext.headline),
              const SizedBox(height: 4),
              AppText('하나씩 묻고, 답은 글로 받아 두세요.', style: AppTypographyNext.caption),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _progress(cards, done),
        const SizedBox(height: 20),
        _magicLine(),
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
            label: AppText('중개사에게 미리 보내기', style: AppTypographyNext.button.copyWith(color: Colors.white)),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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

  Widget _progress(List<AskCard> cards, int done) => Container(
    key: const ValueKey('ask-progress'),
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
    decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(24)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: AppText('확인한 것', style: AppTypographyNext.bodyStrong.copyWith(fontWeight: FontWeight.w700))),
            AppText(
              '$done / ${cards.length}',
              style: AppTypographyNext.bodyStrong.copyWith(fontWeight: FontWeight.w800, color: AppColors.primary),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (int i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: _answerColor(_answers[cards[i].id]) ?? AppColorsNext.divider,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    ),
  );

  Widget _magicLine() => Container(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
    decoration: BoxDecoration(color: kAskBandBg, borderRadius: BorderRadius.circular(24)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText('현장에서 이 한마디', style: AppTypographyNext.caption.copyWith(fontWeight: FontWeight.w700, color: kAskBandIcon)),
        const SizedBox(height: 4),
        AppText(
          '중개사가 “괜찮아요” 하면\n→ “그럼 계약서에 적어 주세요”',
          style: AppTypographyNext.title.copyWith(color: Colors.white),
        ),
      ],
    ),
  );

  static Color? _answerColor(AskAnswer? a) => switch (a) {
    AskAnswer.written => AppColors.ok,
    AskAnswer.verbal => AppColors.caution,
    AskAnswer.refused => AppColorsNext.dangerText,
    null => null,
  };

  static (String, Color, Color)? _pill(AskAnswer? a) => switch (a) {
    AskAnswer.written => ('글로 받음', AppColors.okSoft, AppColors.ok),
    AskAnswer.verbal => ('말로만', AppColors.cautionSoft, const Color(0xFF7A4A05)),
    AskAnswer.refused => ('거절', AppColors.dangerSoft, AppColorsNext.dangerText),
    null => null,
  };

  Widget _card(int i, AskCard c) {
    final bool open = _open == i;
    final AskAnswer? a = _answers[c.id];
    final pill = _pill(a);
    return Container(
      key: ValueKey('ask-card-${c.id}'),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: ValueKey('ask-toggle-${c.id}'),
            onTap: () => setState(() => _open = open ? -1 : i),
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
                        color: open ? Colors.white : const Color(0xFF3C4842),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: AppText(c.title, style: AppTypographyNext.title)),
                  if (pill != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(color: pill.$2, borderRadius: BorderRadius.circular(999)),
                      child: AppText(
                        pill.$1,
                        style: AppTypographyNext.caption.copyWith(fontSize: 13, fontWeight: FontWeight.w700, color: pill.$3),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: const Icon(Icons.expand_more, color: AppColorsNext.textMuted),
                  ),
                ],
              ),
            ),
          ),
          if (open) _cardBody(c, a),
        ],
      ),
    );
  }

  Widget _label(String t) => AppText(
    t,
    style: AppTypographyNext.caption.copyWith(fontWeight: FontWeight.w700),
  );

  Widget _cardBody(AskCard c, AskAnswer? a) {
    final pass = c.passLine;
    return Padding(
      key: ValueKey('ask-body-${c.id}'),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (c.legal) ...[
            const Align(
              alignment: Alignment.centerLeft,
              child: AskChip(
                icon: Icons.task_outlined,
                label: '법이 정한 서류 · 집주인이 보여 줘야 해요',
                bg: Color(0xFFECEFED),
                fg: Color(0xFF3C4842),
              ),
            ),
            const SizedBox(height: 14),
          ],
          if (c.facts.isNotEmpty) ...[
            _label('이 집 등기부에서 본 것'),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: AppColorsNext.divider),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (int k = 0; k < c.facts.length; k++)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        border: k == 0 ? null : const Border(top: BorderSide(color: AppColorsNext.divider)),
                      ),
                      child: AppText(c.facts[k], style: AppTypographyNext.bodyStrong),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(16)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 5),
                  child: Icon(Icons.auto_awesome, size: 15, color: AppColors.primary),
                ),
                const SizedBox(width: 8),
                Expanded(child: AppText(c.why, style: AppTypographyNext.body.copyWith(color: kAskMineFg))),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _label('이렇게 물어보세요'),
          const SizedBox(height: 10),
          MineBubble(text: c.ask),
          const SizedBox(height: 10),
          _broker('좋은 답', AppColors.ok, c.okReply, AppColors.background),
          const SizedBox(height: 10),
          _broker('이럴 땐 조심', AppColorsNext.dangerText, c.badReply, AppColors.dangerSoft),
          const SizedBox(height: 10),
          Align(alignment: Alignment.centerRight, child: _label('이렇게 받아치세요')),
          const SizedBox(height: 4),
          MineBubble(text: c.counter, outlined: true),
          const SizedBox(height: 16),
          Container(
            key: ValueKey('ask-pass-${c.id}'),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.track_changes_rounded, size: 18, color: AppColors.primary),
                    const SizedBox(width: 6),
                    _label('합격선'),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.end,
                  spacing: 8,
                  children: [
                    if (pass.big != null)
                      AppText(pass.big!, style: AppTypographyNext.numberLarge.copyWith(color: AppColors.ok, fontWeight: FontWeight.w800)),
                    AppText(
                      pass.text,
                      style: AppTypographyNext.bodyStrong.copyWith(
                        fontWeight: FontWeight.w700,
                        color: pass.big != null ? AppColorsNext.textStrong : AppColors.primary,
                      ),
                    ),
                  ],
                ),
                if (pass.sub != null) ...[
                  const SizedBox(height: 2),
                  AppText(
                    pass.sub!,
                    style: AppTypographyNext.caption.copyWith(
                      fontWeight: FontWeight.w600,
                      color: pass.danger ? AppColorsNext.dangerText : AppColorsNext.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (c.docs.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _label('받을 것'),
                for (final d in c.docs)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.line),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: AppText(d, style: AppTypographyNext.caption.copyWith(fontWeight: FontWeight.w600, color: const Color(0xFF3C4842))),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          const Divider(height: 1, thickness: 1, color: AppColorsNext.divider),
          const SizedBox(height: 14),
          _label('중개사 답은?'),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final (AskAnswer v, String label) in const [
                (AskAnswer.written, '글로 받았어요'),
                (AskAnswer.verbal, '말로만 들었어요'),
                (AskAnswer.refused, '거절했어요'),
              ]) ...[
                if (v != AskAnswer.written) const SizedBox(width: 6),
                Expanded(child: _answerChip(c, v, label, a == v)),
              ],
            ],
          ),
          if (a == AskAnswer.written) ...[
            const SizedBox(height: 12),
            _note(AppColors.okSoft, AppColors.ok, '기록했어요 · 계약서에 들어가는지 마지막에 한 번 더 보세요'),
          ],
          if (a == AskAnswer.verbal) ...[
            const SizedBox(height: 12),
            Container(
              key: ValueKey('ask-clause-${c.id}'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.cautionSoft, borderRadius: BorderRadius.circular(16)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText(
                    '말은 나중에 증거가 안 돼요 — 이 특약을 넣어 달라고 하세요',
                    style: AppTypographyNext.bodyStrong.copyWith(fontWeight: FontWeight.w700, color: const Color(0xFF7A4A05)),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12)),
                    child: AppText(c.clause, style: AppTypographyNext.body),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: c.clause));
                      if (mounted) setState(() => _copied = c.id);
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18, color: Color(0xFF7A4A05)),
                    label: AppText(
                      _copied == c.id ? '복사했어요' : '특약 복사',
                      style: AppTypographyNext.caption.copyWith(fontWeight: FontWeight.w700, color: const Color(0xFF7A4A05)),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (a == AskAnswer.refused) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.dangerSoft, borderRadius: BorderRadius.circular(16)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText('가계약금 보내기 전에 멈추세요', style: AppTypographyNext.bodyStrong.copyWith(fontWeight: FontWeight.w700, color: AppColorsNext.dangerText)),
                  const SizedBox(height: 4),
                  AppText(c.stopSub, style: AppTypographyNext.caption.copyWith(color: const Color(0xFF3C4842))),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _note(Color bg, Color fg, String text) => Container(
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
    child: AppText(text, style: AppTypographyNext.bodyStrong.copyWith(fontWeight: FontWeight.w700, color: fg)),
  );

  Widget _broker(String tag, Color tagColor, String text, Color bg) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      const BrokerAvatar(),
      const SizedBox(width: 8),
      Flexible(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppText.rich(
              TextSpan(
                children: [
                  const TextSpan(text: '중개사 · '),
                  TextSpan(text: tag, style: TextStyle(color: tagColor)),
                ],
              ),
              style: AppTypographyNext.caption.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 262),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(6),
                    topRight: Radius.circular(20),
                    bottomLeft: Radius.circular(20),
                    bottomRight: Radius.circular(20),
                  ),
                ),
                child: AppText(text, style: AppTypographyNext.body),
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _answerChip(AskCard c, AskAnswer v, String label, bool selected) {
    final (Color bg, Color fg, Color bd) = !selected
        ? (AppColors.surface, const Color(0xFF3C4842), AppColors.line)
        : switch (v) {
            AskAnswer.written => (AppColors.okSoft, AppColors.ok, AppColors.ok),
            AskAnswer.verbal => (AppColors.cautionSoft, const Color(0xFF7A4A05), AppColors.caution),
            AskAnswer.refused => (AppColors.dangerSoft, AppColorsNext.dangerText, AppColorsNext.dangerText),
          };
    return InkWell(
      key: ValueKey('ask-answer-${c.id}-${v.name}'),
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() {
        if (selected) {
          _answers.remove(c.id);
        } else {
          _answers[c.id] = v;
        }
      }),
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: bd, width: 1.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: AppText(
          label,
          textAlign: TextAlign.center,
          style: AppTypographyNext.caption.copyWith(fontWeight: FontWeight.w700, color: fg, height: 1.3),
        ),
      ),
    );
  }
}
