/// S-08 판례 매칭 — IA.md §6.
///
/// 현재 매물의 위험 패턴 칩 → 패턴별 큐레이션 판례 카드. 빈 상태는 다음 행동과 짝짓는다.
/// 판례는 전부 예시(E-3에서 큐레이션·출처 확정).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../models/content_models.dart';
import '../../repositories/analysis_repository.dart';
import '../../repositories/content_repository.dart';

class CaseMatchScreen extends StatelessWidget {
  const CaseMatchScreen({super.key, required this.reportId});

  final String reportId;

  @override
  Widget build(BuildContext context) {
    final analysisRepo = context.read<AnalysisRepository>();
    final contentRepo = context.read<ContentRepository>();

    return Scaffold(
      appBar: AppBar(title: const Text('판례 매칭')),
      body: FutureBuilder<AnalysisReport?>(
        future: analysisRepo.getReport(reportId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final report = snapshot.data;
          if (report == null) {
            return _error(context);
          }
          final patterns = report.riskLabels;
          final cases = contentRepo.matchedCases(riskPatterns: patterns);

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            children: [
              Text('이 매물의 위험 패턴', style: AppTypography.title),
              const SizedBox(height: AppSpacing.sm),
              if (patterns.isEmpty)
                Text('눈에 띄는 위험 패턴이 없어요', style: AppTypography.caption)
              else
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [for (final p in patterns) _patternChip(p)],
                ),
              const SizedBox(height: AppSpacing.xl),
              if (cases.isEmpty)
                _emptyState(context)
              else
                for (final c in cases) ...[
                  _caseCard(c),
                  const SizedBox(height: AppSpacing.md),
                ],
              const SizedBox(height: AppSpacing.xl),
              Text('판례 데이터는 계속 추가되고 있어요', style: AppTypography.caption),
              const SizedBox(height: AppSpacing.xxxl),
            ],
          );
        },
      ),
    );
  }

  Widget _patternChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.dangerSoft,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style: AppTypography.label.copyWith(color: AppColors.danger),
      ),
    );
  }

  Widget _caseCard(CaseMatch c) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(c.caseNo, style: AppTypography.caption),
          const SizedBox(height: AppSpacing.sm),
          Text(c.summary, style: AppTypography.bodyStrong),
          const SizedBox(height: AppSpacing.md),
          _row('결과', c.result, AppColors.danger),
          const SizedBox(height: AppSpacing.xs),
          _row('우리 매물과 공통점', c.commonPoint, AppColors.textBody),
        ],
      ),
    );
  }

  Widget _row(String label, String value, Color valueColor) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 108, child: Text(label, style: AppTypography.caption)),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            value,
            style: AppTypography.body.copyWith(color: valueColor),
          ),
        ),
      ],
    );
  }

  Widget _emptyState(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        children: [
          Text(
            '이 매물의 위험 패턴과 일치하는 판례가 아직 없어요. '
            '위험이 없다는 뜻은 아니니, 중개사에게 확인할 질문을 챙겨 가세요.',
            style: AppTypography.body,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.lg),
          AppCompactButton(
            label: '질문 생성기',
            icon: Icons.quiz_outlined,
            onPressed: () => context.push('/questions/$reportId'),
          ),
        ],
      ),
    );
  }

  Widget _error(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('리포트를 불러올 수 없어요', style: AppTypography.body),
          const SizedBox(height: AppSpacing.lg),
          AppCompactButton(label: '홈으로', onPressed: () => context.go('/home')),
        ],
      ),
    );
  }
}
