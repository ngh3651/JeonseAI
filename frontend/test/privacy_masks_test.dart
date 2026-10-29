/// '사진 속 이름 가리기' 2단계 — 서버가 보낸 **실명·주민번호 자리 전부**를 덮는다 (P0-2b, 2026-10-22).
///
/// PR #4는 집주인 이름 하이라이트만 덮었다. 이제 서버가 채무자·이전 소유자·권리자 이름과 주민번호의
/// 위치를 `privacyMasks`로 보낸다(api-contract §9.8). 여기서 못 박는 것:
/// 1. 그 상자가 **진짜로 불투명하게** 덮인다 (픽셀로 확인)
/// 2. 스위치를 끄면 아무것도 안 덮는다 (내 등기부 대조 기능은 그대로)
/// 3. 위치를 모르는 쪽(옛 기록·OCR 실패)은 **통째로** 덮고, 왜 덮었는지 말한다
/// 4. 진입 카드 미리보기에도 같은 규칙
/// 5. 스위치 설명이 실제 범위와 같다
library;

import 'dart:io';
import 'dart:typed_data' show ByteData;
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/tokens/app_colors.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/screens/my/my_screen.dart';
import 'package:jeonse_ai/screens/my/privacy_policy_screen.dart';
import 'package:jeonse_ai/screens/report/registry_entry_card.dart';
import 'package:jeonse_ai/screens/report/registry_mark_stripe.dart';
import 'package:jeonse_ai/screens/report/registry_viewer_screen.dart';
import 'package:jeonse_ai/state/privacy_settings.dart';
import 'package:jeonse_ai/state/registry_photo_store.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart';

