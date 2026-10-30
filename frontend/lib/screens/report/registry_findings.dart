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

  /// 펼침 (2026-10-31 개편 — 규혁 "가독성 최악, 이 집 맞춤으로 쏠쏠하게"):
  /// [특별 상태] → 기준 막대 → **이 집 숫자** 줄 → ✦ AI 설명(문단마다 띄움) → **이 집에서 할 일** → 근거 한 줄 → 행동 버튼.
  /// 숫자·할 일은 서버 규칙 값 그대로(`evidence_view.py`). 옛 리포트(숫자 줄 없음)는 예전 상세 상자를 그린다.
  Widget _details(BuildContext context, EvidenceItem e, Color toneFg) {
    final String? status = e.statusLabel?.trim();
    final paragraphs = [
      for (final p in softenDashes(e.easyExplanation).split('\n'))
        if (p.trim().isNotEmpty) p.trim(),
    ];
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
          const SizedBox(height: 10),
        ],
        if (e.meter != null) ...[
          EvidenceMeterBar(meter: e.meter!),
          const SizedBox(height: 12),
        ],
        if (e.points.isNotEmpty) ...[
          EvidencePoints(points: e.points),
          const SizedBox(height: 16),
        ] else if (e.detailText != null && e.detailText!.trim().isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(14),
            ),
            child: AppText.rich(
              caseRichText(
                context,
                text: softenDashes(e.detailText!),
                base: AppTypographyNext.body.copyWith(
                  color: AppColorsNext.textStrong,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        const _SectionLabel(icon: Icons.auto_awesome, text: 'AI 설명', ai: true),
        const SizedBox(height: 6),
        for (int i = 0; i < paragraphs.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          AppText.rich(
            caseRichText(
              context,
              text: paragraphs[i],
              base: AppTypographyNext.body.copyWith(
                color: AppColorsNext.textBody,
                height: 1.55,
              ),
              glossary: e.termGlossary,
            ),
          ),
        ],
        if (e.todo.isNotEmpty) ...[
          const SizedBox(height: 16),
          const _SectionLabel(icon: Icons.checklist_rounded, text: '이 집에서 할 일'),
          const SizedBox(height: 8),
          for (int i = 0; i < e.todo.length; i++)
            _TodoRow(index: i + 1, text: e.todo[i]),
        ],
        if (e.sourceText != null && e.sourceText!.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          AppText(
            '근거 · ${softenDashes(e.sourceText!)}',
            key: ValueKey('finding-source-${e.id}'),
            style: AppTypographyNext.caption.copyWith(
              color: AppColorsNext.textMuted,
            ),
          ),
        ],
        if (widget.action != null) ...[
          const SizedBox(height: 14),
          Align(alignment: Alignment.centerLeft, child: widget.action!),
        ],
      ],
    );
  }
}

/// 줄표(—, –)를 문장 끊기로 바꾼다 (2026-10-31 규혁 "대시는 AI 티가 난다"). 서버·AI 문장 모두 화면에서 한 번 더.
/// 문장이 끝난 자리(…요·…다 뒤)의 줄표는 마침표로, 그 밖은 쉼표로.
String softenDashes(String text) => text
    .replaceAllMapped(RegExp(r'([요다죠까])\s*[—–]\s*'), (m) => '${m[1]}. ')
    .replaceAll(RegExp(r'\s*[—–]\s*'), ', ')
    .replaceAll(RegExp(r',\s*,'), ',');

/// 펼침 안 작은 제목 — "✦ AI 설명"(초록) · "이 집에서 할 일"
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.text, this.ai = false});

  final IconData icon;
  final String text;
  final bool ai;

  @override
  Widget build(BuildContext context) {
    final Color fg = ai ? AppColors.primary : AppColorsNext.textMuted;
    return Row(
      children: [
        Icon(icon, size: 15, color: fg),
        const SizedBox(width: 5),
        AppText(
          text,
          style: AppTypographyNext.caption.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: fg,
          ),
        ),
      ],
    );
  }
}

Color _pointTone(String tone) => switch (tone) {
  'danger' => AppColorsNext.dangerText,
  'caution' => AppColors.caution,
  'ok' => AppColors.ok,
  _ => AppColorsNext.textStrong,
};

/// 이 집 숫자 — 회색 바탕 안에 이름(왼쪽) · 값(오른쪽, 굵게) 줄들
class EvidencePoints extends StatelessWidget {
  const EvidencePoints({super.key, required this.points});

  final List<EvidencePoint> points;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('finding-points'),
    padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
    decoration: BoxDecoration(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      children: [
        for (int i = 0; i < points.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: i == points.length - 1
                ? null
                : BoxDecoration(
                    border: Border(bottom: BorderSide(color: AppColorsNext.divider)),
                  ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: AppText(
                    points[i].label,
                    style: AppTypographyNext.caption.copyWith(
                      fontSize: 14,
                      color: AppColorsNext.textBody,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 6,
                  child: AppText(
                    points[i].value,
                    textAlign: TextAlign.right,
                    style: AppTypographyNext.bodyStrong.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: _pointTone(points[i].tone),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// 기준 막대 — 0~100%(넘으면 끝에 붙음), 기준선 눈금, 이 집 값 점
class EvidenceMeterBar extends StatelessWidget {
  const EvidenceMeterBar({super.key, required this.meter});

  final EvidenceMeter meter;

  @override
  Widget build(BuildContext context) {
    final Color fg = _pointTone(meter.tone);
    final double v = (meter.value.clamp(0, 100)) / 100;
    return Column(
      key: const ValueKey('finding-meter'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: AppText(
                meter.label,
                style: AppTypographyNext.caption.copyWith(
                  fontSize: 14,
                  color: AppColorsNext.textBody,
                ),
              ),
            ),
            AppText(
              '${meter.value}%',
              style: AppTypographyNext.title.copyWith(
                fontWeight: FontWeight.w800,
                color: fg,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            return SizedBox(
              height: 22,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 5,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        height: 10,
                        child: Stack(
                          children: [
                            Positioned.fill(child: ColoredBox(color: AppColors.barIdle)),
                            Positioned(
                              left: 0,
                              top: 0,
                              bottom: 0,
                              width: w * v,
                              child: ColoredBox(color: fg),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  for (final m in meter.marks)
                    Positioned(
                      left: (w * (m.clamp(0, 100) / 100)) - 1,
                      top: 0,
                      bottom: 0,
                      child: Container(width: 2, color: AppColorsNext.textStrong),
                    ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 4),
        AppText(
          '기준선 ${meter.marks.map((m) => '$m%').join(' · ')}',
          style: AppTypographyNext.caption.copyWith(color: AppColorsNext.textMuted),
        ),
      ],
    );
  }
}

/// 할 일 한 줄 — 번호 원 + 문장(**굵게** 표시)
class _TodoRow extends StatelessWidget {
  const _TodoRow({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          margin: const EdgeInsets.only(top: 1),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: AppColors.primarySoft, shape: BoxShape.circle),
          child: AppText(
            '$index',
            textScaler: TextScaler.noScaling,
            style: AppTypographyNext.caption.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: AppColors.primaryStrong,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: AppText.rich(
            caseRichText(
              context,
              text: text,
              base: AppTypographyNext.body.copyWith(
                color: AppColorsNext.textStrong,
                height: 1.45,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

