// D-3 스모크 테스트.
//
// 1) 더미 저장소를 주입한 흐름 테스트 (서버 없이 화면 흐름 검증)
// 2) 기본 앱(서버 구현 주입) — 위젯 테스트 환경은 실제 HTTP가 차단되므로
//    "서버에 연결할 수 없을 때 홈이 더미로 폴백하지 않고 에러를 보여준다"를 증명한다.
//
// 참고: appRouter가 전역이라 테스트 간 라우터 상태가 이어진다(1번이 홈에서 끝나고
// 2번이 홈에서 시작). 순서를 바꾸면 네비게이션 단계를 함께 옮길 것.
import 'package:flutter_test/flutter_test.dart';

import 'package:jeonse_ai/main.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';

void main() {
  testWidgets('더미 주입: 온보딩 → 시작 → 비회원 시작 → 홈 대시보드 진입', (tester) async {
    await tester.pumpWidget(
      JeonseSafeApp(
        analysisRepository: DummyAnalysisRepository(),
        contentRepository: DummyContentRepository(),
      ),
    );
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

  testWidgets('서버 불능: 홈이 더미로 폴백하지 않고 에러를 보여준다', (tester) async {
    // 기본 주입 = ApiRepository. 위젯 테스트 환경은 HTTP가 차단되어
    // 서버가 꺼진 것과 같은 상태다 → 이력 자리에 에러 + [다시 시도]가 떠야 한다.
    await tester.pumpWidget(const JeonseSafeApp());
    await tester.pumpAndSettle();

    expect(find.text('분석 이력을 불러오지 못했어요'), findsOneWidget);
    expect(find.text('다시 시도'), findsOneWidget);
    // 빈 상태 문구("아직 분석한 매물이 없어요")로 위장하지 않아야 한다
    expect(find.text('아직 분석한 매물이 없어요'), findsNothing);
    // 더미 데이터가 몰래 나오지 않아야 한다
    expect(find.text('정자동 빌라'), findsNothing);
  });
}
