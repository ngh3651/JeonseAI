/// 표시 하나의 자세히 보기 — 하단 시트.
///
/// ⚠ **문구는 전부 백엔드가 준 것이다.** 제목(`title`)·본문(`body`)·공동명의 안내
///   (`caution`)·출처(`source`) 어느 것도 앱에서 고치거나 덧붙이지 않는다. 이 화면의
///   설득력은 "앱이 지어낸 말이 하나도 없다"에서 나온다.
///
/// 시안(2a 통합안) 대비 하나 더 둔 것: `caution` 블록.
/// 시안에는 그 슬롯이 없지만 백엔드가 **공동명의 안내**를 여기로 보낸다
/// ("이 집은 4명이 함께 가진 집이에요…"). 슬롯을 없애면 실제 정보가 사라지므로 남긴다.
library;

import 'package:flutter/material.dart';

import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/analysis_report.dart';
import '../../models/registry_mark_kind.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/text/phrase_text.dart';
import '../cases/case_card.dart' show caseRichText;
import '../../design_system/components/app_section.dart';
import '../common/ask_selection.dart';
import 'mark_title.dart';
import 'registry_findings.dart' show softenDashes;

/// 시트 진입 시간 (시안: 260ms cubic-bezier(.22,1,.36,1))
const Duration kSheetEnterDuration = Duration(milliseconds: 260);

/// 시트 퇴장 시간 — Material 기본값과 같게 둔다(닫힘은 빠를수록 좋다).
const Duration kSheetExitDuration = Duration(milliseconds: 200);

/// 핸들바 — 38×4
const double kSheetHandleWidth = 38;
const double kSheetHandleHeight = 4;

/// 시트를 연다.
///
/// ⚠ **`transitionAnimationController`를 직접 만들어 넘기지 않는다.**
///   예전에는 260ms를 맞추려고 컨트롤러를 만들어 넘기고 `future.whenComplete`에서
///   버렸는데, 그 future는 **퇴장 애니메이션이 끝나기 전에**(`didPop`이 부르는
///   `didComplete` 시점에) 완료된다. 그래서 되감기는 도중에 컨트롤러가 죽고,
///   `dismissed` 상태가 오지 않아 `finalizeRoute`가 불리지 않는다 →
///   **시트가 화면에 그대로 남는다.** 닫는 길 셋(딤 탭·드래그·뒤로가기)이 전부
///   "컨트롤러를 reverse한다"로 시작하므로 셋이 한꺼번에 막혔다(2026-07-27 실기기).
///   시간 조절은 [AnimationStyle]로 한다 — 컨트롤러는 route가 만들고 route가 버린다.
Future<void> showRegistryMarkSheet(
  BuildContext context,
  RegistryHighlight mark,
) {
  return showModalBottomSheet<void>(
    context: context,
    // 핸들바를 시안 규격(38×4, 구분선 색)으로 직접 그리므로 기본 핸들은 끈다.
    showDragHandle: false,
    backgroundColor: AppColors.surface,
    barrierColor: AppColors.viewerSheetScrim,
    isScrollControlled: true,
    sheetAnimationStyle: AnimationStyle(
      duration: kSheetEnterDuration,
      reverseDuration: kSheetExitDuration,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.sheet),
      ),
    ),
    builder: (_) => RegistryMarkSheet(mark: mark),
  );
}

/// 기본 확인 줄이 '이 집 맞춤 할 일'에 이미 있는 말인가 — 같은 말을 두 번 읽히지 않게 (2026-10-31 페르소나 리뷰).
///
/// 글자 두 개씩 묶음(띄어쓰기·굵게 표시 무시)이 할 일 한 줄에 **60% 이상** 들어 있으면 같은 말로 본다.
/// 거르기만 한다 — 문장을 고치지 않는다(문구는 백엔드 것).
bool coveredByPlan(String line, List<String> plan) {
  String norm(String t) => t.replaceAll('**', '').replaceAll(RegExp(r'[\s.,·()]'), '');
  Set<String> grams(String t) => {for (int i = 0; i + 2 <= t.length; i++) t.substring(i, i + 2)};
  final g = grams(norm(line));
  if (g.isEmpty) return false;
  for (final p in plan) {
    final pg = grams(norm(p));
    if (pg.isEmpty) continue;
    final hit = g.where(pg.contains).length;
    if (hit / g.length >= 0.6) return true;
  }
  return false;
}

/// 출처 한 줄 — 줄표 없이 "등기부 을구 · 사진에서 직접 찾은 위치"
String markSourceLine(String? source) {
  final raw = (source ?? '등기부 원본').replaceAll('이 앱이 사진에서 직접 찾은 위치', '사진에서 직접 찾은 위치');
  return softenDashes(raw).replaceAll(', ', ' · ');
}

