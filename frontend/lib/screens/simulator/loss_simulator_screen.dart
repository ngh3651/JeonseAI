/// S-09 손실 시뮬레이터 — 2026-10-28 다시 짰다 (손실 시뮬레이터 1단계).
///
/// "이 집이 경매로 넘어가면 보증금이 얼마나 돌아오나"를 **이 집의 지역·용도 매각가율**로 보여 준다.
/// 숫자는 전부 서버가 규칙으로 계산한다(`GET /api/reports/{id}/loss-estimate`) — 앱은 그리기만 한다.
///
/// 예전 화면에서 뺀 것과 이유:
/// - 낙찰가율 슬라이더(근거 없는 70% 예시값) → 대법원 매각통계의 지역·용도별 값 하나
/// - 보증보험 토글(가입하면 0원) → 시뮬레이터와 상관없다. 가입 가능성은 리포트 근거 카드가 말한다
/// - 시세가 없을 때 보증금을 기준가로 쓰던 계산 → 계산하지 않고 같은 화면에서 [입력하기]
///
/// 화면은 하나다: 보증금 막대(돌려받음 초록 · 못 받음 빨강) → 계산 4줄 → 근거(기준 · 기간 · 출처).
/// - 매매 시세는 **이 화면에서 바로** 넣고 고친다(연필). 넣은 값은 이 계산에만 쓴다 — 리포트는 그대로다.
/// - 시세가 없으면 같은 모양에 "매매 시세를 넣으면 계산돼요" + 회색 막대 + 금액 자리에 [입력하기].
/// - 화면엔 계산에 **쓴 것**만 적는다 — 넣지 않은 것·고른 이유를 설명하지 않는다(2026-10-28 규혁).
/// 글자·색은 판례·여정 리디자인과 같은 새 체계(`AppTypographyNext`·`AppColorsNext`).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/analysis_report.dart';
import '../../models/loss_estimate.dart';
import '../../repositories/analysis_repository.dart';
import '../../utils/money_format.dart';

/// 시세가 없을 때 위 카드 한 줄
const String kLossNeedPrice = '매매 시세를 넣으면 계산돼요';

/// 회색 막대 (시세가 없을 때)
Color get _kBarIdle => AppColors.barIdle;

class LossSimulatorScreen extends StatefulWidget {
  const LossSimulatorScreen({super.key, required this.reportId});

  final String reportId;

  @override
  State<LossSimulatorScreen> createState() => _LossSimulatorScreenState();
}

class _LossSimulatorScreenState extends State<LossSimulatorScreen> {
  late Future<(AnalysisReport?, LossEstimate?)> _future;

