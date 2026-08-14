/// 점선 테두리 — "새로 추가" 자리와 "아직 먼 단계" 표식에만 쓴다.
///
/// Flutter 기본 [Border]는 점선을 그리지 못한다. 점선이 필요한 곳은 둘 다 **비어 있음**을
/// 뜻하는 자리다: 아직 안 만든 것(＋ 새로 분석), 아직 오지 않은 것(1~2년 뒤 단계).
/// 실선으로 그리면 이미 있는 것과 같은 무게로 읽히므로 형태로 구분한다.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

class DashedBorder extends StatelessWidget {
  const DashedBorder({
    super.key,
    required this.child,
    required this.color,
    this.radius = 16,
    this.strokeWidth = 1,
    this.dash = 5,
    this.gap = 4,
    this.circle = false,
  });

  final Widget child;
  final Color color;
  final double radius;
  final double strokeWidth;
  final double dash;
  final double gap;

  /// true면 원형 점선 (타임라인의 '아직 먼 단계' 도트)
  final bool circle;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedPainter(
        color: color,
        radius: radius,
        strokeWidth: strokeWidth,
        dash: dash,
        gap: gap,
        circle: circle,
      ),
      child: child,
    );
  }
}

class _DashedPainter extends CustomPainter {
  const _DashedPainter({
    required this.color,
    required this.radius,
    required this.strokeWidth,
    required this.dash,
    required this.gap,
    required this.circle,
  });

  final Color color;
  final double radius;
  final double strokeWidth;
  final double dash;
  final double gap;
  final bool circle;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final Path base = circle
        ? (Path()..addOval(rect.deflate(strokeWidth / 2)))
        : (Path()..addRRect(
            RRect.fromRectAndRadius(
              rect.deflate(strokeWidth / 2),
              Radius.circular(radius),
            ),
          ));

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    for (final metric in base.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final double next = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.strokeWidth != strokeWidth ||
      old.dash != dash ||
      old.gap != gap ||
      old.circle != circle;
}
