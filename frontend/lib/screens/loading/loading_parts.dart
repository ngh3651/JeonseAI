/// 분석 로딩 화면(S-06)의 **부품** (2026-10-28 새로 그림) — 그림 영역 · 단계 표시 · 진행 막대 · 꿀팁 카드.
///
/// 화면 상태(언제 어느 단계인지)는 [AnalysisLoadingScreen]이 정하고, 여기 부품은 받은 값을 그리기만 한다.
/// 시간에 따라 계속 움직이는 것(세이프 통통·종이 흔들림·스캔 줄·물결·막대 빛)은 [motion] 하나(초 단위 시계)를
/// 보고 그린다. 휴대폰 "동작 줄이기"가 켜지면 [reduceMotion] = true 로 모두 멈춘다.
///
/// 위치는 전부 **고정 높이**다 — 팁 글이 2줄이든 3줄이든 다른 요소가 1px도 움직이지 않게(시안 2026-10-28).
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography.dart';
import 'loading_tips.dart';

// ─────────────────────────────── 진행 계산 (그림 없이 시간만 본다 — 테스트가 직접 부른다)

/// 분석·대조가 보통 걸리는 시간(초) — 실측(NOW.md 2절: 21~31초). 배포 서버에서 다시 재면 **이 숫자 하나만** 고친다
/// (로딩 막대의 %·남은 초·단계 나누기가 함께 바뀐다).
const int kAnalysisExpectedSeconds = 30;

/// 로딩 단계 — 서버가 단계를 알려 주지 않아 **예상 시간으로 나눈다**(30초 기준 0~8·8~15·15~22·22~28·그 뒤).
enum LoadingStage {
  read('AI가 등기부를 한 장씩 읽고 있어요', 8),
  gap('집주인과 압류를 살펴보고 있어요', 15),
  eul('집에 걸린 빚을 살펴보고 있어요', 22),
  precedent('비슷한 판례를 찾고 있어요', 28),
  finish('리포트를 정리하고 있어요', double.infinity);

  const LoadingStage(this.title, this.untilSecond);

  /// 단계 제목 (한 줄 고정)
  final String title;

  /// 30초 기준 이 단계가 끝나는 때(초)
  final double untilSecond;

  /// 단계 표시 4칸(읽기·갑구·을구·판례) 이름 — 마무리는 칸이 없다
  static const List<String> stepLabels = ['읽기', '갑구', '을구', '판례'];
}

double _scaled(Duration elapsed) =>
    elapsed.inMicroseconds / 1e6 * 30 / kAnalysisExpectedSeconds;

/// 지금 단계 — 예상 시간(30초)을 기준으로 비율대로 늘리거나 줄인다.
LoadingStage loadingStageAt(Duration elapsed) {
  final s = _scaled(elapsed);
  return LoadingStage.values.firstWhere((st) => s < st.untilSecond);
}

/// 진행률(0~0.99) — 처음엔 빨리, 끝으로 갈수록 천천히. **99%에서 멈춘다**(100%는 서버가 답했을 때만).
/// 30초 기준 4초 20% · 13초 60% · 20초 83% · 29초 99% (시안 ①~④).
double loadingProgress(Duration elapsed) {
  final t = (elapsed.inMicroseconds / 1e6 / kAnalysisExpectedSeconds).clamp(
    0.0,
    1.0,
  );
  return math.min(0.99, 1 - math.pow(1 - t, 1.6).toDouble());
}

/// 앞 종이에 보일 쪽수 — 읽기 단계 동안 1/N → N/N 으로 고르게 넘기고, 그 뒤로는 N/N.
int loadingPageAt(Duration elapsed, int totalPages) {
  final total = math.max(1, totalPages);
  final s = _scaled(elapsed);
  final readEnd = LoadingStage.read.untilSecond;
  if (s >= readEnd) return total;
  return math.min(total, 1 + (s / readEnd * total).floor());
}

/// "약 N초 남았어요" — 예상 시간을 넘기면 "거의 다 됐어요".
String loadingTimeText(Duration elapsed) {
  final left = (kAnalysisExpectedSeconds - elapsed.inMicroseconds / 1e6).ceil();
  return left >= 1 ? '약 $left초 남았어요' : '거의 다 됐어요';
}

