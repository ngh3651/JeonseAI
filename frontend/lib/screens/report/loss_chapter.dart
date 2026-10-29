/// 리포트 2장 '손실 시뮬레이터' (2026-10-29 확정안 A2).
///
/// 「2 / 5 · 실제 경매 통계」(회색 칩 — 초록 '✦ AI 분석'과 구분: 초록 = AI가 한 일, 회색 = 공공 데이터)
/// + "손실 시뮬레이터" + 카드 [경매로 넘어가면 · N원 돌려받아요 · 막대 · 돌려받음/못 받음 · 자세히 보기 ›].
///
/// 숫자는 손실 시뮬레이터 화면과 **같은 서버 계산**(`GET /api/reports/{id}/loss-estimate`)을 그대로 쓴다.
/// 자세한 계산 4줄 · 출처 · 매매 시세 입력은 [자세히 보기] → 시뮬레이터 화면에만 있다.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/loss_estimate.dart';
import '../../repositories/analysis_repository.dart';
import '../../utils/money_format.dart';

/// 회색 칩 색 — 공공 데이터 표시
const Color _kDataChipBg = Color(0xFFECEFED);
const Color _kDataChipFg = Color(0xFF3C4842);

/// 계산 못 했을 때 막대
const Color _kBarIdle = Color(0xFFE3E7E5);

class LossChapter extends StatefulWidget {
  const LossChapter({super.key, required this.reportId});

  final String reportId;

  @override
  State<LossChapter> createState() => _LossChapterState();
}

class _LossChapterState extends State<LossChapter> {
  late final Future<LossEstimate?> _future = () async {
    try {
      return await context.read<AnalysisRepository>().getLossEstimate(
        widget.reportId,
      );
    } catch (_) {
      return null;
    }
  }();

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('report-chapter-loss'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            AppText(
              '2 / 5',
              style: AppTypographyNext.caption.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColorsNext.textMuted,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: _kDataChipBg,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.bar_chart_rounded,
                    size: 15,
                    color: _kDataChipFg,
                  ),
                  const SizedBox(width: 4),
                  AppText(
                    '실제 경매 통계',
                    style: AppTypographyNext.caption.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: _kDataChipFg,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        AppText(
          '손실 시뮬레이터',
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
          child: FutureBuilder<LossEstimate?>(
            future: _future,
            builder: (context, snap) {
              final bool loading = snap.connectionState != ConnectionState.done;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
                    child: loading ? _loading() : _body(snap.data),
                  ),
                  const Divider(
                    height: 1,
                    thickness: 1,
                    indent: 20,
                    endIndent: 20,
                    color: AppColorsNext.divider,
                  ),
                  InkWell(
                    key: const ValueKey('loss-chapter-more'),
                    onTap: () => context.push('/simulator/${widget.reportId}'),
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
                          const Icon(
                            Icons.chevron_right,
                            color: AppColors.primary,
                          ),
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

  /// 받는 동안 — 자리만 잡아 둔다(화면이 튀지 않게)
  Widget _loading() => const SizedBox(
    key: ValueKey('loss-chapter-loading'),
    height: 118,
    child: Center(
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    ),
  );

  Widget _body(LossEstimate? e) {
    final bool priced =
        e != null &&
        (e.status == LossStatus.ok || e.status == LossStatus.debtExceeds);
    final String? message = switch (e?.status) {
      null => '불러오지 못했어요',
      LossStatus.noPrice => '매매 시세를 넣으면 계산돼요',
      LossStatus.noRate => '이 지역 경매 통계를 준비 중이에요',
      _ => null,
    };
    final int back = e?.expectedReturn ?? 0;
    final int loss = e?.expectedLoss ?? 0;
    final TextStyle legend = AppTypographyNext.caption.copyWith(
      fontSize: 14,
      color: AppColorsNext.textMuted,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppText(
          '경매로 넘어가면',
          style: AppTypographyNext.caption.copyWith(
            color: AppColorsNext.textMuted,
          ),
        ),
        const SizedBox(height: 6),
        if (priced)
          AppText.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: formatWon(back),
                  style: AppTypographyNext.numberLarge.copyWith(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: loss == 0
                        ? AppColors.ok
                        : back == 0
                        ? AppColorsNext.dangerText
                        : AppColorsNext.textStrong,
                  ),
                ),
                TextSpan(
                  text: '  돌려받아요',
                  style: AppTypographyNext.bodyStrong.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColorsNext.textStrong,
                  ),
                ),
              ],
            ),
            key: const ValueKey('loss-chapter-amount'),
          )
        else
          AppText(
            message ?? '',
            key: const ValueKey('loss-chapter-message'),
            style: AppTypographyNext.title.copyWith(
              color: AppColorsNext.textStrong,
            ),
          ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 16,
            child: priced
                ? _bar(back, loss)
                : const ColoredBox(color: _kBarIdle),
          ),
        ),
        if (priced) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: AppText.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: '돌려받음 ', style: legend),
                      TextSpan(
                        text: formatWon(back),
                        style: legend.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppColors.ok,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              AppText.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '못 받음 ', style: legend),
                    TextSpan(
                      text: formatWon(loss),
                      style: legend.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColorsNext.dangerText,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 손실 시뮬레이터 화면의 막대와 같은 규칙 — 돌려받음 초록 · 못 받음 빨강
  Widget _bar(int back, int loss) {
    final int total = back + loss;
    final int backFlex = total == 0 ? 0 : (back * 1000 / total).round();
    final int lossFlex = total == 0 ? 1 : 1000 - backFlex;
    return Row(
      key: const ValueKey('loss-chapter-bar'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (backFlex > 0)
          Expanded(
            flex: backFlex,
            child: const ColoredBox(color: AppColors.ok),
          ),
        if (backFlex > 0 && lossFlex > 0) const SizedBox(width: 2),
        if (lossFlex > 0)
          Expanded(
            flex: lossFlex,
            child: const ColoredBox(color: AppColorsNext.dangerText),
          ),
      ],
    );
  }
}
