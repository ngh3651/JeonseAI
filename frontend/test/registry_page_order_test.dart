/// '내 등기부등본 보기' — **1쪽부터 정렬 · 글자가 바로 서게** (2026-10-26, api-contract §9.12).
///
/// 5장을 1·4·2·5·3이나 5·4·3·2·1로 올려도 종이와 같은 순서로, 가로·거꾸로 찍어도 바로 선 방향으로 보여야
/// 손에 든 등기부와 대조할 수 있다. 서버가 `pageOrder`(1쪽부터의 업로드 인덱스)와 `pageRotations`(장마다
/// 시계 방향 각도)를 주고, 앱은 **사진 파일은 그대로 두고 그리는 순서·방향만** 바꾼다.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/screens/report/registry_viewer_screen.dart';
import 'package:jeonse_ai/state/registry_photo_store.dart';
import 'package:provider/provider.dart';

import 'support/registry_fixture.dart';

/// 실제로 디코딩되는 사진(PNG) — 크기를 진짜로 재야 쪽 높이·회전 계산을 확인할 수 있다.
Future<String> _writePhoto(Directory dir, String name, int w, int h) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFFFFFFFF));
  final image = await recorder.endRecording().toImage(w, h);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  return file.path;
}

AnalysisReport _report({List<int> order = const [], List<int> rotations = const [], List<RegistryHighlight>? marks}) =>
    AnalysisReport(
      id: 'r1',
      alias: '샘플빌라',
      address: '서울특별시 샘플구 샘플동 1-1',
      analyzedAt: DateTime(2026, 10, 26),
      grade: RiskGrade.caution,
      headline: '확인이 필요해요',
      nextAction: '확인하세요',
      topRiskSummary: '선순위 채권',
      deposit: 100000000,
      marketPrice: null,
      seniorDebtAmount: 0,
      gaugeProgress: 0.5,
      evidences: const [],
      highlights: marks ?? [fixtureMark(1, 'owner', 1, 0.3, '집주인 이름 · 주식회사가나다')],
      pageOrder: order,
      pageRotations: rotations,
    );

