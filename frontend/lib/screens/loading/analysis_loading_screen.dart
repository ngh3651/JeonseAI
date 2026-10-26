/// S-06 분석 로딩 — IA.md §6.
///
/// 2026-10-23 다시 짬: **예상 시간 막대(%·남은 초)** + **"알고 계셨나요?" 꿀팁**(게임 로딩처럼 몇 초마다 바뀜).
/// 막대·단계 문장은 서버 진행과 이어지지 않은 **예상 시간 기준**이다 — 그래서 끝나기 전엔 98%를 넘지 않고,
/// 서버가 답을 줘야 100%가 된다. 예상보다 길면 남은 초 대신 "조금 더 걸리고 있어요"라고 말한다(가짜 완료 없음 — D1).
/// 완료되면 홈으로 리셋 후 리포트를 push (분석 직후 리포트 백=홈 — IA §7).
/// 로딩 중 시스템 백은 취소 확인 다이얼로그. 실단계(E-1)에서는 여기서
/// 업로드→Information Extract→규칙 엔진을 호출한다.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
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
import 'loading_tips.dart';

/// 분석·대조가 보통 걸리는 시간(초) — 실측(NOW.md 2절: 21~31초). 배포 서버에서 다시 재면 **이 숫자 하나만** 고친다
/// (로딩 막대의 %·남은 초와 아래 문장이 함께 바뀐다).
const int kAnalysisExpectedSeconds = 30;

/// 분석·대조가 보통 걸리는 시간 — 화면에 쓰는 말.
const String kAnalysisTypicalWait = '보통 $kAnalysisExpectedSeconds초쯤 걸려요';

/// 예상 시간 기준 진행률(0~0.98). 예상 시간까지 90%, 그 뒤로는 98%에 천천히 다가간다 — 100%는 서버가 답했을 때만.
double estimatedProgress(Duration elapsed) {
  final t = elapsed.inMilliseconds / (kAnalysisExpectedSeconds * 1000);
  if (t <= 1) return 0.9 * t;
  return 0.9 + 0.08 * (1 - math.exp(-(t - 1) * 2));
}

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

class _AnalysisLoadingScreenState extends State<AnalysisLoadingScreen> {
  // 단계 문장 — **예상 시간 비율**에 맞춰 바뀐다(서버 진행과 연결 안 됨 → 진행형으로만). 지수 리뷰: 쉬운 말.
  static const _stages = [
    (until: 0.1, text: '사진을 보내고 있어요'),
    (until: 0.5, text: 'AI가 등기부등본을 읽고 있어요'), // B3: 정식 명칭
    (until: 0.8, text: '위험한 부분을 하나씩 확인하고 있어요'),
    (until: double.infinity, text: '쉬운 말로 정리하고 있어요'),
  ];

  /// 꿀팁이 바뀌는 간격
  static const _tipEvery = Duration(seconds: 6);

  final Stopwatch _clock = Stopwatch();
  bool _done = false; // 서버가 답했다 → 100%
  int _tipStart = 0; // 매번 다른 꿀팁부터
  Timer? _timer;
  bool _navigated = false;
  bool _failed = false; // 서버 연결·분석 실패 (user-scenario §4 S-06 네트워크 오류)
  String? _errorMessage; // 서버가 보낸 한국어 detail (요약본 거부·크레딧 소진 등)
  int? _errorStatus; // 상태코드별 복구 동선 분기 (400계열=사진 다시 / 402·429=재시도 없음)
  bool _needsAppUpdate = false; // 기기 정보(400)·앱 인증(401) — 재시도·사진 교체로 안 풀린다

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _failed = false;
      _done = false;
      _tipStart = math.Random().nextInt(kLoadingTips.length);
    });
    _clock
      ..reset()
      ..start();
    _timer?.cancel();
    // 막대·남은 초·꿀팁을 다시 그리는 시계 (서버 진행과는 무관 — 예상 시간 기준)
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });

    final repo = context.read<AnalysisRepository>();
    final router = GoRouter.of(context); // go+push 전에 참조 확보 (context 무효화 대비)

    final AnalysisReport report;
    try {
      final results = await Future.wait([
        repo.analyze(widget.request),
        Future.delayed(const Duration(milliseconds: 2600)),
      ]);
      report = results.first as AnalysisReport;
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
      return;
    }

    _timer?.cancel();
    _clock.stop();
    if (!mounted || _navigated) return;
    // 서버가 답했다 → 막대를 100%로 채워 보여 주고 넘어간다(진짜 완료라서 괜찮다)
    setState(() => _done = true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
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
    _clock.stop();
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
    final message =
        _errorMessage ?? '연결이 불안정해요. 서버 연결을 확인하고 다시 시도해 주세요';

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

  /// 로딩 중 화면 — 세이프 · 단계 문장 · 예상 시간 막대(% · 남은 초) · 꿀팁 카드
  Widget _loadingBody() {
    final elapsed = _clock.elapsed;
    final progress = _done ? 1.0 : estimatedProgress(elapsed);
    final fraction = elapsed.inMilliseconds / (kAnalysisExpectedSeconds * 1000);
    final stage = _stages.firstWhere((s) => fraction < s.until).text;
    final secondsLeft = (kAnalysisExpectedSeconds - elapsed.inMilliseconds / 1000).ceil();
    final String timeText;
    if (_done) {
      timeText = '다 됐어요';
    } else if (secondsLeft >= 1) {
      timeText = '약 $secondsLeft초 남았어요';
    } else {
      timeText = '조금 더 걸리고 있어요'; // '거의 다 됐어요'는 사실이 아닐 수 있다(가짜 완료 없음)
    }
    final tipIndex =
        (_tipStart + elapsed.inMilliseconds ~/ _tipEvery.inMilliseconds) % kLoadingTips.length;

    return _Scrollable(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: MascotSafe(size: 96, state: MascotState.loading)),
          const SizedBox(height: AppSpacing.xl),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: AppText(
              _done ? '리포트를 열고 있어요' : stage,
              key: ValueKey(_done ? 'done' : stage),
              style: AppTypography.title,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          // 예상 시간 막대 — 퍼센트와 남은 초로 '언제 끝나는지' 가늠하게 한다
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: AppSpacing.sm,
              backgroundColor: AppColors.line,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: AppText(
                  timeText,
                  style: AppTypography.caption,
                ),
              ),
              AppText(
                '${(progress * 100).floor()}%',
                style: AppTypography.bodyStrong.copyWith(color: AppColors.primary),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xxxl),
          _TipCard(tip: kLoadingTips[tipIndex], index: tipIndex),
        ],
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
          : Scaffold(body: SafeArea(child: _loadingBody())),
    );
  }
}

/// "알고 계셨나요?" 꿀팁 카드 — 문장이 바뀔 때 부드럽게 겹쳐 바뀐다.
class _TipCard extends StatelessWidget {
  const _TipCard({required this.tip, required this.index});

  final String tip;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.cardPadH,
        vertical: AppSpacing.cardPadV,
      ),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lightbulb_outline, size: AppSize.iconSm, color: AppColors.primary),
              const SizedBox(width: AppSpacing.xs),
              AppText(
                '알고 계셨나요?',
                style: AppTypography.caption.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            child: AppText(
              tip,
              key: ValueKey(index),
              style: AppTypography.body.copyWith(color: AppColors.textBody),
            ),
          ),
        ],
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
            minHeight: (box.maxHeight - AppSpacing.xxxl * 2).clamp(0.0, double.infinity).toDouble(),
          ),
          child: child,
        ),
      ),
    );
  }
}
