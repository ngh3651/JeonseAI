/// 안전도 게이지 — 리포트 결론 헤더의 원형 게이지.
///
/// 점수 체계·임계값은 Phase E-1에서 출처 기반 확정 (docs/IA.md §6 S-07).
/// 이 컴포넌트는 시각 슬롯만 제공한다: 진행률(0~1)과 등급을 받아 그리며,
/// 어떤 수치가 어떤 등급인지는 여기서 판단하지 않는다 (규칙 엔진의 몫).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/risk_grade.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_typography.dart';
import '../../design_system/text/app_text.dart';

class SafetyGauge extends StatelessWidget {
  const SafetyGauge({
    super.key,
    required this.grade,
    required this.progress,
    this.caption,
    this.size = 180,
  });

  final RiskGrade grade;

  /// 시각적 진행률 (0.0~1.0). 값의 의미는 E-1에서 확정.
  final double progress;

  /// 게이지 아래 보조 문구 (예: "7일 전 분석")
  final String? caption;

  final double size;

  @override
  Widget build(BuildContext context) {
    // 글자는 대비 확보용 텍스트 색, 호는 한 단계 밝은 그래픽 색 (F11)
    final Color textColor = AppColors.gradeColor(grade);
    final Color arcColor = AppColors.gradeArcColor(grade);

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _GaugePainter(
          progress: progress.clamp(0.0, 1.0),
          color: arcColor,
          trackColor: AppColors.line,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // F4: '확인 필요'처럼 공백 있는 라벨은 2줄로 접히게 폭을 제한 —
              // 아치 안쪽 여백에 맞춰 답답함 해소. 단어 하나짜리(양호·위험)는 그대로 1줄.
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: size * 0.62),
                child: AppText(
                  grade.label,
                  textAlign: TextAlign.center,
                  // 하한 19px bold — 작은 게이지에서도 large-text 대비 기준(≥18.7px bold) 유지
                  style: AppTypography.conclusion.copyWith(
                    color: textColor,
                    fontSize: math.max(size * 0.17, 19),
                    height: 1.1,
                  ),
                ),
              ),
              if (caption != null) ...[
                const SizedBox(height: 4),
                AppText(caption!, style: AppTypography.caption),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  const _GaugePainter({
    required this.progress,
    required this.color,
    required this.trackColor,
  });

  final double progress;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final double stroke = size.width * 0.075;
    final Rect rect =
        Offset(stroke / 2, stroke / 2) &
        Size(size.width - stroke, size.height - stroke);

    // 아래쪽이 열린 270도 아치 (시작: 왼쪽 아래, 시계방향)
    const double startAngle = 3 * math.pi / 4;
    const double sweepTotal = 3 * math.pi / 2;

    final Paint track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = trackColor;

    final Paint fill = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;

    canvas.drawArc(rect, startAngle, sweepTotal, false, track);
    if (progress > 0) {
      canvas.drawArc(rect, startAngle, sweepTotal * progress, false, fill);
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.progress != progress || old.color != color;
}
