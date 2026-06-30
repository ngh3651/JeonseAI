// 전세AI프 앱 기본 위젯 테스트.

import 'package:flutter_test/flutter_test.dart';

import 'package:jeonse_ai/main.dart';

void main() {
  testWidgets('첫 화면에 타이틀과 버튼이 보인다', (WidgetTester tester) async {
    await tester.pumpWidget(const JeonseAiApp());

    // 앱 타이틀과 주요 버튼이 화면에 있는지 확인합니다.
    expect(find.text('전세AI프'), findsOneWidget);
    expect(find.text('사진 촬영'), findsOneWidget);
    expect(find.text('갤러리에서 선택'), findsOneWidget);
    expect(find.text('분석하기'), findsOneWidget);
  });
}
