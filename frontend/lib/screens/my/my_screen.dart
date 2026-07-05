/// S-13 마이/설정 (탭) — IA.md §6.
///
/// 회원: 프로필 + 분석 이력 전체(재열람·삭제) + 로그아웃.
/// 비회원: [로그인하고 이력 저장하기]. 이력은 기기 로컬 단일 저장(계정 구분 없음).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/components/mascot_safe.dart';
import '../../design_system/components/risk_badge.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../repositories/analysis_repository.dart';
import '../../services/api_client.dart';
import '../../state/app_session.dart';
import '../../utils/money_format.dart';
import '../common/analyze_gate.dart';

class MyScreen extends StatefulWidget {
  const MyScreen({super.key});

  @override
  State<MyScreen> createState() => _MyScreenState();
}

class _MyScreenState extends State<MyScreen> {
  late Future<List<AnalysisReport>> _historyFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _historyFuture = context.read<AnalysisRepository>().getHistory();
  }

  Future<void> _delete(AnalysisReport report) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('이 리포트를 삭제할까요?'),
        content: const Text('삭제하면 되돌릴 수 없어요'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (!(ok ?? false) || !mounted) return;
    try {
      await context.read<AnalysisRepository>().deleteReport(report.id);
    } on ApiException catch (e) {
      // 예시 리포트 403, 서버 연결 실패 등 — 서버가 준 한국어 메시지 그대로 표시
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('삭제하지 못했어요. 다시 시도해 주세요')),
          );
      }
    }
    if (mounted) setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();

    return Scaffold(
      appBar: AppBar(title: const Text('마이'), automaticallyImplyLeading: false),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          _profile(session),
          const SizedBox(height: AppSpacing.xxl),
          Text('분석 이력', style: AppTypography.title),
          const SizedBox(height: AppSpacing.md),
          _historyList(),
          const SizedBox(height: AppSpacing.xxl),
          if (!session.isGuest)
            AppSecondaryButton(
              label: '로그아웃',
              onPressed: () {
                context.read<AppSession>().signOut();
                context.go('/start');
              },
            ),
          const SizedBox(height: AppSpacing.xxxl),
        ],
      ),
    );
  }

  Widget _profile(AppSession session) {
    return AppCard(
      child: Row(
        children: [
          const MascotSafe(size: 48),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: session.isGuest
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('비회원으로 이용 중', style: AppTypography.bodyStrong),
                      const SizedBox(height: AppSpacing.xs),
                      Text('로그인하면 분석 이력이 저장돼요', style: AppTypography.caption),
                    ],
                  )
                : Text('${session.greetingName}님', style: AppTypography.title),
          ),
          if (session.isGuest)
            AppCompactButton(
              label: '로그인',
              onPressed: () => context.push('/login?mode=login'),
            ),
        ],
      ),
    );
  }

  Widget _historyList() {
    return FutureBuilder<List<AnalysisReport>>(
      future: _historyFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          // 서버 연결 실패 — 빈 상태로 위장하지 않음 (D-3: 더미 폴백 금지)
          return AppCard(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              children: [
                const Text('분석 이력을 불러오지 못했어요', style: AppTypography.bodyStrong),
                const SizedBox(height: AppSpacing.xs),
                Text('서버 연결을 확인해 주세요', style: AppTypography.caption),
                const SizedBox(height: AppSpacing.lg),
                AppCompactButton(
                  label: '다시 시도',
                  icon: Icons.refresh,
                  onPressed: () => setState(_reload),
                ),
              ],
            ),
          );
        }
        final history = snapshot.data ?? const [];
        if (history.isEmpty) {
          return AppCard(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              children: [
                Text('아직 분석한 매물이 없어요', style: AppTypography.bodyStrong),
                const SizedBox(height: AppSpacing.md),
                AppCompactButton(
                  label: '매물 분석 시작하기',
                  onPressed: () => startAnalysis(context),
                ),
              ],
            ),
          );
        }
        return Column(
          children: [
            for (final report in history) ...[
              _historyCard(report),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        );
      },
    );
  }

  Widget _historyCard(AnalysisReport report) {
    return AppCard(
      onTap: () => context.push('/report/${report.id}'),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  report.alias,
                  style: AppTypography.bodyStrong,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${formatDate(report.analyzedAt)} · 보증금 ${formatWon(report.deposit)}',
                  style: AppTypography.caption,
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
          RiskBadge(grade: report.grade),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: AppSize.iconSm),
            tooltip: '삭제',
            onPressed: () => _delete(report),
          ),
        ],
      ),
    );
  }
}
