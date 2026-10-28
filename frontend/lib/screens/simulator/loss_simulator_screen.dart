/// S-09 손실 시뮬레이터 — 2026-10-28 다시 짰다 (손실 시뮬레이터 1단계).
///
/// "이 집이 경매로 넘어가면 보증금이 얼마나 돌아오나"를 **이 집의 지역·용도 매각가율**로 보여 준다.
/// 숫자는 전부 서버가 규칙으로 계산한다(`GET /api/reports/{id}/loss-estimate`) — 앱은 그리기만 한다.
///
/// 예전 화면에서 뺀 것과 이유:
/// - 낙찰가율 슬라이더(근거 없는 70% 예시값) → 대법원 매각통계의 지역·용도별 값 하나
/// - 보증보험 토글(가입하면 0원) → 시뮬레이터와 상관없다. 가입 가능성은 리포트 근거 카드가 말한다
/// - 시세가 없을 때 보증금을 기준가로 쓰던 계산 → 계산하지 않고 [시세 입력하기]
///
/// 글은 줄이고 모양으로 말한다: 보증금 막대(돌려받음 초록 · 못 받음 빨강) → 계산 4줄 → 근거 몇 줄.
/// 글자·색은 판례·여정 리디자인과 같은 새 체계(`AppTypographyNext`·`AppColorsNext`).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/analysis_report.dart';
import '../../models/loss_estimate.dart';
import '../../repositories/analysis_repository.dart';
import '../../utils/money_format.dart';
import '../report/market_price_reanalyze.dart';

/// 빠진 것 한 줄 — 1단계 계산에 넣지 않은 것 (화면 맨 아래 고지)
const String kLossNotIncludedLine = '감정가 대신 시세로 계산 · 경매 비용·세금·최우선변제는 빠져 있어요';

class LossSimulatorScreen extends StatefulWidget {
  const LossSimulatorScreen({super.key, required this.reportId});

  final String reportId;

  @override
  State<LossSimulatorScreen> createState() => _LossSimulatorScreenState();
}

