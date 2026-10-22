/// '사진 속 이름 가리기' — 켜면 **화면에 실명이 0건**이어야 한다 (NOW.md P0-2 완료 조건).
///
/// 이 기능이 틀리기 쉬운 곳 세 군데를 못 박는다:
/// 1. 덮는 상자가 **진짜로 불투명한가** — 형광펜(곱하기)은 글자가 비친다. 그 버릇대로 그리면
///    "가렸다"고 말해 놓고 이름이 그대로 보인다. 그래서 픽셀을 직접 읽는다.
/// 2. **이름 칸만** 덮는가 — 빚(근저당) 형광펜까지 덮으면 대조 기능이 통째로 사라진다.
/// 3. 스위치(마이 화면) → 저장 → 뷰어·진입 카드가 **같은 값**을 보는가.
library;

import 'dart:io';
import 'dart:typed_data' show ByteData;
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/tokens/app_colors.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/registry_mark_kind.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/screens/my/my_screen.dart';
import 'package:jeonse_ai/screens/report/registry_entry_card.dart';
import 'package:jeonse_ai/screens/report/registry_mark_stripe.dart';
import 'package:jeonse_ai/screens/report/registry_viewer_screen.dart';
import 'package:jeonse_ai/state/privacy_settings.dart';
import 'package:jeonse_ai/state/registry_photo_store.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart';

RegistryHighlight _mark(String kind, {double y = 0.4}) => RegistryHighlight(
  id: '$kind-1',
  page: 0,
  kind: kind,
  badge: 1,
  box: HighlightBox(x: 0.1, y: y, w: 0.8, h: 0.2),
  title: kind,
  body: '본문',
);

/// 흰 종이 위 검은 글자 한 줄(y 45~55%) — 폰트에 기대지 않고 직접 칠한다.
class _PaperPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawRect(
      Rect.fromLTRB(0, size.height * 0.45, size.width, size.height * 0.55),
      Paint()..color = const Color(0xFF000000),
    );
  }

  @override
  bool shouldRepaint(_PaperPainter old) => false;
}

