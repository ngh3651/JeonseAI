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

/// 분석·대조가 보통 걸리는 시간 — 실측(NOW.md 2절: 21~31초)에 맞춘 말.
const String kAnalysisTypicalWait = '보통 30초쯤 걸려요';

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
  // 단계 문구 — 지수 리뷰 반영: '규칙' 같은 내부 용어 대신 쉬운 말.
  // (판정/설명 주체 구분은 리포트 근거 카드의 라벨이 담당 — judge-reviewer 요구도 그쪽에서 충족)
  static const _stages = [
    '사진을 올리고 있어요',
    '등기부등본을 읽는 중이에요', // B3: 정식 명칭
    '위험한 부분을 하나씩 확인하는 중이에요',
    '쉬운 말로 정리하는 중이에요',
  ];

  // G3: 마지막(가장 긴) 단계에서 대기가 길어질 때 순환하는 보조 멘트.
  // 진행 단계 문구는 그대로 두고, 아래에 세이프 멘트를 돌려 지루함을 던다.
  static const _waitingMents = [
    '세이프가 집을 지키는 중입니다',
    '꼼꼼히 살펴보는 중이에요',
    '거의 다 됐어요, 조금만 기다려 주세요',
  ];

  // 살펴보는 항목이 하나씩 나타나는 연출 — 용어 대신 쉬운 말 (지수 리뷰).
  //
  // ⚠ **진행형으로만 쓴다**(2026-10-23 D1). 이 목록은 서버 진행과 이어져 있지 않은 타이머 연출이라,
  //   예전처럼 '…읽었어요 ✓'로 쓰면 사진이 거절될 때도 ✓가 다 찬 뒤 "분석하지 않았어요"가 나왔다(가짜 완료).
  //   그래서 체크 표시 없이 흐린 점, 맨 아래 줄만 작은 스피너를 둔다.
  static const _extracted = [
    '집에 걸린 빚을 찾고 있어요',
    '소유권을 확인하고 있어요',
    '집주인을 확인하고 있어요',
  ];

  int _stage = 0;
  final List<String> _found = [];
  int _mentIndex = 0; // G3: 마지막 단계 순환 멘트 인덱스
  int _lastStageTicks = 0; // 마지막 단계에서 흐른 타이머 틱 수
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
      _stage = 0;
      _found.clear();
      _mentIndex = 0;
      _lastStageTicks = 0;
    });

    // 단계 진행 연출 (더미). 실단계에선 실제 파이프라인 진행에 연동.
    _timer = Timer.periodic(const Duration(milliseconds: 700), (t) {
      if (!mounted) return;
      setState(() {
        if (_stage < _stages.length - 1) {
          _stage++;
        } else {
          // G3: 마지막 단계에선 약 2.1초(3틱)마다 순환 멘트 교체
          _lastStageTicks++;
          if (_lastStageTicks % 3 == 0) {
            _mentIndex = (_mentIndex + 1) % _waitingMents.length;
          }
        }
        if (_found.length < _extracted.length) {
          _found.add(_extracted[_found.length]);
        }
      });
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
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxxl),
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
          : Scaffold(
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xxxl),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(
                        child: MascotSafe(size: 96, state: MascotState.loading),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      AppText(
                        _stages[_stage],
                        style: AppTypography.title,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      // 실측 21~31초(NOW.md 2절) — '1~2분'은 실제보다 길게 말했다(D1). 배포 서버에서 다시 잰다(NOW.md 사람 할 일)
                      AppText(
                        kAnalysisTypicalWait,
                        style: AppTypography.caption,
                        textAlign: TextAlign.center,
                      ),
                      // G3: 마지막 단계에서만 순환 세이프 멘트
                      if (_stage >= _stages.length - 1) ...[
                        const SizedBox(height: AppSpacing.xs),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: AppText(
                            _waitingMents[_mentIndex],
                            key: ValueKey(_mentIndex),
                            style: AppTypography.caption.copyWith(
                              color: AppColors.primary,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                      const SizedBox(height: AppSpacing.xl),
                      // 마지막 단계는 실제 서버 응답(최대 3분)을 기다리므로
                      // 확정형 100%로 멈춰 보이지 않게 물결(indeterminate)로 전환
                      LinearProgressIndicator(
                        value: _stage >= _stages.length - 1
                            ? null
                            : (_stage + 1) / _stages.length,
                        backgroundColor: AppColors.line,
                        color: AppColors.primary,
                      ),
                      const SizedBox(height: AppSpacing.xxl),
                      // 살펴보는 항목 — 완료(✓)를 말하지 않는다. 지난 줄은 흐린 점, 맨 아래 줄만 작은 스피너(D1)
                      for (int i = 0; i < _found.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: LoadingStepLine(
                            text: _found[i],
                            active: i == _found.length - 1,
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
