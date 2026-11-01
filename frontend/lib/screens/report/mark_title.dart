/// 표시 제목의 **자연스러운 줄바꿈** (2026-10-31 규혁 — "이 서류가 전체본인가 (지워진 기록까지 / 나오는가)"처럼
/// 아무 데서나 끊기던 것).
///
/// 제목을 줄이지 않는다. 낱말을 쪼개지 않는다. 한 줄에 들어가면 한 줄. 안 들어가면 **덩어리 사이에서만** 줄이 바뀐다.
/// - 덩어리 = ' · '로 나눈 토막, 그리고 토막 끝의 괄호 부분 "(근저당권)"
/// - ' · '는 앞 덩어리 끝에 붙인다(줄 첫머리에 점이 오지 않게)
/// - 괄호 덩어리는 흐린 색
///
/// 덩어리 하나가 한 줄에 들어가면 글자 사이를 전부 묶는다(띄어쓰기·음절 사이 모두). 한 줄보다 길면(드묾) 그 안에서는
/// 낱말 사이로만 나눈다 — 폭을 재서 고른다([phraseSpan], 2026-11-01).
library;

import 'package:flutter/material.dart';

import '../../design_system/text/phrase_text.dart';

/// 제목 → 덩어리들 (글자, 괄호인가).
List<(String, bool)> markTitleChunks(String title) {
  final parts = title.trim().split(' · ');
  final out = <(String, bool)>[];
  final paren = RegExp(r'\s\(([^()]+)\)$');
  for (int i = 0; i < parts.length; i++) {
    final part = parts[i];
    final m = paren.firstMatch(part);
    final chunk = <(String, bool)>[
      if (m != null) ...[
        (part.substring(0, m.start), false),
        ('(${m.group(1)})', true),
      ] else
        (part, false),
    ];
    if (i < parts.length - 1) {
      final (t, p) = chunk.last;
      chunk[chunk.length - 1] = ('$t ·', p);
    }
    out.addAll(chunk.where((c) => c.$1.trim().isNotEmpty));
  }
  return out;
}

/// 덩어리 사이에서만 줄이 바뀌는 제목 글자 — 한 줄에 들어가는 덩어리는 **통째로** 묶는다(2026-11-01).
///
/// 전엔 덩어리 안 띄어쓰기만 줄 안 바뀌는 공백으로 바꿨다. 그런데 엔진은 한글 **음절 사이**에서도 줄을 바꿔
/// `(지워진 기록까` / `지 나오는가)`가 됐다. 이제 덩어리 글자 사이를 전부 묶고([glueAll]), 덩어리가 한 줄보다
/// 길 때만 그 안에서 낱말 사이로 나눈다([phraseSpan]).
TextSpan markTitleSpan(
  String title, {
  required TextStyle style,
  required Color mutedColor,
  required double maxWidth,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final muted = TextStyle(color: mutedColor, fontWeight: FontWeight.w700);
  return phraseSpan(
    [for (final (text, paren) in markTitleChunks(title)) PhraseChunk(text, paren ? muted : null)],
    base: style,
    maxWidth: maxWidth,
    textScaler: textScaler,
  );
}

/// 제목 위젯 — [AppText]의 낱말 지킴(keep-all)을 거치지 않고 덩어리 규칙만 쓴다.
///
/// [maxWidth]: 한 줄 폭. 사진 아래 카드 줄은 IntrinsicHeight 안이라 LayoutBuilder를 못 쓴다 → 카드가 폭을 넘겨준다.
class MarkTitle extends StatelessWidget {
  const MarkTitle(
    this.title, {
    super.key,
    required this.style,
    required this.mutedColor,
    this.maxLines,
    this.maxWidth,
  });

  final String title;
  final TextStyle style;
  final Color mutedColor;
  final int? maxLines;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    Widget paint(double width) => Text.rich(
      markTitleSpan(
        title,
        style: DefaultTextStyle.of(context).style.merge(style),
        mutedColor: mutedColor,
        maxWidth: width,
        textScaler: MediaQuery.textScalerOf(context),
      ),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      // 화면 읽기 프로그램은 원래 제목 그대로 읽는다
      semanticsLabel: title,
    );
    if (maxWidth != null) return paint(maxWidth!);
    return LayoutBuilder(builder: (context, c) => paint(c.maxWidth));
  }
}