/// 종이 위에 표시 레이어를 얹고 100x100 픽셀을 읽는다.
Future<Color Function(int x, int y)> _render(
  WidgetTester tester,
  List<RegistryHighlight> marks, {
  required bool hideNames,
}) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: 100,
            height: 100,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(painter: _PaperPainter()),
                RegistryHighlightOverlay(highlights: marks, hideNames: hideNames),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  late ByteData pixels;
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    pixels = (await image.toByteData(format: ImageByteFormat.rawRgba))!;
    image.dispose();
  });
  return (x, y) {
    final i = (y * 100 + x) * 4;
    return Color.fromARGB(
      pixels.getUint8(i + 3),
      pixels.getUint8(i),
      pixels.getUint8(i + 1),
      pixels.getUint8(i + 2),
    );
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PrivacySettings.instance.resetForTest();
  });

  tearDown(() => PrivacySettings.instance.resetForTest());

  group('무엇을 가리나 — 이름이 찍힌 칸만', () {
    test('집주인 이름은 가린다', () {
      expect(MarkKind.owner.carriesPersonalName, isTrue);
    });

    test('나머지 종류는 이름 칸이 아니다 (서버가 상자를 순위번호~금액·등기목적에 잡는다)', () {
      for (final kind in MarkKind.values) {
        if (kind == MarkKind.owner) continue;
        expect(kind.carriesPersonalName, isFalse, reason: kind.key);
      }
    });

    test('가림 상자는 표시 상자보다 조금 넓다 — 획 끝이 삐져나오지 않게', () {
      const mark = Rect.fromLTWH(10, 40, 80, 20);
      final cover = redactionRectFor(mark);
      expect(cover.left, lessThan(mark.left));
      expect(cover.top, lessThan(mark.top));
      expect(cover.right, greaterThan(mark.right));
      expect(cover.bottom, greaterThan(mark.bottom));
      // 옆 칸 글자를 덮을 만큼 크지는 않다 (높이의 15%)
      expect(cover.height, closeTo(mark.height * 1.3, 0.001));
    });

    test('가림 색은 완전 불투명이다 (형광펜과 정반대)', () {
      expect(AppColors.markRedaction.a, 1.0);
    });
  });

  group('뷰어 오버레이 — 픽셀로 확인', () {
    testWidgets('켜면 이름 칸이 불투명 상자로 덮인다 — 글자도 종이도 안 보인다', (tester) async {
      final at = await _render(tester, [_mark('owner')], hideNames: true);
      // 글자 자리(y 50)도, 그 옆 흰 종이 자리(y 42)도 전부 가림 색 하나다.
      expect(at(50, 50), AppColors.markRedaction);
      expect(at(50, 42), AppColors.markRedaction);
      expect(at(50, 58), AppColors.markRedaction);
      // 상자 밖은 손대지 않는다
      expect(at(50, 10), const Color(0xFFFFFFFF));
      expect(at(50, 90), const Color(0xFFFFFFFF));
    });

    testWidgets('끄면(기본) 예전 그대로 형광펜 — 이름 글자가 비쳐 대조할 수 있다', (tester) async {
      final at = await _render(tester, [_mark('owner')], hideNames: false);
      final onText = at(50, 50);
      expect(onText.r + onText.g + onText.b, lessThan(0.2), reason: '글자는 그대로 검다');
      expect(at(50, 42), isNot(const Color(0xFFFFFFFF)), reason: '종이는 형광펜 색으로 물든다');
      expect(at(50, 42), isNot(AppColors.markRedaction));
    });

    testWidgets('켜도 빚(근저당) 형광펜은 그대로다 — 이름 칸만 덮는다', (tester) async {
      final at = await _render(tester, [_mark('mortgage')], hideNames: true);
      final onText = at(50, 50);
      expect(onText.r + onText.g + onText.b, lessThan(0.2), reason: '빚 금액은 읽혀야 한다');
      expect(at(50, 42), isNot(AppColors.markRedaction));
      expect(at(50, 42), isNot(const Color(0xFFFFFFFF)));
    });

    testWidgets('그어지는 도중(진행도 0)에도 이름 칸은 처음부터 다 덮여 있다', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 100,
                height: 100,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(painter: _PaperPainter()),
                    RegistryHighlightOverlay(
                      highlights: [_mark('owner')],
                      selectedId: 'owner-1',
                      drawProgress: 0,
                      hideNames: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      late ByteData pixels;
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        pixels = (await image.toByteData(format: ImageByteFormat.rawRgba))!;
        image.dispose();
      });
      Color at(int x, int y) {
        final i = (y * 100 + x) * 4;
        return Color.fromARGB(
          pixels.getUint8(i + 3),
          pixels.getUint8(i),
          pixels.getUint8(i + 1),
          pixels.getUint8(i + 2),
        );
      }

      // 형광펜처럼 왼→오로 그었다면 진행도 0에서는 아직 아무것도 안 칠해졌을 자리들이다.
      // (오른쪽 끝 x 80 이후는 선택 뱃지가 서는 자리라 피한다)
      expect(at(30, 50), AppColors.markRedaction);
      expect(at(65, 50), AppColors.markRedaction);
    });

    test('페인터는 스위치가 바뀌면 다시 그린다', () {
      final marks = [_mark('owner')];
      final off = HighlightPainter(highlights: marks);
      final on = HighlightPainter(highlights: marks, hideNames: true);
      expect(on.shouldRepaint(off), isTrue);
      expect(on.redacts(marks.first), isTrue);
      expect(off.redacts(marks.first), isFalse);
    });
  });

  group('스위치 — 마이 화면 · 저장 · 뷰어가 같은 값을 본다', () {
    testWidgets('기본은 꺼짐, 켜면 hide_names_in_photos_v1에 저장된다', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: PrivacySettingsCard())),
        ),
      );
      expect(find.koText('사진 속 이름 가리기'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);
      // 사진을 어디에 남기는지 — 앱 전체가 쓰는 같은 문장
      expect(find.koText(RegistryPhotoStore.retentionNotice), findsOneWidget);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(PrivacySettings.instance.hideNamesInPhotos, isTrue);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PrivacySettings.hideNamesKey), isTrue);
      expect(PrivacySettings.hideNamesKey, 'hide_names_in_photos_v1');
    });

    test('앱을 다시 켜면 저장된 값으로 시작한다', () async {
      SharedPreferences.setMockInitialValues({PrivacySettings.hideNamesKey: true});
      PrivacySettings.instance.resetForTest();
      expect(PrivacySettings.instance.hideNamesInPhotos, isFalse);
      await PrivacySettings.instance.restore();
      expect(PrivacySettings.instance.hideNamesInPhotos, isTrue);
    });

    group('뷰어 화면', () {
      late Directory temp;
      late FakeAnalysisRepository repo;

      setUp(() async {
        RegistryPhotoStore.instance.clear();
        temp = await Directory.systemTemp.createTemp('privacy_viewer');
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
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ChangeNotifierProvider<AnalysisRepository>.value(
            value: repo,
            child: const MaterialApp(home: RegistryViewerScreen(reportId: 'r1')),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      }

      List<HighlightPainter> painters(WidgetTester tester) => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<HighlightPainter>()
          .toList();

      testWidgets('스위치를 켜면 열려 있는 뷰어의 이름 칸이 바로 가려진다', (tester) async {
        await pumpViewer(tester);
        final before = painters(tester);
        expect(before, isNotEmpty);
        expect(before.every((p) => !p.hideNames), isTrue);

        await PrivacySettings.instance.setHideNamesInPhotos(true);
        await tester.pump();

        final after = painters(tester);
        expect(after, isNotEmpty);
        expect(after.every((p) => p.hideNames), isTrue);
        // 픽스처의 집주인 이름(owner) 표시는 가림 대상, 빚(mortgage)은 아니다
        final marks = buildFixtureReport().highlights;
        final owner = marks.firstWhere((h) => h.kind == 'owner');
        final mortgage = marks.firstWhere((h) => h.kind == 'mortgage');
        expect(after.first.redacts(owner), isTrue);
        expect(after.first.redacts(mortgage), isFalse);
        expect(tester.takeException(), isNull);
      });
    });
  });

  group('리포트 진입 카드 미리보기', () {
    late Directory temp;
    late String photo;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('privacy_card');
      // 크기를 읽을 수 있어야 스트립이 그려진다 — 1x1 PNG
      photo = (File('${temp.path}/page_1.png')..writeAsBytesSync(_onePixelPng)).path;
    });

    tearDown(() async {
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    Future<void> pumpCard(WidgetTester tester, RegistryPreviewSource source) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: RegistryEntryCard(subtitle: null, onTap: () {}, preview: source),
            ),
          ),
        ),
      );
      // 사진 크기 읽기(ImmutableBuffer)는 진짜 비동기 I/O다
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
    }

    testWidgets('켜면 이름 표시의 형광펜 대신 가림 상자를 그린다', (tester) async {
      final owner = _mark('owner');
      final source = RegistryPreviewSource(
        path: photo,
        mark: owner,
        examineCount: 0,
        totalCount: 1,
        pageMarks: [owner],
      );

      await pumpCard(tester, source);
      expect(find.byType(MarkStripe), findsOneWidget);
      expect(find.byType(NameRedactionBox), findsNothing);

      await PrivacySettings.instance.setHideNamesInPhotos(true);
      await tester.pump();
      expect(find.byType(MarkStripe), findsNothing);
      expect(find.byType(NameRedactionBox), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('대표 표시가 빚이어도, 같은 쪽의 이름 칸은 덮는다 (형광펜은 빚에 그대로)', (tester) async {
      final mortgage = _mark('mortgage', y: 0.6);
      final owner = _mark('owner', y: 0.3);
      PrivacySettings.instance.resetForTest(hideNamesInPhotos: true);
      await pumpCard(
        tester,
        RegistryPreviewSource(
          path: photo,
          mark: mortgage,
          examineCount: 1,
          totalCount: 2,
          pageMarks: [owner, mortgage],
        ),
      );
      expect(find.byType(MarkStripe), findsOneWidget);
      expect(find.byType(NameRedactionBox), findsOneWidget);
    });
  });

  group('사진 보관 문구 — 앱 어디서나 같은 사실 하나', () {
    test('서버에는 저장하지 않고, 폰에는 최근 5건만 남는다 (지금 설정 기준)', () {
      expect(RegistryPhotoStore.keepRecentReports, 5);
      expect(RegistryPhotoStore.retentionNotice, contains('서버에는 저장하지 않아요'));
      expect(RegistryPhotoStore.retentionNotice, contains('이 휴대폰에만 최근 분석 5건'));
      // 예전 문구("등기부 사진은 안전을 위해 저장하지 않아요")는 폰 보관과 모순이었다
      expect(RegistryPhotoStore.retentionNotice, isNot(contains('안전을 위해')));
    });
  });
}

/// 1x1 투명 PNG — 크기(1x1)만 읽히면 된다.
final List<int> _onePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];
