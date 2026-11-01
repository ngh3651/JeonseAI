/// 줄바꿈·굵게 표시 — 2026-11-01 실기기에서 본 네 가지가 다시 안 생기게 (규혁 사진 1~4).
///
/// ① 사진 카드 제목 '이 서류가 전체본인가 (지워진 기록까지 나오는가)'가 `…기록까` / `지 나오는가)`로
/// ② 자세히 보기 '뜻 · 지워진 옛 기록까지 다 나온 **전체본**이에요' — 별표가 그대로
/// ③ 근거 카드 값 '1,978명과 맞춰봤어요 · 같은 이름 없음'이 `…맞춰봤어요 · 같은` / `이름 없음`으로
/// ④ 근거 카드 이름 '신탁·압류·가압류·가처분·경매'가 `…가처분·경` / `매`로
///
/// 문자열이 아니라 **실제로 나눠진 줄**을 본다(TextPainter). 테스트 글꼴은 모든 글자 폭이 같아 결정적이다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeonse_ai/design_system/text/app_text.dart';
import 'package:jeonse_ai/design_system/text/keep_all.dart';
import 'package:jeonse_ai/design_system/text/phrase_text.dart';
import 'package:jeonse_ai/screens/cases/case_card.dart';
import 'package:jeonse_ai/screens/report/mark_title.dart';

const _style = TextStyle(fontSize: 20);

/// 실제로 나뉜 줄 (줄바꿈 부호는 빼고, 앞뒤 공백 지움)
List<String> linesOf(InlineSpan span, double width) {
  final tp = TextPainter(
    text: TextSpan(style: _style, children: [span]),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width);
  final plain = tp.plainText;
  final out = <String>[];
  var offset = 0;
  while (offset < plain.length) {
    final r = tp.getLineBoundary(TextPosition(offset: offset));
    if (r.end <= offset) break;
    out.add(stripWordJoiner(plain.substring(r.start, r.end)).trim());
    offset = r.end;
  }
  return out;
}

