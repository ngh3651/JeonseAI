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
import '../loading/analysis_loading_screen.dart'
    show LoadingStepLine, kAnalysisTypicalWait;
import '../search/capture_issue_panel.dart';
import '../search/capture_loop_route.dart';
import 'compare_result_view.dart';

/// 대조 요청 — 여정 화면이 `push`의 `extra`로 넘긴다.
class CompareRequest {
  const CompareRequest({
    required this.report,
    this.imagePaths = const [],
    this.initialResult,
    this.initialError,
  });

  final AnalysisReport report;

  /// 이미 받은 결과 — 여정의 대조 시트가 '일부만 맞춰봄·다른 집' 같은 결과를 이 화면에 넘길 때.
  /// 있으면 **서버를 다시 부르지 않고** 바로 그린다(대조 1번 = 분석 1번 비용, 2026-10-26).
  final CompareResult? initialResult;

  /// 이미 받은 오류 — 사진 거절(그 장만 다시 찍기)·앱 업데이트 안내를 이 화면이 맡는다.
  final ApiException? initialError;

  /// 이번에 뗀 등기부 사진. **비어 있을 수 있다** — 기준이 없는 리포트는 사진을 받기
  /// 전에 서버가 "기준 없음"으로 답한다.
  final List<String> imagePaths;
}

/// '빠진 쪽만 더 찍기'의 사진 시트 제목 — 통째로 다시 찍는 게 아니라는 것을 시트에서도 말한다.
const String kAddMissingSheetTitle = '빠진 쪽만 찍어 주세요 — 먼저 찍은 장과 합쳐 다시 맞춰봐요';

class CompareScreen extends StatefulWidget {
  const CompareScreen({
    super.key,
    required this.reportId,
    this.request,
    this.captureOne = defaultCaptureOne,
    this.pickMany = defaultPickMany,
  });

  final String reportId;
  final CompareRequest? request;

  /// 카메라 주입 지점 — 사진 품질로 거절됐을 때 '그 장만 다시 찍기', 일부만 맞춰봤을 때
  /// '빠진 쪽만 더 찍기'에서 쓴다(테스트는 가짜 함수).
  final CaptureOne captureOne;

  /// 앨범 주입 지점 — '빠진 쪽만 더 찍기'·'사진 다시 고르기'의 [앨범에서 고르기].
  final PickMany pickMany;

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  CompareResult? _result;
  bool _running = true;
  String? _errorMessage;
  int? _errorStatus;

  /// 기기 정보(400)·앱 인증(401) — 다시 시도해도 풀리지 않는다(최신 앱 설치가 답).
  bool _needsAppUpdate = false;

  /// 사진 품질로 분석 전에 거절됐을 때(400 + captureCheck, P1-1) 장별 안내. 있으면 '그 장만 다시 찍기'.
  CaptureCheck? _captureCheck;

  /// 거절 뒤에 **이미 바꿔 찍은** 장(0부터). 있으면 위 안내가 서버의 처음 문구("2·3쪽이 흐려요") 대신
  /// "바꾼 장 · 아직 다시 찍을 장"을 말한다 — 바꾼 쪽 번호를 또 찍으라고 하지 않게.
  final Set<int> _replacedPages = {};

  /// 진행 항목이 하나씩 나타나는 연출 (시안 0 / 0.5 / 1.1 / 1.7초)
  int _shownSteps = 0;
  Timer? _stepTimer;

  /// 이번에 올린 사진. 결과 화면에서 [빠진 쪽만 더 찍기]를 누르면 새 장을 **뒤에 덧붙이고**,
  /// [사진 다시 고르기](다른 집일 때)를 누르면 통째로 갈아 끼운다. 어느 쪽이든 같은 화면에서
  /// 다시 돈다 — 라우트를 쌓지 않아야 뒤로가기가 여정으로 곧장 간다.
  late List<String> _imagePaths = widget.request?.imagePaths ?? const [];

