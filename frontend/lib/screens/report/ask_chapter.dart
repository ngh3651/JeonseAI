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
                  // 질문 고르기·문구는 규칙이다 — 'AI'라고 쓰지 않는다(과대 표기 금지, 2026-11-01 디자인 점검)
                  AskChip(
                    icon: Icons.home_outlined,
                    label: '이 집 맞춤',
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
              // 상세 화면과 같은 모양 — 번호 · 질문 이름 · 내가 할 말 상자(말풍선은 상세에서 뺐다, 2026-11-01 디자인 점검)
              for (int i = 0; i < shown.length; i++) ...[
                if (i > 0) const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                      child: AppText(
                        '${i + 1}',
                        textScaler: TextScaler.noScaling,
                        style: AppTypographyNext.caption.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: AppColors.onPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: AppText(
                        shown[i].title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypographyNext.bodyStrong.copyWith(fontWeight: FontWeight.w700, color: AppColorsNext.textStrong),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                AskQuote(text: shown[i].ask, compact: true),
              ],
              const SizedBox(height: 12),
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

/// 진초록 띠 — "이 집에 맞춰 고른 질문 N개" (15 · 한 줄)
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
            '이 집에 맞춰 고른 질문 $count개',
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

/// 내가 할 말 — 큰 글씨, 따옴표, 왼쪽 굵은 초록 줄 (2026-11-01 — 중개사 질문 상세와 4장 미리보기가 같이 쓴다)
class AskQuote extends StatelessWidget {
  const AskQuote({super.key, required this.text, this.compact = false});

  final String text;

  /// 4장 미리보기 — 한 칸 작게(17)
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.fromLTRB(18, compact ? 12 : 16, 16, compact ? 12 : 16),
    decoration: BoxDecoration(
      color: AppColors.primarySoft,
      borderRadius: BorderRadius.circular(16),
      border: Border(left: BorderSide(color: AppColors.primary, width: 5)),
    ),
    child: AppText(
      '“$text”',
      style: AppTypographyNext.title.copyWith(
        fontSize: compact ? 17 : 19,
        height: compact ? 26 / 17 : 29 / 19,
        fontWeight: FontWeight.w700,
        color: kAskQuoteFg,
      ),
    ),
  );
}

/// 할 말 상자 글자색 — 밝게는 진한 초록, 어둡게는 밝은 초록
Color get kAskQuoteFg =>
    AppColors.isDark ? AppColors.primaryStrong : const Color(0xFF0E3B27);



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
