/// 등기부 대조 — 진행 화면 + 결과 (S-11 화면 5·6).
///
/// 한 라우트가 진행과 결과를 **모두** 들고 있다. 그래야 결과에서 뒤로가기를 눌렀을 때
/// 로딩 화면이 아니라 **출발한 여정 화면**으로 돌아간다.
///
/// 여기서 하는 일은 "서버에 보내고 받은 것을 그리는 것"뿐이다 — 판정도, 문구도 만들지
/// 않는다. 화면 아래 "AI가 판단하지 않았어요" 고지가 참이 되는 자리가 여기다.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/mascot_safe.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../models/compare_result.dart';
import '../../repositories/analysis_repository.dart';
import '../../services/api_client.dart';
import '../../utils/korean_date.dart';
import '../common/analyze_gate.dart';
import '../journey/journey_actions.dart';
import 'compare_result_view.dart';

/// 대조 요청 — 여정 화면이 `push`의 `extra`로 넘긴다.
class CompareRequest {
  const CompareRequest({required this.report, this.imagePaths = const []});

  final AnalysisReport report;

  /// 이번에 뗀 등기부 사진. **비어 있을 수 있다** — 기준이 없는 리포트는 사진을 받기
  /// 전에 서버가 "기준 없음"으로 답한다.
  final List<String> imagePaths;
}

class CompareScreen extends StatefulWidget {
  const CompareScreen({super.key, required this.reportId, this.request});

  final String reportId;
  final CompareRequest? request;

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  CompareResult? _result;
  bool _running = true;
  String? _errorMessage;
  int? _errorStatus;

  /// 진행 항목이 하나씩 나타나는 연출 (시안 0 / 0.5 / 1.1 / 1.7초)
  int _shownSteps = 0;
  Timer? _stepTimer;

