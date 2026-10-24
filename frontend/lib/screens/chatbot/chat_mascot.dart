/// 챗봇 말풍선 위의 세이프 — "답 들기"(머리+앞발이 말풍선에 걸침)와 "달리기"(답 쓰는 중) (2026-10-24 리디자인).
///
/// 그림 파일은 여기 상수에서만 고른다 — 새 그림을 넣으면 경로만 바꾸면 된다.
/// - 답 들기: `mascot_hold.png` = 기존 `mascot_loading.png`(선에 매달린 세이프)에서 머리·앞발만 잘라 만든 것
/// - 달리기: `safe_run_1~4.png`(원본 560×560, 투명 배경, 귀 끝 높이 맞춤 — 2026-10-24 전달)를 90ms씩 바꾸고
///   몸 전체를 통통 뛰며 흔든다. [kSafeRunFrames]를 비우면 기본 세이프에 흔들기만 준다.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design_system/tokens/app_colors.dart';

/// 답 들기 그림 (머리 + 말풍선을 잡은 앞발)
const String kSafeHoldAsset = 'assets/mascot/mascot_hold.png';

/// 달리기가 없을 때 쓰는 기본 세이프
const String kSafeDefaultAsset = 'assets/mascot/mascot_tip.png';

/// 달리기 프레임 — 비어 있으면 기본 그림 + 흔들기
const List<String> kSafeRunFrames = [
  'assets/mascot/safe_run_1.png',
  'assets/mascot/safe_run_2.png',
  'assets/mascot/safe_run_3.png',
  'assets/mascot/safe_run_4.png',
];

/// 마스코트 칸 크기(그대로 — 글자 배율과 무관)
const double kSafeSize = 56;

/// 말풍선 위로 솟는 높이
const double kSafeRise = 48;

/// 답 들기 — 아래 끝이 말풍선 윗선에 걸치도록 놓는다(앞발이 테두리를 덮는다).
class SafeHold extends StatelessWidget {
  const SafeHold({super.key});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        width: kSafeSize + 8,
        height: kSafeRise + 6,
        child: Image.asset(
          kSafeHoldAsset,
          fit: BoxFit.contain,
          alignment: Alignment.bottomCenter,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => const _SafeFallback(),
        ),
      ),
    );
  }
}

/// 달리기 — 답을 쓰는 동안. 애니메이션 끄기 설정이면 멈춘 그림.
class SafeRunning extends StatefulWidget {
  const SafeRunning({super.key});

  @override
  State<SafeRunning> createState() => _SafeRunningState();
}

class _SafeRunningState extends State<SafeRunning> with SingleTickerProviderStateMixin {
  /// 한 걸음 0.36초 (프레임 4장 × 90ms)
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );

  /// 원본 560을 화면 크기(56 × 기기 배율)로만 풀어 둔다 — 메모리 절약
  int _cacheWidth(BuildContext context) => (kSafeSize * MediaQuery.devicePixelRatioOf(context)).round();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 첫 바퀴에 프레임이 깜빡이지 않게 미리 풀어 둔다
    final w = _cacheWidth(context);
    for (final f in kSafeRunFrames) {
      precacheImage(ResizeImage(AssetImage(f), width: w), context, onError: (_, _) {});
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _ctrl.stop();
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cacheWidth = kSafeRunFrames.isEmpty ? null : _cacheWidth(context);
    return ExcludeSemantics(
      child: SizedBox(
        width: kSafeSize,
        height: kSafeRise + 6,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            final t = _ctrl.value; // 0 → 1 한 걸음
            final wave = math.sin(t * 2 * math.pi);
            final dy = -4 * wave.abs(); // 위아래 0 → -4 → 0 (한 걸음에 두 번 통통)
            final angle = wave * 4 * math.pi / 180; // 기울기 -4° ↔ +4°
            final frame = kSafeRunFrames.isEmpty
                ? kSafeDefaultAsset
                : kSafeRunFrames[(t * kSafeRunFrames.length).floor() % kSafeRunFrames.length];
            return Transform.translate(
              offset: Offset(0, dy),
              child: Transform.rotate(
                angle: angle,
                alignment: Alignment.bottomCenter,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: _OnSoftCircle(
                    child: Image.asset(
                      frame,
                      cacheWidth: cacheWidth,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const _SafeFallback(),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 흰 강아지가 회색 바탕에 묻히지 않게 연초록 받침 원 위에
class _OnSoftCircle extends StatelessWidget {
  const _OnSoftCircle({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: kSafeSize,
      height: kSafeSize,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.line),
      ),
      child: child,
    );
  }
}

class _SafeFallback extends StatelessWidget {
  const _SafeFallback();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(color: AppColors.primarySoft, shape: BoxShape.circle),
      child: Icon(Icons.pets, color: AppColors.primary),
    );
  }
}
