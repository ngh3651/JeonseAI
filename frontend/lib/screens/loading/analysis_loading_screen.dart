/// S-06 분석 로딩 — IA.md §6.
///
/// 2026-10-28 다시 그림(시안 '분석로딩_시안.png' ①~④): 종이 더미 위로 스캔 줄이 훑고, 세이프가 돋보기로 들여다본다.
/// 단계(읽기·갑구·을구·판례·마무리)·쪽수·%·남은 초는 서버 진행과 이어지지 않은 **예상 시간 기준**이다
/// (서버는 결과를 한 번에 준다) — 그래서 끝나기 전엔 99%에서 멈추고, 서버가 답해야 100%가 된다(가짜 완료 없음 — D1).
/// 모든 요소는 **고정 위치** — 꿀팁 글이 2줄이든 3줄이든 막대·세이프가 움직이지 않는다.
/// 휴대폰 "동작 줄이기"가 켜져 있으면 움직임을 모두 멈추고 세이프는 한 장으로 고정한다.
/// 완료되면 홈으로 리셋 후 리포트를 push (분석 직후 리포트 백=홈 — IA §7).
/// 로딩 중 시스템 백은 취소 확인 다이얼로그. **분석 로직(저장소 호출·오류 분기)은 그대로다.**
/// [중단] = 결과 버리기(2026-10-29): 보내던 요청을 끊고, 뒤늦게 답이 와도 저장·이동하지 않는다([AnalysisCancelToken]).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/mascot_safe.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../repositories/analysis_repository.dart';
import '../../services/api_client.dart';
import '../search/capture_issue_panel.dart' show CaptureRejection;
import '../../design_system/text/app_text.dart';
import 'loading_parts.dart';
import 'loading_tips.dart';

export 'loading_parts.dart' show kAnalysisExpectedSeconds;

/// 분석·대조가 보통 걸리는 시간 — 화면에 쓰는 말.
const String kAnalysisTypicalWait = '보통 $kAnalysisExpectedSeconds초쯤 걸려요';

/// 로딩 화면의 한 줄 — 흐린 점(지난 줄) 또는 작은 스피너(지금 줄). **체크(완료) 표시는 쓰지 않는다**(D1).
class LoadingStepLine extends StatelessWidget {
  const LoadingStepLine({super.key, required this.text, required this.active});

  final String text;

  /// 맨 아래(지금) 줄 — 작은 스피너
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: AppSize.iconSm,
          height: AppSize.iconSm,
          child: Center(
            child: active
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.textMuted,
                    ),
                  )
                : Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: AppColors.line,
                      shape: BoxShape.circle,
                    ),
                  ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: AppText(
            text,
            style: AppTypography.body.copyWith(
              color: active ? AppColors.textBody : AppColors.textMuted,
            ),
          ),
        ),
      ],
    );
  }
}

class AnalysisLoadingScreen extends StatefulWidget {
  const AnalysisLoadingScreen({super.key, required this.request});

  final AnalysisRequest request;

  @override
  State<AnalysisLoadingScreen> createState() => _AnalysisLoadingScreenState();
}