/// 세이프 그림 4장
const List<String> kInspectFrames = [
  'assets/mascot/safe_inspect_1.png', // 정면, 돋보기를 가슴 앞에
  'assets/mascot/safe_inspect_2.png', // 들어 올리며 돌아봄
  'assets/mascot/safe_inspect_3.png', // 렌즈로 들여다봄 (문서 쪽)
  'assets/mascot/safe_inspect_4.png', // 렌즈를 내려 훑음
];

/// 세이프 그림 번호(0~3) — 10초 한 바퀴:
/// 0~2.6 정면 · 2.6~2.9 돌아봄 · 2.9~9.6 들여다봄↔훑음 0.6초마다 · 9.6~10 돌아봄.
int inspectFrameAt(double seconds) {
  final c = seconds % 10;
  if (c < 2.6) return 0;
  if (c < 2.9) return 1;
  if (c < 9.6) return ((c - 2.9) / 0.6).floor().isEven ? 2 : 3;
  return 1;
}

// ─────────────────────────────── 크기·색 (시안 360×800 기준)

/// 그림 영역 높이
const double kArtHeight = 300;

const double _paperW = 150;
const double _paperH = 196;
const double _paperLeft = 62; // 그림 영역(폭 360) 안에서 — 가운데보다 왼쪽
const double _paperTop = 50;
const double _mascotW = 136;
const double _mascotH = _mascotW * 557 / 459; // 그림 원본 비율
const double _mascotLeft = 188;
const double _mascotTop = kArtHeight - _mascotH - 14;

const Color _paperBack1 = Color(0xFFDDE5E0);
const Color _paperBack2 = Color(0xFFE9EEEB);
const Color _paperLine = Color(0xFFECEFED);
const Color _paperTitle = Color(0xFF4A524E);
const Color _ink = Color(0x1A101814); // rgba(16,24,20,.10)
const Color _shadowInk = Color(0x2E101814); // rgba(16,24,20,.18)

/// 종이 글줄 6개의 길이(앞 종이 안쪽 폭 대비)
const List<double> _lineWidths = [0.92, 0.86, 0.6, 0.9, 0.74, 0.82];

/// 숫자 폭 고정 — 쪽수·퍼센트가 바뀔 때 글자가 옆으로 흔들리지 않게
const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

double _wave(double t, double period) => math.sin(2 * math.pi * t / period);

// ─────────────────────────────── 1. 그림 영역

/// 종이 더미 + 스캔 줄 + 형광펜 + 세이프. 폭 360 고정, 가로 가운데.
class LoadingArt extends StatelessWidget {
  const LoadingArt({
    super.key,
    required this.stage,
    required this.page,
    required this.totalPages,
    required this.motion,
    required this.reduceMotion,
  });

