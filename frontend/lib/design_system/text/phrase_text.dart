/// 덩어리 사이에서만 줄이 바뀌는 글 — ' · '로 이은 값·제목 (2026-11-01).
///
/// 실기기에서 본 것:
/// - 근거 카드 값 '1,978명과 맞춰봤어요 · 같은 이름 없음'이 좁은 칸에서 `…맞춰봤어요 · 같은` / `이름 없음`으로 갈렸다.
/// - 사진 카드 제목 '이 서류가 전체본인가 (지워진 기록까지 나오는가)'가 `…기록까` / `지 나오는가)`로 갈렸다
///   (덩어리 안 띄어쓰기만 막고 한글 음절 사이는 열어 둬서, 엔진이 음절 사이에서 끊었다).
///
/// 규칙: 덩어리 하나가 **한 줄에 들어가면 통째로 묶고**([glueAll]), 안 들어가면 그 덩어리 안에서만
/// **낱말 사이**로 나눈다([keepAll]). 덩어리 사이(띄어쓰기)는 늘 줄이 바뀔 수 있다. 낱말은 절대 쪼개지 않는다
/// (한 낱말이 한 줄보다 길 때만 엔진이 쪼갠다).
///
/// 폭: [maxWidth]를 주면 그것으로 재고, 안 주면 LayoutBuilder로 잰다.
/// ⚠ IntrinsicHeight 안(사진 아래 카드 줄)에서는 LayoutBuilder를 쓸 수 없다 — 그곳은 꼭 [maxWidth]를 준다.
library;

import 'package:flutter/material.dart';

import 'app_text.dart';
import 'keep_all.dart';

/// 덩어리 하나 — 글과 (있으면) 그 덩어리만의 모양.
class PhraseChunk {
  const PhraseChunk(this.text, [this.style]);

  final String text;
  final TextStyle? style;
}

/// ' · '로 나눈 덩어리들. 점은 앞 덩어리 끝에 붙인다(줄 첫머리에 점이 오지 않게).
List<PhraseChunk> dotChunks(String text, {TextStyle? style}) {
  final parts = text.split(' · ');
  return [
    for (int i = 0; i < parts.length; i++)
      if (parts[i].trim().isNotEmpty) PhraseChunk(i < parts.length - 1 ? '${parts[i]} ·' : parts[i], style),
  ];
}

/// 덩어리들 → 글 조각. 한 줄([maxWidth])에 들어가는 덩어리는 통째로 묶는다.
TextSpan phraseSpan(
  List<PhraseChunk> chunks, {
  required TextStyle base,
  required double maxWidth,
  required TextScaler textScaler,
  TextDirection textDirection = TextDirection.ltr,
}) {
  bool fits(PhraseChunk c) {
    if (!maxWidth.isFinite) return true;
    final tp = TextPainter(
      text: TextSpan(text: c.text, style: base.merge(c.style)),
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w <= maxWidth - 0.5;
  }

  return TextSpan(
    style: base,
    children: [
      for (int i = 0; i < chunks.length; i++) ...[
        if (i > 0) const TextSpan(text: ' '),
        TextSpan(text: fits(chunks[i]) ? glueAll(chunks[i].text) : keepAll(chunks[i].text), style: chunks[i].style),
      ],
    ],
  );
}

/// ' · '로 이은 글을 덩어리 사이에서만 줄 바꿔 그린다. 점이 없거나 `**` 굵게 표시가 있으면 [AppText]와 같다.
class PhraseText extends StatelessWidget {
  const PhraseText(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.maxWidth,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  /// 한 줄의 폭. 없으면 LayoutBuilder로 잰다(IntrinsicHeight 안에서는 꼭 준다).
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    if (!text.contains(' · ') || text.contains('**')) {
      return AppText(text, style: style, textAlign: textAlign, maxLines: maxLines, overflow: overflow);
    }
    Widget paint(double width) {
      final base = DefaultTextStyle.of(context).style.merge(style);
      return Text.rich(
        phraseSpan(
          dotChunks(text),
          base: base,
          maxWidth: width,
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
        ),
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
        semanticsLabel: text,
      );
    }

    if (maxWidth != null) return paint(maxWidth!);
    return LayoutBuilder(builder: (context, c) => paint(c.maxWidth));
  }
}