class _AnalysisLoadingScreenState extends State<AnalysisLoadingScreen>
    with SingleTickerProviderStateMixin {
  /// 꿀팁이 바뀌는 간격 — 팁 5개 × 6초 = 30초(예상 시간)에 한 바퀴
  static const _tipEvery = Duration(seconds: 6);

  final Stopwatch _clock = Stopwatch();
  int _ticks = 0; // 250ms 시계가 몇 번 울렸나

  /// 분석을 시작하고 지난 시간 — 진짜 시계([_clock])와 250ms 시계 횟수 중 큰 값.
  /// (위젯 테스트는 시간을 가짜로 빨리 돌리는데 Stopwatch는 따라가지 않는다 — 횟수로 재면 테스트에서도 맞다)
  Duration get _elapsed {
    final byTicks = Duration(milliseconds: _ticks * 250);
    return _clock.elapsed > byTicks ? _clock.elapsed : byTicks;
  }

  bool _done = false; // 서버가 답했다 → 남은 단계 체크 + 100%
  Timer? _timer;
  bool _navigated = false;
  bool _failed = false; // 서버 연결·분석 실패 (user-scenario §4 S-06 네트워크 오류)
  String? _errorMessage; // 서버가 보낸 한국어 detail (요약본 거부·크레딧 소진 등)
  int? _errorStatus; // 상태코드별 복구 동선 분기 (400계열=사진 다시 / 402·429=재시도 없음)
  bool _needsAppUpdate = false; // 기기 정보(400)·앱 인증(401) — 재시도·사진 교체로 안 풀린다

  /// 지금 돌고 있는 분석의 중단 표시 — [중단]을 누르거나 화면이 닫히면 켠다([_run]마다 새로 만든다)
  AnalysisCancelToken? _cancel;

  /// 움직임 시계(초) — 세이프·종이·스캔 줄·물결·막대 빛이 이 값 하나를 보고 그린다(화면 전체를 다시 그리지 않는다)
  final ValueNotifier<double> _motion = ValueNotifier<double>(0);
  late final Ticker _ticker = createTicker(
    (d) => _motion.value = d.inMicroseconds / 1e6,
  );
  bool _reduceMotion = false;
  bool _precached = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 휴대폰 "동작 줄이기" — 켜져 있으면 움직임 시계를 세운다
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _syncTicker();
    if (!_precached) {
      _precached = true;
      // 세이프 4장을 미리 불러 둔다 — 그림을 바꿀 때 깜빡이지 않게
      for (final f in kInspectFrames) {
        precacheImage(AssetImage(f), context);
      }
    }
  }

  void _syncTicker() {
    final shouldRun = !_reduceMotion && !_failed;
    if (shouldRun && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
    }
  }

  Future<void> _run() async {
    setState(() {
      _failed = false;
      _done = false;
    });
    _syncTicker();
    _clock
      ..reset()
      ..start();
    _timer?.cancel();
    _ticks = 0;
    // 단계·쪽수·%·남은 초·꿀팁을 다시 그리는 시계 (서버 진행과는 무관 — 예상 시간 기준)
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      _ticks++;
      if (mounted) setState(() {});
    });

    final repo = context.read<AnalysisRepository>();
    final router = GoRouter.of(context); // go+push 전에 참조 확보 (context 무효화 대비)
    final cancel = _cancel = AnalysisCancelToken();

    final AnalysisReport report;
    try {
      final results = await Future.wait([
        repo.analyzeCancellable(widget.request, cancel),
        Future.delayed(const Duration(milliseconds: 2600)),
      ]);
      report = results.first as AnalysisReport;
    } on AnalysisCancelledException {
      return; // [중단]으로 버린 결과 — 화면은 이미 닫혔다
    } on ApiException catch (e) {
      // 서버가 보낸 진짜 원인(요약본 거부·크레딧 소진 등)을 뭉개지 않고 그대로 보여준다
      // (gap-checker 2026-07-07 치명 지적 — user-scenario §4 S-06 분기 복원)
      _timer?.cancel();
      if (!mounted) return;
      // 사진 품질 거절(2026-10-22, P1-1) — 분석 전에 막혔다(크레딧 0원). 실패 화면 대신 **촬영 화면으로 바로**
      // 돌아가 "몇 쪽이 왜 — 그 장만 다시 찍기"를 띄운다(사진·입력값은 그대로 남아 있다).
      final capture = e.captureCheck;
      if (capture != null && capture.pages.isNotEmpty && context.canPop()) {
        _navigated = true;
        context.pop(CaptureRejection(check: capture, message: e.message));
        return;
      }
      setState(() {
        _failed = true;
        _errorMessage = e.message;
        _errorStatus = e.statusCode;
        _needsAppUpdate = e.needsAppUpdate;
      });
      _syncTicker();
      return;
    } catch (_) {
      // 그 외(네트워크 단절 등) — 더미로 폴백하지 않고 실패를 그대로 보여준다
      _timer?.cancel();
      if (!mounted) return;
      setState(() {
        _failed = true;
        _errorMessage = null;
        _errorStatus = null;
        _needsAppUpdate = false;
      });
      _syncTicker();
      return;
    }

    _timer?.cancel();
    _clock.stop();
    if (!mounted || _navigated || cancel.isCancelled) return;
    // 서버가 답했다 → 남은 단계를 체크하고 막대를 100%로 채워 보여 준 뒤 넘어간다(0.5초 안 — 진짜 완료라서 괜찮다)
    setState(() => _done = true);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted || _navigated) return;
    _navigated = true;
    // 분석 직후 리포트에서 뒤로가기 = 홈 (검색 폼·로딩으로 되돌아가지 않음 — IA §7).
    // 홈으로 스택을 리셋한 뒤 리포트를 push해 [홈, 리포트] 상태로 만든다.
    router.go('/home');
    router.push('/report/${report.id}');
  }

  @override
  void dispose() {
    _cancel?.cancel(); // 다 끝난 뒤라면 아무 일도 없다 — 도는 중에 닫히면 결과를 버린다
    _timer?.cancel();
    _clock.stop();
    _ticker.dispose();
    _motion.dispose();
    super.dispose();
  }

  /// 로딩 중 시스템 백 → 취소 확인 (user-scenario §4 S-06)
  Future<void> _confirmCancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const AppText('분석을 중단할까요?'),
        content: const AppText('처음부터 다시 해야 해요'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const AppText('계속하기'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const AppText('중단'),
          ),
        ],
      ),
    );
    if ((ok ?? false) && mounted) {
      _timer?.cancel();
      // 결과 버리기 (2026-10-29) — 보내던 요청을 끊고(서버가 남은 단계를 건너뛴다) 늦게 온 답은 저장하지 않는다
      _cancel?.cancel();
      _navigated = true; // 완료 콜백이 뒤늦게 네비게이션하지 않도록
      context.pop(); // 검색 화면(S-04)으로 복귀 (사진·입력값 유지)
    }
  }

  /// 분석 실패 화면 — 서버가 보낸 원인을 그대로 보여주고, 원인별 복구 동선 분기.
  /// (user-scenario §4 S-06: 요약본/추출 실패=사진 다시 고르기, 402·429=재시도 미노출)
  Widget _failedBody() {
    final status = _errorStatus;
    // 기기 정보(400)·앱 인증(401)은 사진을 바꿔도, 다시 눌러도 풀리지 않는다 — 최신 앱 설치가 답이다.
    // 그래서 아래 두 버튼을 모두 감춘다(헛걸음만 시키고 크레딧과 무관하게 같은 실패만 반복된다).
    final needsAppUpdate = _needsAppUpdate || status == 401;
    // 400계열(요약본·형식·용량)은 같은 사진으로 재시도해도 반드시 실패 + 크레딧만 소모
    final isInputProblem =
        !needsAppUpdate && (status == 400 || status == 413 || status == 415);
    // 크레딧 소진·호출 한도는 재시도 버튼을 주지 않는다 (무한 재시도 루프 방지)
    final isQuotaProblem = status == 402 || status == 429;
    final message = _errorMessage ?? '연결이 불안정해요. 서버 연결을 확인하고 다시 시도해 주세요';

    return SafeArea(
      child: _Scrollable(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: MascotSafe(size: 96, state: MascotState.error)),
            const SizedBox(height: AppSpacing.xl),
            const AppText(
              '분석을 진행하지 못했어요',
              style: AppTypography.title,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            AppText(
              message,
              style: AppTypography.caption,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xxl),
            if (isInputProblem)
              AppPrimaryButton(
                label: '사진 다시 고르기',
                icon: Icons.photo_library_outlined,
                onPressed: () => context.pop(), // S-04 복귀 (사진·입력값 유지)
              )
            else if (!isQuotaProblem && !needsAppUpdate)
              AppPrimaryButton(
                label: '다시 시도',
                icon: Icons.refresh,
                onPressed: _run,
              ),
            const SizedBox(height: AppSpacing.sm),
            AppSecondaryButton(
              label: '나중에 하기',
              onPressed: () => context.pop(), // S-04 복귀 (사진·입력값 유지)
            ),
          ],
        ),
      ),
    );
  }

  /// 로딩 중 화면 — 그림(종이·스캔·세이프) · 단계 제목 · 단계 표시 · 진행 막대 · 리포트 꿀팁.
  /// 시안 360×800 기준 **고정 위치**(위에서 96 · 420 · 464 · 552 · 628). 글자 배율이 커지면 글 줄 높이만 함께 커지고,
  /// 화면보다 길면 스크롤된다.
  Widget _loadingBody() {
    final elapsed = _elapsed;
    final stage = _done ? LoadingStage.finish : loadingStageAt(elapsed);
    final progress = _done ? 1.0 : loadingProgress(elapsed);
    final timeText = _done ? '다 됐어요' : loadingTimeText(elapsed);
    final total = widget.request.imagePaths.isEmpty
        ? 1
        : widget.request.imagePaths.length;
    final page = _done ? total : loadingPageAt(elapsed, total);
    final tipIndex =
        (elapsed.inMilliseconds ~/ _tipEvery.inMilliseconds) %
        kLoadingTips.length;
    final scale = MediaQuery.textScalerOf(context).scale(100) / 100;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 96),
        Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: LoadingArt(
              stage: stage,
              page: page,
              totalPages: total,
              motion: _motion,
              reduceMotion: _reduceMotion,
            ),
          ),
        ),
        const SizedBox(height: 24),
        // 단계 제목 — 한 줄 고정 (좁으면 글자만 살짝 줄인다)
        SizedBox(
          height: 28 * scale,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: FittedBox(
                key: ValueKey(stage),
                fit: BoxFit.scaleDown,
                child: AppText(
                  stage.title,
                  key: const ValueKey('loading-title'),
                  maxLines: 1,
                  softWrap: false,
                  textAlign: TextAlign.center,
                  style: AppTypography.title.copyWith(
                    fontSize: 19,
                    height: 1.4,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textStrong,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: LoadingSteps(
            stage: stage,
            motion: _motion,
            reduceMotion: _reduceMotion,
            labelHeight: 21 * scale,
          ),
        ),
        const SizedBox(height: 31),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: LoadingBar(
            progress: progress,
            timeText: timeText,
            motion: _motion,
            reduceMotion: _reduceMotion,
            rowHeight: 24 * scale,
          ),
        ),
        const SizedBox(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: LoadingTipCard(index: tipIndex, scale: scale),
        ),
        const SizedBox(height: 32),
      ],
    );

    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: content,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 실패 상태에서는 자유롭게 뒤로가기(S-04 복귀), 진행 중에는 취소 확인
      canPop: _failed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmCancel();
      },
      child: _failed
          ? Scaffold(body: _failedBody())
          // 상단 앱바·하단 탭 없음 · 바탕 #F5F5F5 — 위에서 96은 상태 표시줄을 포함한 자리라 SafeArea를 쓰지 않는다
          : Scaffold(
              backgroundColor: AppColors.background,
              body: _loadingBody(),
            ),
    );
  }
}

/// 글자 배율 2.0·작은 폰에서도 넘치지 않게 — 넘칠 때만 스크롤, 아니면 가운데 정렬 그대로 (디자인 리뷰 2026-10-24).
class _Scrollable extends StatelessWidget {
  const _Scrollable({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xxxl),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: (box.maxHeight - AppSpacing.xxxl * 2)
                .clamp(0.0, double.infinity)
                .toDouble(),
          ),
          child: child,
        ),
      ),
    );
  }
}
