/// 리포트 4장 '중개사에게 물어볼 질문' (2026-10-29 확정안 — 채팅 미리보기).
///
/// 「4 / 5 · 법이 정한 서류(회색) · ✦ AI 맞춤(초록)」 + "중개사에게 물어볼 질문"
/// + 카드 [진초록 띠 "AI가 이 집에서 뽑은 질문 N개" → 내 질문 말풍선 2개(각각 중개사 '…' 입력 중) → 자세히 보기 ›].
///
/// - 미리보기엔 **질문 2개까지만**. 합격선·대답은 상세 화면에서만 본다(2026-10-29 규혁).
/// - 말풍선은 연초록 바탕·진한 글씨 — 판례 카드의 결과 문장과 무게를 맞춘다.
/// - '…'는 움직이지 않는 점 3개다(테스트의 pumpAndSettle이 끝나지 않는 무한 애니메이션을 두지 않는다).
/// - 경매가 진행 중인 집은 질문 대신 멈춤 문장 하나.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/ask_cards.dart';
import '../../repositories/content_repository.dart';

Color get _kDataChipBg => AppColors.chipBg;
Color get _kDataChipFg => AppColors.chipFg;

/// 띠 — 진초록 바탕 · 연초록 말풍선 아이콘 (판례는 피해 사례라 숯색, 질문은 행동이라 초록)
const Color kAskBandBg = Color(0xFF0B3D2A);
const Color kAskBandIcon = Color(0xFF8FD3AE);

/// 내 질문 말풍선
Color get kAskMineBg => AppColors.primarySoft;
Color get kAskMineFg =>
    AppColors.isDark ? const Color(0xFFD5EBDD) : const Color(0xFF1F3529);

/// 미리보기에 보이는 질문 수
const int kAskPreviewCount = 2;

class AskChapter extends StatefulWidget {
  const AskChapter({super.key, required this.reportId});

  final String reportId;

  @override
  State<AskChapter> createState() => _AskChapterState();
}

class _AskChapterState extends State<AskChapter> {
  late final Future<AskCards> _future = () async {
    try {
      return await context.read<ContentRepository>().askCards(widget.reportId);
    } catch (_) {
      return AskCards.empty;
    }
  }();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AskCards>(
      future: _future,
      builder: (context, snap) {
        final bool loading = snap.connectionState != ConnectionState.done;
        final AskCards data = snap.data ?? AskCards.empty;
        // 서버가 4장을 모르면(옛 서버) 장 전체를 조용히 뺀다 — 빈 카드를 두지 않는다
        if (!loading && data.isEmpty) return const SizedBox.shrink();
        return Padding(
          key: const ValueKey('report-chapter-ask'),
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  AppText(
                    '4 / 5',
                    style: AppTypographyNext.caption.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColorsNext.textMuted,
                    ),
                  ),
                  AskChip(
                    icon: Icons.task_outlined,
                    label: '법이 정한 서류',
                    bg: _kDataChipBg,
                    fg: _kDataChipFg,
                  ),
                  AskChip(
                    icon: Icons.auto_awesome,
                    label: 'AI 맞춤',
                    bg: AppColors.primarySoft,
                    fg: AppColors.primary,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              AppText(
                '중개사에게 물어볼 질문',
                style: AppTypographyNext.headline.copyWith(
                  color: AppColorsNext.textStrong,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(20),
                ),
                clipBehavior: Clip.antiAlias,
                child: loading
                    ? const SizedBox(
                        key: ValueKey('ask-chapter-loading'),
                        height: 160,
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        ),
                      )
                    : data.stop != null
                    ? _stop(data.stop!)
                    : _preview(context, data),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _stop(String text) => Padding(
    key: const ValueKey('ask-chapter-stop'),
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
    child: AppText(
      text,
      style: AppTypographyNext.title.copyWith(color: AppColorsNext.dangerText),
    ),
  );

  Widget _preview(BuildContext context, AskCards data) {
    final shown = data.cards.take(kAskPreviewCount).toList();
    return Column(
      key: const ValueKey('ask-chapter-preview'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AskBand(count: data.cards.length),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final c in shown) ...[
                MineBubble(text: c.ask),
                const SizedBox(height: 10),
                const BrokerTyping(),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
        Divider(
          height: 1,
          thickness: 1,
          indent: 20,
          endIndent: 20,
          color: AppColorsNext.divider,
        ),
        InkWell(
          key: const ValueKey('ask-chapter-more'),
          onTap: () => context.push('/questions/${widget.reportId}'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 16, 14),
            child: Row(
              children: [
                Expanded(
                  child: AppText(
                    '자세히 보기',
                    style: AppTypographyNext.bodyStrong.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, color: AppColors.primary),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 진초록 띠 — "AI가 이 집에서 뽑은 질문 N개" (15 · 한 줄)
class AskBand extends StatelessWidget {
  const AskBand({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('ask-chapter-band'),
    color: kAskBandBg,
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
    child: Row(
      children: [
        const Icon(Icons.chat_bubble_outline_rounded, size: 20, color: kAskBandIcon),
        const SizedBox(width: 10),
        Expanded(
          child: AppText(
            'AI가 이 집에서 뽑은 질문 $count개',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypographyNext.caption.copyWith(
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 내 말풍선 (오른쪽)
class MineBubble extends StatelessWidget {
  const MineBubble({super.key, required this.text, this.outlined = false});

  final String text;

  /// '이렇게 받아치세요' — 흰 바탕 초록 테두리
  final bool outlined;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 288),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: outlined ? AppColors.surface : kAskMineBg,
          border: outlined ? Border.all(color: AppColors.primary, width: 2) : null,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomLeft: Radius.circular(20),
            bottomRight: Radius.circular(6),
          ),
        ),
        child: AppText(
          text,
          style: AppTypographyNext.bodyStrong.copyWith(
            color: outlined ? AppColors.primary : kAskMineFg,
          ),
        ),
      ),
    ),
  );
}

/// 중개사 얼굴 (회색 원)
class BrokerAvatar extends StatelessWidget {
  const BrokerAvatar({super.key});

  @override
  Widget build(BuildContext context) => Container(
    width: 32,
    height: 32,
    decoration: BoxDecoration(color: _kDataChipBg, shape: BoxShape.circle),
    child: Icon(Icons.person_outline, size: 18, color: AppColorsNext.textMuted),
  );
}

/// 중개사 '…' 입력 중 (움직이지 않는 점 3개)
class BrokerTyping extends StatelessWidget {
  const BrokerTyping({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: '중개사 답을 기다리는 중',
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const BrokerAvatar(),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(6),
              topRight: Radius.circular(20),
              bottomLeft: Radius.circular(20),
              bottomRight: Radius.circular(20),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final double o in const [0.45, 0.7, 1.0]) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C8882).withValues(alpha: o),
                    shape: BoxShape.circle,
                  ),
                ),
                if (o != 1.0) const SizedBox(width: 5),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class AskChip extends StatelessWidget {
  const AskChip({
    super.key,
    required this.icon,
    required this.label,
    required this.bg,
    required this.fg,
  });

  final IconData icon;
  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: fg),
        const SizedBox(width: 4),
        Flexible(
          child: AppText(
            label,
            style: AppTypographyNext.caption.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ),
      ],
    ),
  );
}