  @override
  void initState() {
    super.initState();
    final given = widget.request?.initialResult;
    final error = widget.request?.initialError;
    if (given != null) {
      _result = given;
      _running = false;
    } else if (error != null) {
      _running = false;
      _errorMessage = error.message;
      _errorStatus = error.statusCode;
      _needsAppUpdate = error.needsAppUpdate;
      _captureCheck = error.captureCheck;
    } else {
      _run();
    }
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
      _needsAppUpdate = false;
      _captureCheck = null;
      _replacedPages.clear();
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
        _needsAppUpdate = e.needsAppUpdate;
        _captureCheck = e.captureCheck;
      });
    } catch (_) {
      _stepTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _running = false;
        _errorMessage = null;
        _errorStatus = null;
        _needsAppUpdate = false;
      });
    }
  }

  /// 서버가 흐리다·어둡다고 한 **그 장만** 다시 찍어 바꾸고 같은 화면에서 다시 대조한다 (P1-1).
  /// 나머지 장은 그대로 쓴다 — 다섯 장을 처음부터 다시 찍게 하지 않는다.
  Future<void> _retakePage(CapturePageIssue page) async {
    final index = page.index;
    if (index < 0 || index >= _imagePaths.length) return;
    final CaptureLoopResult? result = await Navigator.of(context).push(
      MaterialPageRoute<CaptureLoopResult>(
        fullscreenDialog: true,
        builder: (_) => CaptureLoopRoute(
          alreadyTaken: _imagePaths.length,
          maxPhotos: _imagePaths.length,
          captureOne: widget.captureOne,
          replacePage: index,
          replaceTip: page.tip,
        ),
      ),
    );
    if (!mounted || result == null || result.newPaths.isEmpty) return;
    final severeLeft = [
      for (final p in _captureCheck?.pages ?? const <CapturePageIssue>[])
        if (p.severe && p.index != index) p,
    ];
    setState(() {
      _imagePaths = List<String>.of(_imagePaths)
        ..[index] = result.newPaths.last;
      _replacedPages.add(index);
      // 아직 바꿀 심한 장이 남았으면 안내만 줄이고 기다린다(같은 사진을 또 보내지 않게).
      if (severeLeft.isNotEmpty) {
        _captureCheck = CaptureCheck(
          ok: false,
          pages: [
            for (final p in _captureCheck?.pages ?? const <CapturePageIssue>[])
              if (p.index != index) p,
          ],
        );
      }
    });
    if (severeLeft.isEmpty) await _run();
  }

  /// **다른 집**일 때만 — 사진을 통째로 다시 골라 같은 화면에서 다시 대조한다.
  Future<void> _recapture() async {
    final paths = await pickRegistryPhotos(
      context,
      captureOne: widget.captureOne,
      pickMany: widget.pickMany,
    );
    if (paths.isEmpty || !mounted) return;
    setState(() {
      _imagePaths = paths;
      _result = null;
    });
    await _run();
  }

  /// **일부만 맞춰봤을 때**(partial) — 빠진 쪽만 새로 찍어 **먼저 찍은 장 뒤에 덧붙이고** 다시 대조한다.
  ///
  /// 대조 API는 한 번에 받은 사진만 본다(서버는 이전 요청의 사진을 갖고 있지 않다 — 원본 사진을 저장하지 않으므로).
  /// 그래서 앱이 먼저 찍은 사진 + 새 사진을 **합쳐** 보낸다. 순서는 서버가 쪽 번호(N/M)를 읽어 다시 맞춘다
  /// (highlight.py '사진 순서 자동 정렬'). 쪽 번호를 못 읽으면 서버가 "순서대로 다시 올려 주세요"라고 말한다.
  Future<void> _addMissingPages() async {
    final int kept = _imagePaths.length;
    if (kept >= kCompareMaxPhotos) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: AppText('사진은 최대 $kCompareMaxPhotos장까지 올릴 수 있어요'),
          ),
        );
      return;
    }
    final added = await pickRegistryPhotos(
      context,
      title: kAddMissingSheetTitle,
      subtitle: '먼저 찍은 $kept장은 그대로 두고, 새로 찍은 장만 뒤에 붙여요',
      alreadyTaken: kept,
      captureOne: widget.captureOne,
      pickMany: widget.pickMany,
    );
    if (added.isEmpty || !mounted) return;
    setState(() {
      _imagePaths = [..._imagePaths, ...added].take(kCompareMaxPhotos).toList();
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

  // ⚠ 진행형으로만 쓴다(2026-10-23 D1) — 타이머 연출이라 서버보다 먼저 '…했어요 ✓'를 띄우면 사진이 거절될 때
  //   ✓가 다 찬 뒤 "대조하지 않았어요"가 나온다(가짜 완료). 내부어 '규칙'도 뺐다.
  List<String> get _steps => [
    '사진 ${_imagePaths.length}장을 올리는 중이에요',
    '등기부를 읽는 중이에요',
    '안전도를 다시 계산하는 중이에요',
    '기준 서류와 달라진 항목을 맞춰보는 중이에요',
  ];

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(
        // 진행 중에는 제목을 두지 않는다(시안 5는 앱바 없는 전면 화면이다)
        title: AppText(
          _running ? '' : _appBarTitle(result),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        automaticallyImplyLeading: !_running,
      ),
      body: SafeArea(
        child: _running
            ? _loadingBody()
            : result != null
            ? CompareResultView(
                result: result,
                baselineReportId: widget.reportId,
                keptPhotoCount: _imagePaths.length,
                onRetry: _run,
                onRecapture: _recapture,
                onAddMissing: _addMissingPages,
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

  /// 앱바 — "{별칭} · 대조 결과" (서연 리뷰 #2: 캡처해 보내면 어느 집인지 알 수 있게). 별칭이 없으면 예전 제목.
  String _appBarTitle(CompareResult? result) {
    if (result == null) return '등기부 대조';
    final String alias = (result.baseline.alias ?? '').trim();
    return switch (result.outcome) {
      CompareOutcome.changed ||
      CompareOutcome.partial => alias.isEmpty ? '등기부 대조 결과' : '$alias · 대조 결과',
      _ => '등기부 대조',
    };
  }

  // ── 진행 화면 (시안 5) ─────────────────────────────────────────────────────

  Widget _loadingBody() {
    final baseline = widget.request?.report;
    final viewed = parseRegistryViewedAt(baseline?.registryViewedAt);
    // 실측 21~31초(NOW.md 2절) — 분석 로딩과 같은 말(kAnalysisTypicalWait)
    final String docLine = viewed == null
        ? '지금 뗀 서류와 맞춰보는 중 · $kAnalysisTypicalWait'
        : '${formatMonthDay(viewed)}자 ↔ 오늘 뗀 서류 · $kAnalysisTypicalWait';

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
          const Center(
            child: MascotSafe(size: 96, state: MascotState.analyzing),
          ),
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
                // 체크(완료) 표시 없이 — 지난 줄은 흐린 점, 지금(맨 아래) 줄만 작은 스피너(D1)
                for (int i = 0; i < _steps.length; i++)
                  if (i < _shownSteps) ...[
                    if (i > 0) const SizedBox(height: AppSpacing.md),
                    LoadingStepLine(
                      text: _steps[i],
                      active: i == _shownSteps - 1,
                    ),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 실패 ──────────────────────────────────────────────────────────────────

  /// 사진 품질 거절(P1-1) — "몇 쪽이 왜" + 장마다 [그 장만 다시 찍기]. 대조는 하지 않았다(크레딧 0원).
  Widget _captureRejectedBody(CaptureCheck check) {
    final bool waiting = check.pages.any((p) => p.severe);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        const SizedBox(height: AppSpacing.lg),
        const Center(child: MascotSafe(size: 80, state: MascotState.caution)),
        const SizedBox(height: AppSpacing.lg),
        CaptureIssuePanel(
          check: check,
          title: waiting ? '사진을 다시 찍어야 대조할 수 있어요' : '남은 장도 바꿀 수 있어요',
          message: _captureMessage(check),
          onRetake: _retakePage,
          retakeParticle: waiting ? '만' : '도',
        ),
        const SizedBox(height: AppSpacing.sm),
        // 실패를 '이상 없음'으로 읽지 않게 못 박는다(일반 실패 화면과 같은 고지).
        AppText(
          '대조하지 못한 것은 "달라진 게 없다"는 뜻이 아니에요',
          style: AppTypography.caption.copyWith(color: AppColors.caution),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.xl),
        AppSecondaryButton(label: '여정으로 돌아가기', onPressed: () => context.pop()),
      ],
    );
  }

  /// 거절 안내 한 줄. 아직 아무 장도 안 바꿨으면 서버 문구 그대로, 바꾼 장이 있으면 **지금 남은 것**을 말한다.
  String _captureMessage(CaptureCheck check) {
    // '크레딧' 같은 내부 말은 빼고 지금 상태와 할 일만(지수 리뷰 #4)
    const String tail = '아직 대조하지 않았어요. 문제인 장만 다시 찍으면 나머지 사진은 그대로 써요.';
    if (_replacedPages.isEmpty) return '${_errorMessage ?? ''}\n$tail';
    final done = (_replacedPages.toList()..sort())
        .map((i) => '${i + 1}쪽')
        .join(', ');
    final left = [
      for (final p in check.pages)
        if (p.severe) '${p.index + 1}쪽',
    ];
    final leftText = left.isEmpty ? '' : ' · 아직 다시 찍을 장: ${left.join(', ')}';
    return '바꾼 장: $done$leftText\n$tail';
  }

  Widget _errorBody() {
    final capture = _captureCheck;
    if (capture != null && capture.pages.isNotEmpty)
      return _captureRejectedBody(capture);
    final bool isInputProblem =
        _errorStatus == 400 || _errorStatus == 413 || _errorStatus == 415;
    final bool isQuotaProblem = _errorStatus == 402 || _errorStatus == 429;
    final bool needsAppUpdate = _needsAppUpdate || _errorStatus == 401;
    final message = _errorMessage ?? '연결이 불안정해요. 서버 연결을 확인하고 다시 시도해 주세요';

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
          if (!isInputProblem && !isQuotaProblem && !needsAppUpdate)
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
