// 스모크 테스트: 앱이 뜨고 갤러리 화면이 렌더링되는지 확인합니다.
import 'package:flutter_test/flutter_test.dart';

import 'package:jeonse_ai/main.dart';

void main() {
  testWidgets('앱 실행 시 컴포넌트 갤러리가 표시된다 (C-1)', (WidgetTester tester) async {
    await tester.pumpWidget(const JeonseSafeApp());
    await tester.pumpAndSettle();

    expect(find.text('디자인 시스템 갤러리 (예시 데이터)'), findsOneWidget);
  });
}
