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
import '../cases/case_card.dart' show caseRichText;
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
  RegistryHighlight mark, {
  String? aiText,
}) {
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
    builder: (_) => RegistryMarkSheet(mark: mark, aiText: aiText),
  );
}

/// 이 표시와 같은 이야기를 하는 리포트 근거 카드 — 그 카드의 AI 설명을 시트에 함께 보여 준다(추가 호출 0).
String? evidenceIdForMark(String kind) => switch (kind) {
  'mortgage' || 'jeonse' || 'lease_registration' => 'senior_debt',
  'seizure' || 'provisional_seizure' || 'auction' || 'trust' => 'ownership',
  'pending_application' => 'pending',
  // 집주인 이름 — 공개 명단과 맞춰 본 카드(명단을 받았을 때만 설명이 있다, 아래 _aiFor가 '아직 안 됨'은 거른다)
  'owner' => 'blacklist',
  _ => null,
};

/// 출처 한 줄 — 줄표 없이 "등기부 을구 · 사진에서 직접 찾은 위치"
String markSourceLine(String? source) {
  final raw = (source ?? '등기부 원본').replaceAll('이 앱이 사진에서 직접 찾은 위치', '사진에서 직접 찾은 위치');
  return softenDashes(raw).replaceAll(', ', ' · ');
}

/// 자세히 보기 (2026-10-31 개편 — 규혁 "글자 체계·줄바꿈·볼드가 엉망, 쓸데없는 말·대시 빼고, AI가 쓰였으면"):
/// [톤 칩 · 번호] 제목 → **이 집에서 본 것**(칩) → **이 집 맞춤 할 일**(번호) → ✦ AI 설명(리포트 근거 카드의 설명)
/// → **기본 확인**(어느 집에나 같은 원래 안내, 줄마다) → 공동명의 안내 → 근거 한 줄. '위험도 판정이 아닙니다'는 뺐다.
class RegistryMarkSheet extends StatelessWidget {
  const RegistryMarkSheet({super.key, required this.mark, this.aiText});

  final RegistryHighlight mark;

  /// 같은 이야기를 하는 근거 카드의 AI 설명 (없으면 그 칸이 없다)
  final String? aiText;

  @override
  Widget build(BuildContext context) {
    final tone = mark.markKind.tone;
    final color = AppColors.markSolid(tone);
    final basics = [
      for (final line in softenDashes(mark.body).split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    final ai = aiText == null
        ? const <String>[]
        : [
            for (final p in softenDashes(aiText!).split('\n'))
              if (p.trim().isNotEmpty) p.trim(),
          ].take(2).toList();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
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
                AppText(
                  mark.title,
                  key: const ValueKey('mark-sheet-title'),
                  style: AppTypographyNext.title.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppColorsNext.textStrong,
                  ),
                ),
                if (mark.facts.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  const _Label('이 집에서 본 것'),
                  const SizedBox(height: 8),
                  Wrap(
                    key: const ValueKey('mark-sheet-facts'),
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final f in mark.facts)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: AppText(
                            f,
                            style: AppTypographyNext.caption.copyWith(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppColorsNext.textStrong,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                if (mark.plan.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  const _Label('이 집 맞춤 할 일'),
                  const SizedBox(height: 8),
                  for (int i = 0; i < mark.plan.length; i++)
                    _NumberedRow(index: i + 1, text: mark.plan[i]),
                ],
                if (ai.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    key: const ValueKey('mark-sheet-ai'),
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    decoration: BoxDecoration(
                      color: AppColors.primarySoft,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.auto_awesome, size: 15, color: AppColors.primary),
                            const SizedBox(width: 5),
                            AppText(
                              'AI가 이 집에 맞춰 쓴 설명',
                              style: AppTypographyNext.caption.copyWith(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primary,
                              ),
                            ),
                          ],
                        ),
                        for (final para in ai) ...[
                          const SizedBox(height: 6),
                          AppText.rich(
                            caseRichText(
                              context,
                              text: para,
                              base: AppTypographyNext.body.copyWith(
                                color: AppColorsNext.textStrong,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                if (basics.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  const _Label('기본 확인'),
                  const SizedBox(height: 8),
                  for (final line in basics)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Icon(Icons.check_circle_outline_rounded, size: 16, color: AppColorsNext.textMuted),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: AppText.rich(
                              caseRichText(
                                context,
                                text: line,
                                base: AppTypographyNext.body.copyWith(
                                  color: AppColorsNext.textBody,
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                if (mark.caution != null) ...[
                  const SizedBox(height: AppSpacing.sm),
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
                const SizedBox(height: 14),
                // 출처 한 줄 — 이게 없으면 시트 문장이 "앱이 그냥 하는 말"로 읽힌다.
                AppText(
                  '근거 · ${markSourceLine(mark.source)}',
                  key: const ValueKey('mark-sheet-source'),
                  style: AppTypographyNext.caption.copyWith(
                    color: AppColorsNext.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => AppText(
    text,
    style: AppTypographyNext.caption.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      color: AppColorsNext.textMuted,
    ),
  );
}

class _NumberedRow extends StatelessWidget {
  const _NumberedRow({required this.index, required this.text});

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
