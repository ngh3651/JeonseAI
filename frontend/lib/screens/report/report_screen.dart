/// S-07 AI 안전도 리포트 — 핵심 화면 (IA.md §6).
///
/// 구조: 결론 헤더(게이지 크게 + 의사결정 한 줄 + 보증금) → 지금 해야 할 일(+질문 버튼)
/// → 근거 카드(최고 심각도 1개 기본 펼침, 용어 툴팁) → 다음 행동(등급별 추천 강조).
/// 판례·질문 생성기·체크리스트·공유는 C-3에서 실화면 연결 (스텁 문구는 사용자 언어로).
/// 2026-07-04 C-2 리뷰 3종(design-reviewer·persona 2인) 반영.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/components/risk_badge.dart';
import '../../design_system/components/safety_gauge.dart';
import '../../design_system/components/term_tooltip_sheet.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../models/risk_grade.dart';
import '../../repositories/analysis_repository.dart';
import '../../utils/money_format.dart';

class ReportScreen extends StatelessWidget {
  const ReportScreen({super.key, required this.reportId});

  final String reportId;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<AnalysisRepository>();

    return FutureBuilder<AnalysisReport?>(
      future: repo.getReport(reportId),
      builder: (context, snapshot) {
        final AnalysisReport? report = snapshot.data;

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (report == null) {
          // 이력 손상/없음 (user-scenario.md §5) — 막다른 길 방지 CTA 포함
          return Scaffold(
            appBar: AppBar(title: const Text('안전도 리포트')),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('이 리포트를 불러올 수 없어요', style: AppTypography.body),
                  const SizedBox(height: AppSpacing.lg),
                  AppCompactButton(
                    label: '홈으로',
                    onPressed: () => context.go('/home'),
                  ),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(report.alias),
            actions: [
              IconButton(
                icon: const Icon(Icons.ios_share),
                tooltip: '리포트 공유',
                onPressed: () => _stub(context),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            children: [
              if (_isStale(report)) _staleBanner(context, report),
              _conclusionHeader(report),
              const SizedBox(height: AppSpacing.xl),
              _nextActionCard(context, report),
              const SizedBox(height: AppSpacing.xxxl),
              const Text('근거 살펴보기', style: AppTypography.title),
              const SizedBox(height: AppSpacing.xs),
              Text('카드를 탭하면 쉬운 설명과 출처가 열려요', style: AppTypography.caption),
              const SizedBox(height: AppSpacing.md),
              ..._evidenceCards(context, report),
              const SizedBox(height: AppSpacing.xl),
              const Text('다음 행동', style: AppTypography.title),
              const SizedBox(height: AppSpacing.md),
              ..._actionArea(context, report),
              const SizedBox(height: AppSpacing.xxxl),
            ],
          ),
        );
      },
    );
  }

  bool _isStale(AnalysisReport report) =>
      DateTime.now().difference(report.analyzedAt).inDays >= 1;

  /// 오래된 분석 배너 — 컴팩트 한 줄 (결론을 밀어내지 않게, 서연 리뷰 반영)
  Widget _staleBanner(BuildContext context, AnalysisReport report) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.lg),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.cautionSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.history,
            size: AppSize.iconSm,
            color: AppColors.caution,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '${formatDaysAgo(report.analyzedAt)} 결과예요 — 계약 직전엔 최신 등기부로 재확인하세요',
              style: AppTypography.caption.copyWith(color: AppColors.caution),
            ),
          ),
          TextButton(onPressed: () => _stub(context), child: const Text('재분석')),
        ],
      ),
    );
  }

  /// 결론 헤더 — 등급 크게 + 의사결정 한 줄 + 보증금 (IA §0 + 서연 리뷰 반영)
  Widget _conclusionHeader(AnalysisReport report) {
    final String priceText = report.marketPrice != null
        ? '보증금 ${formatWon(report.deposit)} · 시세 ${formatWon(report.marketPrice!)} (입력값)'
        : '보증금 ${formatWon(report.deposit)} · 시세 미입력';

    return Column(
      children: [
        SafetyGauge(
          grade: report.grade,
          progress: report.gaugeProgress,
          caption: '${formatDate(report.analyzedAt)} 분석',
          size: 190,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          report.headline,
          style: AppTypography.headline,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.sm),
        // 진행/보류/회피 의사결정 대응 — 문구는 E-1에서 등급 체계와 함께 확정
        RiskBadge(
          grade: report.grade,
          labelOverride: report.grade.decisionLabel,
          large: true,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          report.address,
          style: AppTypography.caption,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          priceText,
          style: AppTypography.caption.copyWith(
            color: AppColors.textBody,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _nextActionCard(BuildContext context, AnalysisReport report) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.flag_outlined,
                color: AppColors.primary,
                size: AppSize.iconMd,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '지금 해야 할 일',
                      style: AppTypography.label.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(report.nextAction, style: AppTypography.bodyStrong),
                  ],
                ),
              ),
            ],
          ),
          // "아래 질문" 을 찾으러 헤매지 않게 바로가기 제공 (지수 리뷰 반영)
          if (report.grade != RiskGrade.ok) ...[
            const SizedBox(height: AppSpacing.md),
            AppCompactButton(
              label: '중개사 질문 모아 보기',
              icon: Icons.quiz_outlined,
              onPressed: () => context.push('/questions/${report.id}'),
            ),
          ],
        ],
      ),
    );
  }

  /// 근거 카드 목록 — 가장 심각한 카드 1개는 기본 펼침 (서연 리뷰 반영)
  List<Widget> _evidenceCards(BuildContext context, AnalysisReport report) {
    final int expandedIndex = _mostSevereIndex(report.evidences);
    return [
      for (int i = 0; i < report.evidences.length; i++) ...[
        _evidenceCard(
          context,
          report.evidences[i],
          initiallyExpanded: i == expandedIndex,
        ),
        const SizedBox(height: AppSpacing.md),
      ],
    ];
  }

  int _mostSevereIndex(List<EvidenceItem> evidences) {
    int severity(RiskGrade g) => switch (g) {
      RiskGrade.danger => 2,
      RiskGrade.caution => 1,
      RiskGrade.ok => 0,
    };
    int best = 0;
    for (int i = 1; i < evidences.length; i++) {
      if (severity(evidences[i].grade) > severity(evidences[best].grade)) {
        best = i;
      }
    }
    return best;
  }

  Widget _evidenceCard(
    BuildContext context,
    EvidenceItem evidence, {
    required bool initiallyExpanded,
  }) {
    return EvidenceCard(
      title: evidence.title,
      termSubtitle: evidence.termSubtitle,
      grade: evidence.grade,
      statusLabel: evidence.statusLabel,
      easyExplanation: evidence.easyExplanation,
      explanationSpan: _explanationSpan(context, evidence),
      detailText: evidence.detailText,
      sourceText: evidence.sourceText,
      initiallyExpanded: initiallyExpanded,
      action: evidence.actionLabel == null
          ? null
          : AppCompactButton(
              label: evidence.actionLabel!,
              onPressed: () => _onEvidenceAction(context, evidence),
            ),
    );
  }

  void _onEvidenceAction(BuildContext context, EvidenceItem evidence) {
    if (evidence.actionLabel == '중개사에게 물어볼 질문 보기') {
      context.push('/questions/$reportId');
    } else {
      // 예: "시세 입력하기" — 매물 검색 재진입은 C-3 범위 밖(재분석 흐름). 안내만.
      _stub(context);
    }
  }

  /// 쉬운 설명에 용어 툴팁(termSpan)을 심는다 (지수·design-reviewer 리뷰 반영).
  /// "챗봇에 더 물어보기" 연결은 챗봇 실화면과 함께 C-3에서.
  InlineSpan? _explanationSpan(BuildContext context, EvidenceItem evidence) {
    if (evidence.termGlossary.isEmpty) return null;

    final List<InlineSpan> children = [];
    String rest = evidence.easyExplanation;
    while (rest.isNotEmpty) {
      int bestIndex = -1;
      String? bestTerm;
      for (final term in evidence.termGlossary.keys) {
        final int idx = rest.indexOf(term);
        if (idx >= 0 && (bestIndex == -1 || idx < bestIndex)) {
          bestIndex = idx;
          bestTerm = term;
        }
      }
      if (bestTerm == null) {
        children.add(TextSpan(text: rest));
        break;
      }
      if (bestIndex > 0) {
        children.add(TextSpan(text: rest.substring(0, bestIndex)));
      }
      children.add(
        termSpan(
          context,
          term: bestTerm,
          description: evidence.termGlossary[bestTerm]!,
          onAskChatbot: () => context.push('/chatbot'),
        ),
      );
      rest = rest.substring(bestIndex + bestTerm.length);
    }
    return TextSpan(style: AppTypography.body, children: children);
  }

  /// 다음 행동 — 등급별 추천 1개 강조 + 나머지 그리드 (지수 리뷰 반영)
  List<Widget> _actionArea(BuildContext context, AnalysisReport report) {
    final bool recommendQuestions = report.grade != RiskGrade.ok;

    final recommended = recommendQuestions
        ? (
            icon: Icons.quiz_outlined,
            label: '질문 생성기',
            caption: '위험 요소별로 중개사에게 물어볼 질문을 만들어 드려요',
            onTap: () => context.push('/questions/${report.id}'),
          )
        : (
            icon: Icons.fact_check_outlined,
            label: '계약 여정 체크리스트',
            caption: '계약 전부터 보증금 반환까지 단계별 할 일을 확인하세요',
            onTap: () => context.push('/checklist'),
          );

    final others = [
      if (!recommendQuestions)
        (
          icon: Icons.quiz_outlined,
          label: '질문 생성기',
          onTap: () => context.push('/questions/${report.id}'),
        ),
      (
        icon: Icons.gavel_outlined,
        label: '비슷한 피해 사례',
        onTap: () => context.push('/cases/${report.id}'),
      ),
      (
        icon: Icons.calculate_outlined,
        label: '손실 시뮬레이터',
        onTap: () => context.push('/simulator/${report.id}'),
      ),
      if (recommendQuestions)
        (
          icon: Icons.fact_check_outlined,
          label: '체크리스트',
          onTap: () => context.push('/checklist'),
        ),
    ];

    return [
      // 추천 행동 — 전폭 강조 카드
      AppCard(
        onTap: recommended.onTap,
        child: Row(
          children: [
            Icon(
              recommended.icon,
              color: AppColors.primary,
              size: AppSize.iconMd,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(recommended.label, style: AppTypography.bodyStrong),
                      const SizedBox(width: AppSpacing.sm),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primarySoft,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Text(
                          '추천',
                          style: AppTypography.label.copyWith(
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(recommended.caption, style: AppTypography.caption),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.textMuted),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.md),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: AppSpacing.md,
        crossAxisSpacing: AppSpacing.md,
        childAspectRatio: 2.4,
        children: [
          for (final action in others)
            AppCard(
              onTap: action.onTap,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: [
                  Icon(
                    action.icon,
                    color: AppColors.primary,
                    size: AppSize.iconMd,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(action.label, style: AppTypography.bodyStrong),
                  ),
                ],
              ),
            ),
        ],
      ),
    ];
  }

  void _stub(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('곧 제공되는 기능이에요')));
  }
}
