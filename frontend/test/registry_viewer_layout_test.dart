/// 사진 뷰어의 **세로 예산** — 하단 크롬이 문서 영역을 얼마나 먹는가.
///
/// 왜 테스트로 재는가:
/// 하단이 네 겹(위치 레일 · 범례 · 표시 못 한 것 한 줄 · 카드 캐러셀)이라, 어느 하나에
/// 한 줄만 늘어도 문서 영역이 조용히 줄어든다. 등기부 한 쪽이 화면에 들어오지 못하면
/// "종이와 대조한다"는 이 화면의 목적 자체가 흔들리므로, **숫자로 못 박아 둔다.**
///
/// 이 테스트가 깨지면 하단에 무언가 늘어난 것이다. 상한을 올리기 전에
/// 무엇을 줄일 수 있는지 먼저 본다.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/screens/report/registry_mark_carousel.dart';
import 'package:jeonse_ai/screens/report/registry_viewer_screen.dart';
import 'package:jeonse_ai/state/registry_photo_store.dart';
import 'package:provider/provider.dart';

import 'support/registry_fixture.dart';

/// 문서 영역 하한 — 이보다 좁아지면 등기부 한 쪽(폭 344dp × 종횡비 ≈ 504dp)의
/// 8할도 못 보여 준다. 그 아래로 내려가면 캐러셀을 접는 안을 꺼내야 한다.
const double kMinDocumentHeight = 400;

void main() {
  late Directory temp;
  late FakeAnalysisRepository repo;

  setUp(() async {
    RegistryPhotoStore.instance.clear();
    temp = await Directory.systemTemp.createTemp('viewer_layout');
    RegistryPhotoStore.instance.register('r1', await writeFixturePhotos(temp));
    repo = FakeAnalysisRepository(buildFixtureReport());
  });

  tearDown(() async {
    RegistryPhotoStore.instance.clear();
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Future<void> pumpViewer(WidgetTester tester) async {
    tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(
      top: kStatusBar * 3,
      bottom: kGestureBar * 3,
    );
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AnalysisRepository>.value(
        value: repo,
        child: const MaterialApp(home: RegistryViewerScreen(reportId: 'r1')),
      ),
    );
    // 사진 크기 읽기(ImmutableBuffer)와 이미지 디코딩은 **진짜 비동기 I/O**라
    // 위젯 테스트의 가짜 시계로는 끝나지 않는다. 실제 시간을 잠깐 흘려 보낸다.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('360dp에서 문서 영역에 남는 높이를 잰다', (tester) async {
    await pumpViewer(tester);

    final rail = tester.getSize(find.byType(RegistryPositionRail));
    final carousel = tester.getSize(find.byType(RegistryMarkCarousel));
    final document = tester.getSize(
      find.ancestor(
        of: find.byType(ListView).first,
        matching: find.byType(Expanded),
      ),
    );

    // 측정값을 로그로 남긴다 — 하단을 손볼 때 이 줄을 근거로 쓴다.
    debugPrint(
      '[뷰어 세로 예산] 화면 ${kPhoneHeight}dp / 상태바 $kStatusBar / 앱바 47'
      ' / 문서 ${document.height.toStringAsFixed(1)}'
      ' / 레일 ${rail.height.toStringAsFixed(1)}'
      ' / 캐러셀 ${carousel.height.toStringAsFixed(1)}'
      ' / 제스처바 $kGestureBar',
    );

    expect(
      document.height,
      greaterThanOrEqualTo(kMinDocumentHeight),
      reason:
          '하단 크롬이 커져 문서가 ${document.height.toStringAsFixed(0)}dp로 줄었다. '
          '한 쪽(≈504dp)의 8할도 못 보여 준다 — 캐러셀 접기 안을 꺼낼 때다.',
    );
  });

  testWidgets('네 겹이 전부 살아 있다 (어느 것도 조용히 사라지지 않았다)', (tester) async {
    await pumpViewer(tester);

    expect(find.byType(RegistryPositionRail), findsOneWidget);
    expect(find.byType(RegistryMarkCarousel), findsOneWidget);
    // 범례 — 색상만 다르고 형태가 같은 두 표시의 유일한 구분 단서다
    expect(find.text('이름처럼 대조할 곳'), findsOneWidget);
    expect(find.text('빚처럼 따져볼 곳'), findsOneWidget);
    // 회색 한 줄 — 리포트엔 근저당 4건인데 카드가 3장인 이유를 대는 자리
    expect(find.textContaining('말소'), findsOneWidget);
  });

  testWidgets('앱바 제목은 매물 별칭이다 (캡처해 보냈을 때 무슨 집인지 알 수 있게)', (tester) async {
    await pumpViewer(tester);
    expect(find.text('샘플빌라 제101호'), findsOneWidget);
    expect(find.text('내가 올린 사진에서 보기'), findsNothing);
  });

  testWidgets('디버그 토글은 남아 있지 않다 (실기기 확인 후 제거)', (tester) async {
    await pumpViewer(tester);
    expect(find.byIcon(Icons.bug_report), findsNothing);
    expect(find.byIcon(Icons.bug_report_outlined), findsNothing);
  });
}