class _LossSimulatorScreenState extends State<LossSimulatorScreen> {
  late Future<(AnalysisReport?, LossEstimate?)> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final repo = context.read<AnalysisRepository>();
    _future = () async {
      final reportF = repo.getReport(widget.reportId);
      LossEstimate? est;
      try {
        est = await repo.getLossEstimate(widget.reportId);
      } catch (_) {
        est = null;
      }
      return (await reportF, est);
    }();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: AppText('손실 시뮬레이터', style: AppTypographyNext.title),
        centerTitle: true,
        backgroundColor: AppColors.background,
      ),
      body: FutureBuilder<(AnalysisReport?, LossEstimate?)>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final (report, est) = snap.data ?? (null, null);
          if (est == null) {
            return ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                _Message(
                  icon: Icons.cloud_off_outlined,
                  title: '불러올 수 없어요',
                  actionLabel: '다시 시도',
                  onAction: () => setState(_load),
                ),
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            children: [
              if (report != null) ...[
                AppText(
                  report.alias,
                  textAlign: TextAlign.center,
                  style: AppTypographyNext.caption,
                ),
                const SizedBox(height: 12),
              ],
              ...switch (est.status) {
                LossStatus.ok => _ok(est),
                LossStatus.debtExceeds => _debtExceeds(est),
                LossStatus.noPrice => [
                  _Message(
                    icon: Icons.home_work_outlined,
                    title: '집값을 몰라 계산할 수 없어요',
                    actionLabel:
                        report != null && canReanalyzeWithMarketPrice(report)
                        ? '시세 입력하기'
                        : null,
                    onAction: report == null
                        ? null
                        : () => reanalyzeWithMarketPrice(context, report),
                  ),
                ],
                LossStatus.noRate => [
                  const _Message(
                    icon: Icons.query_stats_outlined,
                    title: '이 지역 경매 통계를 준비 중이에요',
                  ),
                ],
              },
            ],
          );
        },
      ),
    );
  }

  // ── 계산함 ────────────────────────────────────────────────────────────────

  List<Widget> _ok(LossEstimate e) {
    final int back = e.expectedReturn ?? 0;
    final int loss = e.expectedLoss ?? 0;
    return [
      _Card(
        key: const ValueKey('loss-hero'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppText('경매로 넘어가면', style: AppTypographyNext.caption),
            const SizedBox(height: 2),
            AppText.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: formatWon(back),
                    style: AppTypographyNext.numberLarge.copyWith(
                      color: loss == 0
                          ? AppColors.ok
                          : AppColorsNext.textStrong,
                    ),
                  ),
                  TextSpan(
                    text: '  돌려받아요',
                    style: AppTypographyNext.bodyStrong.copyWith(
                      color: AppColorsNext.textStrong,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _DepositBar(back: back, loss: loss),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              runSpacing: 4,
              children: [
                _Legend(
                  color: AppColors.ok,
                  label: '돌려받음',
                  value: formatWon(back),
                ),
                _Legend(
                  key: const ValueKey('loss-legend-loss'),
                  color: AppColorsNext.dangerText,
                  label: '못 받음',
                  value: formatWon(loss),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _Card(
        key: const ValueKey('loss-steps'),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
        child: Column(
          children: [
            _Step(label: '집값', value: formatWon(e.basePrice ?? 0)),
            _Step(
              label: '경매 낙찰가',
              tag: '${_pct(e.ratePct)}%',
              value: formatWon(e.expectedSale ?? 0),
            ),
            _Step(
              label: '먼저 갚을 빚',
              value: '− ${formatWon(e.seniorDebt)}',
              danger: true,
            ),
            _Step(label: '내 몫', value: formatWon(back), strong: true, last: true),
          ],
        ),
      ),
      const SizedBox(height: 16),
      _Basis(e),
    ];
  }

  // ── 빚 ≥ 집값 ────────────────────────────────────────────────────────────

  List<Widget> _debtExceeds(LossEstimate e) => [
    _Card(
      key: const ValueKey('loss-debt-exceeds'),
      color: AppColors.dangerSoft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: AppColorsNext.dangerText,
                  shape: BoxShape.circle,
                ),
                child: AppText(
                  '!',
                  textScaler: TextScaler.noScaling,
                  style: AppTypographyNext.bodyStrong.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AppText(
                  '돌려받기 어려워요',
                  style: AppTypographyNext.title.copyWith(
                    color: AppColorsNext.dangerText,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _Tile(label: '집값', value: formatWon(e.basePrice ?? 0)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Tile(
                    label: '먼저 갚을 빚',
                    value: formatWon(e.seniorDebt),
                    danger: true,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          AppText(
            '빚이 집값보다 커서, 경매로 팔려도 내 차례가 오기 어려워요',
            style: AppTypographyNext.caption.copyWith(
              color: AppColorsNext.textBody,
            ),
          ),
        ],
      ),
    ),
    const SizedBox(height: 16),
    AppText(
      '최우선변제(보증금 일부를 먼저 받는 제도)는 아직 계산에 넣지 않았어요',
      style: AppTypographyNext.caption,
    ),
  ];
}

String _pct(double? v) {
  if (v == null) return '-';
  return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

String _count(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

// ── 부품 ───────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  const _Card({
    super.key,
    required this.child,
    this.color = AppColors.surface,
    this.padding = const EdgeInsets.all(20),
  });

  final Widget child;
  final Color color;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(20),
    ),
    child: child,
  );
}

/// 보증금 막대 — 돌려받음(초록) · 못 받음(빨강). 글 대신 모양으로 비율을 보여 준다.
class _DepositBar extends StatelessWidget {
  const _DepositBar({required this.back, required this.loss});

  final int back;
  final int loss;

  @override
  Widget build(BuildContext context) {
    final int total = back + loss;
    final int backFlex = total == 0 ? 0 : (back * 1000 / total).round();
    final int lossFlex = total == 0 ? 1 : 1000 - backFlex;
    return ClipRRect(
      key: const ValueKey('loss-bar'),
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 16,
        child: Row(
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
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    super.key,
    required this.color,
    required this.label,
    required this.value,
  });

  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      AppText('$label ', style: AppTypographyNext.caption),
      AppText(
        value,
        style: AppTypographyNext.caption.copyWith(
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    ],
  );
}

/// 계산 한 줄 — 왼쪽 이름(+ 작은 꼬리표), 오른쪽 금액
class _Step extends StatelessWidget {
  const _Step({
    required this.label,
    required this.value,
    this.tag,
    this.danger = false,
    this.strong = false,
    this.last = false,
  });

  final String label;
  final String value;
  final String? tag;
  final bool danger;
  final bool strong;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final TextStyle valueStyle = AppTypographyNext.bodyStrong.copyWith(
      color: danger
          ? AppColorsNext.dangerText
          : strong
          ? AppColors.primary
          : AppColorsNext.textStrong,
      fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: last
          ? null
          : const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColorsNext.divider)),
            ),
      child: Row(
        children: [
          AppText(
            label,
            style: strong
                ? AppTypographyNext.bodyStrong.copyWith(
                    color: AppColorsNext.textStrong,
                  )
                : AppTypographyNext.body.copyWith(
                    color: AppColorsNext.textBody,
                  ),
          ),
          if (tag != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(999),
              ),
              child: AppText(
                tag!,
                style: AppTypographyNext.caption.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ),
          ],
          const SizedBox(width: 12),
          Expanded(
            child: AppText(value, textAlign: TextAlign.right, style: valueStyle),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, this.danger = false});

  final String label;
  final String value;
  final bool danger;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(label, style: AppTypographyNext.caption),
        const SizedBox(height: 2),
        AppText(
          value,
          style: AppTypographyNext.title.copyWith(
            color: danger ? AppColorsNext.dangerText : AppColorsNext.textStrong,
          ),
        ),
      ],
    ),
  );
}

/// 근거 — 어디 값을 썼는지(지역·용도·기간·건수·출처) + 빠진 것 한 줄. 흐린 글씨, 맨 아래.
class _Basis extends StatelessWidget {
  const _Basis(this.e);

  final LossEstimate e;

  @override
  Widget build(BuildContext context) {
    final where = [
      if (e.region != null) e.region!,
      if (e.use != null) e.use!,
    ].join(' · ');
    final lines = <String>[
      [
        '$where 매각가율',
        if (e.period != null && e.period!.isNotEmpty) e.period!,
        if (e.soldCount != null) '${_count(e.soldCount!)}건',
      ].join(' · '),
      if (e.source != null && e.source!.isNotEmpty) '출처 ${e.source}',
      if (e.regionFallback) '이 지역 자료가 적어 전국 값을 썼어요',
      if (e.useGuessed) '집 종류를 확실히 몰라 가장 낮은 값을 썼어요',
      kLossNotIncludedLine,
    ];
    return Column(
      key: const ValueKey('loss-basis'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: AppText(l, style: AppTypographyNext.caption),
          ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 40),
    child: _Card(
      child: Column(
        children: [
          Icon(icon, size: 40, color: AppColorsNext.textMuted),
          const SizedBox(height: 12),
          AppText(
            title,
            key: const ValueKey('loss-message'),
            textAlign: TextAlign.center,
            style: AppTypographyNext.bodyStrong.copyWith(
              color: AppColorsNext.textStrong,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: AppText(
                  actionLabel!,
                  style: AppTypographyNext.button.copyWith(color: Colors.white),
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
