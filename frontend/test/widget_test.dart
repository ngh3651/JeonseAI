// 스모크 테스트: 온보딩 → 시작 → 비회원 시작 → 홈까지 진입 흐름을 확인합니다. (C-3)
// 참고: appRouter가 전역이라 테스트를 하나의 흐름으로 둔다(테스트 간 라우터 상태 공유 방지).
import 'package:flutter_test/flutter_test.dart';

import 'package:jeonse_ai/main.dart';

void main() {
  testWidgets('온보딩 → 시작 → 비회원 시작 → 홈 대시보드 진입', (tester) async {
    await tester.pumpWidget(const JeonseSafeApp());
    await tester.pumpAndSettle();

    // 온보딩 첫 장
    expect(find.text('전세 계약, 도장 찍기 전에'), findsOneWidget);

    // 건너뛰기 → 시작(S-02)
    await tester.tap(find.text('건너뛰기'));
    await tester.pumpAndSettle();
    expect(find.text('비회원으로 시작하기'), findsOneWidget);

    // 비회원 시작 → 홈
    await tester.tap(find.text('비회원으로 시작하기'));
    await tester.pumpAndSettle();
    expect(find.text('매물 분석 시작하기'), findsWidgets);
    // 더미 이력 2건 중 최신
    expect(find.text('정자동 빌라'), findsOneWidget);
  });
}