  final LoadingStage stage;
  final int page;
  final int totalPages;
  final ValueListenable<double> motion;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      height: kArtHeight,
      child: ValueListenableBuilder<double>(
        valueListenable: motion,
        builder: (context, t, _) {
          final m = reduceMotion ? 0.0 : t;
          final bob = reduceMotion
              ? 0.0
              : (1 - math.cos(2 * math.pi * m / 1.2)) / 2; // 0~1
          return Stack(
            clipBehavior: Clip.none,
            children: [
              // 뒤 원
              Positioned(
                left: (360 - 236) / 2,
                top: (kArtHeight - 236) / 2 - 6,
                child: Container(
                  width: 236,
                  height: 236,
                  decoration: BoxDecoration(
                    color: AppColors.primarySoft,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              // 뒤 종이 2장 — 3초대 주기로 천천히 흔들린다
              _backPaper(
                _paperBack1,
                -9 + 2 * _wave(m, 3.2),
                3.5 * _wave(m + 0.8, 3.2),
              ),
              _backPaper(
                _paperBack2,
                7 + 2 * _wave(m + 1.1, 3.6),
                3 * _wave(m + 0.3, 3.6),
              ),
              // 앞 종이
              Positioned(
                left: _paperLeft,
                top: _paperTop,
                child: _FrontPaper(
                  stage: stage,
                  page: page,
                  totalPages: totalPages,
                  scanSeconds: m,
                  reduceMotion: reduceMotion,
                ),
              ),
              // 발밑 그림자 — 몸이 올라가면 살짝 작아진다
              Positioned(
                left: _mascotLeft + (_mascotW - 96) / 2 + 6,
                top: _mascotTop + _mascotH - 10,
                child: Transform.scale(
                  scale: 1 - 0.12 * bob,
                  child: Container(
                    width: 96,
                    height: 12,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(48),
                      gradient: const RadialGradient(
                        colors: [_shadowInk, Color(0x00101814)],
                      ),
                    ),
                  ),
                ),
              ),
              // 세이프 — 4장을 같은 자리에 겹쳐 두고 보이는 것만 바꾼다(크로스페이드 없음)
              Positioned(
                left: _mascotLeft,
                top: _mascotTop - 4 * bob,
                child: _InspectMascot(
                  frame: reduceMotion ? 2 : inspectFrameAt(m),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _backPaper(Color color, double degrees, double dy) {
    return Positioned(
      left: _paperLeft,
      top: _paperTop + dy,
      child: Transform.rotate(
        angle: degrees * math.pi / 180,
        child: Container(
          width: _paperW,
          height: _paperH,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}

class _InspectMascot extends StatelessWidget {
  const _InspectMascot({required this.frame});

  final int frame;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('loading-mascot'),
      width: _mascotW,
      height: _mascotH,
      child: Stack(
        children: [
          for (var i = 0; i < kInspectFrames.length; i++)
            Positioned.fill(
              child: Opacity(
                key: ValueKey('inspect-frame-$i'),
                opacity: i == frame ? 1 : 0,
                child: Image.asset(
                  kInspectFrames[i],
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  excludeFromSemantics: true,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FrontPaper extends StatelessWidget {
  const _FrontPaper({
    required this.stage,
    required this.page,
    required this.totalPages,
    required this.scanSeconds,
    required this.reduceMotion,
  });

  final LoadingStage stage;
  final int page;
  final int totalPages;
  final double scanSeconds;
  final bool reduceMotion;

  /// 글줄 번호 → 형광펜 색 (단계가 넘어갈 때마다 하나씩)
  Color _lineColor(int i) {
    final at = stage.index;
    if (i == 1 && at >= LoadingStage.gap.index) return AppColors.cautionSoft;
    if (i == 3 && at >= LoadingStage.eul.index) return AppColors.dangerSoft;
    if (i == 4 && at >= LoadingStage.precedent.index) return AppColors.okSoft;
    return _paperLine;
  }

  @override
  Widget build(BuildContext context) {
    const inner = _paperW - 40;
    final showScan = !reduceMotion && stage != LoadingStage.finish;
    final period = stage == LoadingStage.read ? 1.6 : 2.4;
    final scanY = (scanSeconds % period) / period * (_paperH + 26) - 26;

    return Container(
      width: _paperW,
      height: _paperH,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(color: _ink, offset: Offset(0, 8), blurRadius: 24),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          children: [
            // 제목 줄
            Positioned(
              left: 20,
              top: 26,
              child: Container(
                width: 56,
                height: 8,
                decoration: BoxDecoration(
                  color: _paperTitle,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            // 쪽수 알약
            Positioned(
              right: 10,
              top: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: AppText(
                  '$page / $totalPages쪽',
                  key: const ValueKey('loading-page'),
                  maxLines: 1,
                  textScaler: TextScaler.noScaling, // 종이 그림 안 — 그림과 함께 고정 크기
                  style: AppTypography.bodyStrong.copyWith(
                    fontSize: 15,
                    height: 1.3,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                    fontFeatures: _tabular,
                  ),
                ),
              ),
            ),
            // 글줄 6개
            for (var i = 0; i < 6; i++)
              Positioned(
                left: 20,
                top: 62.0 + i * 20,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  width: inner * _lineWidths[i],
                  height: 7,
                  decoration: BoxDecoration(
                    color: _lineColor(i),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            // 스캔 줄 — 위→아래로 계속 훑는다
            if (showScan)
              Positioned(
                left: 0,
                right: 0,
                top: scanY,
                height: 26,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppColors.primaryBright.withValues(alpha: 0),
                        AppColors.primaryBright.withValues(alpha: 0.16),
                        AppColors.primaryBright.withValues(alpha: 0.85),
                        AppColors.primaryBright.withValues(alpha: 0.16),
                        AppColors.primaryBright.withValues(alpha: 0),
                      ],
                      stops: const [0, 0.38, 0.5, 0.62, 1],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────── 2. 단계 표시 (읽기 · 갑구 · 을구 · 판례)

class LoadingSteps extends StatelessWidget {
  const LoadingSteps({
    super.key,
    required this.stage,
    required this.motion,
    required this.reduceMotion,
    required this.labelHeight,
  });

  final LoadingStage stage;
  final ValueListenable<double> motion;
  final bool reduceMotion;

  /// 이름 줄 높이(글자 배율만큼 커진다 — 화면 안에서는 늘 같은 값)
  final double labelHeight;

  static const double _dot = 28;

  @override
  Widget build(BuildContext context) {
    final current = stage.index; // 마무리 = 4 → 모두 끝남
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final span = w - _dot;
        double cx(int i) => _dot / 2 + span * i / 3;
        final fill = (math.min(current, 3) / 3).toDouble();
        return SizedBox(
          height: _dot + 8 + labelHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 바탕 선
              Positioned(
                left: cx(0),
                width: span,
                top: _dot / 2 - 1,
                height: 2,
                child: ColoredBox(color: AppColors.line),
              ),
              // 지난 구간 — 0.5초에 걸쳐 채운다
              Positioned(
                left: cx(0),
                top: _dot / 2 - 2,
                height: 4,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: fill),
                  duration: const Duration(milliseconds: 500),
                  builder: (_, f, _) => Container(
                    width: span * f,
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              for (var i = 0; i < 4; i++) ...[
                Positioned(
                  left: cx(i) - _dot / 2,
                  top: 0,
                  child: _StepDot(
                    state: i < current
                        ? _Step.done
                        : (i == current ? _Step.now : _Step.later),
                    motion: motion,
                    reduceMotion: reduceMotion,
                  ),
                ),
                Positioned(
                  left: cx(i) - 40,
                  width: 80,
                  top: _dot + 8,
                  height: labelHeight,
                  child: AppText(
                    LoadingStage.stepLabels[i],
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    style: AppTypography.body.copyWith(
                      fontSize: 15,
                      height: 1.4,
                      fontWeight: i == current
                          ? FontWeight.w700
                          : FontWeight.w600,
                      color: i <= current
                          ? AppColors.textStrong
                          : AppColors.textMuted,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

enum _Step { done, now, later }

class _StepDot extends StatelessWidget {
  const _StepDot({
    required this.state,
    required this.motion,
    required this.reduceMotion,
  });

  final _Step state;
  final ValueListenable<double> motion;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    const d = LoadingSteps._dot;
    final Widget dot = switch (state) {
      _Step.done => Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          color: AppColors.primary,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.check_rounded,
          size: 18,
          color: AppColors.surface,
        ),
      ),
      _Step.now => Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          color: AppColors.surface,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.primaryBright, width: 2),
        ),
        alignment: Alignment.center,
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: AppColors.primary,
            shape: BoxShape.circle,
          ),
        ),
      ),
      _Step.later => Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          color: AppColors.surface,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.line, width: 1.5),
        ),
      ),
    };
    if (state != _Step.now || reduceMotion) return dot;
    // 지금 칸 — 1.2초마다 초록 물결이 퍼진다
    return SizedBox(
      width: d,
      height: d,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          ValueListenableBuilder<double>(
            valueListenable: motion,
            builder: (_, t, _) {
              final p = (t % 1.2) / 1.2;
              final size = d + 18 * p;
              return OverflowBox(
                maxWidth: d + 18,
                maxHeight: d + 18,
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.primaryBright.withValues(
                      alpha: 0.28 * (1 - p),
                    ),
                  ),
                ),
              );
            },
          ),
          dot,
        ],
      ),
    );
  }
}

// ─────────────────────────────── 3. 진행 막대

class LoadingBar extends StatelessWidget {
  const LoadingBar({
    super.key,
    required this.progress,
    required this.timeText,
    required this.motion,
    required this.reduceMotion,
    required this.rowHeight,
  });

  final double progress;
  final String timeText;
  final ValueListenable<double> motion;
  final bool reduceMotion;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: Stack(
              children: [
                Positioned.fill(child: ColoredBox(color: AppColors.line)),
                TweenAnimationBuilder<double>(
                  tween: Tween(end: progress),
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 300),
                  builder: (_, p, _) => FractionallySizedBox(
                    widthFactor: p.clamp(0.0, 1.0),
                    heightFactor: 1,
                    alignment: Alignment.centerLeft,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    AppColors.primary,
                                    AppColors.primaryBright,
                                    AppColors.primary,
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (!reduceMotion)
                            Positioned.fill(
                              child: ValueListenableBuilder<double>(
                                valueListenable: motion,
                                builder: (_, t, _) {
                                  final x =
                                      (t % 1.4) / 1.4 * 2 - 0.5; // -0.5 ~ 1.5
                                  return FractionallySizedBox(
                                    widthFactor: 0.3,
                                    alignment: Alignment(x * 2 - 1, 0),
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            AppColors.surface.withValues(
                                              alpha: 0,
                                            ),
                                            AppColors.surface.withValues(
                                              alpha: 0.45,
                                            ),
                                            AppColors.surface.withValues(
                                              alpha: 0,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: rowHeight,
          child: Row(
            children: [
              Expanded(
                child: AppText(
                  timeText,
                  key: const ValueKey('loading-time'),
                  maxLines: 1,
                  style: AppTypography.body.copyWith(
                    fontSize: 15,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
              // 폭 고정 — '9%'→'99%'로 자릿수가 늘어도 옆 글자가 밀리지 않게
              SizedBox(
                key: const ValueKey('loading-percent'),
                width: 56 * rowHeight / 24,
                child: AppText(
                  '${(progress * 100).floor()}%',
                  maxLines: 1,
                  textAlign: TextAlign.right,
                  style: AppTypography.bodyStrong.copyWith(
                    fontSize: 17,
                    height: 1.4,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                    fontFeatures: _tabular,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────── 4. 리포트 꿀팁 카드 (높이 고정)

/// 꿀팁 본문 글꼴 — 17/400, 줄 높이 27 (3줄 = 81)
TextStyle get kTipBodyStyle => TextStyle(
  fontFamily: AppTypography.fontFamily,
  fontSize: 17,
  height: 27 / 17,
  fontWeight: FontWeight.w400,
  color: AppColors.textStrong,
);

class LoadingTipCard extends StatelessWidget {
  const LoadingTipCard({super.key, required this.index, required this.scale});

  final int index;

  /// 글자 배율 — 카드 높이도 같은 비율로 (화면 안에서는 늘 같은 값이라 팁이 바뀌어도 안 움직인다)
  final double scale;

  @override
  Widget build(BuildContext context) {
    final tip = kLoadingTips[index];
    return Container(
      key: const ValueKey('loading-tip-card'),
      height: 38 + 102 * scale, // 배율 1 = 140
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 21 * scale,
            child: Row(
              children: [
                Icon(
                  Icons.lightbulb_outline_rounded,
                  size: 18,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: AppText(
                    kLoadingTipsTitle,
                    maxLines: 1,
                    style: AppTypography.bodyStrong.copyWith(
                      fontSize: 15,
                      height: 1.4,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                for (var i = 0; i < kLoadingTips.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 350),
                    margin: const EdgeInsets.only(left: 4),
                    width: i == index ? 16 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == index ? AppColors.primary : AppColors.line,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 81 * scale,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topLeft,
                children: [...previous, ?current],
              ),
              child: AppText.rich(
                TextSpan(
                  children: tipSpans(
                    tip,
                    bold: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                key: ValueKey('tip-$index'),
                maxLines: 3,
                overflow: TextOverflow.clip,
                style: kTipBodyStyle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