  /// 이번에 올린 사진. 결과 화면에서 [빠진 쪽 찍어서 올리기]를 누르면 여기만 갈아 끼우고
  /// 같은 화면에서 다시 돈다 — 라우트를 쌓지 않아야 뒤로가기가 여정으로 곧장 간다.
  late List<String> _imagePaths = widget.request?.imagePaths ?? const [];

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _stepTimer?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _errorMessage = null;
      _errorStatus = null;
      _shownSteps = _imagePaths.isEmpty ? 4 : 0;
    });
    if (_imagePaths.isNotEmpty) _startStepChoreography();

    final repo = context.read<AnalysisRepository>();
    try {
      final result = await repo.compareRegistry(widget.reportId, _imagePaths);
      _stepTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _result = result;
        _running = false;
      });
    } on ApiException catch (e) {
      _stepTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _running = false;
        _errorMessage = e.message;
        _errorStatus = e.statusCode;
      });
    } catch (_) {
      _stepTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _running = false;
        _errorMessage = null;
        _errorStatus = null;
      });
    }
  }

  /// 사진을 다시 골라 **같은 화면에서** 다시 대조한다 (빠진 쪽 올리기 · 사진 다시 고르기).
  Future<void> _recapture() async {
    final paths = await pickRegistryPhotos(context);
    if (paths.isEmpty || !mounted) return;
    setState(() {
      _imagePaths = paths;
      _result = null;
    });
    await _run();
  }

  void _startStepChoreography() {
    // 0.6초마다 한 줄씩 — 마지막 줄은 서버 응답을 기다리며 계속 돈다.
    _stepTimer = Timer.periodic(const Duration(milliseconds: 600), (t) {
      if (!mounted) return;
      if (_shownSteps >= _steps.length) {
        t.cancel();
        return;
      }
      setState(() => _shownSteps++);
    });
  }

  List<String> get _steps => [
    '사진 ${_imagePaths.length}장 올렸어요',
    '등기부를 읽었어요 — 소유자·빚·압류 항목',
    '안전도를 규칙으로 다시 계산했어요',
    '기준 서류와 달라진 항목을 맞춰보는 중',
  ];

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(
        // 진행 중에는 제목을 두지 않는다(시안 5는 앱바 없는 전면 화면이다)
        title: AppText(_running ? '' : _appBarTitle(result)),
        automaticallyImplyLeading: !_running,
      ),
      body: SafeArea(
        child: _running
            ? _loadingBody()
            : result != null
            ? CompareResultView(
                result: result,
                baselineReportId: widget.reportId,
                onRetry: _run,
                onRecapture: _recapture,
                onQuestions: () => context.push(
                  '/questions/${result.newReportId ?? widget.reportId}',
                ),
                onAnalyze: () => startAnalysis(context),
                onGuide: () => context.push('/guide'),
                onBackToJourney: () => context.pop(),
              )
            : _errorBody(),
      ),
    );
  }

  String _appBarTitle(CompareResult? result) {
    if (result == null) return '등기부 대조';
    return switch (result.outcome) {
      CompareOutcome.changed || CompareOutcome.partial => '등기부 대조 결과',
      _ => '등기부 대조',
    };
  }

  // ── 진행 화면 (시안 5) ─────────────────────────────────────────────────────

  Widget _loadingBody() {
    final baseline = widget.request?.report;
    final viewed = parseRegistryViewedAt(baseline?.registryViewedAt);
    final String docLine = viewed == null
        ? '지금 뗀 서류와 맞춰보는 중 · 보통 1~2분 걸려요'
        : '${formatMonthDay(viewed)}자 ↔ 오늘 뗀 서류 · 보통 1~2분 걸려요';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        0,
        AppSpacing.screenPadding,
        AppSpacing.xxl,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: MascotSafe(size: 96, state: MascotState.analyzing)),
          const SizedBox(height: AppSpacing.lg),
          const AppText(
            '두 등기부를 맞춰보고 있어요',
            style: AppTypography.headline,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          AppText(
            docLine,
            style: AppTypography.caption,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xxl),
          // 시안의 2.4초 진행 바. **100%로 채우지 않는다** — 다 됐다고 말해 놓고
          // 기다리게 하는 것이 가장 나쁜 로딩이다(실제 응답은 수십 초 걸린다).
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.04, end: 0.92),
            duration: const Duration(milliseconds: 2400),
            curve: Curves.easeOut,
            builder: (context, value, _) => ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 6,
                backgroundColor: AppColors.line,
                color: AppColors.primaryBright,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: AppSpacing.lg,
            ),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < _steps.length; i++)
                  if (i < _shownSteps) ...[
                    if (i > 0) const SizedBox(height: AppSpacing.md),
                    _stepLine(_steps[i], spinning: i == _steps.length - 1),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepLine(String text, {required bool spinning}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (spinning)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.textMuted,
            ),
          )
        else
          const Icon(
            Icons.check_circle,
            size: 18,
            color: AppColors.primary,
          ),
        const SizedBox(width: 10),
        Expanded(child: AppText(text, style: AppTypography.body)),
      ],
    );
  }

  // ── 실패 ──────────────────────────────────────────────────────────────────

  Widget _errorBody() {
    final bool isInputProblem =
        _errorStatus == 400 || _errorStatus == 413 || _errorStatus == 415;
    final bool isQuotaProblem = _errorStatus == 402 || _errorStatus == 429;
    final message =
        _errorMessage ?? '연결이 불안정해요. 서버 연결을 확인하고 다시 시도해 주세요';

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxxl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: MascotSafe(size: 96, state: MascotState.error)),
          const SizedBox(height: AppSpacing.xl),
          const AppText(
            '대조를 끝내지 못했어요',
            style: AppTypography.title,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppText(
            message,
            style: AppTypography.caption,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
          // 실패를 '이상 없음'으로 읽지 않게 못 박는다.
          AppText(
            '대조하지 못한 것은 "달라진 게 없다"는 뜻이 아니에요',
            style: AppTypography.caption.copyWith(color: AppColors.caution),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xxl),
          if (!isInputProblem && !isQuotaProblem)
            AppPrimaryButton(
              label: '다시 시도',
              icon: Icons.refresh,
              onPressed: _run,
            ),
          const SizedBox(height: AppSpacing.sm),
          AppSecondaryButton(
            label: '여정으로 돌아가기',
            onPressed: () => context.pop(),
          ),
        ],
      ),
    );
  }
}
