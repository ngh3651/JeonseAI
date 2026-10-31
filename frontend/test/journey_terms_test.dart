/// 여정 할 일 속 어려운 말 = 초록 밑줄 (2026-10-31 인터뷰 반영 — 가계약금 문구 등).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/screens/journey/journey_parts.dart';

import 'support/ko_finders.dart';

void main() {
  test('서버 응답의 풀이를 읽는다 (옛 서버면 빈 값)', () {
    final item = JourneyItem.fromJson({
      'text': '반환 조건 문자로 남기기',
      'why': '"가계약금은 해약금으로 한다"처럼 쓰세요',
      'termGlossary': {'해약금': '계약을 그만두는 대가로 주고받기로 한 돈이에요.'},
    });
    expect(item.termGlossary.keys, ['해약금']);
    expect(JourneyItem.fromJson({'text': 'a', 'why': 'b'}).termGlossary, isEmpty);
  });

  testWidgets('펼치면 어려운 말에 밑줄 — 누르면 뜻', (tester) async {
    const item = JourneyItem(
      text: '반환 조건 문자로 남기기',
      why: '"가계약금은 **해약금**으로 한다"처럼 쓰세요',
      termGlossary: {'가계약금': '정식 계약 전에 먼저 보내는 돈이에요.', '해약금': '계약을 그만두는 대가로 주고받기로 한 돈이에요.'},
    );
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: const Scaffold(body: JourneyItemRow(number: 1, item: item, open: true)),
    ));
    await tester.pumpAndSettle();
    expect(find.koText('가계약금'), findsOneWidget);
    expect(find.koText('해약금'), findsOneWidget);
    await tester.tap(find.koText('해약금'));
    await tester.pumpAndSettle();
    expect(find.koTextContaining('그만두는 대가'), findsOneWidget);
  });
}
