/// 한글 어절 단위 줄바꿈이 **실제로 동작하는지**를 재는 테스트.
///
/// 여기서 문자열 변환만 확인하면 의미가 없다. 핵심 질문은 "U+2060을 끼우면
/// Flutter의 줄바꿈 엔진이 정말 그 자리를 피하는가"이고, 그건 [TextPainter]로
/// **직접 줄을 나눠 봐야** 알 수 있다. 그래서 이 테스트는 문자열이 아니라
/// **레이아웃 결과**를 본다.
///
/// 테스트 환경의 기본 폰트는 모든 글자 폭이 같아(FlutterTest) 계산이 결정적이다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeonse_ai/design_system/text/keep_all.dart';

const _style = TextStyle(fontSize: 20);

/// [text]를 [width] 안에서 줄바꿈했을 때 실제로 나뉜 줄들.
List<String> layoutLines(String text, double width) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: _style),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width);

  final lines = <String>[];
  var offset = 0;
  while (offset < text.length) {
    final range = tp.getLineBoundary(TextPosition(offset: offset));
    if (range.end <= offset) break;
    lines.add(text.substring(range.start, range.end));
    offset = range.end;
  }
  return lines;
}

/// 줄들이 전부 **온전한 어절**로만 이루어졌는가.
bool breaksOnlyAtSpaces(List<String> lines, String original) {
  final words = stripWordJoiner(original).split(RegExp(r'\s+')).toSet();
  for (final line in lines) {
    final pieces = stripWordJoiner(line).trim().split(RegExp(r'\s+'));
    for (final p in pieces) {
      if (p.isEmpty) continue;
      if (!words.contains(p)) return false; // 어절이 잘렸다
    }
  }
  return true;
}

