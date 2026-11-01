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

// ─────────────────────────────────────────────────────────────────────────────
// `**굵게**` 표시 (2026-11-01)
// ─────────────────────────────────────────────────────────────────────────────
//
// 서버·데이터 글자에는 `**…**`가 들어 있을 수 있다(할 일·자세히 보기 표·AI 글). 그런데 굵게를 그리는 곳이
// 화면마다 따로였다(caseRichText·boldMarkup …). 그 밖의 자리로 가면 **별표가 그대로 보였다**
// (2026-11-01 실기기: 자세히 보기 '뜻 · 지워진 옛 기록까지 다 나온 **전체본**이에요').
// 그래서 글자를 그리는 한 곳(AppText)에서 막는다: 짝이 맞으면 굵게, 짝 없는 `**`는 지운다.
// `*******`(가린 주민번호 같은 별 여러 개)는 건드리지 않는다.

final RegExp _boldPair = RegExp(r'\*\*(?=[^\s*])(.+?)(?<=[^\s*])\*\*');
final RegExp _strayStars = RegExp(r'(?<!\*)\*\*(?!\*)');

/// `**` 표시를 뺀 원문 — 스크린 리더·복사·비교에 쓴다.
String stripBoldMarkup(String text) =>
    text.replaceAllMapped(_boldPair, (m) => m[1]!).replaceAll(_strayStars, '');

/// 글 속 `**…**`를 굵은 조각으로. 표시가 없으면 null(그대로 그린다).
TextSpan? boldMarkupSpan(String text, {required TextStyle bold}) {
  if (!text.contains('**')) return null;
  final children = <InlineSpan>[];
  int at = 0;
  for (final m in _boldPair.allMatches(text)) {
    if (m.start > at) children.add(TextSpan(text: text.substring(at, m.start).replaceAll(_strayStars, '')));
    children.add(TextSpan(text: m[1], style: bold));
    at = m.end;
  }
  if (at < text.length) children.add(TextSpan(text: text.substring(at).replaceAll(_strayStars, '')));
  return TextSpan(children: children);
}

/// 굵게 칠할 무게 — 이미 굵은 글(700 이상)이면 한 단계 더(800).
FontWeight _boldWeightFor(BuildContext context, TextStyle? style) {
  final w = DefaultTextStyle.of(context).style.merge(style).fontWeight ?? FontWeight.w400;
  return w.value >= 700 ? FontWeight.w800 : FontWeight.w700;
}

/// 스팬 트리 안의 글자 조각에서도 `**`를 굵게로 바꾼다.
InlineSpan _boldInTree(InlineSpan span, TextStyle bold) {
  if (span is! TextSpan) return span;
  final t = span.text;
  final parsed = t == null ? null : boldMarkupSpan(t, bold: bold);
  final kids = span.children?.map((c) => _boldInTree(c, bold)).toList();
  final kidsChanged = kids != null && [for (int i = 0; i < kids.length; i++) !identical(kids[i], span.children![i])].any((x) => x);
  if (parsed == null && !kidsChanged) return span;
  return TextSpan(
    style: span.style,
    recognizer: span.recognizer,
    mouseCursor: span.mouseCursor,
    onEnter: span.onEnter,
    onExit: span.onExit,
    // 부모에 semanticsLabel을 달면 toPlainText가 자식 글과 겹쳐 두 번 읽는다 — 자식 글(별표 없음)이 곧 원문이다
    semanticsLabel: span.semanticsLabel,
    locale: span.locale,
    spellOut: span.spellOut,
    text: parsed == null ? t : null,
    children: [
      ...?parsed?.children,
      ...?kids,
    ],
  );
}

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
    final boldStyle = TextStyle(fontWeight: _boldWeightFor(context, style));
    if (textSpan != null) {
      return Text.rich(
        keepAllSpan(_boldInTree(textSpan!, boldStyle)),
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
    final marked = boldMarkupSpan(data!, bold: boldStyle);
    if (marked != null) {
      return Text.rich(
        keepAllSpan(marked),
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        locale: locale,
        softWrap: softWrap,
        overflow: overflow,
        textScaler: textScaler,
        maxLines: maxLines,
        semanticsLabel: semanticsLabel ?? stripBoldMarkup(data!),
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