void main() {
  group('① 제목 덩어리', () {
    const title = '이 서류가 전체본인가 (지워진 기록까지 나오는가)';

    test('한 줄에 안 들어가면 괄호 앞에서만 줄이 바뀐다 — 덩어리 안 음절 사이에서 끊기지 않는다', () {
      for (final width in [360.0, 400.0, 460.0]) {
        final span = markTitleSpan(title, style: _style, mutedColor: Colors.grey, maxWidth: width);
        expect(linesOf(span, width), ['이 서류가 전체본인가', '(지워진 기록까지 나오는가)'], reason: '폭 $width');
      }
    });

    test('다 들어가면 한 줄', () {
      final span = markTitleSpan(title, style: _style, mutedColor: Colors.grey, maxWidth: 2000);
      expect(linesOf(span, 2000), [title]);
    });

    test('덩어리 하나가 한 줄보다 길면 그 안에서는 낱말 사이로만 나뉜다', () {
      const long = '집에 잡힌 빚 (지워진 기록까지 모두 나오는 전체본인가)';
      final span = markTitleSpan(long, style: _style, mutedColor: Colors.grey, maxWidth: 200);
      final words = stripWordJoiner(long).split(' ').toSet();
      for (final line in linesOf(span, 200)) {
        for (final w in line.split(' ')) {
          expect(words.contains(w), isTrue, reason: '낱말이 잘렸어요: "$line"');
        }
      }
    });

    testWidgets('사진 카드 줄(IntrinsicHeight) 안에서도 폭을 넘겨받아 그린다', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 300,
                    child: MarkTitle(title, style: _style, mutedColor: Colors.grey, maxWidth: 300, maxLines: 2),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('② 별표(**)', () {
    testWidgets('AppText는 짝이 맞는 **…**를 굵게 그리고 별표를 보이지 않는다', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: AppText('지워진 옛 기록까지 다 나온 **전체본**이에요'))),
      );
      final rich = tester.widget<RichText>(find.byType(RichText).first);
      final shown = stripWordJoiner(rich.text.toPlainText(includeSemanticsLabels: false));
      expect(shown, '지워진 옛 기록까지 다 나온 전체본이에요');
      expect(shown.contains('*'), isFalse);
      bool boldFound = false;
      rich.text.visitChildren((s) {
        if (s is TextSpan && (s.text ?? '').contains('전') && s.style?.fontWeight == FontWeight.w700) boldFound = true;
        return true;
      });
      expect(boldFound, isTrue);
    });

    testWidgets('짝 없는 **는 지우고, 가린 번호(*******)는 그대로 둔다', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Column(children: [AppText('**머리말만 열림 본문'), AppText('110111-*******')])),
        ),
      );
      final texts = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((r) => stripWordJoiner(r.text.toPlainText(includeSemanticsLabels: false)))
          .toList();
      expect(texts.first, '머리말만 열림 본문');
      expect(texts.last, '110111-*******');
    });

    test('스팬으로 나뉜 글 속 ** 도 굵게', () {
      expect(stripBoldMarkup('**가** 나 **다**'), '가 나 다');
    });
  });

  group('③ 값 덩어리 (' ' · ' ')', () {
    const value = '1,978명과 맞춰봤어요 · 같은 이름 없음';

    test('좁은 칸에서도 "같은 이름 없음"은 한 줄로 붙어 있다', () {
      // 덩어리('같은 이름 없음' = 8자 · 160)가 한 줄에 들어가는 폭부터 — 그보다 좁으면 낱말 사이로 나뉘는 게 맞다
      for (final width in [170.0, 200.0, 240.0, 300.0]) {
        final span = phraseSpan(dotChunks(value), base: _style, maxWidth: width, textScaler: TextScaler.noScaling);
        final lines = linesOf(span, width);
        expect(lines.any((l) => l.endsWith('같은')), isFalse, reason: '폭 $width: $lines');
        expect(lines.any((l) => l.contains('같은 이름 없음')), isTrue, reason: '폭 $width: $lines');
      }
    });

    testWidgets('PhraseText는 폭을 재서 그린다(LayoutBuilder)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SizedBox(width: 160, child: PhraseText(value, style: _style))),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(LayoutBuilder), findsWidgets);
    });
  });

  group('④ 긴 낱말 · 용어 밑줄', () {
    test('가운뎃점으로 이은 긴 낱말은 점 뒤에서만 줄이 바뀐다', () {
      const label = '신탁·압류·가압류·가처분·경매';
      for (final width in [120.0, 200.0, 260.0]) {
        final lines = linesOf(TextSpan(text: keepAll(label)), width);
        final pieces = {'신탁·', '압류·', '가압류·', '가처분·', '경매'};
        for (final line in lines) {
          // 한 줄 = 온전한 토막들의 이어 붙임
          var rest = line;
          while (rest.isNotEmpty) {
            final p = pieces.firstWhere((x) => rest.startsWith(x), orElse: () => '');
            expect(p, isNotEmpty, reason: '폭 $width에서 낱말이 잘렸어요: $lines');
            rest = rest.substring(p.length);
          }
        }
      }
    });

    test('용어 밑줄 칸은 바로 앞 여는 괄호와 바로 뒤 토씨를 함께 싣는다 — 그 사이에서 줄이 안 바뀌게', () {
      const body = '빚(선순위 채권)이 있고 근저당이에요. 또 근저당권자들에게 아주길게이어지는낱말이에요';
      int at(String t) => body.indexOf(t);
      expect(termNeighbors(body, at('선순위 채권'), at('선순위 채권') + 6), ('빚(', ')이'));
      expect(termNeighbors(body, at('근저당'), at('근저당') + 3), ('', '이에요.'));
      // 뒤 낱말이 너무 길면(8자 넘게) 싣지 않는다 — 칸이 한 줄보다 커지지 않게
      final long = at('아주길게');
      expect(termNeighbors(body, long, long + 2), ('', ''));
      // 굵게 칠할 글자는 싣지 않는다(굵기가 사라진다)
      final bold = List<bool>.filled(body.length, false);
      for (int k = at('근저당') + 3; k < at('근저당') + 6; k++) {
        bold[k] = true;
      }
      expect(termNeighbors(body, at('근저당'), at('근저당') + 3, bold: bold), ('', ''));
    });

    testWidgets('용어 칸 안에 토씨가 함께 그려진다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => AppText.rich(
                caseRichText(context, text: '이 집은 근저당이에요', base: _style, glossary: const {'근저당': '집을 담보로 빌린 돈'}),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(Row), findsOneWidget);
    });
  });
}
