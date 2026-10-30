/// 리포트 1장 '등기부에서 찾은 것'의 **근거 목록** (2026-10-28 '1장 다듬기' 시안).
///
/// - 위에 요약 한 줄(● 위험 N ● 확인 필요 N ● 양호 N) — 카드 밖
/// - 둥근 흰 상자 안에 근거 한 줄씩: [등급 동그라미 아이콘] 제목(한 줄) / 등급 · 부제(한 줄) [⌄]
///   - 위험 아이콘은 판례 화면과 같은 **삼각형 느낌표**(warning_amber_rounded) + 연분홍 원
/// - 누르면 펼침: (서버 특별 상태 문구) → 숫자 상자 → 쉬운 설명 → 행동 버튼
///   글자는 판례 카드와 **같은 체계**(caseRichText — 굵게 · 초록 실선 밑줄 용어 → 풀이 시트)
///
/// 화면에서 뺀 것 (2026-10-28 규혁 — 데이터는 그대로 남아 있다, docs/decisions.md):
/// - "판정 · 규칙 기반 (…기준)" · "✦ 설명 · solar-pro2" 출처 칩 → 판단 기준은 나중에 따로 모아 보여 줄 자리
/// - "중개사에게 물어볼 질문 보기" 버튼 → 질문은 따로 항목이 있다
library;

import 'package:flutter/material.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/analysis_report.dart';
import '../../models/risk_grade.dart';
import '../cases/case_card.dart' show caseRichText;

/// 등급별 색·아이콘 — 위험은 판례 화면과 같은 삼각형 느낌표
({Color fg, Color bg, IconData icon}) _toneOf(RiskGrade g) => switch (g) {
  RiskGrade.danger => (
    fg: AppColorsNext.dangerText,
    bg: AppColors.dangerSoft,
    icon: Icons.warning_amber_rounded,
  ),
  RiskGrade.caution => (
    fg: AppColors.caution,
    bg: AppColors.cautionSoft,
    icon: Icons.question_mark_rounded,
  ),
  RiskGrade.ok => (
    fg: AppColors.ok,
    bg: AppColors.okSoft,
    icon: Icons.check_rounded,
  ),
};

int _severity(RiskGrade g) => switch (g) {
  RiskGrade.danger => 2,
  RiskGrade.caution => 1,
  RiskGrade.ok => 0,
};

/// 위험 → 확인 필요 → 양호 순 (같은 등급은 서버 순서 그대로)
List<EvidenceItem> sortBySeverity(List<EvidenceItem> items) {
  final indexed = [for (int i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((a, b) {
    final s = _severity(b.$2.grade).compareTo(_severity(a.$2.grade));
    return s != 0 ? s : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// 요약 한 줄 — 0개인 등급은 빼고 적는다
class FindingsSummary extends StatelessWidget {
  const FindingsSummary({super.key, required this.items});

  final List<EvidenceItem> items;

  @override
  Widget build(BuildContext context) {
    final parts = [
      for (final g in const [RiskGrade.danger, RiskGrade.caution, RiskGrade.ok])
        (g, items.where((e) => e.grade == g).length),
    ].where((p) => p.$2 > 0);
    return Padding(
      key: const ValueKey('findings-summary'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Wrap(
        spacing: 14,
        runSpacing: 4,
        children: [
          for (final (g, n) in parts)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _toneOf(g).fg,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                AppText(
                  '${g.label} $n',
                  style: AppTypographyNext.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: _toneOf(g).fg,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 둥근 흰 상자 + 근거 줄들
class FindingsCard extends StatelessWidget {
  const FindingsCard({
    super.key,
    required this.items,
    required this.actionFor,
    this.expandedIndex,
  });

  /// 이미 정렬된 근거
  final List<EvidenceItem> items;

  /// 근거마다 행동 버튼(없으면 null)
  final Widget? Function(EvidenceItem) actionFor;

  /// 처음부터 펼쳐 둘 줄 (가장 심각한 1개)
  final int? expandedIndex;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('findings-card'),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                color: AppColorsNext.divider,
              ),
            FindingRow(
              item: items[i],
              action: actionFor(items[i]),
              initiallyExpanded: i == expandedIndex,
            ),
          ],
        ],
      ),
    );
  }
}

class FindingRow extends StatefulWidget {
  const FindingRow({
    super.key,
    required this.item,
    this.action,
    this.initiallyExpanded = false,
  });

  final EvidenceItem item;
  final Widget? action;
  final bool initiallyExpanded;

  @override
  State<FindingRow> createState() => _FindingRowState();
}

class _FindingRowState extends State<FindingRow> {
  late bool _open = widget.initiallyExpanded;

  /// 아이콘 동그라미 + 간격 — 펼침 내용이 제목과 같은 선에서 시작하게
  static const double _iconBox = 28;
  static const double _iconGap = 10;

  @override
  Widget build(BuildContext context) {
    final e = widget.item;
    final tone = _toneOf(e.grade);
    return Semantics(
      button: true,
      expanded: _open,
      label: '근거: ${e.title}',
      child: InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: _iconBox,
                    height: _iconBox,
                    decoration: BoxDecoration(
                      color: tone.bg,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(tone.icon, size: 17, color: tone.fg),
                  ),
                  const SizedBox(width: _iconGap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 제목은 **한 줄** — 넘치면 줄이지 않고 살짝 작아진다(글자 130%에서도)
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: AppText(
                            e.title,
                            maxLines: 1,
                            style: AppTypographyNext.bodyStrong.copyWith(
                              color: AppColorsNext.textStrong,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ),
                        AppText(
                          '${e.grade.label} · ${e.termSubtitle}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypographyNext.caption.copyWith(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: tone.fg,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: AppColorsNext.textMuted,
                  ),
                ],
              ),
              AnimatedCrossFade(
                duration: const Duration(milliseconds: 180),
                crossFadeState: _open
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                firstChild: const SizedBox(width: double.infinity),
                secondChild: Padding(
                  padding: const EdgeInsets.only(
                    left: _iconBox + _iconGap,
                    right: 6,
                    top: 12,
                  ),
                  child: _details(context, e, tone.fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _details(BuildContext context, EvidenceItem e, Color toneFg) {
    final String? status = e.statusLabel?.trim();
    return Column(
      key: ValueKey('finding-details-${e.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 서버가 등급 대신 붙인 특별 상태(예: "이 집 유형에는 쓸 수 없어요") — 등급은 위 줄이 말한다
        if (status != null && status.isNotEmpty && status != e.grade.label) ...[
          AppText(
            status,
            style: AppTypographyNext.caption.copyWith(
              fontWeight: FontWeight.w700,
              color: toneFg,
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (e.detailText != null && e.detailText!.trim().isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(14),
            ),
            child: AppText.rich(
              caseRichText(
                context,
                text: e.detailText!,
                base: AppTypographyNext.body.copyWith(
                  color: AppColorsNext.textStrong,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        AppText.rich(
          caseRichText(
            context,
            text: e.easyExplanation,
            base: AppTypographyNext.body.copyWith(
              color: AppColorsNext.textBody,
            ),
            glossary: e.termGlossary,
          ),
        ),
        if (widget.action != null) ...[
          const SizedBox(height: 14),
          Align(alignment: Alignment.centerLeft, child: widget.action!),
        ],
      ],
    );
  }
}