/// 자세히 보기 (2026-10-31 두 번째 개편 — 규혁 "소제목이 안 보이고, 순서·구조가 엉망, 초록 AI 상자는 빼고, 확신 있게"):
/// [번호 · 톤 칩] 제목 → **이 집에서 본 것**(표, ✦ AI가 읽었어요) → **기본 확인**(점)
/// → **이 집 맞춤 할 일**(번호) → 공동명의 안내 → 근거 한 줄. 칸 사이마다 가는 줄.
///
/// 따져볼 곳이면 칸 아이콘·'AI가 읽었어요'·번호 원이 주황(따져볼 곳 색), 대조할 곳이면 초록. 용어 밑줄은 늘 초록.
/// 글자를 꾹 누르면 [챗봇에 묻기] — 시트를 닫고 챗봇으로 간다.
class RegistryMarkSheet extends StatelessWidget {
  const RegistryMarkSheet({super.key, required this.mark});

  final RegistryHighlight mark;

  @override
  Widget build(BuildContext context) {
    final tone = mark.markKind.tone;
    final color = AppColors.markSolid(tone);
    final accent = AppColors.markText(tone);
    // 용어 밑줄은 이 시트 글 전체에서 처음 한 번만(기본 확인 → 할 일 순서로 센다)
    final seenTerms = <String>{};
    // 기본 확인 = 어느 집에나 같은 원래 안내. 맞춤 할 일에 이미 있는 줄은 뺀다(같은 말 두 번 X)
    final basics = [
      for (final line in softenDashes(mark.body).split('\n'))
        if (line.trim().isNotEmpty && !coveredByPlan(line.trim(), mark.plan)) line.trim(),
    ];
    final markGlossary = mark.termGlossary;
    final hasFacts = mark.factRows.isNotEmpty || mark.facts.isNotEmpty;
    final sections = <Widget>[
      if (hasFacts)
        AppSection(
          icon: Icons.check_rounded,
          label: kSectionSeen,
          color: accent,
          note: kAiReadNote,
          child: mark.factRows.isNotEmpty
              ? _FactTable(key: const ValueKey('mark-sheet-facts'), rows: mark.factRows)
              : Wrap(
                  key: const ValueKey('mark-sheet-facts'),
                  spacing: 6,
                  runSpacing: 6,
                  children: [for (final f in mark.facts) _FactChip(f)],
                ),
        ),
      if (basics.isNotEmpty)
        AppSection(
          icon: Icons.menu_book_rounded,
          label: '기본 확인',
          color: accent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final line in basics)
                _DotRow(text: line, glossary: markGlossary, seenTerms: seenTerms),
            ],
          ),
        ),
      if (mark.plan.isNotEmpty)
        AppSection(
          icon: Icons.checklist_rounded,
          label: kSectionPlan,
          color: accent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < mark.plan.length; i++)
                _NumberedRow(
                  index: i + 1,
                  text: mark.plan[i],
                  glossary: markGlossary,
                  color: color,
                  seenTerms: seenTerms,
                ),
            ],
          ),
        ),
    ];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: AskSelectionArea(
              // 챗봇으로 가기 전에 시트부터 닫는다(시트가 챗봇 위에 남지 않게)
              beforeAsk: () => Navigator.of(context).maybePop(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: kSheetHandleWidth,
                      height: kSheetHandleHeight,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: AppColors.line,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      _SheetBadge(number: mark.badge, color: color),
                      const SizedBox(width: 8),
                      MarkTonePill(tone: tone),
                    ],
                  ),
                  const SizedBox(height: 10),
                  MarkTitle(
                    mark.title,
                    key: const ValueKey('mark-sheet-title'),
                    mutedColor: AppColorsNext.textMuted,
                    style: AppTypographyNext.title.copyWith(
                      fontSize: 21,
                      height: 1.4,
                      fontWeight: FontWeight.w800,
                      color: AppColorsNext.textStrong,
                    ),
                  ),
                  for (int i = 0; i < sections.length; i++)
                    i == 0
                        ? Padding(padding: const EdgeInsets.only(top: 20), child: sections[i])
                        : AppDivided(child: sections[i]),
                  if (mark.caution != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: AppColors.cautionSoft,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: AppText(
                        softenDashes(mark.caution!),
                        style: AppTypographyNext.body.copyWith(
                          color: AppColorsNext.textStrong,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                  // 출처 한 줄 — 이게 없으면 시트 문장이 "앱이 그냥 하는 말"로 읽힌다.
                  AppDivided(
                    child: AppText(
                      '근거 · ${markSourceLine(mark.source)}',
                      key: const ValueKey('mark-sheet-source'),
                      style: AppTypographyNext.caption.copyWith(
                        color: AppColorsNext.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 이 집에서 본 것 — 회색 둥근 줄마다 [이름 | 값]
class _FactTable extends StatelessWidget {
  const _FactTable({super.key, required this.rows});

  final List<List<String>> rows;

  // 리포트 근거 카드의 '이 집에서 본 것'과 같은 상자 — 회색 한 상자 + 줄 사이 가는 선(2026-11-01 디자인 점검)
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < rows.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: i == 0
                ? null
                : BoxDecoration(border: Border(top: BorderSide(color: AppColorsNext.divider))),
            child: rows[i][0].isEmpty
                ? _value(rows[i][1])
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 84,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: AppText(
                            rows[i][0],
                            style: AppTypographyNext.caption.copyWith(
                              fontWeight: FontWeight.w600,
                              color: AppColorsNext.textBody,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: _value(rows[i][1])),
                    ],
                  ),
          ),
      ],
    ),
  );

  // 값은 ' · ' 덩어리 사이에서만 줄이 바뀐다('1,978명과 맞춰봤어요 · 같은 이름 없음', 2026-11-01). `**굵게**`는 굵게 그린다.
  Widget _value(String v) => PhraseText(
    v,
    style: AppTypographyNext.bodyStrong.copyWith(
      fontSize: 17,
      height: 1.4,
      fontWeight: FontWeight.w700,
      color: AppColorsNext.textStrong,
    ),
  );
}

/// 옛 리포트(표 줄 없음)의 이 집에서 본 것 — 칩
class _FactChip extends StatelessWidget {
  const _FactChip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(999),
    ),
    child: AppText(
      text,
      style: AppTypographyNext.caption.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: AppColorsNext.textStrong,
      ),
    ),
  );
}

