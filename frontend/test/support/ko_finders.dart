/// 어절 줄바꿈 부호를 무시하고 글자를 찾는 파인더.
///
/// 왜 필요한가:
///   [AppText]는 화면에 그릴 때 어절 안에 보이지 않는 U+2060을 끼운다
///   (한글이 낱말 중간에서 줄바뀜하는 것을 막기 위함 — `keep_all.dart` 참고).
///   그래서 `find.text('보증금을 지키기 어려웠어요')`는 실제 위젯의 문자열과
///   글자 단위로 달라 찾지 못한다. **화면에 보이는 글자는 똑같은데** 못 찾는 것이라,
///   테스트는 부호를 걷어내고 비교해야 한다.
///
/// 쓰는 법: `find.text(...)` → `find.koText(...)`,
///          `find.textContaining(...)` → `find.koTextContaining(...)`
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeonse_ai/design_system/text/keep_all.dart';

/// 위젯이 실제로 그리는 글자 (없으면 null).
String? renderedText(Widget widget) {
  if (widget is Text) return widget.data ?? widget.textSpan?.toPlainText();
  if (widget is EditableText) return widget.controller.text;
  return null;
}

extension KoFinders on CommonFinders {
  /// [find.text]와 같되, 어절 줄바꿈 부호를 무시한다.
  Finder koText(String text, {bool skipOffstage = true}) => byWidgetPredicate(
    (w) {
      final s = renderedText(w);
      return s != null && stripWordJoiner(s) == text;
    },
    description: 'text "$text" (어절 줄바꿈 부호 무시)',
    skipOffstage: skipOffstage,
  );

  /// [find.textContaining]과 같되, 어절 줄바꿈 부호를 무시한다.
  Finder koTextContaining(Pattern pattern, {bool skipOffstage = true}) =>
      byWidgetPredicate(
        (w) {
          final s = renderedText(w);
          if (s == null) return false;
          return stripWordJoiner(s).contains(pattern);
        },
        description: 'text containing $pattern (어절 줄바꿈 부호 무시)',
        skipOffstage: skipOffstage,
      );
}
