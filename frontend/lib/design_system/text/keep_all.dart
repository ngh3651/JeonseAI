/// 한글 줄바꿈을 **어절 단위**로 묶는다 (CSS `word-break: keep-all`에 해당).
///
/// 왜 필요한가:
///   Flutter는 UAX #14 기본 규칙으로 줄을 나눈다. 그 규칙은 한글 음절 사이를 전부
///   줄바꿈 가능 지점으로 보기 때문에, 좁은 화면에서 **"…못했어 / 요"** 처럼 한 낱말이
///   두 줄로 쪼개진다. 한국어 조판 관행(그리고 웹의 `word-break: keep-all`)은 띄어쓰기
///   에서만 줄을 바꾸는 것이고, Flutter에는 이를 켜는 API가 없다.
///
/// 어떻게 하나:
///   어절 안의 글자 사이마다 **U+2060 WORD JOINER**를 끼운다. UAX #14에서 WJ는
///   앞뒤 줄바꿈을 모두 금지하는 부호(line break class WJ)라, 결과적으로 띄어쓰기
///   에서만 줄이 바뀐다. 폭이 0이라 화면에 보이지 않는다.
///
/// 안전장치 — **긴 어절은 손대지 않는다**:
///   한 줄에 못 들어가는 어절까지 묶어 버리면 줄바꿈 대신 **글자가 잘려 나간다**
///   (overflow). URL·긴 영문처럼 원래 쪼개져야 하는 것들이 여기 해당한다.
///   그래서 [kMaxKeepAllRunes]자 이하만 묶는다. 한국어 어절은 대부분 2~5자다.
library;

import 'package:flutter/painting.dart';

/// 줄바꿈 금지 부호 (U+2060). 폭 0, 화면에 보이지 않는다.
const String wordJoiner = '⁠';

/// 이 길이 이하의 어절만 통째로 묶는다.
///
/// 12자는 가장 좁은 지원 화면(320dp)에서 본문 크기 글자가 한 줄에 들어가는
/// 한계에서 잡았다. 이보다 긴 어절은 묶으면 줄바꿈 대신 잘려 나간다.
const int kMaxKeepAllRunes = 12;

final RegExp _word = RegExp(r'\S+');

/// 이모지·결합 문자가 든 어절은 건드리지 않는다 — 글자 사이에 부호를 끼우면
/// ZWJ 이모지 시퀀스(예: 👩‍👧)가 깨진다.
bool _isFragile(String token) =>
    token.contains('‍') || token.runes.any((r) => r > 0xFFFF);

/// 어절 안에서 줄이 바뀌지 않게 만든 문자열을 돌려준다.
///
/// 줄바꿈(`\n`)·띄어쓰기는 그대로 두므로 문단 구조는 바뀌지 않는다.
/// 이미 처리된 문자열에 다시 적용해도 결과가 같다(멱등).
String keepAll(String text) {
  if (text.isEmpty) return text;
  return text.replaceAllMapped(_word, (m) {
    final token = m[0]!;
    if (token.contains(wordJoiner)) return token; // 이미 처리됨
    if (_isFragile(token)) return token;
    final runes = token.runes.toList();
    if (runes.length < 2 || runes.length > kMaxKeepAllRunes) return token;
    return runes.map(String.fromCharCode).join(wordJoiner);
  });
}

/// [keepAll]이 끼운 부호를 없앤 원문. 비교·검색·복사에 쓴다.
String stripWordJoiner(String text) => text.replaceAll(wordJoiner, '');

// ─────────────────────────────────────────────────────────────────────────────
// 여러 조각(TextSpan)으로 이루어진 글
// ─────────────────────────────────────────────────────────────────────────────

/// 스팬 트리 전체에 [keepAll]을 적용한다.
///
/// 조각마다 따로 처리하는 것으로는 부족하다. 용어 강조처럼 **한 어절이 두 스팬에
/// 걸치는** 경우가 있기 때문이다:
///
/// ```
/// TextSpan('…에서 나온 ') + TextSpan('판례') + TextSpan('를 모았어요.')
/// ```
///
/// '판례를'은 한 어절인데 조각이 나뉘어 있어, 조각 안만 묶으면 `판례` / `를` 로
/// 줄이 갈린다. 그래서 **조각 경계도** 앞이 공백이 아니고 뒤도 공백이 아니면 이어 붙인다.
InlineSpan keepAllSpan(InlineSpan span) => _SpanJoiner().visit(span);

class _SpanJoiner {
  /// 바로 앞에서 내보낸 글자가 공백이 아니었는가 (= 경계를 이어 붙여야 하는가).
  bool _pendingJoin = false;

  InlineSpan visit(InlineSpan span) {
    if (span is! TextSpan) {
      // WidgetSpan 등 글자가 아닌 조각. 여기서는 줄이 바뀌어도 된다.
      _pendingJoin = false;
      return span;
    }

    String? text = span.text;
    if (text != null && text.isNotEmpty) {
      final bridge = _pendingJoin && !_startsWithSpace(text);
      text = (bridge ? wordJoiner : '') + keepAll(text);
      _pendingJoin = !_endsWithSpace(span.text!);
    }

    final children = span.children?.map(visit).toList();

    return TextSpan(
      text: text,
      children: children,
      style: span.style,
      recognizer: span.recognizer,
      mouseCursor: span.mouseCursor,
      onEnter: span.onEnter,
      onExit: span.onExit,
      // 스크린 리더에는 부호가 없는 원문을 넘긴다.
      semanticsLabel: span.semanticsLabel ?? span.text,
      locale: span.locale,
      spellOut: span.spellOut,
    );
  }

  static bool _startsWithSpace(String s) => RegExp(r'^\s').hasMatch(s);
  static bool _endsWithSpace(String s) => RegExp(r'\s$').hasMatch(s);
}