/// 기본 확인 한 줄 — 회색 점(체크는 '이미 확인됨'으로 읽혔다, 2026-10-31 페르소나 리뷰)
class _DotRow extends StatelessWidget {
  const _DotRow({required this.text, this.glossary = const {}, this.seenTerms});

  final String text;
  final Map<String, String> glossary;
  final Set<String>? seenTerms;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 5,
          height: 5,
          margin: const EdgeInsets.only(top: 11, left: 4, right: 4),
          decoration: BoxDecoration(color: AppColorsNext.textMuted, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: AppText.rich(
            caseRichText(
              context,
              text: text,
              base: AppTypographyNext.body.copyWith(
                fontSize: 17,
                color: AppColorsNext.textBody,
                height: 27 / 17,
              ),
              glossary: glossary,
              seenTerms: seenTerms,
            ),
          ),
        ),
      ],
    ),
  );
}

class _NumberedRow extends StatelessWidget {
  const _NumberedRow({
    required this.index,
    required this.text,
    required this.color,
    this.glossary = const {},
    this.seenTerms,
  });

  final int index;
  final String text;
  final Color color;
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
              color: Colors.white,
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
                fontSize: 17,
                color: AppColorsNext.textStrong,
                height: 1.5,
              ),
              glossary: glossary,
              seenTerms: seenTerms,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 톤 칩 — "따져볼 곳"(주황) · "대조할 곳"(초록). 시트·카드가 같은 칩을 쓴다.
class MarkTonePill extends StatelessWidget {
  const MarkTonePill({super.key, required this.tone});

  final MarkTone tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: AppColors.markHighlight(tone, selected: false),
      borderRadius: BorderRadius.circular(999),
    ),
    child: AppText(
      tone.legendVerb,
      textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2),
      style: AppTypographyNext.caption.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        color: AppColors.markText(tone),
      ),
    ),
  );
}

/// 시트 제목 앞 번호 원 — 사진 위 뱃지·카드 번호와 같은 것임을 잇는 표식.
class _SheetBadge extends StatelessWidget {
  const _SheetBadge({required this.number, required this.color});

  final int number;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 23,
      height: 23,
      // 제목 첫 줄과 눈높이를 맞춘다 (16.5sp × 1.4 기준)
      margin: const EdgeInsets.only(top: 1),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: AppText(
        '$number',
        // 사진 위 뱃지와 동작을 맞춘다(그쪽은 캔버스라 시스템 글꼴 확대가 안 걸린다)
        textScaler: TextScaler.noScaling,
        style: AppTypography.label.copyWith(
          color: Colors.white,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