void main() {
  group('모델 — pageOrder · pageRotations', () {
    test('서버 JSON을 읽는다 · 없으면 올린 순서·돌리지 않음', () {
      final base = {
        'id': 'r1',
        'alias': 'a',
        'address': 'b',
        'analyzedAt': '2026-10-26T10:00:00',
        'grade': '확인 필요',
        'headline': 'h',
        'nextAction': 'n',
        'topRiskSummary': 't',
        'deposit': 1,
        'marketPrice': null,
        'seniorDebtAmount': 0,
        'gaugeProgress': 0.5,
        'evidences': <Object>[],
      };
      final old = AnalysisReport.fromJson(base);
      expect(old.pageDisplayOrder(3), [0, 1, 2]);
      expect(old.quarterTurnsOf(0), 0);

      final r = AnalysisReport.fromJson({
        ...base,
        'pageOrder': [4, 3, 2, 1, 0],
        'pageRotations': [0, 90, 180, 270, 0],
      });
      expect(r.pageDisplayOrder(5), [4, 3, 2, 1, 0]);
      expect([for (var i = 0; i < 5; i++) r.quarterTurnsOf(i)], [0, 1, 2, 3, 0]);
    });

    test('1·4·2·5·3으로 올렸으면 1쪽부터', () {
      // 업로드 0=1쪽, 1=4쪽, 2=2쪽, 3=5쪽, 4=3쪽 → 1쪽부터의 업로드 인덱스
      expect(_report(order: [0, 2, 4, 1, 3]).pageDisplayOrder(5), [0, 2, 4, 1, 3]);
    });

    test('믿을 수 없는 순서면 올린 순서 그대로 (장수가 다름·중복·범위 밖)', () {
      expect(_report(order: [1, 0]).pageDisplayOrder(3), [0, 1, 2]);
      expect(_report(order: [0, 0, 1]).pageDisplayOrder(3), [0, 1, 2]);
      expect(_report(order: [0, 1, 5]).pageDisplayOrder(3), [0, 1, 2]);
    });

    test('이상한 각도는 돌리지 않는다', () {
      final r = _report(rotations: [45, -90, 360]);
      expect(r.quarterTurnsOf(0), 0);
      expect(r.quarterTurnsOf(2), 0);
      expect(r.quarterTurnsOf(9), 0);
    });
  });

  group('뷰어', () {
    late Directory temp;

    setUp(() async {
      RegistryPhotoStore.instance.clear();
      temp = await Directory.systemTemp.createTemp('page_order');
    });

    tearDown(() async {
      RegistryPhotoStore.instance.clear();
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    Future<List<String>> photos(WidgetTester tester, List<Size> sizes) async {
      final paths = <String>[];
      await tester.runAsync(() async {
        for (var i = 0; i < sizes.length; i++) {
          paths.add(await _writePhoto(temp, 'page_$i.png', sizes[i].width.round(), sizes[i].height.round()));
        }
      });
      return paths;
    }

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
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    /// 화면에 그린 사진들의 파일 경로 (위에서부터)
    List<String> shownPaths(WidgetTester tester) => [
      for (final img in tester.widgetList<Image>(find.byType(Image)))
        if (img.image is FileImage) (img.image as FileImage).file.path
        else if (img.image is ResizeImage && (img.image as ResizeImage).imageProvider is FileImage)
          ((img.image as ResizeImage).imageProvider as FileImage).file.path,
    ];

    testWidgets('3·1·2쪽 순서로 올려도 1쪽 사진이 맨 위, 형광펜도 그 사진에', (tester) async {
      const portrait = Size(200, 300);
      final paths = await photos(tester, [portrait, portrait, portrait]);
      RegistryPhotoStore.instance.register('r1', paths);
      // 업로드 0=3쪽, 1=1쪽, 2=2쪽 → 1쪽부터 [1, 2, 0]. 표시는 업로드 1번(=1쪽) 사진에 있다.
      await pumpViewer(tester, _report(order: [1, 2, 0]));

      expect(shownPaths(tester).first, paths[1], reason: '1쪽(두 번째로 올린 사진)이 맨 위');
      final overlays = tester.widgetList<RegistryHighlightOverlay>(find.byType(RegistryHighlightOverlay)).toList();
      expect(overlays.first.highlights.map((h) => h.badge), [1], reason: '형광펜은 그 사진(화면 첫 쪽)에 그대로');
      expect(overlays.first.highlights.single.page, 0);
    });

    testWidgets('가로로 찍은 장은 돌려서 바로 세우고, 쪽 크기도 바로 선 크기로', (tester) async {
      // 두 번째 장을 가로로 찍었다(파일은 300×200) — 서버가 시계 방향 90°로 바로 세웠다
      final paths = await photos(tester, [const Size(200, 300), const Size(300, 200)]);
      RegistryPhotoStore.instance.register('r1', paths);
      await pumpViewer(
        tester,
        _report(
          order: [1, 0],
          rotations: [0, 90],
          marks: [fixtureMark(1, 'owner', 1, 0.3, '집주인 이름 · 주식회사가나다')],
        ),
      );

      final rotated = tester.widget<RotatedBox>(find.byType(RotatedBox).first);
      expect(rotated.quarterTurns, 1, reason: '시계 방향 90°');
      expect(shownPaths(tester).first, paths[1]);
      final size = tester.getSize(find.byType(RotatedBox).first);
      expect(size.height / size.width, closeTo(1.5, 0.02), reason: '바로 선 사진(200×300) 비율로 자리를 잡는다');
      expect(tester.takeException(), isNull);
    });

    testWidgets('거꾸로 찍은 장은 180° 돌린다 · 돌리지 않은 장에는 RotatedBox가 없다', (tester) async {
      final paths = await photos(tester, [const Size(200, 300), const Size(200, 300)]);
      RegistryPhotoStore.instance.register('r1', paths);
      await pumpViewer(tester, _report(rotations: [180, 0]));
      final boxes = tester.widgetList<RotatedBox>(find.byType(RotatedBox)).toList();
      expect(boxes.length, 1);
      expect(boxes.single.quarterTurns, 2);
      expect(shownPaths(tester).first, paths[0], reason: 'pageOrder가 없으면 올린 순서 그대로');
    });
  });
}
