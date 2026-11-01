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

import '../../design_system/components/source_label.dart' show kLegacyExplanationSource;
import '../../design_system/text/app_text.dart';
import '../../design_system/text/phrase_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/analysis_report.dart';
import '../../models/risk_grade.dart';
import '../../design_system/components/app_link_chip.dart';
import '../../design_system/components/app_section.dart';
import '../../utils/money_format.dart';
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

/// 근거 카드 → 사진 위 표시 종류 — [등기부에서 위치 보기]가 어느 표시로 갈지 (2026-11-01).
/// 표시가 없는 근거(전세가율·보증보험)는 빈 집합 — 칩을 달지 않는다.
Set<String> markKindsForEvidence(String evidenceId) => switch (evidenceId) {
  'senior_debt' => const {'mortgage', 'jeonse', 'lease_registration'},
  'ownership' => const {'seizure', 'provisional_seizure', 'auction', 'trust', 'lease_registration'},
  'pending' => const {'pending_application'},
  'blacklist' => const {'owner'},
  _ => const <String>{},
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
    this.locateFor,
    this.expandedIndex,
    this.focusKey,
  });

  /// 이미 정렬된 근거
  final List<EvidenceItem> items;

  /// 근거마다 행동 버튼(없으면 null)
  final Widget? Function(EvidenceItem) actionFor;

  /// [등기부에서 위치 보기] — 갈 수 없으면 null (2026-11-01)
  final VoidCallback? Function(EvidenceItem)? locateFor;

  /// 처음부터 펼쳐 둘 줄
  final int? expandedIndex;

  /// 펼쳐 둔 줄에 달 키 — 리포트가 그 자리로 내려간다
  final Key? focusKey;

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
              key: i == expandedIndex ? focusKey : null,
              item: items[i],
              action: actionFor(items[i]),
              onLocate: locateFor?.call(items[i]),
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
    this.onLocate,
    this.initiallyExpanded = false,
  });

  final EvidenceItem item;
  final Widget? action;

  /// [등기부에서 위치 보기] (없으면 칩이 없다)
  final VoidCallback? onLocate;
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 머리만 눌러 접고 편다 — 펼친 안의 칩·탭·글을 눌러도 닫히지 않게 (2026-11-01)
          Semantics(
            button: true,
            expanded: _open,
            label: '근거: ${e.title}',
            child: InkWell(
              onTap: () => setState(() => _open = !_open),
              child: Row(
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
                        // 용어가 많으면('신탁등기 · 압류 · 가압류 · 가처분') 한 줄에서 '…'로 잘렸다 —
                        // 두 줄까지, ' · ' 사이에서만 줄을 바꾼다(2026-11-01)
                        PhraseText(
                          '${e.grade.label} · ${e.termSubtitle}',
                          maxLines: 2,
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
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.only(left: 2, right: 6, top: 6),
              child: _details(context, e, tone.fg),
            ),
          ),
        ],
      ),
    );
  }

  /// 펼침 (2026-11-01 리디자인 — 캔버스 W-1~W-3, 규혁 "신문 보는 느낌 → 쉽지만 깊게, 하나의 앱"):
  /// [특별 상태] → **한눈에**(큰 한 줄 + 그림 하나) → **이 집에서 본 것**(✦ AI가 읽었어요) → **이 집 핵심**(굵은 머리말 문단,
  /// ✦ AI가 썼어요 — 모델이 썼을 때만) → **이 집 맞춤 할 일** → [등기부에서 위치 보기] · 행동 버튼 → 근거 한 줄.
  /// 숫자·그림·할 일은 서버 규칙 값 그대로. 옛 리포트(한 줄·그림 없음)는 기준 막대를 그린다.
  /// 색은 카드 등급 하나(아이콘 · ✦ · 할 일 번호). 용어 밑줄은 이 카드 글 전체에서 처음 한 번만.
  Widget _details(BuildContext context, EvidenceItem e, Color toneFg) {
    final String? status = e.statusLabel?.trim();
    final seenTerms = <String>{};
    final paragraphs = [
      for (final p in softenDashes(e.easyExplanation).split('\n'))
        if (p.trim().isNotEmpty) p.trim(),
    ];
    final visual = e.visual;
    // '✦ AI가 읽었어요'는 등기부에서 읽은 줄일 때만(전세가율·보증보험의 보증금·시세는 입력값이라 붙이지 않는다)
    final bool aiRead = const {'senior_debt', 'ownership', 'pending', 'blacklist'}.contains(e.id);

    Widget? seen;
    if (visual != null && visual.type == 'checks' && visual.items.isNotEmpty) {
      seen = EvidenceChecks(items: visual.items);
    } else if (e.points.isNotEmpty) {
      seen = EvidencePoints(points: e.points, visual: visual);
    } else if (e.detailText != null && e.detailText!.trim().isNotEmpty) {
      seen = Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(14)),
        child: AppText.rich(
          caseRichText(
            context,
            text: softenDashes(e.detailText!),
            base: AppTypographyNext.body.copyWith(color: AppColorsNext.textStrong, fontWeight: FontWeight.w600),
          ),
        ),
      );
    }

    final sections = <Widget>[
      if (seen != null)
        AppSection(
          icon: Icons.check_rounded,
          label: kSectionSeen,
          color: toneFg,
          note: aiRead ? kAiReadNote : null,
          child: seen,
        ),
      if (paragraphs.isNotEmpty)
        AppSection(
          key: ValueKey('finding-core-${e.id}'),
          icon: Icons.auto_awesome,
          label: kSectionCore,
          color: toneFg,
          // 'AI가 썼어요'는 **모델이 쓴 카드만**(서버가 카드마다 알려 준다). 준비된 문구에 'AI'라 쓰면 거짓말이다(2026-07-09 결정)
          note: explanationByAi(e.explanationSource) ? kAiWroteNote : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < paragraphs.length; i++)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 14),
                  child: LeadParagraph(text: paragraphs[i], glossary: e.termGlossary, seenTerms: seenTerms),
                ),
            ],
          ),
        ),
      if (e.todo.isNotEmpty)
        AppSection(
          icon: Icons.checklist_rounded,
          label: kSectionPlan,
          color: toneFg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < e.todo.length; i++)
                _TodoRow(index: i + 1, text: e.todo[i], glossary: e.termGlossary, color: toneFg, seenTerms: seenTerms),
            ],
          ),
        ),
    ];
    final bool hasFoot = widget.onLocate != null || widget.action != null;
    final bool hasSource = e.sourceText != null && e.sourceText!.trim().isNotEmpty;
    final bool hasTop = e.hero != null || visual != null || e.meter != null || (status != null && status.isNotEmpty && status != e.grade.label);
    return Column(
      key: ValueKey('finding-details-${e.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 서버가 등급 대신 붙인 특별 상태(예: "이 집 유형에는 쓸 수 없어요") — 등급은 위 줄이 말한다
        if (status != null && status.isNotEmpty && status != e.grade.label) ...[
          const SizedBox(height: 4),
          AppText(status, style: AppTypographyNext.caption.copyWith(fontWeight: FontWeight.w700, color: toneFg)),
        ],
        if (e.hero != null) ...[
          const SizedBox(height: 8),
          EvidenceHeroLine(hero: e.hero!, color: toneFg),
        ],
        if (visual != null && visual.type == 'queue')
          Padding(padding: const EdgeInsets.only(top: 14), child: EvidenceQueue(visual: visual))
        else if (visual != null && visual.type == 'checks')
          Padding(padding: const EdgeInsets.only(top: 12), child: EvidenceCheckMeter(visual: visual))
        else if (visual != null && visual.type == 'zones' && visual.value != null)
          Padding(padding: const EdgeInsets.only(top: 14), child: EvidenceZones(visual: visual))
        else if (e.meter != null)
          Padding(padding: const EdgeInsets.only(top: 8), child: EvidenceMeterBar(meter: e.meter!)),
        if (sections.isNotEmpty)
          hasTop
              ? AppDivided(child: AppSectionList(children: sections))
              : Padding(padding: const EdgeInsets.only(top: 8), child: AppSectionList(children: sections)),
        if (hasFoot || hasSource)
          AppDivided(
            gap: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (hasFoot)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (widget.onLocate != null)
                        AppLinkChip(
                          key: ValueKey('finding-locate-${e.id}'),
                          label: '등기부에서 위치 보기',
                          icon: Icons.image_search_rounded,
                          onTap: widget.onLocate!,
                        ),
                      if (widget.action != null) widget.action!,
                    ],
                  ),
                if (hasFoot && hasSource) const SizedBox(height: 12),
                if (hasSource)
                  AppText(
                    '근거 · ${softenDashes(e.sourceText!)}',
                    key: ValueKey('finding-source-${e.id}'),
                    style: AppTypographyNext.caption.copyWith(color: AppColorsNext.textMuted),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 이 설명을 모델(AI)이 썼나 — 서버가 카드마다 알려 준다(`explanationSource`, 계약 §2.2).
/// 준비된 문구거나 옛 리포트(알 수 없음)면 'AI'라고 하지 않는다 — 과대 표기 금지(2026-07-09 · 2026-10-31 페르소나 리뷰).
bool explanationByAi(String? source) {
  final s = source?.trim() ?? '';
  return s.isNotEmpty && s != '준비된 문구' && s != kLegacyExplanationSource;
}

/// 줄표(—, –)를 문장 끊기로 바꾼다 (2026-10-31 규혁 "대시는 AI 티가 난다"). 서버·AI 문장 모두 화면에서 한 번 더.
/// 문장이 끝난 자리(…요·…다 뒤)의 줄표는 마침표로, 그 밖은 쉼표로.
String softenDashes(String text) => text
    .replaceAllMapped(RegExp(r'([요다죠까])\s*[—–]\s*'), (m) => '${m[1]}. ')
    .replaceAll(RegExp(r'\s*[—–]\s*'), ', ')
    .replaceAll(RegExp(r',\s*,'), ',');

Color _pointTone(String tone) => switch (tone) {
  'danger' => AppColorsNext.dangerText,
  'caution' => AppColors.caution,
  'ok' => AppColors.ok,
  _ => AppColorsNext.textStrong,
};

/// 줄 서기 막대의 칸 색 — 빚은 진한 회색부터 차례로 옅게, 내 보증금은 위험 빨강 (2026-11-01)
Color queueColor(EvidenceVisualItem item, int debtIndex) {
  if (item.kind == 'mine') return AppColorsNext.dangerText;
  final dark = AppColors.isDark;
  const light = [Color(0xFF3D4A43), Color(0xFF7C8983), Color(0xFFA3ADA8), Color(0xFFC2C9C5)];
  const night = [Color(0xFFD5DDD8), Color(0xFFA9B4AE), Color(0xFF7F8B85), Color(0xFF5E6B64)];
  final list = dark ? night : light;
  return list[debtIndex.clamp(0, list.length - 1)];
}

/// 줄 서기 칸 번호 → 색 (빚 칸만 차례를 센다)
Color? queueColorAt(EvidenceVisual? visual, int? index) {
  if (visual == null || visual.type != 'queue' || index == null) return null;
  if (index < 0 || index >= visual.items.length) return null;
  int debt = 0;
  for (int i = 0; i < index; i++) {
    if (visual.items[i].kind != 'mine') debt++;
  }
  return queueColor(visual.items[index], debt);
}

/// 이 집에서 본 것 — 회색 바탕 줄마다: (색 점) 이름 · 작은 둘째 줄 | 값(굵게)
class EvidencePoints extends StatelessWidget {
  const EvidencePoints({super.key, required this.points, this.visual});

  final List<EvidencePoint> points;

  /// 위 그림 — 점 색을 맞춘다
  final EvidenceVisual? visual;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('finding-points'),
    decoration: BoxDecoration(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      children: [
        for (int i = 0; i < points.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: i == 0
                ? null
                : BoxDecoration(border: Border(top: BorderSide(color: AppColorsNext.divider))),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (queueColorAt(visual, points[i].dot) case final Color dot)
                  Container(
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(top: 7, right: 8),
                    decoration: BoxDecoration(color: dot, borderRadius: BorderRadius.circular(3)),
                  ),
                Expanded(
                  flex: 6,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 이름·둘째 줄·값 모두 ' · ' 덩어리 사이에서만 줄이 바뀐다(2026-11-01 — '…맞춰봤어요 · 같은' / '이름 없음')
                      PhraseText(
                        points[i].label,
                        style: AppTypographyNext.caption.copyWith(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColorsNext.textBody,
                        ),
                      ),
                      if ((points[i].sub ?? '').trim().isNotEmpty)
                        PhraseText(
                          points[i].sub!,
                          style: AppTypographyNext.caption.copyWith(fontSize: 14, color: AppColorsNext.textMuted),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 5,
                  child: PhraseText(
                    points[i].value,
                    textAlign: TextAlign.right,
                    style: AppTypographyNext.bodyStrong.copyWith(
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

/// 펼침 맨 위 큰 한 줄 — 한 줄에 맞춘다(넘치면 살짝 작게). [EvidenceHero.accent]만 등급 색.
class EvidenceHeroLine extends StatelessWidget {
  const EvidenceHeroLine({super.key, required this.hero, required this.color});

  final EvidenceHero hero;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final base = AppTypographyNext.title.copyWith(
      fontSize: 22,
      height: 31 / 22,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.4,
      color: AppColorsNext.textStrong,
    );
    final accent = hero.accent?.trim();
    final at = (accent == null || accent.isEmpty) ? -1 : hero.text.indexOf(accent);
    final span = at < 0
        ? TextSpan(text: hero.text, style: base)
        : TextSpan(
            style: base,
            children: [
              TextSpan(text: hero.text.substring(0, at)),
              TextSpan(text: accent, style: TextStyle(color: color)),
              TextSpan(text: hero.text.substring(at + accent!.length)),
            ],
          );
    return FittedBox(
      key: const ValueKey('finding-hero'),
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: AppText.rich(span, maxLines: 1),
    );
  }
}

/// 빚 카드 그림 — "경매로 팔리면 이 순서로 나눠 가져요" 막대 하나 + 경매로 팔리는 값 선 하나 (2026-11-01 캔버스 W-1).
/// 선 오른쪽은 흐리게(못 받는 돈). 아래 상자 = 돌려받을 돈.
class EvidenceQueue extends StatelessWidget {
  const EvidenceQueue({super.key, required this.visual});

  final EvidenceVisual visual;

  @override
  Widget build(BuildContext context) {
    final items = [for (final it in visual.items) if ((it.amount ?? 0) > 0) it];
    final int total = items.fold(0, (a, it) => a + (it.amount ?? 0));
    if (items.isEmpty || total <= 0) return const SizedBox.shrink();
    final int? cut = visual.cutAmount;
    final caption = AppTypographyNext.caption.copyWith(fontSize: 14, fontWeight: FontWeight.w700, color: AppColorsNext.textMuted);
    return Column(
      key: const ValueKey('finding-queue'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppText(cut != null ? '경매로 팔리면 이 순서로 나눠 가져요' : '먼저 받아 가는 순서예요', style: caption),
        SizedBox(height: cut != null ? 40 : 8),
        LayoutBuilder(
          builder: (context, box) {
            final double w = box.maxWidth;
            final double? cutX = cut == null ? null : (cut / total * w).clamp(0.0, w);
            int debtIndex = 0;
            double x = 0;
            final segs = <Widget>[];
            final labels = <Widget>[];
            for (int i = 0; i < items.length; i++) {
              final it = items[i];
              final double sw = (it.amount! / total * w);
              final color = queueColor(it, it.kind == 'mine' ? 0 : debtIndex);
              final bool dimmed = cutX != null && x >= cutX - 0.5;
              if (it.kind != 'mine') debtIndex++;
              segs.add(Positioned(
                left: x,
                top: 0,
                width: (sw - (i < items.length - 1 ? 2 : 0)).clamp(0.0, w),
                height: 40,
                child: ColoredBox(color: color),
              ));
              // 이름은 흐린 막 **위**에 — 흐린 칸에서도 읽히게(흐린 칸은 그 칸 색 글자, 진한 칸은 흰/진한 글자)
              if (sw > it.label.length * 13.0 + 16) {
                labels.add(Positioned(
                  left: x + 8,
                  top: 0,
                  height: 40,
                  width: sw - 12,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AppText(
                      it.label,
                      maxLines: 1,
                      textScaler: TextScaler.noScaling,
                      style: AppTypographyNext.caption.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: dimmed
                            ? (it.kind == 'mine' ? AppColorsNext.dangerText : AppColorsNext.textStrong)
                            : (AppColors.isDark ? const Color(0xFF0D1210) : Colors.white),
                      ),
                    ),
                  ),
                ));
              }
              x += sw;
            }
            return SizedBox(
              height: 40,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(
                        children: [
                          ...segs,
                          if (cutX != null)
                            Positioned(
                              left: cutX,
                              right: 0,
                              top: 0,
                              bottom: 0,
                              child: ColoredBox(color: AppColors.surface.withValues(alpha: 0.72)),
                            ),
                          ...labels,
                        ],
                      ),
                    ),
                  ),
                  if (cutX != null) ...[
                    Positioned(
                      left: cutX - 1,
                      top: -8,
                      width: 2,
                      height: 56,
                      child: ColoredBox(color: AppColorsNext.textStrong),
                    ),
                    Positioned(
                      left: (cutX - 80).clamp(0.0, (w - 170).clamp(0.0, w)),
                      top: -34,
                      child: Container(
                        height: 24,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppColorsNext.textStrong,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: AppText(
                          '${visual.cutLabel ?? '경매로 팔리는 값'} ${formatWon(cut!)}',
                          maxLines: 1,
                          textScaler: TextScaler.noScaling,
                          style: AppTypographyNext.caption.copyWith(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.surface,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
        if (cut != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Flexible(
                child: AppText('← 받는 돈', maxLines: 1, style: caption.copyWith(fontSize: 14, color: AppColorsNext.textStrong)),
              ),
              const SizedBox(width: 8),
              const Spacer(),
              Flexible(
                flex: 2,
                child: AppText('흐린 쪽은 못 받는 돈 →', maxLines: 1, textAlign: TextAlign.right, style: caption.copyWith(fontSize: 14)),
              ),
            ],
          ),
        ],
        if ((visual.resultValue ?? '').isNotEmpty) ...[
          const SizedBox(height: 14),
          EvidenceResultBox(visual: visual),
        ],
      ],
    );
  }
}

/// 돌려받을 돈 상자 — "경매로 가면 돌려받을 돈 / 내 보증금 2억 5,000만원 중 → 0원"
class EvidenceResultBox extends StatelessWidget {
  const EvidenceResultBox({super.key, required this.visual});

  final EvidenceVisual visual;

  @override
  Widget build(BuildContext context) {
    final Color fg = _pointTone(visual.resultTone);
    return Container(
      key: const ValueKey('finding-result'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(color: fg.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  visual.resultLabel ?? '경매로 가면 돌려받을 돈',
                  style: AppTypographyNext.caption.copyWith(fontSize: 14, fontWeight: FontWeight.w700, color: fg),
                ),
                if ((visual.resultSub ?? '').isNotEmpty)
                  PhraseText(visual.resultSub!, style: AppTypographyNext.caption.copyWith(color: AppColorsNext.textBody)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: AppText(
              visual.resultValue!,
              maxLines: 1,
              style: AppTypographyNext.headline.copyWith(fontSize: 28, fontWeight: FontWeight.w800, color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

/// 보증보험 그림 — 조건 칸 N개(통과 초록 · 막힘 빨강 · 모름 회색) + "통과 3 · 막힘 2"
class EvidenceCheckMeter extends StatelessWidget {
  const EvidenceCheckMeter({super.key, required this.visual});

  final EvidenceVisual visual;

  @override
  Widget build(BuildContext context) {
    final items = visual.items;
    final int pass = items.where((i) => i.ok == true).length;
    final int fail = items.where((i) => i.ok == false).length;
    final style = AppTypographyNext.caption.copyWith(fontSize: 14, fontWeight: FontWeight.w700);
    return Column(
      key: const ValueKey('finding-checks-meter'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (int i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: Container(
                  height: 10,
                  decoration: BoxDecoration(
                    color: switch (items[i].ok) {
                      true => AppColors.ok,
                      false => AppColorsNext.dangerText,
                      null => AppColorsNext.divider,
                    },
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            AppText('통과 $pass', style: style.copyWith(color: AppColorsNext.textMuted)),
            const Spacer(),
            if (fail > 0) AppText('막힘 $fail', style: style.copyWith(color: AppColorsNext.dangerText)),
          ],
        ),
      ],
    );
  }
}

/// 보증보험 조건 줄 — ✓/✕ 동그라미 + 조건 + 이 집 값
class EvidenceChecks extends StatelessWidget {
  const EvidenceChecks({super.key, required this.items});

  final List<EvidenceVisualItem> items;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('finding-checks'),
    decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(14)),
    child: Column(
      children: [
        for (int i = 0; i < items.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: i == 0 ? null : BoxDecoration(border: Border(top: BorderSide(color: AppColorsNext.divider))),
            child: Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: switch (items[i].ok) {
                      true => AppColors.ok,
                      false => AppColorsNext.dangerText,
                      null => AppColorsNext.textMuted,
                    },
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    switch (items[i].ok) {
                      true => Icons.check_rounded,
                      false => Icons.close_rounded,
                      null => Icons.question_mark_rounded,
                    },
                    size: 14,
                    color: AppColors.surface,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 6,
                  child: AppText(
                    items[i].label,
                    style: AppTypographyNext.caption.copyWith(fontSize: 15, fontWeight: FontWeight.w600, color: AppColorsNext.textBody),
                  ),
                ),
                const SizedBox(width: 8),
                // 값이 길면('아직 못 맞춰 봤어요') 이름 칸을 누르지 않게 폭을 나눠 쓴다(2026-11-01 — 이름이 세 줄로 접혔다)
                Flexible(
                  flex: 5,
                  child: PhraseText(
                    items[i].value ?? '',
                    textAlign: TextAlign.right,
                    style: AppTypographyNext.bodyStrong.copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: switch (items[i].ok) {
                        true => AppColors.ok,
                        false => AppColorsNext.dangerText,
                        null => AppColorsNext.textMuted,
                      },
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

/// 전세가율 그림 — 구간 색(초록 · 주황 · 빨강)을 깐 막대 + 이 집 자리 핀 하나
class EvidenceZones extends StatelessWidget {
  const EvidenceZones({super.key, required this.visual});

  final EvidenceVisual visual;

  @override
  Widget build(BuildContext context) {
    final zones = visual.zones.length >= 2 ? visual.zones : const [80, 90];
    final int v = visual.value!.clamp(0, 100);
    final Color pin = _pointTone(visual.tone == 'plain' ? 'ok' : visual.tone);
    return SizedBox(
      key: const ValueKey('finding-zones'),
      height: 44,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          double xOf(int p) => p / 100 * w;
          final bands = [
            (0, zones[0], AppColors.ok),
            (zones[0], zones[1], AppColors.caution),
            (zones[1], 100, AppColorsNext.dangerText),
          ];
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 4,
                height: 14,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: Stack(
                    children: [
                      for (final (a, b, c) in bands)
                        Positioned(
                          left: xOf(a),
                          width: (xOf(b) - xOf(a) - (b < 100 ? 2 : 0)).clamp(0.0, w),
                          top: 0,
                          bottom: 0,
                          child: ColoredBox(color: c.withValues(alpha: 0.22)),
                        ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: xOf(v) - 11,
                top: 0,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: pin, width: 4),
                  ),
                ),
              ),
              for (final (p, c, right) in [(zones[0], AppColors.caution, true), (zones[1], AppColorsNext.dangerText, false)])
                Positioned(
                  left: right ? xOf(p) - 44 : xOf(p) + 2,
                  width: 42,
                  top: 24,
                  child: AppText(
                    '$p%',
                    textAlign: right ? TextAlign.right : TextAlign.left,
                    textScaler: TextScaler.noScaling,
                    style: AppTypographyNext.caption.copyWith(fontSize: 14, fontWeight: FontWeight.w700, color: c),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// AI 글 한 문단 — "**머리말** 본문"이면 머리말을 굵은 한 줄로 세우고 본문을 그 아래에 (2026-11-01).
class LeadParagraph extends StatelessWidget {
  const LeadParagraph({super.key, required this.text, this.glossary = const {}, this.seenTerms});

  final String text;
  final Map<String, String> glossary;
  final Set<String>? seenTerms;

  @override
  Widget build(BuildContext context) {
    final p = splitLeadParagraph(text);
    final body = AppTypographyNext.body.copyWith(color: AppColorsNext.textBody);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (p.lead != null)
          AppText(
            p.lead!,
            style: AppTypographyNext.bodyStrong.copyWith(fontSize: 17, height: 25 / 17, fontWeight: FontWeight.w800, color: AppColorsNext.textStrong),
          ),
        if (p.body.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: p.lead != null ? 3 : 0),
            child: AppText.rich(
              caseRichText(context, text: p.body, base: body, glossary: glossary, seenTerms: seenTerms),
            ),
          ),
      ],
    );
  }
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

/// 할 일 한 줄 — 카드 등급 색 번호 원 + 문장(**굵게** 표시)
class _TodoRow extends StatelessWidget {
  const _TodoRow({required this.index, required this.text, required this.color, this.glossary = const {}, this.seenTerms});

  final int index;
  final String text;
  final Color color;

  /// 할 일 속 어려운 말(말소·특약 …) 풀이 — 누르면 뜻 (2026-10-31 페르소나 리뷰)
  final Map<String, String> glossary;
  final Set<String>? seenTerms;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          margin: const EdgeInsets.only(top: 1),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: AppText(
            '$index',
            textScaler: TextScaler.noScaling,
            style: AppTypographyNext.caption.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: AppColors.surface,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: AppText.rich(
            caseRichText(
              context,
              text: text,
              base: AppTypographyNext.body.copyWith(color: AppColorsNext.textStrong),
              glossary: glossary,
              seenTerms: seenTerms,
            ),
          ),
        ),
      ],
    ),
  );
}