const HighlightBox _nameRow = HighlightBox(x: 0.1, y: 0.4, w: 0.8, h: 0.2);

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
  WidgetTester tester, {
  List<RegistryHighlight> marks = const [],
  List<HighlightBox> privacyBoxes = const [],
  bool coverWholePage = false,
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
                RegistryHighlightOverlay(
                  highlights: marks,
                  hideNames: hideNames,
                  privacyBoxes: privacyBoxes,
                  coverWholePage: coverWholePage,
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

AnalysisReport _report({
  required bool ready,
  List<PrivacyMask> masks = const [],
}) {
  final base = buildFixtureReport();
  return AnalysisReport(
    id: base.id,
    alias: base.alias,
    address: base.address,
    analyzedAt: base.analyzedAt,
    grade: RiskGrade.danger,
    headline: base.headline,
    nextAction: base.nextAction,
    topRiskSummary: base.topRiskSummary,
    deposit: base.deposit,
    marketPrice: base.marketPrice,
    seniorDebtAmount: base.seniorDebtAmount,
    gaugeProgress: base.gaugeProgress,
    evidences: const [],
    highlights: base.highlights,
    checkedNotes: base.checkedNotes,
    privacyMasks: masks,
    privacyMasksReady: ready,
  );
}

const Color _white = Color(0xFFFFFFFF);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PrivacySettings.instance.resetForTest();
  });

  tearDown(() => PrivacySettings.instance.resetForTest());

  group('계약 — 서버 JSON을 읽는다 (§9.8)', () {
    test('privacyMasks·privacyMasksReady를 읽고, 쪽별 상자를 고른다', () {
      final json = <String, dynamic>{
        'id': 'r9',
        'alias': '별칭',
        'address': '주소',
        'analyzedAt': '2026-10-22T10:00:00+09:00',
        'grade': '위험',
        'headline': 'h',
        'nextAction': 'n',
        'topRiskSummary': 't',
        'deposit': 1,
        'marketPrice': null,
        'seniorDebtAmount': 0,
        'gaugeProgress': 0.5,
        'evidences': <dynamic>[],
        'privacyMasksReady': true,
        'privacyMasks': [
          {'page': 0, 'x': 0.1, 'y': 0.2, 'w': 0.3, 'h': 0.04},
          {'page': 0, 'x': 0.5, 'y': 0.6, 'w': 0.2, 'h': 0.03},
          {'page': 2, 'x': 0.0, 'y': 0.0, 'w': 1.0, 'h': 1.0},
        ],
      };
      final r = AnalysisReport.fromJson(json);
      expect(r.privacyMasksReady, isTrue);
      expect(r.privacyMasks, hasLength(3));
      expect(r.privacyBoxesOn(0), hasLength(2));
      expect(r.privacyBoxesOn(0).first.x, closeTo(0.1, 1e-9));
      expect(r.namesUnlocatedOn(0), isFalse);
      expect(r.namesUnlocatedOn(1), isFalse, reason: '찾아봤는데 이름이 없는 쪽');
      // 쪽 전체 상자 = 서버가 그 쪽을 못 찾아봤다 → 통째로 덮는다(상자 목록에는 안 넣는다)
      expect(r.namesUnlocatedOn(2), isTrue);
      expect(r.privacyBoxesOn(2), isEmpty);
    });

    test('옛 서버·옛 기록(필드 없음)은 위치를 모르는 것 — 통째로 덮을 대상이다', () {
      final json = <String, dynamic>{
        'id': 'old',
        'alias': '별칭',
        'address': '주소',
        'analyzedAt': '2026-08-14T10:00:00+09:00',
        'grade': '확인 필요',
        'headline': 'h',
        'nextAction': 'n',
        'topRiskSummary': 't',
        'deposit': 1,
        'seniorDebtAmount': 0,
        'gaugeProgress': 0.5,
        'evidences': <dynamic>[],
      };
      final r = AnalysisReport.fromJson(json);
      expect(r.privacyMasksReady, isFalse);
      expect(r.privacyMasks, isEmpty);
      expect(r.namesUnlocatedOn(0), isTrue);
    });
  });

  group('뷰어 오버레이 — 픽셀로 확인', () {
    testWidgets('켜면 서버가 보낸 이름 자리가 불투명 상자로 덮인다', (tester) async {
      final at = await _render(tester, privacyBoxes: const [_nameRow], hideNames: true);
      expect(at(50, 50), AppColors.markRedaction, reason: '글자 자리');
      expect(at(50, 42), AppColors.markRedaction, reason: '글자 옆 종이 자리도');
      expect(at(50, 10), _white, reason: '상자 밖은 손대지 않는다');
      expect(at(50, 90), _white);
    });

    testWidgets('끄면(기본) 아무것도 덮지 않는다 — 내 등기부 대조가 그대로 된다', (tester) async {
      final at = await _render(tester, privacyBoxes: const [_nameRow], hideNames: false);
      final onText = at(50, 50);
      expect(onText.r + onText.g + onText.b, lessThan(0.2), reason: '글자가 그대로 검다');
      expect(at(50, 42), _white);
    });

    testWidgets('빚 형광펜이 채무자 칸까지 번져 있어도 이름 자리는 덮인다 (상자가 형광펜 위)', (tester) async {
      final mortgage = RegistryHighlight(
        id: 'mortgage-1',
        page: 0,
        kind: 'mortgage',
        badge: 1,
        box: const HighlightBox(x: 0.0, y: 0.3, w: 1.0, h: 0.4),
        title: '빚',
        body: '본문',
      );
      final at = await _render(
        tester,
        marks: [mortgage],
        privacyBoxes: const [HighlightBox(x: 0.6, y: 0.4, w: 0.3, h: 0.2)],
        hideNames: true,
      );
      expect(at(75, 50), AppColors.markRedaction, reason: '이름 자리');
      // 이름 자리 밖의 빚 줄은 형광펜 그대로 — 글자가 비쳐 보인다
      final debt = at(20, 50);
      expect(debt.r + debt.g + debt.b, lessThan(0.2));
      expect(at(20, 35), isNot(AppColors.markRedaction));
      expect(at(20, 35), isNot(_white), reason: '형광펜으로 물든 종이');
    });

    testWidgets('위치를 모르는 쪽은 켜면 통째로 덮는다', (tester) async {
      final at = await _render(tester, coverWholePage: true, hideNames: true);
      for (final p in const [(2, 2), (50, 50), (97, 97), (10, 80)]) {
        expect(at(p.$1, p.$2), AppColors.markRedaction, reason: '$p');
      }
    });

    testWidgets('위치를 모르는 쪽이라도 끄면 그대로 보인다', (tester) async {
      final at = await _render(tester, coverWholePage: true, hideNames: false);
      expect(at(2, 2), _white);
      final onText = at(50, 50);
      expect(onText.r + onText.g + onText.b, lessThan(0.2));
    });

    test('페인터는 가림 상자·통째 덮기가 바뀌면 다시 그린다', () {
      final a = HighlightPainter(highlights: const [], hideNames: true);
      final b = HighlightPainter(
        highlights: const [],
        hideNames: true,
        privacyBoxes: const [_nameRow],
      );
      final c = HighlightPainter(highlights: const [], hideNames: true, coverWholePage: true);
      expect(b.shouldRepaint(a), isTrue);
      expect(c.shouldRepaint(a), isTrue);
    });
  });

  group('리포트 진입 카드 미리보기', () {
    late Directory temp;
    late String photo;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('privacy_masks_card');
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
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
    }

    RegistryPreviewSource source({
      List<HighlightBox> privacyBoxes = const [],
      bool namesUnlocated = false,
    }) {
      final mortgage = RegistryHighlight(
        id: 'mortgage-1',
        page: 0,
        kind: 'mortgage',
        badge: 1,
        box: const HighlightBox(x: 0.1, y: 0.4, w: 0.8, h: 0.05),
        title: '빚',
        body: '본문',
      );
      return RegistryPreviewSource(
        path: photo,
        mark: mortgage,
        examineCount: 1,
        totalCount: 1,
        pageMarks: [mortgage],
        privacyBoxes: privacyBoxes,
        namesUnlocated: namesUnlocated,
      );
    }

    testWidgets('빚 줄 미리보기 바로 아래 채무자 칸도 켜면 덮는다', (tester) async {
      await pumpCard(
        tester,
        source(privacyBoxes: const [
          HighlightBox(x: 0.5, y: 0.46, w: 0.2, h: 0.04),
          HighlightBox(x: 0.5, y: 0.52, w: 0.2, h: 0.04),
        ]),
      );
      expect(find.byType(NameRedactionBox), findsNothing, reason: '끈 상태(기본)');
      expect(find.byType(MarkStripe), findsOneWidget);

      await PrivacySettings.instance.setHideNamesInPhotos(true);
      await tester.pump();
      expect(find.byType(NameRedactionBox), findsNWidgets(2));
      expect(find.byType(MarkStripe), findsOneWidget, reason: '빚 형광펜은 그대로');
      expect(tester.takeException(), isNull);
    });

    testWidgets('이름 자리를 모르는 쪽이면 켰을 때 스트립 사진을 통째로 덮는다', (tester) async {
      await pumpCard(tester, source(namesUnlocated: true));
      expect(find.byKey(const ValueKey('preview-whole-cover')), findsNothing);

      await PrivacySettings.instance.setHideNamesInPhotos(true);
      await tester.pump();
      expect(find.byKey(const ValueKey('preview-whole-cover')), findsOneWidget);
      // 까만 띠만 있으면 "사진이 깨졌다"로 읽힌다 — 왜 덮었는지 가운데에 흰 글씨로(2026-10-23 서연 리뷰 #10)
      expect(find.koText(kWholePageCoverLabel), findsOneWidget);
      expect(find.koText('이름 가리기 켜짐 · 이 쪽은 통째로 가렸어요'), findsOneWidget);
    });
  });

  group('뷰어 화면 — 리포트의 상자가 쪽마다 전달된다', () {
    late Directory temp;

    setUp(() async {
      RegistryPhotoStore.instance.clear();
      temp = await Directory.systemTemp.createTemp('privacy_masks_viewer');
      RegistryPhotoStore.instance.register('r1', await writeFixturePhotos(temp));
    });

    tearDown(() async {
      RegistryPhotoStore.instance.clear();
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    Future<void> pumpViewer(WidgetTester tester, AnalysisReport report) async {
      tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AnalysisRepository>.value(
          value: FakeAnalysisRepository(report),
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

    testWidgets('서버가 위치를 보냈으면 그 쪽의 상자만 받고 통째로 덮지 않는다', (tester) async {
      await pumpViewer(
        tester,
        _report(
          ready: true,
          masks: const [
            PrivacyMask(page: 0, box: HighlightBox(x: 0.2, y: 0.3, w: 0.2, h: 0.02)),
          ],
        ),
      );
      await PrivacySettings.instance.setHideNamesInPhotos(true);
      await tester.pump();

      final ps = painters(tester);
      expect(ps, isNotEmpty);
      expect(ps.every((p) => p.hideNames && !p.coverWholePage), isTrue);
      expect(ps.any((p) => p.privacyBoxes.length == 1), isTrue, reason: '1쪽 상자가 전달된다');
      expect(find.byType(WholePageCoverLabel), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('위치를 모르는 옛 기록은 켜면 쪽을 통째로 덮고 이유를 말한다', (tester) async {
      await pumpViewer(tester, _report(ready: false));
      expect(find.byType(WholePageCoverLabel), findsNothing, reason: '끈 상태(기본)');

      await PrivacySettings.instance.setHideNamesInPhotos(true);
      await tester.pump();
      final ps = painters(tester);
      expect(ps, isNotEmpty);
      expect(ps.every((p) => p.coverWholePage), isTrue);
      expect(find.byType(WholePageCoverLabel), findsWidgets);
      expect(WholePageCoverLabel.message, contains('사진 속 이름 가리기'));
    });
  });

  group('스위치 설명 — 실제로 가리는 범위 그대로', () {
    testWidgets('사진과 글자 속 사람 이름 + 회사·은행은 그대로 + 분석 전 사진은 못 가린다 (처리방침에 적는다)', (tester) async {
      expect(
        privacyPolicySections().expand((s) => s.lines),
        contains(kHideNamesSwitchDescription),
      );
      expect(kHideNamesSwitchDescription, contains('주민번호'));
      // 2026-10-22: 사진뿐 아니라 리포트 글자 속 이름도 가린다 — 켜는 때는 남이 볼 때만(기본 꺼짐)
      expect(kHideNamesSwitchDescription, contains('글자 속 사람 이름'));
      expect(kHideNamesSwitchDescription, contains('회사·은행 이름은 그대로'));
      expect(kHideNamesSwitchDescription, contains('분석 전'));
      // 예전 문구("집주인 이름 칸을 … 다른 글자는 그대로")는 이제 사실이 아니다
      expect(kHideNamesSwitchDescription, isNot(contains('다른 글자는 그대로')));
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
