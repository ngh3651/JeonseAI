/// 형광펜 한 줄을 그리는 공통 부품 — 사진 뷰어와 리포트 진입 카드가 함께 쓴다.
///
/// 두 화면이 같은 모양이어야 하는 이유: 진입 카드의 미리보기 스트립은 "뷰어에 들어가면
/// 이런 게 보인다"는 약속이다. 모서리나 색이 다르면 그 약속이 어긋난다.
///
/// **곱하기(multiply)로 겹친다.** 불투명하게 칠하면 정작 그 글자를 못 읽는 최악이 된다 —
/// 글자가 비쳐 보여야 사용자가 종이와 화면을 대조할 수 있다.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design_system/tokens/app_colors.dart';
import '../../models/registry_mark_kind.dart';

/// 형광펜 모서리 — 손으로 그은 느낌을 내려고 네 귀퉁이를 일부러 다르게 준다.
const BorderRadius kMarkRadius = BorderRadius.only(
  topLeft: Radius.circular(2),
  topRight: Radius.circular(7),
  bottomRight: Radius.circular(3),
  bottomLeft: Radius.circular(6),
);

/// 형광펜 한 줄. 부모가 준 상자를 그대로 채운다(위치·크기는 부모가 정한다).
class MarkStripe extends StatelessWidget {
  const MarkStripe({super.key, required this.tone, this.selected = false});

  final MarkTone tone;
  final bool selected;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _StripePainter(AppColors.markHighlight(tone, selected: selected)),
    child: const SizedBox.expand(),
  );
}

class _StripePainter extends CustomPainter {
  _StripePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      kMarkRadius.toRRect(Offset.zero & size),
      Paint()
        ..color = color
        ..blendMode = BlendMode.multiply,
    );
  }

  @override
  bool shouldRepaint(_StripePainter old) => old.color != color;
}

// ══════════════════════════════════════════════════════════════════════════
// 이름 가림 상자 ('사진 속 이름 가리기' 스위치 — 2026-10-22)
// ══════════════════════════════════════════════════════════════════════════

/// 이름 가림 상자의 모서리 — 형광펜처럼 손맛을 내지 않는다. "지운 칸"은 반듯해야 한다.
const BorderRadius kRedactionRadius = BorderRadius.all(Radius.circular(2));

/// 표시 상자 → 실제로 덮을 사각형. **사방으로 조금 넓힌다.**
///
/// 서버가 주는 상자는 OCR 글자 상자라 글자에 딱 붙어 있다. 그대로 덮으면 획 끝(ㄹ의 꼬리, 받침)이
/// 상자 밖으로 삐져나와 이름을 짐작할 수 있다. 높이의 15%(최소 1)만큼 넓힌다 — 옆 칸 글자를
/// 덮을 만큼 크지는 않다.
Rect redactionRectFor(Rect markRect) =>
    markRect.inflate(math.max(1.0, markRect.height * 0.15));

/// 이름 칸을 **불투명하게** 덮는다 — 사진 뷰어(CustomPainter)와 진입 카드([NameRedactionBox])가 함께 쓴다.
///
/// 형광펜([MarkStripe])과 정반대다: 형광펜은 곱하기로 글자를 비치게 하고, 이 상자는 보통 덮기로
/// 글자를 완전히 지운다. 두 화면이 같은 함수를 써야 "카드에서는 가렸는데 뷰어에선 보인다"가 안 생긴다.
void paintNameRedaction(Canvas canvas, Rect markRect) {
  canvas.drawRRect(
    kRedactionRadius.toRRect(redactionRectFor(markRect)),
    Paint()..color = AppColors.markRedaction,
  );
}

/// 진입 카드 미리보기용 이름 가림 상자. 부모가 준 상자(= 표시 상자)를 기준으로 덮는다.
///
/// 넓힌 만큼 부모 상자 밖으로 그린다 — 그래서 클립하지 않는 [CustomPaint]로 그린다.
class NameRedactionBox extends StatelessWidget {
  const NameRedactionBox({super.key});

  @override
  Widget build(BuildContext context) =>
      const CustomPaint(painter: _RedactionPainter(), child: SizedBox.expand());
}

class _RedactionPainter extends CustomPainter {
  const _RedactionPainter();

  @override
  void paint(Canvas canvas, Size size) =>
      paintNameRedaction(canvas, Offset.zero & size);

  @override
  bool shouldRepaint(_RedactionPainter old) => false;
}