  /// 이 화면에서 사용자가 넣은 매매 시세(원) — 리포트에는 저장하지 않는다
  int? _price;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final repo = context.read<AnalysisRepository>();
    final int? price = _price;
    _future = () async {
      final reportF = repo.getReport(widget.reportId);
      LossEstimate? est;
      try {
        est = await repo.getLossEstimate(widget.reportId, marketPrice: price);
      } catch (_) {
        est = null;
      }
      AnalysisReport? report;
      try {
        report = await reportF;
      } catch (_) {
        report = null;
      }
      return (report, est);
    }();
  }

  Future<void> _editPrice(int? current) async {
    final int? won = await showDialog<int>(
      context: context,
      builder: (_) => _PriceDialog(initialWon: current),
    );
    if (won == null || !mounted) return;
    setState(() {
      _price = won;
      _load();
    });
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
                // 빚이 집값보다 커도, 시세가 없어도 같은 화면 (2026-10-28 화면 하나로)
                LossStatus.ok ||
                LossStatus.debtExceeds ||
                LossStatus.noPrice => _view(est),
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

  List<Widget> _view(LossEstimate e) {
    final bool priced = e.status != LossStatus.noPrice && e.basePrice != null;
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
            if (priced)
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
              )
            else
              AppText(
                kLossNeedPrice,
                key: const ValueKey('loss-need-price'),
                style: AppTypographyNext.headline.copyWith(
                  color: AppColorsNext.textStrong,
                ),
              ),
            const SizedBox(height: 16),
            if (priced)
              _DepositBar(back: back, loss: loss)
            else
              ClipRRect(
                key: const ValueKey('loss-bar-idle'),
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  height: 16,
                  width: double.infinity,
                  child: ColoredBox(color: _kBarIdle),
                ),
              ),
            if (priced) ...[
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
          ],
        ),
      ),
      const SizedBox(height: 12),
      _Card(
        key: const ValueKey('loss-steps'),
        padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
        child: Column(
          children: [
            _Step(
              key: const ValueKey('loss-price-row'),
              label: '매매 시세',
              value: priced ? formatWon(e.basePrice!) : '입력하기',
              action: !priced,
              onTap: () => _editPrice(priced ? e.basePrice : null),
            ),
            if (e.ratePct != null)
              _Step(
                label: '경매 낙찰가',
                tag: '${_pct(e.ratePct)}%',
                value: priced ? formatWon(e.expectedSale ?? 0) : '-',
              ),
            // 최우선변제(2026-10-31) — 낙찰가에서 **가장 먼저** 내 몫으로 빠진다(빚보다 앞). 그래서 이 자리다.
            if (e.hasPriority) _PriorityStep(e: e, priced: priced),
            _Step(
              label: '먼저 갚을 빚',
              value: '− ${formatWon(e.seniorDebt)}',
              danger: true,
            ),
            _Step(
              label: '내 몫',
              value: priced ? formatWon(back) : '-',
              strong: true,
              danger: priced && back == 0,
              last: true,
            ),
          ],
        ),
      ),
      if (e.ratePct != null) ...[const SizedBox(height: 16), _Basis(e)],
    ];
  }
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
    this.padding = const EdgeInsets.all(20),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding,
    decoration: BoxDecoration(
      color: AppColors.surface,
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
                child: ColoredBox(color: AppColors.ok),
              ),
            if (backFlex > 0 && lossFlex > 0) const SizedBox(width: 2),
            if (lossFlex > 0)
              Expanded(
                flex: lossFlex,
                child: ColoredBox(color: AppColorsNext.dangerText),
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

/// 계산 한 줄 — 왼쪽 이름(+ 작은 꼬리표 또는 연필), 오른쪽 금액.
///
/// 금액은 모든 줄이 **같은 오른쪽 끝**에 선다 — 연필은 이름 옆에 둬서 금액 정렬을 흐트리지 않는다.
class _Step extends StatelessWidget {
  const _Step({
    super.key,
    required this.label,
    required this.value,
    this.tag,
    this.danger = false,
    this.strong = false,
    this.last = false,
    this.action = false,
    this.onTap,
  });

  final String label;
  final String value;
  final String? tag;
  final bool danger;
  final bool strong;
  final bool last;

  /// 금액 자리가 [입력하기] 버튼 글씨
  final bool action;

  /// 있으면 줄 전체를 눌러 고친다(이름 옆 연필)
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final TextStyle valueStyle = AppTypographyNext.bodyStrong.copyWith(
      color: action || (strong && !danger)
          ? AppColors.primary
          : danger
          ? AppColorsNext.dangerText
          : AppColorsNext.textStrong,
      fontWeight: strong || action ? FontWeight.w700 : FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final row = Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
      decoration: last
          ? null
          : BoxDecoration(
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
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.edit_outlined,
              key: ValueKey('loss-price-edit'),
              size: 18,
              color: AppColorsNext.textMuted,
            ),
          ],
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
            child: AppText(
              value,
              textAlign: TextAlign.right,
              style: valueStyle,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return row;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: row,
      ),
    );
  }
}

/// 최우선변제 줄 (2026-10-31) — 이름 · 칩 · 금액 + 이 집에 맞춘 한 줄(지역 · 상한 · 어느 날짜의 표).
class _PriorityStep extends StatelessWidget {
  const _PriorityStep({required this.e, required this.priced});

  final LossEstimate e;
  final bool priced;

