/// S-08 판례 매칭 — IA.md §6. (사용자 노출 명칭: "비슷한 피해 사례" — 지수 리뷰 반영)
///
/// 현재 매물의 위험 패턴 칩(쉬운 말) → 패턴별 큐레이션 사례 카드.
/// 사례가 있든 없든 하단에 "질문 챙기기" 다음 행동을 상시 둔다 (공포 뒤 행동 짝짓기).
/// 사례는 전부 예시(E-3에서 큐레이션·출처 확정).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_callout.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/components/app_pill.dart';
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

  /// 위험 패턴 라벨을 지수도 이해할 쉬운 말로 (매칭 키는 원래 라벨 유지)
  static const _easyLabel = {
    '선순위 채권': '먼저 갚을 빚',
    '신탁등기': '소유권을 맡긴 집',
    '전세가율': '보증금 비율',
    '보증보험': '보증보험',
  };

  @override
  Widget build(BuildContext context) {
    final analysisRepo = context.read<AnalysisRepository>();
    final contentRepo = context.read<ContentRepository>();

    return Scaffold(
      appBar: AppBar(title: const Text('비슷한 피해 사례')),
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
              Text('이 매물에서 눈에 띈 위험', style: AppTypography.title),
              const SizedBox(height: AppSpacing.sm),
              if (patterns.isEmpty)
                Text('눈에 띄는 위험 패턴이 없어요', style: AppTypography.caption)
              else
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final p in patterns)
                      AppPill(
                        label: _easyLabel[p] ?? p,
                        color: AppColors.danger,
                        background: AppColors.dangerSoft,
                      ),
                  ],
                ),
              const SizedBox(height: AppSpacing.xl),
              if (cases.isEmpty)
                AppCallout(
                  tone: CalloutTone.neutral,
                  text:
                      '이 매물의 위험과 딱 맞는 사례가 아직 없어요. '
                      '위험이 없다는 뜻은 아니니, 중개사에게 확인할 질문을 챙겨 가세요.',
                )
              else
                for (final c in cases) ...[
                  _caseCard(c),
                  const SizedBox(height: AppSpacing.md),
                ],
              const SizedBox(height: AppSpacing.lg),
              // 사례 유무와 상관없이 "그래서 뭘 하라"를 상시로 (지수 리뷰: 공포 뒤 행동)
              AppCallout(
                tone: CalloutTone.info,
                icon: Icons.shield_outlined,
                title: '이런 피해를 피하려면',
                text: '중개사무소에 가기 전에, 꼭 물어봐야 할 질문을 챙겨 가세요.',
                action: AppPrimaryButton(
                  label: '중개사에게 물어볼 질문 보기',
                  icon: Icons.quiz_outlined,
                  onPressed: () => context.push('/questions/$reportId'),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('사례 데이터는 계속 추가되고 있어요', style: AppTypography.caption),
              const SizedBox(height: AppSpacing.xxxl),
            ],
          );
        },
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
          const SizedBox(height: AppSpacing.sm),
          _row('우리 매물과 공통점', c.commonPoint, AppColors.textBody),
        ],
      ),
    );
  }

  Widget _row(String label, String value, Color valueColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTypography.caption),
        const SizedBox(height: 2),
        Text(value, style: AppTypography.body.copyWith(color: valueColor)),
      ],
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
