/// 표시 제목의 **자연스러운 줄바꿈** (2026-10-31 규혁 — "이 서류가 전체본인가 (지워진 기록까지 / 나오는가)"처럼
/// 아무 데서나 끊기던 것).
///
/// 제목을 줄이지 않는다. 낱말을 쪼개지 않는다. 한 줄에 들어가면 한 줄. 안 들어가면 **덩어리 사이에서만** 줄이 바뀐다.
/// - 덩어리 = ' · '로 나눈 토막, 그리고 토막 끝의 괄호 부분 "(근저당권)"
/// - ' · '는 앞 덩어리 끝에 붙인다(줄 첫머리에 점이 오지 않게)
/// - 괄호 덩어리는 흐린 색
///
/// 덩어리 안의 띄어쓰기는 줄이 안 바뀌는 공백(U+00A0)으로 바꿔 둔다 — 그래서 글자 엔진이 덩어리 사이 공백에서만 줄을 바꾼다.
/// 덩어리 하나가 한 줄보다 길면(드묾) 그 안에서 끊긴다.
library;

import 'package:flutter/material.dart';

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

/// 덩어리 사이에서만 줄이 바뀌는 제목 글자.
TextSpan markTitleSpan(
  String title, {
  required TextStyle style,
  required Color mutedColor,
}) {
  final chunks = markTitleChunks(title);
  return TextSpan(
    style: style,
    children: [
      for (int i = 0; i < chunks.length; i++) ...[
        if (i > 0) const TextSpan(text: ' '),
        TextSpan(
          text: chunks[i].$1.replaceAll(' ', ' '),
          style: chunks[i].$2
              ? TextStyle(color: mutedColor, fontWeight: FontWeight.w700)
              : null,
        ),
      ],
    ],
  );
}

/// 제목 위젯 — [AppText]의 낱말 지킴(keep-all)을 거치지 않고 덩어리 규칙만 쓴다.
class MarkTitle extends StatelessWidget {
  const MarkTitle(
    this.title, {
    super.key,
    required this.style,
    required this.mutedColor,
    this.maxLines,
  });

  final String title;
  final TextStyle style;
  final Color mutedColor;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      markTitleSpan(title, style: style, mutedColor: mutedColor),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      // 화면 읽기 프로그램은 원래 제목 그대로 읽는다
      semanticsLabel: title,
    );
  }
}
