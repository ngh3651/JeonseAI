// 스모크 테스트: 앱이 뜨고 홈 대시보드가 렌더링되는지 확인합니다. (C-2)
import 'package:flutter_test/flutter_test.dart';

import 'package:jeonse_ai/main.dart';

void main() {
  testWidgets('앱 실행 시 홈 대시보드가 표시된다', (WidgetTester tester) async {
    await tester.pumpWidget(const JeonseSafeApp());
    await tester.pumpAndSettle();

    // 분석 시작 CTA와 최근 분석 이력(더미 2건 중 최신)이 보여야 한다
    expect(find.text('매물 분석 시작하기'), findsOneWidget);
    expect(find.text('정자동 빌라'), findsOneWidget);
  });

  testWidgets('이력 카드를 탭하면 안전도 리포트가 열린다', (WidgetTester tester) async {
    await tester.pumpWidget(const JeonseSafeApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('정자동 빌라'));
    await tester.pumpAndSettle();

    // 결론 헤더(한 줄 결론)와 근거 섹션이 보여야 한다
    expect(find.text('몇 가지를 확인한 뒤 결정해도 늦지 않아요'), findsOneWidget);
    expect(find.text('근거 살펴보기'), findsOneWidget);
  });
}
