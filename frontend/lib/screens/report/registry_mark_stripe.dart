/// 형광펜 한 줄을 그리는 공통 부품 — 사진 뷰어와 리포트 진입 카드가 함께 쓴다.
///
/// 두 화면이 같은 모양이어야 하는 이유: 진입 카드의 미리보기 스트립은 "뷰어에 들어가면
/// 이런 게 보인다"는 약속이다. 모서리나 색이 다르면 그 약속이 어긋난다.
///
/// **곱하기(multiply)로 겹친다.** 불투명하게 칠하면 정작 그 글자를 못 읽는 최악이 된다 —
/// 글자가 비쳐 보여야 사용자가 종이와 화면을 대조할 수 있다.
library;

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
