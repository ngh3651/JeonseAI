/// S-03 홈 대시보드 (IA.md §6).
///
/// 구성: 인사 영역 → 분석 시작 대형 CTA → 최근 분석 이력(최근 3건 + 전체 보기)
/// → 기능 바로가기. 빈 상태 포함 (user-scenario.md §6).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/components/mascot_safe.dart';
import '../../design_system/components/risk_badge.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../repositories/analysis_repository.dart';
import '../../state/app_session.dart';
import '../../utils/money_format.dart';
import '../common/analyze_gate.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // watch: 분석·삭제로 이력이 바뀌면 홈이 갱신되도록 구독
    final repo = context.watch<AnalysisRepository>();

    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<List<AnalysisReport>>(
          future: repo.getHistory(),
          builder: (context, snapshot) {
            final List<AnalysisReport> history = snapshot.data ?? const [];

            return ListView(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              children: [
                _greeting(context),
                const SizedBox(height: AppSpacing.xxl),
                AppPrimaryButton(
                  label: '매물 분석 시작하기',
                  icon: Icons.search,
                  onPressed: () => startAnalysis(context),
                ),
                const SizedBox(height: AppSpacing.xxxl),
                _sectionHeader(
                  context,
                  '최근 분석',
                  trailing: history.isEmpty
                      ? null
                      : TextButton(
                          onPressed: () => context.go('/my'),
                          child: const Text('전체 보기'),
                        ),
                ),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (history.isEmpty)
                  _emptyHistory(context)
                else
                  for (final report in history.take(3)) ...[
                    _historyCard(context, report),
                    const SizedBox(height: AppSpacing.md),
                  ],
                const SizedBox(height: AppSpacing.xl),
                _sectionHeader(context, '바로가기'),
                _shortcuts(context),
                const SizedBox(height: AppSpacing.xxxl),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _greeting(BuildContext context) {
    final session = context.watch<AppSession>();
    final String hello = session.isGuest
        ? '안녕하세요'
        : '${session.greetingName}님, 안녕하세요';

    return Row(
      children: [
        const MascotSafe(size: 52),
        const SizedBox(width: AppSpacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(hello, style: AppTypography.headline),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '오늘도 안전한 전세 계약을 도와드릴게요',
                style: AppTypography.caption.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
        // 비회원엔 상단 로그인 진입점 (user-scenario C1)
        if (session.isGuest)
          TextButton(
            onPressed: () => context.push('/login?mode=login'),
            child: const Text('로그인'),
          ),
      ],
    );
  }

  Widget _sectionHeader(
    BuildContext context,
    String title, {
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: AppTypography.title),
          ?trailing,
        ],
      ),
    );
  }

  /// 이력 카드 — 별칭·분석일·등급 뱃지 + **최대 위험 요인 한 줄** (비교용, IA.md S-03)
  Widget _historyCard(BuildContext context, AnalysisReport report) {
    return AppCard(
      onTap: () => context.push('/report/${report.id}'),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(report.alias, style: AppTypography.title),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${formatDate(report.analyzedAt)} 분석 · 보증금 ${formatWon(report.deposit)}',
                  style: AppTypography.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  report.topRiskSummary,
                  style: AppTypography.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          RiskBadge(grade: report.grade),
          const SizedBox(width: AppSpacing.xs),
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );
  }

  /// 빈 상태 — "아직 분석한 매물이 없어요" + 분석 시작 + 발급 가이드
  Widget _emptyHistory(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        children: [
          const MascotSafe(size: 64),
          const SizedBox(height: AppSpacing.lg),
          const Text('아직 분석한 매물이 없어요', style: AppTypography.title),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '등기부등본 사진만 있으면 바로 시작할 수 있어요',
            style: AppTypography.caption.copyWith(color: AppColors.textMuted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.lg),
          // 빈 상태 명세: [분석 시작] + [발급 가이드] (user-scenario.md §6)
          AppPrimaryButton(
            label: '매물 분석 시작하기',
            onPressed: () => startAnalysis(context),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppCompactButton(
            label: '등기부등본이 없어요 — 발급 가이드',
            onPressed: () => context.push('/guide'),
          ),
        ],
      ),
    );
  }

  Widget _shortcuts(BuildContext context) {
    return Row(
      children: [
        _shortcutCard(
          context,
          Icons.menu_book_outlined,
          '등기부 발급',
          () => context.push('/guide'),
        ),
        const SizedBox(width: AppSpacing.md),
        _shortcutCard(
          context,
          Icons.fact_check_outlined,
          '계약 여정',
          () => context.go('/journey'),
        ),
        const SizedBox(width: AppSpacing.md),
        _shortcutCard(
          context,
          Icons.chat_bubble_outline,
          '용어 챗봇',
          () => context.go('/chatbot'),
        ),
      ],
    );
  }

  Widget _shortcutCard(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return Expanded(
      child: AppCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: Column(
          children: [
            Icon(icon, color: AppColors.primary, size: AppSize.iconMd),
            const SizedBox(height: AppSpacing.sm),
            Text(
              label,
              style: AppTypography.label.copyWith(color: AppColors.textBody),
            ),
          ],
        ),
      ),
    );
  }
}
