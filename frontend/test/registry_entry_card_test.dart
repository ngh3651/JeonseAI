/// 리포트 진입 카드 — **뱃지와 부제가 서로 다른 것을 센다**는 규칙, 그리고
/// 미리보기 스트립이 시안 오프셋 하드코딩 없이 계산되는지.
///
/// 이 카드가 틀리기 쉬운 곳은 하나다: "위험 4곳"이라고 쓰고 싶어지는 것.
/// 표시 4곳 중 집주인 이름은 **위험이 아니라 대조할 곳**이라 위험은 3곳이다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/registry_mark_kind.dart';
import 'package:jeonse_ai/screens/report/registry_entry_card.dart';

import 'support/registry_fixture.dart';

void main() {
  final report = buildFixtureReport();

  group('무엇을 세는가 — 뱃지(위험)와 부제(전체)', () {
    test('표시는 4곳이지만 위험은 3곳이다 (이름은 대조할 곳)', () {
      final kinds = report.highlights.map((h) => h.markKind);
      expect(report.highlights.length, 4);
      expect(MarkLegend.riskCount(kinds), 3);
    });

    test('부제는 kind별 개수로 조립된다 (하드코딩 아님)', () {
      expect(
        MarkLegend.countPhrase(report.highlights.map((h) => h.markKind)),
        '집주인 이름 1곳과 빚 3건',
      );
    });

    test('종류가 늘면 부제도 따라 늘어난다', () {
      expect(
        MarkLegend.countPhrase([
          MarkKind.owner,
          MarkKind.mortgage,
          MarkKind.jeonse,
        ]),
        '집주인 이름 1곳, 빚 1건과 전세권 1건',
      );
    });
  });

  group('미리보기에 쓸 표시 고르기', () {
    test('첫 번째 **위험** 표시를 쓴다 (첫 표시가 아니다)', () {
      final picked = previewMarkOf(report.highlights);
      expect(picked?.kind, 'mortgage');
      expect(picked?.badge, 2);
    });

    test('위험이 없으면 첫 표시로 떨어진다', () {
      final onlyOwner = [report.highlights.first];
      expect(previewMarkOf(onlyOwner)?.kind, 'owner');
    });

    test('표시가 없으면 null — 스트립 없이 하단 행만 남는다', () {
      expect(previewMarkOf(const []), isNull);
    });
  });

  group('crop 계산 — 시안 오프셋(-384, -712)을 하드코딩하지 않는다', () {
    // 시안 샘플: 4쪽(1256x1776), 표시 높이 2%, 스트립 폭 ≈ 320dp
    const page = Size(1256, 1776);
    const strip = Size(320, kPreviewStripHeight);
    const box = HighlightBox(x: 0.505, y: 0.614, w: 0.33, h: 0.02);

    test('글자가 읽히는 배율로 키운다 (시안의 853dp 근처가 나온다)', () {
      final crop = previewCropFor(box: box, pageSize: page, strip: strip);
      expect(crop.imageSize.width, closeTo(849, 15));
    });

    test('표시가 스트립 한가운데 온다', () {
      final crop = previewCropFor(box: box, pageSize: page, strip: strip);
      final rect = crop.markRect(box);
      expect(rect.center.dy, closeTo(strip.height / 2, 1));
      expect(rect.center.dx, closeTo(strip.width / 2, 1));
    });

    // 스트립을 106 → 140dp로 키운 뒤(2026-07-27 실기기) 형광펜이 밖으로 밀리지
    // 않는지 못 박는다. 높이를 또 만지면 여기서 먼저 걸린다.
    test('스트립 높이를 키워도 형광펜이 스트립 안에 들어온다', () {
      expect(kPreviewStripHeight, 140);
      for (final y in const [0.03, 0.25, 0.5, 0.62, 0.95]) {
        final b = HighlightBox(x: 0.505, y: y, w: 0.33, h: 0.02);
        final crop = previewCropFor(box: b, pageSize: page, strip: strip);
        final rect = crop.markRect(b);
        expect(rect.top, greaterThanOrEqualTo(-0.001), reason: 'y=$y');
        expect(rect.bottom, lessThanOrEqualTo(strip.height + 0.001), reason: 'y=$y');
        expect(rect.left, greaterThanOrEqualTo(-0.001), reason: 'y=$y');
        expect(rect.right, lessThanOrEqualTo(strip.width + 0.001), reason: 'y=$y');
      }
    });

    test('사진은 항상 스트립을 덮는다 (빈 곳이 생기지 않는다)', () {
      for (final y in const [0.0, 0.02, 0.5, 0.97]) {
        for (final x in const [0.0, 0.4, 0.9]) {
          final b = HighlightBox(x: x, y: y, w: 0.1, h: 0.02);
          final crop = previewCropFor(box: b, pageSize: page, strip: strip);
          expect(crop.offset.dx, lessThanOrEqualTo(0.001));
          expect(crop.offset.dy, lessThanOrEqualTo(0.001));
          expect(
            crop.offset.dx + crop.imageSize.width,
            greaterThanOrEqualTo(strip.width - 0.001),
          );
          expect(
            crop.offset.dy + crop.imageSize.height,
            greaterThanOrEqualTo(strip.height - 0.001),
          );
        }
      }
    });

    test('글자가 큰 사진(bbox가 두꺼움)은 덜 확대한다', () {
      final thick = previewCropFor(
        box: const HighlightBox(x: 0.5, y: 0.5, w: 0.3, h: 0.06),
        pageSize: page,
        strip: strip,
      );
      final thin = previewCropFor(box: box, pageSize: page, strip: strip);
      expect(thick.imageSize.width, lessThan(thin.imageSize.width));
    });

    test('bbox가 비정상적으로 얇아도 배율이 폭주하지 않는다', () {
      final crop = previewCropFor(
        box: const HighlightBox(x: 0.5, y: 0.5, w: 0.3, h: 0.0001),
        pageSize: page,
        strip: strip,
      );
      expect(
        crop.imageSize.width,
        lessThanOrEqualTo(strip.width * kPreviewMaxZoom + 0.001),
      );
    });

    test('원본 크기를 모르면 A4 비율로 계산한다 (0으로 나누지 않는다)', () {
      final crop = previewCropFor(
        box: box,
        pageSize: Size.zero,
        strip: strip,
      );
      expect(crop.imageSize.width, greaterThan(0));
      expect(crop.imageSize.height, greaterThan(0));
    });
  });

  group('카드는 사라지지 않는다', () {
    Future<void> pumpCard(
      WidgetTester tester, {
      RegistryPreviewSource? preview,
      VoidCallback? onTap,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: RegistryEntryCard(
              subtitle: '집주인 이름 1곳과 빚 3건을 사진 위에 표시했어요',
              onTap: onTap ?? () {},
              preview: preview,
            ),
          ),
        ),
      ),
    );

    testWidgets('사진이 없으면 스트립 없이 하단 행만 남는다', (tester) async {
      await pumpCard(tester);
      expect(find.text('내가 올린 사진에서 보기'), findsOneWidget);
      expect(find.text('집주인 이름 1곳과 빚 3건을 사진 위에 표시했어요'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('부제가 null이면 그 줄만 사라지고 카드는 남는다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: RegistryEntryCard(subtitle: null, onTap: () {}),
            ),
          ),
        ),
      );
      expect(find.text('내가 올린 사진에서 보기'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('열람일 줄은 분석일이 아니라 등기부에 인쇄된 날짜다', (tester) async {
      await pumpCard(tester);
      // 리포트 상단은 "2026.07.27 분석"인데 여기는 열람일(7/9)이어야 한다.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: RegistryEntryCard(
                subtitle: '※ 2026.07.09 기준 등기부등본',
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('※ 2026.07.09 기준 등기부등본'), findsOneWidget);
      expect(find.textContaining('07.27'), findsNothing);
    });

    testWidgets('잠긴 상태(사진 소실)에서도 카드가 남고 이유를 말한다', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: RegistryEntryCard(
                subtitle: '등기부 사진은 안전을 위해 저장하지 않아요. 다시 보려면 새로 분석해 주세요.',
                onTap: null,
              ),
            ),
          ),
        ),
      );
      expect(find.text('내가 올린 사진에서 보기'), findsOneWidget);
      expect(find.textContaining('저장하지 않아요'), findsOneWidget);
      // 열 수 없으니 chevron은 없다
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });
  });
}
