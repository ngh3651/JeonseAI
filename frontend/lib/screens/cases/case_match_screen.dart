/// S-08 판례 매칭 — IA.md §6. (사용자 노출 명칭: "판례" 유지 — 실제 법원 판결이라는
/// 신뢰 무게가 플래그십 차별화의 핵심. 화면 첫 등장에 '법원의 실제 판결' 툴팁만 붙임.)
///
/// 현재 매물의 위험 패턴 칩(쉬운 말) → 패턴별 큐레이션 판례 카드.
/// 판례가 있든 없든 하단에 "질문 챙기기" 다음 행동을 상시 둔다 (공포 뒤 행동 짝짓기).
/// 판례는 전부 예시(E-3에서 큐레이션·출처 확정).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_callout.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/components/app_pill.dart';
import '../../design_system/components/term_tooltip_sheet.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../models/content_models.dart';
import '../../repositories/analysis_repository.dart';
import '../../repositories/content_repository.dart';

class CaseMatchScreen extends StatefulWidget {
  const CaseMatchScreen({super.key, required this.reportId});

  final String reportId;

  @override
  State<CaseMatchScreen> createState() => _CaseMatchScreenState();
}

class _CaseMatchScreenState extends State<CaseMatchScreen> {
  String get reportId => widget.reportId;

  /// 위험 패턴 라벨을 지수도 이해할 쉬운 말로 (매칭 키는 원래 라벨 유지)
  static const _easyLabel = {
    '선순위 채권': '먼저 갚을 빚',
    '신탁등기': '소유권을 맡긴 집',
    '전세가율': '보증금 비율',
    '보증보험': '보증보험',
  };

  late Future<(AnalysisReport?, List<CaseMatch>)> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final analysisRepo = context.read<AnalysisRepository>();
    final contentRepo = context.read<ContentRepository>();
    _future = () async {
      // 칩(위험 패턴)은 리포트에서, 판례 목록은 서버 파생 결과에서 (계약 §2.2·§3.5)
      final report = await analysisRepo.getReport(reportId);
      if (report == null) return (null, const <CaseMatch>[]);
      final cases = await contentRepo.matchedCases(reportId);
      return (report, cases);
    }();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('판례 매칭')),
      body: FutureBuilder<(AnalysisReport?, List<CaseMatch>)>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _error(context, retryable: true);
          }
          final (report, cases) = snapshot.data!;
          if (report == null) {
            return _error(context);
          }
          final patterns = report.riskLabels;

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            children: [
              // '판례' 첫 등장에 툴팁으로 신뢰 무게를 짧게 설명 (용어는 유지)
              Text.rich(
                TextSpan(
                  style: AppTypography.body,
                  children: [
                    const TextSpan(text: '이 매물의 위험과 비슷한 상황에서 나온 '),
                    termSpan(
                      context,
                      term: '판례',
                      description:
                          '법원의 실제 판결이에요. 실제로 이런 일이 일어나 '
                          '법정까지 갔다는 뜻이라, 위험을 훨씬 더 무겁게 봐야 해요.',
                    ),
                    const TextSpan(text: '를 모았어요.'),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
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
                      '이 매물의 위험과 딱 맞는 판례가 아직 없어요. '
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
              Text('판례 데이터는 계속 추가되고 있어요', style: AppTypography.caption),
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

  Widget _error(BuildContext context, {bool retryable = false}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            retryable ? '데이터를 불러오지 못했어요\n서버 연결을 확인해 주세요' : '리포트를 불러올 수 없어요',
            style: AppTypography.body,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.lg),
          if (retryable)
            AppCompactButton(
              label: '다시 시도',
              icon: Icons.refresh,
              onPressed: () => setState(_load),
            )
          else
            AppCompactButton(
              label: '홈으로',
              onPressed: () => context.go('/home'),
            ),
        ],
      ),
    );
  }
}
