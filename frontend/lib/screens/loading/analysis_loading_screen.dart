/// S-06 분석 로딩 — IA.md §6.
///
/// 단계 표시(판정 주체 구분) + 추출 항목 실시간 노출로 "AI가 일하는 순간"을 보여준다.
/// 완료되면 홈으로 리셋 후 리포트를 push (분석 직후 리포트 백=홈 — IA §7).
/// 로딩 중 시스템 백은 취소 확인 다이얼로그. 실단계(E-1)에서는 여기서
/// 업로드→Information Extract→규칙 엔진을 호출한다.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/mascot_safe.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../repositories/analysis_repository.dart';

class AnalysisLoadingScreen extends StatefulWidget {
  const AnalysisLoadingScreen({super.key, required this.request});

  final AnalysisRequest request;

  @override
  State<AnalysisLoadingScreen> createState() => _AnalysisLoadingScreenState();
}

class _AnalysisLoadingScreenState extends State<AnalysisLoadingScreen> {
  // 단계 문구는 판정 주체를 드러낸다 (judge-reviewer 반영)
  static const _stages = [
    '사진을 올리고 있어요',
    '문서를 읽는 중이에요 (AI 추출)',
    '규칙으로 위험 항목을 확인하는 중이에요',
    'AI가 쉬운 말로 정리하는 중이에요',
  ];

  // 추출되는 항목이 하나씩 나타나는 연출 (예시)
  static const _extracted = ['근저당권 2건 발견', '신탁등기 확인', '소유자 정보 확인'];

  int _stage = 0;
  final List<String> _found = [];
  Timer? _timer;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    // 단계 진행 연출 (더미). 실단계에선 실제 파이프라인 진행에 연동.
    _timer = Timer.periodic(const Duration(milliseconds: 700), (t) {
      if (!mounted) return;
      setState(() {
        if (_stage < _stages.length - 1) _stage++;
        if (_found.length < _extracted.length) {
          _found.add(_extracted[_found.length]);
        }
      });
    });

    final repo = context.read<AnalysisRepository>();
    final router = GoRouter.of(context); // go+push 전에 참조 확보 (context 무효화 대비)
    final results = await Future.wait([
      repo.analyze(widget.request),
      Future.delayed(const Duration(milliseconds: 2600)),
    ]);
    final report = results.first as AnalysisReport;

    _timer?.cancel();
    if (!mounted || _navigated) return;
    _navigated = true;
    // 분석 직후 리포트에서 뒤로가기 = 홈 (검색 폼·로딩으로 되돌아가지 않음 — IA §7).
    // 홈으로 스택을 리셋한 뒤 리포트를 push해 [홈, 리포트] 상태로 만든다.
    router.go('/home');
    router.push('/report/${report.id}');
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 로딩 중 시스템 백 → 취소 확인 (user-scenario §4 S-06)
  Future<void> _confirmCancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('분석을 중단할까요?'),
        content: const Text('처음부터 다시 해야 해요'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('계속하기'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('중단'),
          ),
        ],
      ),
    );
    if ((ok ?? false) && mounted) {
      _timer?.cancel();
      _navigated = true; // 완료 콜백이 뒤늦게 네비게이션하지 않도록
      context.pop(); // 검색 화면(S-04)으로 복귀 (사진·입력값 유지)
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmCancel();
      },
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxxl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: MascotSafe(size: 96)),
                const SizedBox(height: AppSpacing.xl),
                Text(
                  _stages[_stage],
                  style: AppTypography.title,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '보통 1~2분 걸려요',
                  style: AppTypography.caption,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.xl),
                LinearProgressIndicator(
                  value: (_stage + 1) / _stages.length,
                  backgroundColor: AppColors.line,
                  color: AppColors.primary,
                ),
                const SizedBox(height: AppSpacing.xxl),
                // 추출 항목 실시간 노출 (동작 실체 증명)
                for (final item in _found)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle,
                          color: AppColors.primary,
                          size: AppSize.iconSm,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text(item, style: AppTypography.body),
                      ],
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
