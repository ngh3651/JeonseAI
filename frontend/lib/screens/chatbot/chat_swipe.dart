/// 챗봇 v2 — 왼쪽으로 밀어서 이어 묻기 (AI 말풍선만) (2026-10-24).
///
/// - 손가락을 따라 최대 [kSwipeMax]까지 왼쪽으로. 미는 동안 그림자.
/// - 말풍선 오른쪽 끝에서 16 떨어진 곳에 답글 화살표(원 40 primarySoft + 화살표 20 primary) — 미는 만큼 0.6 → 1.
/// - [kSwipeMax]를 넘으면 진동 1번 → 놓으면 인용 / 덜 밀고 놓으면 제자리로.
/// - [nudge]: 첫 안내 — 1초 뒤 24만큼 밀렸다 돌아온다(0.6초). 애니메이션 끄기 설정이면 화면이 아예 켜지 않는다.
///
/// 왜 GestureDetector가 아니라 Listener인가: 말풍선은 글자 선택 영역(SelectionArea) 안에 있고,
/// 그 영역이 가로 끌기를 먼저 가져간다(안드로이드). Listener는 손가락 움직임을 그대로 받아서 겹치지 않는다.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_system/tokens/app_colors.dart';

/// 최대로 밀리는 거리 = 인용이 되는 거리
const double kSwipeMax = 64;

/// 첫 안내 때 밀리는 거리
const double kSwipeNudge = 24;

/// 화살표 원 지름 · 화살표 크기 · 말풍선과의 간격
const double kSwipeArrowCircle = 40;
const double kSwipeArrowIcon = 20;
const double kSwipeArrowGap = 16;

class SwipeToQuote extends StatefulWidget {
  const SwipeToQuote({
    super.key,
    required this.builder,
    required this.onQuote,
    this.topInset = 0,
    this.nudge = false,
  });

  /// 말풍선을 그린다 — `lifted`면 미는 중(그림자를 단다)
  final Widget Function(BuildContext context, bool lifted) builder;
  final VoidCallback onQuote;

  /// 말풍선 위에 얹힌 것(세이프)의 높이 — 화살표는 그 아래 말풍선 몸통 가운데에
  final double topInset;

  /// true가 되면 1초 뒤 한 번 살짝 밀렸다 돌아온다
  final bool nudge;

  @override
  State<SwipeToQuote> createState() => _SwipeToQuoteState();
}

class _SwipeToQuoteState extends State<SwipeToQuote> with SingleTickerProviderStateMixin {
  /// 0 = 제자리, 1 = [kSwipeMax]만큼 밀림
  late final AnimationController _ctrl = AnimationController(vsync: this);
  Timer? _nudgeTimer;

  Offset? _down;
  Duration _downAt = Duration.zero;
  bool _decided = false;
  bool _swiping = false;
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    if (widget.nudge) _scheduleNudge();
  }

  @override
  void didUpdateWidget(SwipeToQuote oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.nudge && !oldWidget.nudge) _scheduleNudge();
  }

  @override
  void dispose() {
    _nudgeTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _scheduleNudge() {
    _nudgeTimer?.cancel();
    _nudgeTimer = Timer(const Duration(seconds: 1), () async {
      if (!mounted || _swiping) return;
      await _ctrl.animateTo(kSwipeNudge / kSwipeMax, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      if (!mounted || _swiping) return;
      await _ctrl.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeIn);
    });
  }

  void _onDown(PointerDownEvent e) {
    _down = e.position;
    _downAt = e.timeStamp;
    _decided = false;
    _swiping = false;
    _armed = false;
  }

  void _onMove(PointerMoveEvent e) {
    final start = _down;
    if (start == null) return;
    final d = e.position - start;
    if (!_decided) {
      if (d.distance < kTouchSlop) return;
      _decided = true;
      // 꾹 누른 뒤(글자 선택) 움직이는 건 밀기가 아니다. 세로로 더 움직이면 목록 스크롤.
      final held = e.timeStamp - _downAt;
      _swiping = held < kLongPressTimeout && d.dx < 0 && d.dx.abs() > d.dy.abs();
      if (!_swiping) {
        _down = null;
        return;
      }
      _ctrl.stop();
    }
    final pulled = d.dx < 0 ? -d.dx : 0.0;
    _ctrl.value = (pulled / kSwipeMax).clamp(0.0, 1.0);
    final armed = pulled >= kSwipeMax;
    if (armed && !_armed) HapticFeedback.mediumImpact();
    _armed = armed;
  }

  void _onUp(PointerUpEvent e) {
    if (_swiping && _armed) widget.onQuote();
    _finish();
  }

  void _onCancel(PointerCancelEvent e) => _finish();

  void _finish() {
    if (_swiping) {
      _ctrl.animateTo(0, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    }
    _down = null;
    _swiping = false;
    _armed = false;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final p = _ctrl.value;
          final dx = p * kSwipeMax;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Transform.translate(offset: Offset(-dx, 0), child: widget.builder(context, dx > 0)),
              if (dx > 0)
                Positioned(
                  top: widget.topInset,
                  bottom: 0,
                  right: dx - kSwipeArrowGap - kSwipeArrowCircle,
                  width: kSwipeArrowCircle,
                  child: Center(
                    child: Opacity(
                      opacity: 0.6 + 0.4 * p,
                      child: Transform.scale(
                        scale: 0.6 + 0.4 * p,
                        child: Container(
                          key: const ValueKey('swipe-arrow'),
                          width: kSwipeArrowCircle,
                          height: kSwipeArrowCircle,
                          decoration: BoxDecoration(color: AppColors.primarySoft, shape: BoxShape.circle),
                          child: Icon(Icons.reply, size: kSwipeArrowIcon, color: AppColors.primary),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
