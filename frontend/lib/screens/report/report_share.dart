/// 리포트 요약을 **글자로** 보내기 (2026-10-23, 서연 리뷰 #4 — "공유가 '곧 제공' 가짜 버튼").
///
/// 배우자·가족에게 "이 집 이렇대"를 보낼 때 쓴다. 사진은 보내지 않고 글자 한 줄 요약만 보낸다.
///
///     [전세AI프] {별칭} · {주소} · {분석일} 분석(등기부 {발급일}) · {등급}: {결정 한 줄} · 근거: {근거 카드 제목 2~3개} · 규칙 기반 판정
///
/// - 결론 한 줄은 등급별 고정 문구(`RiskGrade.decisionLabel`)다 — 규칙 엔진의 등급을 그대로 옮길 뿐, 새 판정이 아니다.
/// - **사람 이름은 기본으로 가린다**(`personNames` 규칙, 서버와 같은 `홍○○`). 시트의 스위치로 끌 수 있다
///   (내 가족에게 보낼 때). '사진 속 이름 가리기'가 켜져 있으면 리포트가 이미 가린 이름이라 끄더라도 가린 채로 나간다.
library;

import 'package:flutter/material.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../models/risk_grade.dart';
import '../../utils/money_format.dart';
import '../../utils/name_mask.dart';
import '../common/share_feedback.dart';

/// 요약에 넣는 근거 카드 제목 수 — 문자 한 줄에 읽히는 분량.
const int kShareEvidenceCount = 3;

/// 리포트 → 공유 글자 한 줄.
String reportShareText(AnalysisReport report, {bool hideNames = true}) {
  final String viewed = (report.registryViewedAt ?? '').trim();
  final String dates = viewed.isEmpty
      ? '${formatDate(report.analyzedAt)} 분석(등기부 발급일 확인 필요)'
      : '${formatDate(report.analyzedAt)} 분석(등기부 $viewed)';
  final String evidence = _topEvidenceTitles(report).join(', ');
  final parts = <String>[
    '[전세AI프] ${report.alias.trim()}',
    if (report.address.trim().isNotEmpty) report.address.trim(),
    dates,
    '${report.grade.label}: ${report.grade.decisionLabel}',
    if (evidence.isNotEmpty) '근거: $evidence',
    '규칙 기반 판정',
  ];
  final String text = parts.join(' · ');
  return hideNames ? maskNamesInText(text, report.personNames) : text;
}

/// 심각한 근거부터 [kShareEvidenceCount]개 제목. '명단 대조 아직 안 됨'(우리 데이터 문제)은 뺀다.
List<String> _topEvidenceTitles(AnalysisReport report) {
  int severity(RiskGrade g) => switch (g) {
    RiskGrade.danger => 2,
    RiskGrade.caution => 1,
    RiskGrade.ok => 0,
  };
  final visible = [
    for (final e in report.evidences)
      if (!(e.id == 'blacklist' && e.statusLabel == '명단 대조 아직 안 됨')) e,
  ];
  // 같은 심각도 안에서는 서버가 준 순서를 지킨다(안정 정렬)
  final indexed = [for (int i = 0; i < visible.length; i++) (i, visible[i])];
  indexed.sort((a, b) {
    final bySeverity = severity(b.$2.grade).compareTo(severity(a.$2.grade));
    return bySeverity != 0 ? bySeverity : a.$1.compareTo(b.$1);
  });
  return [
    for (final (_, e) in indexed.take(kShareEvidenceCount))
      if (e.title.trim().isNotEmpty) e.title.trim(),
  ];
}

/// [리포트 공유] — 보낼 글자를 먼저 보여 주고(이름 가리기 기본 켬), 안드로이드 공유 창을 연다.
Future<void> showReportShareSheet(BuildContext context, AnalysisReport report) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _ReportShareSheet(report: report),
  );
}

class _ReportShareSheet extends StatefulWidget {
  const _ReportShareSheet({required this.report});

  final AnalysisReport report;

  @override
  State<_ReportShareSheet> createState() => _ReportShareSheetState();
}

class _ReportShareSheetState extends State<_ReportShareSheet> {
  bool _hideNames = true;
  bool _sharing = false;

  Future<void> _share() async {
    setState(() => _sharing = true);
    final text = reportShareText(widget.report, hideNames: _hideNames);
    final navigator = Navigator.of(context);
    await shareWithFeedback(
      context,
      text,
      subject: '[전세AI프] ${widget.report.alias}',
    );
    if (!mounted) return;
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final text = reportShareText(widget.report, hideNames: _hideNames);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenPadding,
          AppSpacing.xs,
          AppSpacing.screenPadding,
          AppSpacing.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppText('리포트 요약 보내기', style: AppTypography.title),
            const SizedBox(height: AppSpacing.xs),
            AppText('이 글자만 보내요. 사진은 보내지 않아요.', style: AppTypography.caption),
            const SizedBox(height: AppSpacing.md),
            Container(
              key: const ValueKey('report-share-preview'),
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: AppColors.line),
              ),
              child: AppText(text, style: AppTypography.body),
            ),
            const SizedBox(height: AppSpacing.sm),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _hideNames,
              onChanged: _sharing
                  ? null
                  : (v) => setState(() => _hideNames = v),
              title: const AppText(
                '사람 이름 가리기',
                style: AppTypography.bodyStrong,
              ),
              subtitle: AppText(
                '받는 사람 화면에는 홍○○처럼 보여요',
                style: AppTypography.caption,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppPrimaryButton(
              label: '공유 창 열기',
              icon: Icons.ios_share,
              loading: _sharing,
              onPressed: _sharing ? null : _share,
            ),
          ],
        ),
      ),
    );
  }
}
