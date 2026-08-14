/// [Text] 대신 쓰는 기본 글자 위젯 — **어절 중간에서 줄이 바뀌지 않는다**.
///
/// 앱의 글자는 전부 한국어라, Flutter 기본 줄바꿈을 그대로 쓰면 좁은 화면에서
/// `…못했어` / `요` 처럼 한 낱말이 두 줄로 쪼개진다(2026-08-12 실기기 확인).
/// 화면마다 고쳐서 될 일이 아니라 **글자를 그리는 지점 한 곳**에서 막는다.
///
/// 쓰는 법은 [Text]와 같다. `Text(...)` 를 `AppText(...)` 로 바꾸기만 하면 된다.
///
/// 접근성: 화면에 그릴 때만 줄바꿈 금지 부호를 끼우고, 스크린 리더에는 [semanticsLabel]로
/// **원문 그대로** 넘긴다. 부호가 읽히는 일이 없다.
///
/// 규칙과 한계는 [keepAll] 참고.
library;

import 'package:flutter/material.dart';

import 'keep_all.dart';

class AppText extends StatelessWidget {
  const AppText(
    String this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : textSpan = null;

  /// [Text.rich]에 해당한다. 조각 경계에 걸친 어절까지 함께 묶는다
  /// (용어 강조처럼 문장 가운데를 스팬으로 쪼갠 경우 — [keepAllSpan] 참고).
  const AppText.rich(
    InlineSpan this.textSpan, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : data = null;

  final String? data;
  final InlineSpan? textSpan;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  @override
  Widget build(BuildContext context) {
    if (textSpan != null) {
      return Text.rich(
        keepAllSpan(textSpan!),
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        locale: locale,
        softWrap: softWrap,
        overflow: overflow,
        textScaler: textScaler,
        maxLines: maxLines,
        semanticsLabel: semanticsLabel,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
    }
    return Text(
      keepAll(data!),
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: locale,
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      // 부호가 낭독되지 않도록 원문을 따로 넘긴다.
      semanticsLabel: semanticsLabel ?? data,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    );
  }
}
