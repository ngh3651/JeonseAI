/// 리포트 5장 '계약 여정' (2026-10-30 확정안 R2 — 채팅 미리보기).
///
/// 「5 / 5 · 날짜 알림(회색) · 등기 변동 확인(회색)」 + "계약 여정"
/// + 카드 [진초록 띠 "다음 일정 / 단계 이름 · 날짜 [D-n]" → 한 줄 설명 → 더 챙기면 좋은 것 1~N → 자세히 보기 ›].
///
/// - 단계·할 일·체크·날짜는 **여정 화면과 같은 계산**([JourneyProgress.forProperty])을 쓴다 —
///   여정에서 체크하거나 날짜를 넣고 돌아오면 이 장도 그 자리에서 바뀐다(두 저장소를 듣는다).
/// - 날짜가 없으면 띠에 날짜·D-day 없이 단계 이름만. "9단계 중 N단계"는 쓰지 않는다.
/// - 할 일은 그 단계 것을 **모두**(많아야 5개), 여정 화면의 줄([JourneyItemRow])을 그대로 —
///   [자세히 ⌄]는 숨기되 자리는 남겨 줄 바뀌는 자리가 여정과 같다. 설명은 [자세히 보기]에서.
/// - 알림 문장은 리포트에 두지 않는다(여정 화면에 있다).
/// - 옛 리포트를 열어도 **그 집의 지금** 여정을 보여 준다 — 여정은 리포트가 아니라 집에 붙어 있다.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/content_models.dart';
import '../../repositories/content_repository.dart';
import '../../state/journey_progress_store.dart';
import '../../state/journey_schedule_store.dart';
import '../journey/journey_logic.dart';
import '../journey/journey_parts.dart' show JourneyItemRow, plainMarkup;
import 'ask_chapter.dart' show AskChip, kAskBandBg, kAskBandIcon;

class JourneyChapter extends StatefulWidget {
  const JourneyChapter({
    super.key,
    required this.propertyKey,
    required this.onOpen,
  });

  /// 이 리포트가 속한 집의 열쇠 (여정 화면이 고르는 열쇠와 같다)
  final String propertyKey;

  /// [자세히 보기] — 이 집의 여정 화면을 연다
  final VoidCallback onOpen;

  @override
  State<JourneyChapter> createState() => _JourneyChapterState();
}

class _JourneyChapterState extends State<JourneyChapter> {
  late final Future<List<JourneyStage>> _stages = () async {
    try {
      return await context.read<ContentRepository>().journeyStages();
    } catch (_) {
      return const <JourneyStage>[];
    }
  }();

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('report-chapter-journey'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            AppText(
              '5 / 5',
              style: AppTypographyNext.caption.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColorsNext.textMuted,
              ),
            ),
            AskChip(
              icon: Icons.notifications_none,
              label: '날짜 알림',
              bg: AppColors.chipBg,
              fg: AppColors.chipFg,
            ),
            AskChip(
              icon: Icons.sync_alt,
              label: '등기 변동 확인',
              bg: AppColors.chipBg,
              fg: AppColors.chipFg,
            ),
          ],
        ),
        const SizedBox(height: 6),
        AppText(
          '계약 여정',
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
          child: FutureBuilder<List<JourneyStage>>(
            future: _stages,
            builder: (context, snap) {
              final bool loading = snap.connectionState != ConnectionState.done;
              final stages = snap.data ?? const <JourneyStage>[];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (loading)
                    const SizedBox(
                      key: ValueKey('journey-chapter-loading'),
                      height: 120,
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                      ),
                    )
                  else if (stages.isNotEmpty)
                    // 여정 화면에서 체크·날짜가 바뀌면 그 자리에서 다시 그린다
                    ListenableBuilder(
                      listenable: Listenable.merge([
                        JourneyScheduleStore.instance,
                        JourneyProgressStore.instance,
                      ]),
                      builder: (context, _) => _body(
                        JourneyProgress.forProperty(stages, widget.propertyKey),
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
                    key: const ValueKey('journey-chapter-more'),
                    onTap: widget.onOpen,
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
            },
          ),
        ),
      ],
    );
  }

  Widget _body(JourneyProgress progress) {
    final int? i = progress.headlineIndex;
    if (i == null) return const SizedBox.shrink();
    final JourneyStage stage = progress.stages[i];
    final DateTime? date = progress.dateOf(i);
    return Column(
      key: ValueKey('journey-chapter-stage-$i'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _band(stage, date),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 한 줄 설명 — 한 줄을 넘으면 살짝 작아진다
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: AppText(
                  plainMarkup(stage.subtitle),
                  key: const ValueKey('journey-chapter-subtitle'),
                  maxLines: 1,
                  style: AppTypographyNext.bodyStrong.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColorsNext.textStrong,
                  ),
                ),
              ),
              if (stage.items.isNotEmpty) ...[
                const SizedBox(height: 16),
                Divider(height: 1, thickness: 1, color: AppColorsNext.divider),
                const SizedBox(height: 14),
                AppText(
                  '더 챙기면 좋은 것',
                  style: AppTypographyNext.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.caution,
                  ),
                ),
                for (int n = 0; n < stage.items.length; n++) ...[
                  if (n > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: AppColorsNext.divider,
                    ),
                  JourneyItemRow(
                    number: n + 1,
                    item: stage.items[n],
                    preview: true,
                  ),
                ],
              ] else
                const SizedBox(height: 14),
            ],
          ),
        ),
      ],
    );
  }

  Widget _band(JourneyStage stage, DateTime? date) => Container(
    key: const ValueKey('journey-chapter-band'),
    color: kAskBandBg,
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(
                '다음 일정',
                style: AppTypographyNext.caption.copyWith(
                  fontWeight: FontWeight.w700,
                  color: kAskBandIcon,
                ),
              ),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: AppText(
                  date == null
                      ? stage.title
                      : '${stage.title} · ${slashDate(date)}',
                  key: const ValueKey('journey-chapter-title'),
                  maxLines: 1,
                  style: AppTypographyNext.title.copyWith(
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (date != null) ...[
          const SizedBox(width: 12),
          AppText(
            dDayLabel(date),
            key: const ValueKey('journey-chapter-dday'),
            style: AppTypographyNext.numberLarge.copyWith(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
        ],
      ],
    ),
  );
}
