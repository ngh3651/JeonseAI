/// 카드 캐러셀 · 하단 시트 · 그어짐 애니메이션의 **동작 규칙**.
///
/// 여기서 지키는 것은 두 겹 탭 규칙이다(시안):
/// - 카드 **본문** 탭 → 위치만. 시트는 열리지 않는다.
/// - **`자세히 보기 ›`** 탭 → 같은 이동 + **첫 탭에** 시트.
/// 이 둘이 뒤섞이면 "어디 있는지만 보고 싶은" 사람이 매번 시트에 막힌다.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/screens/report/registry_mark_carousel.dart';
import 'package:jeonse_ai/screens/report/registry_mark_sheet.dart';
import 'package:jeonse_ai/screens/report/registry_viewer_screen.dart';
import 'package:jeonse_ai/state/registry_photo_store.dart';
import 'package:provider/provider.dart';

import 'support/registry_fixture.dart';

void main() {
  late Directory temp;
  late FakeAnalysisRepository repo;

  setUp(() async {
    RegistryPhotoStore.instance.clear();
    temp = await Directory.systemTemp.createTemp('viewer_interaction');
    RegistryPhotoStore.instance.register('r1', await writeFixturePhotos(temp));
    repo = FakeAnalysisRepository(buildFixtureReport());
  });

  tearDown(() async {
    RegistryPhotoStore.instance.clear();
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Future<void> pumpViewer(
    WidgetTester tester, {
    bool reduceMotion = false,
  }) async {
    tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AnalysisRepository>.value(
        value: repo,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reduceMotion),
            child: child!,
          ),
          home: const RegistryViewerScreen(reportId: 'r1'),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// 사진 위에 그리는 페인터 — 선택·그어짐 상태를 여기서 읽는다.
  /// 선택 id와 그어짐 진행도는 모든 쪽이 같은 값을 받으므로 아무 쪽이나 보면 된다.
  HighlightPainter painter(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((w) => w.painter)
      .whereType<HighlightPainter>()
      .first;

  Finder cardTitle(String text) => find.text(text);

  /// 캐러셀은 가로로 넘치므로 뒤쪽 카드는 먼저 화면 안으로 끌어와야 누를 수 있다.
  Future<void> tapCard(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
  }

  group('카드 캐러셀', () {
    testWidgets('표시 하나당 카드 하나 — 제목은 백엔드 문구 그대로', (tester) async {
      await pumpViewer(tester);
      expect(cardTitle('집주인 이름 · 주식회사가나다'), findsOneWidget);
      expect(find.text('집에 잡힌 빚 (근저당권) · 4억원'), findsOneWidget);
      expect(find.text('자세히 보기 ›'), findsNWidgets(4));
    });

    testWidgets('카드 요약은 백엔드 본문의 첫 문장이다 (지어낸 문구가 없다)', (tester) async {
      await pumpViewer(tester);
      expect(
        find.textContaining('집이 경매로 넘어가면, 이 돈을 빌려준 곳이'),
        findsWidgets,
      );
    });

    testWidgets('카드 본문을 누르면 시트가 열리지 않는다', (tester) async {
      await pumpViewer(tester);
      await tapCard(tester, cardTitle('집에 잡힌 빚 (근저당권) · 4억원'));
      await tester.pumpAndSettle();

      expect(find.byType(RegistryMarkSheet), findsNothing);
      // 대신 선택이 그 표시로 옮겨간다
      expect(painter(tester).selectedId, 'mortgage-4');
    });

    testWidgets('자세히 보기를 누르면 첫 탭에 바로 시트가 열린다', (tester) async {
      await pumpViewer(tester);
      await tester.tap(find.text('자세히 보기 ›').first);
      await tester.pumpAndSettle();

      expect(find.byType(RegistryMarkSheet), findsOneWidget);
    });

    // 실기기에서 "카드마다 자세히 보기 위치가 다르다"가 나왔다 — 요약이 1줄인 카드는
    // 링크가 위에, 2줄인 카드는 아래에 있어 눈이 매번 링크를 다시 찾아야 했다.
    testWidgets('요약 줄 수가 달라도 자세히 보기가 같은 높이(카드 바닥)에 온다', (tester) async {
      tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: RegistryMarkCarousel(
                marks: [
                  // 요약 1줄 / 제목 1줄
                  fixtureMark(1, 'owner', 0, 0.1, '짧은 제목').copyForTest('짧아요.'),
                  // 요약 2줄 / 제목 2줄
                  fixtureMark(2, 'mortgage', 0, 0.2, '집에 잡힌 빚 (근저당권) · 5억원'),
                ],
                selectedId: null,
                onTapCard: (_) {},
                onTapDetail: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final links = find.text('자세히 보기 ›');
      expect(links, findsNWidgets(2));
      final a = tester.getRect(links.at(0));
      final b = tester.getRect(links.at(1));
      expect(
        a.top,
        closeTo(b.top, 0.5),
        reason: '카드 높이가 통일되고 링크가 바닥에 붙어야 한다',
      );
      expect(a.bottom, closeTo(b.bottom, 0.5));
    });

    testWidgets('자세히 보기의 터치 영역이 44dp 이상이다', (tester) async {
      await pumpViewer(tester);
      final size = tester.getSize(
        find.ancestor(
          of: find.text('자세히 보기 ›').first,
          matching: find.byType(Container),
        ).first,
      );
      expect(size.height, greaterThanOrEqualTo(44));
    });
  });

  group('하단 시트', () {
    testWidgets('구성은 번호+제목 → 본문 → 출처. 백엔드 문구만 나온다', (tester) async {
      await pumpViewer(tester);
      await tester.tap(find.text('자세히 보기 ›').first);
      await tester.pumpAndSettle();

      expect(find.text('집주인 이름 · 주식회사가나다'), findsWidgets);
      expect(
        find.descendant(
          of: find.byType(RegistryMarkSheet),
          matching: find.textContaining('계약서에 적힌 집주인(임대인) 이름'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('등기부 갑구'), findsOneWidget);
    });

    // 실기기에서 "시트가 잘 안 닫힌다"가 나왔다. 닫는 길이 셋인데 어느 것이 막혔는지
    // 눈으로는 못 가리므로 셋을 각각 못 박는다.
    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.text('자세히 보기 ›').first);
      await tester.pumpAndSettle();
      expect(find.byType(RegistryMarkSheet), findsOneWidget);
    }

    testWidgets('닫기 ① 시트 밖(딤)을 탭하면 닫힌다', (tester) async {
      await pumpViewer(tester);
      await openSheet(tester);

      // 시트 위쪽 빈 공간 = 딤 영역
      await tester.tapAt(const Offset(kPhoneWidth / 2, 40));
      await tester.pumpAndSettle();
      expect(find.byType(RegistryMarkSheet), findsNothing);
    });

    testWidgets('닫기 ② 아래로 드래그하면 닫힌다', (tester) async {
      await pumpViewer(tester);
      await openSheet(tester);

      final sheet = tester.getRect(find.byType(RegistryMarkSheet));
      await tester.drag(
        find.byType(RegistryMarkSheet),
        Offset(0, sheet.height),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RegistryMarkSheet), findsNothing);
    });

    testWidgets('닫기 ③ 시스템 뒤로가기로 닫힌다', (tester) async {
      await pumpViewer(tester);
      await openSheet(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(RegistryMarkSheet), findsNothing);
      // 뷰어까지 같이 닫히면 안 된다 — 시트만 걷힌다
      expect(find.byType(RegistryPositionRail), findsOneWidget);
    });

    testWidgets('"중개사에게 물어볼 질문"은 넣지 않는다 (연결할 데이터가 없다)', (tester) async {
      await pumpViewer(tester);
      await tester.tap(find.text('자세히 보기 ›').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('중개사에게 물어볼 질문'), findsNothing);
    });
  });

  group('형광펜 그어짐', () {
    testWidgets('카드를 누르면 왼→오로 그어진다', (tester) async {
      await pumpViewer(tester);
      expect(painter(tester).drawProgress, 1.0);

      await tapCard(tester, cardTitle('집에 잡힌 빚 (근저당권) · 4억원'));
      await tester.pump(); // 애니메이션 시작
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        painter(tester).drawProgress,
        lessThan(1.0),
        reason: '그어지는 중이어야 한다',
      );

      await tester.pumpAndSettle();
      expect(painter(tester).drawProgress, 1.0);
    });

    testWidgets('같은 카드를 다시 눌러도 다시 재생된다', (tester) async {
      await pumpViewer(tester);
      final card = cardTitle('집에 잡힌 빚 (근저당권) · 4억원');

      await tapCard(tester, card);
      await tester.pumpAndSettle();
      expect(painter(tester).drawProgress, 1.0);

      await tapCard(tester, card);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        painter(tester).drawProgress,
        lessThan(1.0),
        reason: '같은 항목을 다시 탭해도 재생되어야 한다(시안)',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('모션 감소가 켜져 있으면 즉시 표시된다', (tester) async {
      await pumpViewer(tester, reduceMotion: true);

      await tapCard(tester, cardTitle('집에 잡힌 빚 (근저당권) · 4억원'));
      await tester.pump();
      expect(
        painter(tester).drawProgress,
        1.0,
        reason: '모션 감소에서는 그어짐 없이 바로 보여야 한다',
      );
      await tester.pumpAndSettle();
    });
  });

  group('본문 문구 파생 (oneLiner 대체)', () {
    RegistryHighlight mark(String body) => RegistryHighlight(
      id: 'x',
      page: 0,
      kind: 'mortgage',
      badge: 1,
      box: const HighlightBox(x: 0, y: 0, w: 0.1, h: 0.01),
      title: 't',
      body: body,
    );

    test('첫 마침표까지 자른다', () {
      expect(
        mark('집이 경매로 넘어가면 먼저 가져갑니다. 그만큼 못 받을 수 있어요.').summary,
        '집이 경매로 넘어가면 먼저 가져갑니다.',
      );
    });

    test('줄바꿈이 먼저 오면 거기서 자른다', () {
      expect(mark('첫 줄이에요\n둘째 문단.').summary, '첫 줄이에요');
    });

    test('한 문장뿐이면 그대로 쓴다', () {
      expect(mark('한 문장입니다.').summary, '한 문장입니다.');
    });

    test('마침표가 없어도 터지지 않는다', () {
      expect(mark('마침표 없음').summary, '마침표 없음');
    });
  });
}