void main() {
  // 화면에서 실제로 문제가 났던 문장 (판례 카드 '결과' 줄)
  const sentence = '후순위 임차인은 낙찰자에게 임차권을 주장하지 못했어요';

  group('줄바꿈 엔진이 U+2060을 존중하는가', () {
    test('그냥 두면 어절 중간에서 잘린다 — 이게 고치려는 증상이다', () {
      final lines = layoutLines(sentence, 150);

      expect(lines.length, greaterThan(1), reason: '줄이 안 나뉘면 테스트가 무의미해요');
      expect(
        breaksOnlyAtSpaces(lines, sentence),
        isFalse,
        reason: '증상이 재현되지 않으면 이 수정은 필요 없는 것입니다',
      );
    });

    test('keepAll을 적용하면 띄어쓰기에서만 줄이 바뀐다', () {
      final joined = keepAll(sentence);
      final lines = layoutLines(joined, 150);

      expect(lines.length, greaterThan(1));
      expect(breaksOnlyAtSpaces(lines, sentence), isTrue);
    });

    test('여러 폭에서 모두 어절이 보존된다', () {
      final joined = keepAll(sentence);
      for (final width in [120.0, 150.0, 200.0, 260.0, 320.0]) {
        expect(
          breaksOnlyAtSpaces(layoutLines(joined, width), sentence),
          isTrue,
          reason: '폭 $width 에서 어절이 잘렸어요',
        );
      }
    });
  });

  group('문자열 변환 규칙', () {
    test('보이는 글자는 그대로다 — 부호를 빼면 원문과 같다', () {
      expect(stripWordJoiner(keepAll(sentence)), sentence);
    });

    test('줄바꿈과 띄어쓰기는 보존된다 — 문단 구조가 바뀌면 안 된다', () {
      const multi = '첫째 줄이에요\n둘째 줄이에요';

      expect(stripWordJoiner(keepAll(multi)), multi);
      expect(keepAll(multi).contains('\n'), isTrue);
    });

    test('긴 어절은 묶지 않는다 — 묶으면 줄바꿈 대신 글자가 잘려 나간다', () {
      const url = 'https://www.law.go.kr/LSW/precInfoP.do?precSeq=228474';

      expect(keepAll(url), url);
    });

    test('한 글자짜리는 묶을 것이 없다', () {
      expect(keepAll('가'), '가');
    });

    test('빈 문자열·공백만 있어도 터지지 않는다', () {
      expect(keepAll(''), '');
      expect(keepAll('   '), '   ');
    });

    test('두 번 적용해도 결과가 같다 (멱등)', () {
      final once = keepAll(sentence);

      expect(keepAll(once), once);
    });

    test('사건번호처럼 쪼개지면 안 되는 것도 함께 보호된다', () {
      // '2022다212594'가 '2022다21 / 2594'로 잘리면 출처 확인이 어려워진다
      const caseNo = '대법원 2022다212594';
      final lines = layoutLines(keepAll(caseNo), 240);

      expect(breaksOnlyAtSpaces(lines, caseNo), isTrue);
    });

    test('어절이 한 줄에 아예 못 들어가면 넘치지 않고 쪼갠다 — 잘림 사고를 막는 안전망', () {
      // U+2060은 "가능하면 붙여 달라"이지 "무조건 붙여라"가 아니다. 한 줄보다 긴
      // 어절은 Flutter가 그냥 쪼개므로, 묶어 놨다고 글자가 화면 밖으로 밀려나지
      // 않는다. kMaxKeepAllRunes 안전장치가 뚫려도 잘림 사고는 안 난다는 뜻이다.
      const caseNo = '대법원 2022다212594';
      final lines = layoutLines(keepAll(caseNo), 130);

      expect(lines.length, greaterThan(2), reason: '좁으면 어절 안에서도 쪼개져야 해요');
      for (final line in lines) {
        expect(stripWordJoiner(line).trim().length, lessThanOrEqualTo(7));
      }
    });

    test('이모지가 든 어절은 건드리지 않는다 — 부호를 끼우면 깨진다', () {
      const emoji = '👩‍👧 가족';

      expect(keepAll(emoji).startsWith('👩‍👧'), isTrue);
    });
  });

  group('조각(TextSpan)으로 나뉜 글', () {
    /// 용어 강조 때문에 한 어절이 두 조각에 걸친 경우.
    /// '판례를'은 한 낱말인데 '판례'만 따로 스팬으로 떼어져 있다.
    TextSpan built() => const TextSpan(
      children: [
        TextSpan(text: '이 매물의 위험과 비슷한 상황에서 나온 '),
        TextSpan(text: '판례'),
        TextSpan(text: '를 모았어요.'),
      ],
    );

    /// 화면에 실제로 그려지는 글자. `toPlainText()` 기본값은 semanticsLabel이
    /// 있으면 그걸 대신 돌려주므로(스크린 리더용 원문), 여기서는 꺼야 한다.
    String rendered(InlineSpan span) =>
        span.toPlainText(includeSemanticsLabels: false);

    test('조각 경계에 걸친 어절도 이어 붙인다', () {
      final joined = rendered(keepAllSpan(built()));

      // 조각 경계('례' | '를')에 줄바꿈 금지 부호가 들어가야 한다.
      // ('판'과 '례' 사이는 keepAll이 이미 채웠으므로 여기서 보는 것은 경계뿐이다)
      expect(joined.contains('례$wordJoiner를'), isTrue);
    });

    test('조각 경계가 띄어쓰기면 그대로 둔다 — 거기서는 줄이 바뀌어도 된다', () {
      const span = TextSpan(
        children: [TextSpan(text: '앞 조각 '), TextSpan(text: '뒤 조각')],
      );

      expect(rendered(keepAllSpan(span)).contains(' $wordJoiner'), isFalse);
    });

    test('보이는 글자는 그대로다', () {
      expect(
        stripWordJoiner(rendered(keepAllSpan(built()))),
        '이 매물의 위험과 비슷한 상황에서 나온 판례를 모았어요.',
      );
    });

    test('스크린 리더에는 부호 없는 원문이 간다', () {
      // 부호가 낭독되면 안 된다. semanticsLabel은 손대지 않은 원문이어야 한다.
      expect(
        keepAllSpan(built()).toPlainText(),
        '이 매물의 위험과 비슷한 상황에서 나온 판례를 모았어요.',
      );
    });

    test('조각으로 나뉘어도 어절 중간에서 줄이 바뀌지 않는다', () {
      final original = rendered(built());
      final painter = TextPainter(
        text: TextSpan(style: _style, children: [keepAllSpan(built())]),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 200);

      final plain = rendered(painter.text!);
      final lines = <String>[];
      var offset = 0;
      while (offset < plain.length) {
        final r = painter.getLineBoundary(TextPosition(offset: offset));
        if (r.end <= offset) break;
        lines.add(plain.substring(r.start, r.end));
        offset = r.end;
      }

      expect(lines.length, greaterThan(1));
      expect(breaksOnlyAtSpaces(lines, original), isTrue);
    });
  });
}