  @override
  Widget build(BuildContext context) {
    final String base = e.priorityBaseDate != null
        ? '${_dot(e.priorityBaseDate!)} ${e.priorityBaseKind ?? '담보'} 기준'
        : '담보가 없어 오늘 기준';
    // 지역 이름 뒤에 조사를 붙이지 않는다('서울특별시은' — 2026-10-31 페르소나 리뷰). 애매하면 따로 한 토막.
    String join(List<String?> parts) => [
      for (final p in parts)
        if (p != null && p.trim().isNotEmpty) p.trim(),
    ].join(' · ');
    final String? region = e.priorityRegion;
    final String? unsure = e.priorityRegionUnsure ? '지역이 애매해 보호가 적은 쪽으로 봤어요' : null;
    final (String value, Color color, String sub) = switch (e.priorityStatus) {
      PriorityStatus.ok => (
        priced ? '+ ${formatWon(e.priorityAmount)}' : '최대 ${formatWon(e.priorityLimit ?? 0)}',
        AppColors.ok,
        join([
          region,
          '보증금 ${formatWon(e.priorityCap ?? 0)} 이하',
          base,
          e.priorityHalfCapped ? '낙찰가의 절반까지' : null,
          unsure,
        ]),
      ),
      PriorityStatus.overCap => (
        '대상 아님',
        AppColorsNext.textMuted,
        join(['보증금 ${formatWon(e.priorityCap ?? 0)} 이하만 받아요', region, base, unsure]),
      ),
      PriorityStatus.blockedAuction => (
        '0원',
        AppColorsNext.dangerText,
        '이미 경매가 시작된 집이에요 · 경매 전에 입주한 세입자만 받아요',
      ),
      PriorityStatus.shared => (
        '나눠 받아요',
        AppColors.caution,
        '다가구는 다른 세입자와 낙찰가의 절반을 나눠요 · 혼자면 최대 ${formatWon(e.priorityLimit ?? 0)}',
      ),
      PriorityStatus.unknownDate => (
        '계산 못 함',
        AppColorsNext.textMuted,
        '빚이 잡힌 날짜를 못 읽어 어느 표인지 몰라요',
      ),
      PriorityStatus.none => ('-', AppColorsNext.textMuted, ''),
    };
    return Container(
      key: const ValueKey('loss-priority-row'),
      padding: const EdgeInsets.fromLTRB(0, 10, 8, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColorsNext.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AppText(
                '최우선변제',
                style: AppTypographyNext.body.copyWith(
                  color: AppColorsNext.textBody,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.chipBg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: AppText(
                  '먼저 받아요',
                  style: AppTypographyNext.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.chipFg,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AppText(
                  value,
                  textAlign: TextAlign.right,
                  style: AppTypographyNext.bodyStrong.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          if (sub.isNotEmpty) ...[
            const SizedBox(height: 4),
            AppText(
              sub,
              key: const ValueKey('loss-priority-sub'),
              // 흐린 글씨 금지(규혁 2026-10-31) — 이 집 한 줄은 본문 색으로
              style: AppTypographyNext.caption.copyWith(
                color: AppColorsNext.textBody,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (e.priorityTableStale) ...[
            const SizedBox(height: 4),
            AppText(
              '법령이 바뀌어 금액을 다시 확인하고 있어요',
              key: const ValueKey('loss-priority-stale'),
              style: AppTypographyNext.caption.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColors.caution,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 'YYYY-MM-DD' → 'YYYY.M.D'
String _dot(String iso) {
  final parts = iso.split('-');
  if (parts.length != 3) return iso;
  return '${parts[0]}.${int.tryParse(parts[1]) ?? parts[1]}.${int.tryParse(parts[2]) ?? parts[2]}';
}

/// 근거 — 기준 · 기간 · 출처 세 줄. 왼쪽 이름 칸을 맞춰 줄바꿈해도 가지런하다.
class _Basis extends StatelessWidget {
  const _Basis(this.e);

  final LossEstimate e;

  @override
  Widget build(BuildContext context) {
    final where = [
      if (e.region != null) e.region!,
      if (e.use != null) e.use!,
    ].join(' ');
    final rows = <(String, String)>[
      (
        '기준',
        [
          '$where 매각가율',
          if (e.soldCount != null) '${_count(e.soldCount!)}건',
        ].join(' · '),
      ),
      if (e.period != null && e.period!.isNotEmpty) ('기간', e.period!),
      if (e.source != null && e.source!.isNotEmpty) ('출처', e.source!),
      // 최우선변제 근거 (2026-10-31) — 법령 이름 + 고른 표
      if (e.hasPriority && e.prioritySource != null)
        (
          '법령',
          [
            e.prioritySource!,
            if (e.priorityTableFrom != null) '${_dot(e.priorityTableFrom!)} 개정 표',
          ].join(' · '),
        ),
    ];
    final TextStyle label = AppTypographyNext.caption.copyWith(
      fontWeight: FontWeight.w600,
      color: AppColorsNext.textMuted,
    );
    return Padding(
      key: const ValueKey('loss-basis'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (k, v) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 40, child: AppText(k, style: label)),
                  Expanded(child: AppText(v, style: AppTypographyNext.caption)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 매매 시세 입력 — 리포트의 [시세 입력하기] 창과 같은 모양(만원 단위 · 숫자만).
/// 다른 점: 다시 분석하지 않고 **이 화면 계산만** 바꾼다.
class _PriceDialog extends StatefulWidget {
  const _PriceDialog({this.initialWon});

  final int? initialWon;

  @override
  State<_PriceDialog> createState() => _PriceDialogState();
}

class _PriceDialogState extends State<_PriceDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initialWon == null || widget.initialWon! < 10000
        ? ''
        : '${widget.initialWon! ~/ 10000}',
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 만원 단위 입력 → 원. 비었거나 0이면 null.
  int? get _won {
    final digits = _ctrl.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    final int manwon = int.parse(digits);
    return manwon > 0 ? manwon * 10000 : null;
  }

  @override
  Widget build(BuildContext context) {
    final int? won = _won;
    return AlertDialog(
      title: const AppText('매매 시세'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText('이 집을 사고팔 때의 값(매매 시세)이에요.', style: AppTypographyNext.caption),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('loss-price-field'),
            controller: _ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(8),
            ],
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(suffixText: '만원'),
          ),
          const SizedBox(height: 6),
          AppText(
            won == null ? ' ' : '= ${formatWon(won)}',
            key: const ValueKey('loss-price-preview'),
            style: AppTypographyNext.caption.copyWith(color: AppColors.primary),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const AppText('취소'),
        ),
        TextButton(
          key: const ValueKey('loss-price-apply'),
          onPressed: won == null ? null : () => Navigator.of(context).pop(won),
          child: const AppText('계산하기'),
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
                  style: AppTypographyNext.button.copyWith(color: AppColors.onPrimary),
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
