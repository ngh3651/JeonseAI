/// 원본 사진 하이라이트 — **좌표 변환**과 표시 규칙 테스트.
///
/// 좌표 변환은 이 기능에서 가장 잘 틀리는 곳이다. 실기기에서 "형광펜이 엉뚱한 데
/// 칠해졌다"가 나오면 원인은 대개 ⑴ 정규화 좌표를 잘못 곱했거나 ⑵ 화면에 그린
/// 이미지 크기와 곱한 크기가 다르거나 ⑶ 서버로 보낸 사진과 화면 사진이 다른 것이다.
/// 여기서는 ⑴을 잡는다(⑵·⑶은 앱 로그 + docs/morning-check.md 절차로 확인).
library;

import 'dart:typed_data' show ByteData;
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/registry_mark_kind.dart';
import 'package:jeonse_ai/screens/report/registry_document_layout.dart';
import 'package:jeonse_ai/screens/report/registry_viewer_screen.dart';
import 'package:jeonse_ai/state/registry_photo_store.dart';
import 'support/ko_finders.dart';

RegistryHighlight _h({
  int badge = 1,
  String kind = 'owner',
  int page = 0,
  double x = 0.5,
  double y = 0.25,
  double w = 0.05,
  double h = 0.02,
  String? caution,
}) => RegistryHighlight(
  id: 'test-$badge',
  page: page,
  kind: kind,
  badge: badge,
  box: HighlightBox(x: x, y: y, w: w, h: h),
  title: '집주인 이름 · 홍길동',
  body: '계약서의 임대인 이름과 상대방 신분증이 이 이름과 같은지 확인하세요. 다르면 계약을 진행하지 마세요.',
  caution: caution,
);

/// 실기기에서 실제로 올린 사진 5장의 원본 픽셀 크기.
/// **쪽마다 다르다** — 특히 2쪽만 종횡비가 눈에 띄게 낮다(1.32 vs 1.41~1.47).
const List<Size> _realPageSizes = [
  Size(1212, 1776),
  Size(1162, 1538),
  Size(1256, 1776),
  Size(1256, 1778),
  Size(1256, 1776),
];

void main() {
  group('좌표 변환 (정규화 → 화면)', () {
    test('정규화 좌표 × 표시 크기 = 그릴 사각형', () {
      final rect = highlightRect(
        const HighlightBox(x: 0.5, y: 0.25, w: 0.1, h: 0.02),
        const Size(800, 1000),
      );
      expect(rect.left, 400);
      expect(rect.top, 250);
      expect(rect.width, closeTo(80, 0.001));
      expect(rect.height, closeTo(20, 0.001));
    });

    test('표시 크기가 달라져도 상대 위치는 그대로다 (줌·기기 무관)', () {
      const box = HighlightBox(x: 0.6047, y: 0.2204, w: 0.0592, h: 0.0186);
      final small = highlightRect(box, const Size(360, 420));
      final large = highlightRect(box, const Size(1080, 1260));
      expect(large.left / small.left, closeTo(3.0, 1e-9));
      expect(large.top / small.top, closeTo(3.0, 1e-9));
      expect(large.width / small.width, closeTo(3.0, 1e-9));
    });

    test('실제 등기부 값으로 계산한 위치가 사람이 기대하는 곳에 온다', () {
      // 3.png 실측: 이름 '홍길동' bbox (531,597)-(575,613), 원본 878x1030px.
      // 서버는 8% 여유를 주고 정규화한다 → 대략 x 0.600, y 0.578
      const box = HighlightBox(x: 0.600, y: 0.578, w: 0.055, h: 0.020);
      final rect = highlightRect(box, const Size(878, 1030));
      expect(rect.left, closeTo(527, 2)); // 원본 픽셀과 거의 일치해야 한다
      expect(rect.top, closeTo(595, 3));
      expect(rect.width, closeTo(48, 2));
    });
  });

  group('터치 영역', () {
    test('작은 표시도 최소 48px까지 넓혀 손가락으로 누를 수 있게 한다', () {
      // 이름 폭 44px / 원본 878px → 화면 360px 기준 약 18px밖에 안 된다
      const box = HighlightBox(x: 0.6, y: 0.5, w: 0.05, h: 0.016);
      final touch = touchRect(box, const Size(360, 640));
      expect(touch.width, greaterThanOrEqualTo(48));
      expect(touch.height, greaterThanOrEqualTo(48));
    });

    test('넓힌 뒤에도 가운데는 원래 표시의 가운데다', () {
      const box = HighlightBox(x: 0.6, y: 0.5, w: 0.05, h: 0.016);
      const size = Size(360, 640);
      expect(touchRect(box, size).center, highlightRect(box, size).center);
    });

    test('이미 충분히 큰 표시는 넓히지 않는다', () {
      const box = HighlightBox(x: 0.1, y: 0.1, w: 0.5, h: 0.5);
      const size = Size(400, 400);
      expect(touchRect(box, size), highlightRect(box, size));
    });
  });

  group('오버레이 위젯', () {
    testWidgets('좌표가 있으면 그린다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 500,
              child: RegistryHighlightOverlay(
                highlights: [_h(badge: 1), _h(badge: 2, kind: 'mortgage')],
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<HighlightPainter>()
          .first;
      expect(painter.highlights.length, 2);
    });

    testWidgets('좌표가 없어도 조용히 그린다 (에러 문구 없음)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox(
            width: 300,
            height: 300,
            child: RegistryHighlightOverlay(highlights: []),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.koTextContaining('실패'), findsNothing);
      expect(find.koTextContaining('오류'), findsNothing);
    });

    testWidgets('선택된 표시만 번호 뱃지를 갖는다 (시안: 화면에 뱃지 1개)', (tester) async {
      final marks = [_h(badge: 1), _h(badge: 2, kind: 'mortgage', y: 0.5)];
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 500,
              child: RegistryHighlightOverlay(
                highlights: marks,
                selectedId: marks[1].id,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<HighlightPainter>()
          .first;
      expect(painter.selectedId, marks[1].id);
      // 선택이 바뀌면 다시 그려야 한다 — 안 그러면 뱃지가 옛 자리에 남는다.
      expect(
        painter.shouldRepaint(
          HighlightPainter(highlights: marks, selectedId: marks[0].id),
        ),
        isTrue,
      );
    });

    testWidgets('선택이 없어도(표시 0건) 예외 없이 그린다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 500,
              child: RegistryHighlightOverlay(highlights: [_h()]),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    // 예전엔 여기서 '디버그 모드(파란 터치 영역)'를 그렸다. 실기기에서 터치가
    // 잘 되는 것이 확인돼 그 스위치를 통째로 걷어냈고(2026-07-27), 같은 자리를
    // 그 스위치를 대체한 **그어짐 중간 상태** 검사로 쓴다.
    testWidgets('그어지는 도중(진행도 0·중간·1)에도 예외 없이 그린다', (tester) async {
      for (final progress in const [0.0, 0.37, 1.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 400,
              height: 500,
              child: RegistryHighlightOverlay(
                highlights: [_h()],
                selectedId: _h().id,
                drawProgress: progress,
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: '진행도 $progress');
      }
    });
  });

  group('형광펜 — 칠한 글자를 여전히 읽을 수 있는가', () {
    // 이 화면의 존재 이유는 "종이와 화면을 대조하는 것"이다. 표시가 글자를 덮어
    // 가려 버리면 기능이 통째로 무의미해진다. 그래서 실제로 그려 픽셀을 확인한다.
    testWidgets('곱하기로 겹쳐 — 검은 글자는 그대로, 흰 종이만 물든다', (tester) async {
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
                    CustomPaint(painter: _FakePaperPainter()),
                    RegistryHighlightOverlay(
                      highlights: [_h(x: 0.1, y: 0.4, w: 0.8, h: 0.2)],
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

      // 형광펜 아래의 '글자'(검은 줄, y 45~55)는 여전히 검다
      final onText = at(50, 50);
      expect(
        onText.r + onText.g + onText.b,
        lessThan(0.2),
        reason: '형광펜이 글자를 덮으면 종이와 대조할 수가 없다',
      );

      // 형광펜 아래의 흰 종이는 물든다 — 표시가 보이긴 해야 한다
      final onPaper = at(50, 42);
      expect(
        onPaper,
        isNot(const Color(0xFFFFFFFF)),
        reason: '아무 변화가 없으면 표시가 보이지 않는다',
      );

      // 형광펜 바깥은 손대지 않는다
      expect(at(50, 10), const Color(0xFFFFFFFF));
    });
  });

  group('탭 판정 — 겹칠 때 누가 이기는가', () {
    // 등기부 표에서 세로로 인접한 행은 48dp로 넓힌 터치 영역이 반드시 겹친다.
    // 첫 매칭을 쓰면 항상 앞 번호가 이겨 ④를 눌러도 ①이 열린다(공동명의에서 필연).
    const size = Size(400, 800);
    final a = _h(badge: 1, y: 0.10, h: 0.01);
    final b = _h(badge: 2, y: 0.13, h: 0.01);

    test('겹친 영역에서는 탭 지점에 가까운 쪽이 열린다', () {
      final rectB = highlightRect(b.box, size);
      final picked = highlightAt([a, b], rectB.center, size);
      expect(picked?.badge, 2, reason: '첫 매칭(①)이 아니라 가까운 ②가 열려야 한다');
    });

    test('반대쪽도 마찬가지다', () {
      final rectA = highlightRect(a.box, size);
      expect(highlightAt([a, b], rectA.center, size)?.badge, 1);
    });

    test('표시 밖을 누르면 아무것도 열리지 않는다', () {
      expect(highlightAt([a, b], const Offset(5, 700), size), isNull);
    });

    test('표시가 없으면 null', () {
      expect(highlightAt([], const Offset(10, 10), size), isNull);
    });
  });

  group('줌 배율', () {
    testWidgets('확대해도 예외 없이 그린다 (뱃지는 역스케일로 크기 유지)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 500,
            child: RegistryHighlightOverlay(
              highlights: [_h(), _h(badge: 2, kind: 'mortgage')],
              scale: 6.0,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('배율 0이 들어와도 나눗셈이 터지지 않는다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 500,
            child: RegistryHighlightOverlay(highlights: [_h()], scale: 0),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('가장자리 표시의 뱃지도 예외 없이 그린다 (클램프)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 500,
            child: RegistryHighlightOverlay(
              highlights: [_h(x: 0.0, y: 0.0), _h(badge: 2, x: 0.97, y: 0.98)],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('문서 기하 — 쪽 높이를 균등 분할하지 않는다', () {
    // 시안의 눈금값(20.6/39.2/61.1/81.0%)은 시안 샘플의 계산 결과지 상수가 아니다.
    // 여기서 잡는 것: 실제 종횡비로 계산했는가, 균등 20%로 퉁쳤는가.
    final layout = RegistryDocumentLayout.fromSizes(
      sizes: _realPageSizes,
      pageWidth: 344,
    );

    test('쪽 높이 = 폭 × 원본 종횡비', () {
      expect(layout.pageCount, 5);
      expect(layout.pageHeight(0), closeTo(344 * 1776 / 1212, 0.01));
      expect(layout.pageHeight(1), closeTo(344 * 1538 / 1162, 0.01));
      // 2쪽이 눈에 띄게 짧다 — 균등 분할이면 이 차이가 사라진다.
      expect(layout.pageHeight(0) - layout.pageHeight(1), greaterThan(40));
    });

    test('전체 높이 = 쪽 높이 합 + 간격 + 상하 여백', () {
      final sum = [
        for (var i = 0; i < layout.pageCount; i++) layout.pageHeight(i),
      ].fold<double>(0, (a, b) => a + b);
      expect(
        layout.totalHeight,
        closeTo(sum + kPageGap * 4 + kDocPadV * 2, 0.01),
      );
    });

    test('쪽 시작 위치는 앞 쪽들의 높이 + 간격을 누적한 값이다', () {
      expect(layout.pageTop(0), kDocPadV);
      expect(
        layout.pageTop(2),
        closeTo(
          kDocPadV + layout.pageHeight(0) + layout.pageHeight(1) + kPageGap * 2,
          0.01,
        ),
      );
    });

    test('레일 눈금은 쪽 경계(쪽 간격 한가운데)에 온다', () {
      var y = kDocPadV;
      for (var i = 0; i < layout.pageCount - 1; i++) {
        y += layout.pageHeight(i);
        expect(
          layout.boundaryFraction(i),
          closeTo((y + kPageGap / 2) / layout.totalHeight, 1e-9),
        );
        y += kPageGap;
      }
    });

    test('쪽 높이가 다르면 눈금이 균등 분할에서 벗어난다', () {
      // 가운데 한 쪽만 멀리서 찍혀 짧게 들어온 묶음.
      // 균등 3분할이면 첫 눈금이 0.33이지만, 실제 높이로 나누면 0.41쯤이다.
      final skew = RegistryDocumentLayout.fromSizes(
        sizes: const [Size(1000, 1400), Size(1000, 600), Size(1000, 1400)],
        pageWidth: 300,
      );
      expect(skew.boundaryFraction(0), greaterThan(0.40));
      expect(skew.boundaryFraction(0), isNot(closeTo(1 / 3, 0.05)));
    });

    test('눈금은 오름차순이고 0~1 안에 있다', () {
      final ticks = [for (var i = 0; i < 4; i++) layout.boundaryFraction(i)];
      expect(ticks, orderedEquals(List.of(ticks)..sort()));
      expect(ticks.first, greaterThan(0));
      expect(ticks.last, lessThan(1));
    });

    test('폭이 달라져도 비율은 그대로다 (360dp ↔ 412dp)', () {
      final wide = RegistryDocumentLayout.fromSizes(
        sizes: _realPageSizes,
        pageWidth: 396,
      );
      expect(wide.boundaryFraction(1), closeTo(layout.boundaryFraction(1), 0.01));
    });

    test('원본 크기를 못 읽은 쪽은 A4 비율로 자리만 잡는다 (뒤 쪽이 밀리지 않게)', () {
      final broken = RegistryDocumentLayout.fromSizes(
        sizes: const [Size.zero, Size(1000, 1500)],
        pageWidth: 300,
      );
      expect(broken.pageHeight(0), closeTo(300 * kFallbackPageAspect, 0.01));
      expect(broken.pageHeight(0), greaterThan(0));
    });

    test('표시의 문서 내 위치는 쪽 시작 + 쪽 안 상대 위치다', () {
      // 4쪽(index 3)의 세로 60% 지점
      final y = layout.markCenterY(3, 0.59, 0.02);
      expect(y, closeTo(layout.pageTop(3) + layout.pageHeight(3) * 0.6, 0.01));
      expect(layout.fractionOf(y), inInclusiveRange(0.0, 1.0));
    });
  });

  group('스크롤 목표 — 190dp 고정이 아니라 뷰포트 비율', () {
    test('표시가 화면 위쪽 1/3 지점에 온다', () {
      expect(
        scrollTargetFor(markY: 1200, viewportHeight: 600, maxScrollExtent: 5000),
        closeTo(1000, 0.01),
      );
    });

    test('작은 화면과 큰 화면에서 목표가 다르다 (고정값이면 같아진다)', () {
      final small = scrollTargetFor(
        markY: 1200,
        viewportHeight: 480,
        maxScrollExtent: 5000,
      );
      final large = scrollTargetFor(
        markY: 1200,
        viewportHeight: 900,
        maxScrollExtent: 5000,
      );
      expect(small, isNot(closeTo(large, 1)));
    });

    test('맨 위 표시는 음수로 가지 않는다', () {
      expect(
        scrollTargetFor(markY: 20, viewportHeight: 600, maxScrollExtent: 5000),
        0,
      );
    });

    test('맨 아래 표시는 스크롤 끝을 넘지 않는다', () {
      expect(
        scrollTargetFor(markY: 9000, viewportHeight: 600, maxScrollExtent: 5000),
        5000,
      );
    });

    test('스크롤할 것이 없으면 0', () {
      expect(
        scrollTargetFor(markY: 300, viewportHeight: 600, maxScrollExtent: 0),
        0,
      );
    });
  });

  group('표시 종류 — 두 가지로 하드코딩하지 않는다', () {
    test('모르는 종류는 위험 쪽으로 떨어진다 (보수적 편향)', () {
      // 예전엔 'seizure'가 이 자리에 있었다 — 2026-07-28에 실제 종류가 되면서
      // 아직 구현되지 않은 kind로 바꿨다(백로그의 가처분).
      final kind = MarkKind.fromKey('provisional_disposition');
      expect(kind, MarkKind.unknown);
      expect(kind.isRisk, isTrue, reason: '모르는 것을 초록(대조할 곳)으로 칠하면 경고를 놓친다');
    });

    test('아는 종류는 톤이 갈린다', () {
      expect(MarkKind.fromKey('owner').tone, MarkTone.verify);
      expect(MarkKind.fromKey('mortgage').tone, MarkTone.risk);
      expect(MarkKind.fromKey('jeonse').tone, MarkTone.risk);
    });

    test('범례는 화면에 실제로 있는 종류로만 만든다', () {
      final legend = MarkLegend.fromKinds([MarkKind.owner, MarkKind.mortgage]);
      expect(legend.map((e) => e.label), ['이름처럼 대조할 곳', '빚처럼 따져볼 곳']);
    });

    test('종류가 늘면 범례 문구가 따라 늘어난다', () {
      final legend = MarkLegend.fromKinds([
        MarkKind.owner,
        MarkKind.mortgage,
        MarkKind.jeonse,
      ]);
      expect(legend.length, 2, reason: '톤은 둘이므로 줄은 늘지 않는다');
      expect(legend.last.label, '빚·전세권처럼 따져볼 곳');
    });

    test('이름만 있으면 초록 줄 하나만 나온다', () {
      final legend = MarkLegend.fromKinds([MarkKind.owner]);
      expect(legend.length, 1);
      expect(legend.single.tone, MarkTone.verify);
    });

    test('따져볼 곳 개수와 전체 표시 개수는 따로 센다', () {
      // 이름 1 + 빚 3 = 표시 4곳이지만, 이름은 따져볼 곳이 아니다 → 3곳
      final kinds = [
        MarkKind.owner,
        MarkKind.mortgage,
        MarkKind.mortgage,
        MarkKind.mortgage,
      ];
      expect(kinds.length, 4);
      expect(MarkLegend.examineCount(kinds), 3);
      expect(MarkLegend.verifyCount(kinds), 1);
    });

    test('종류가 많으면 범례에서 이름을 빼고 색-의미만 남긴다', () {
      // 360dp 가용 폭 328dp인데 이름을 붙이면 364dp가 되어 Wrap이 두 줄이 되고,
      // 문서 영역이 하한 400dp 아래로 떨어진다(2026-07-28 design-reviewer 실측).
      final legend = MarkLegend.fromKinds([
        MarkKind.address,
        MarkKind.owner,
        MarkKind.viewedAt,
        MarkKind.seizure,
      ]);
      expect(legend.first.label, '대조할 곳');
      expect(legend.last.label, '따져볼 곳');
    });

    test('한쪽만 많아도 양쪽 다 이름을 뺀다', () {
      // 한 줄만 이름이 붙어 있으면 "이쪽만 종류가 있다"로 읽힌다.
      final legend = MarkLegend.fromKinds([
        MarkKind.owner, // verify 1종
        MarkKind.seizure, MarkKind.auction, MarkKind.mortgage, // risk 3종
      ]);
      expect(legend.map((e) => e.label), ['대조할 곳', '따져볼 곳']);
    });

    test('미리보기는 가장 무거운 표시를 고른다 (목록 첫 표시가 아니라)', () {
      // 목록 순서는 등기부 읽는 순서라 separate_land(표제부)가 auction(갑구)보다 앞이다.
      // 그 순서로 고르면 **경매가 시작된 집인데 미리보기가 토지 별도등기**가 된다.
      expect(MarkKind.auction.weight, greaterThan(MarkKind.separateLand.weight));
      expect(MarkKind.seizure.weight, greaterThan(MarkKind.jointCollateral.weight));
      expect(MarkKind.mortgage.weight, greaterThan(MarkKind.pendingApplication.weight));
      // 모르는 종류는 무겁게 — 보수적 편향
      expect(MarkKind.unknown.weight, greaterThan(MarkKind.mortgage.weight));
      // 무게는 **등급이 아니다** — 톤(색)은 무게와 무관하게 정해진다
      expect(MarkKind.separateLand.tone, MarkTone.risk);
      expect(MarkKind.owner.tone, MarkTone.verify);
    });

    test('새로 추가된 종류가 전부 파싱된다 (서버 kind ↔ 앱 enum)', () {
      // 백엔드 highlight.py의 _SPECS 키와 1:1이어야 한다. 하나라도 빠지면
      // 그 표시가 unknown(위험 톤)으로 떨어져 색과 개수가 조용히 틀어진다.
      const serverKinds = [
        'address', 'area', 'separate_land', 'doc_title', 'owner',
        'provisional_seizure', 'seizure', 'auction', 'trust',
        'mortgage', 'jeonse', 'lease_registration', 'joint_collateral',
        'pending_application', 'viewed_at',
      ];
      for (final key in serverKinds) {
        expect(
          MarkKind.fromKey(key),
          isNot(MarkKind.unknown),
          reason: '$key 가 MarkKind에 없다 — unknown(위험)으로 떨어진다',
        );
      }
      expect(MarkKind.values.length, serverKinds.length + 1, reason: 'unknown 포함');
    });

    test('대조할 곳과 따져볼 곳의 톤이 지시대로 갈린다', () {
      // 초록(대조할 곳): 주소·면적·서류 종류·이름·뗀 날
      for (final k in [
        MarkKind.address, MarkKind.area, MarkKind.docTitle,
        MarkKind.owner, MarkKind.viewedAt,
      ]) {
        expect(k.tone, MarkTone.verify, reason: '${k.key} 는 대조할 곳이다');
      }
      // 주황(따져볼 곳): 보증금을 깎을 수 있는 권리·문서 상태
      for (final k in [
        MarkKind.separateLand, MarkKind.provisionalSeizure, MarkKind.seizure,
        MarkKind.auction, MarkKind.trust, MarkKind.mortgage, MarkKind.jeonse,
        MarkKind.leaseRegistration, MarkKind.jointCollateral,
        MarkKind.pendingApplication,
      ]) {
        expect(k.tone, MarkTone.risk, reason: '${k.key} 는 따져볼 곳이다');
      }
    });

    test('개수 문구는 종류별로 조립한다', () {
      expect(
        MarkLegend.countPhrase([
          MarkKind.owner,
          MarkKind.mortgage,
          MarkKind.mortgage,
          MarkKind.mortgage,
        ]),
        '집주인 이름 1곳과 빚 3건',
      );
      expect(MarkLegend.countPhrase([MarkKind.owner]), '집주인 이름 1곳');
      expect(MarkLegend.countPhrase(const []), '');
    });
  });

  group('표시하지 못한 것 — 목록 끝 회색 한 줄', () {
    test('말소로 뺀 것이 있으면 그 사유가 나온다', () {
      final line = unmarkedNotice([
        '집주인 이름 1곳 — 사진에서 찾아 표시했어요',
        '집에 잡힌 빚(근저당) 1건은 **모두 말소된 것으로 확인**해 표시하지 않았어요 — 이미 정리된 빚이에요',
        '압류·가압류·신탁 같은 표시는 없었어요',
      ]);
      expect(line, isNotNull);
      expect(line, contains('말소'));
      expect(line, isNot(contains('**')), reason: '마크다운 별표가 화면에 그대로 나가면 안 된다');
    });

    test('말소 전용이 아니다 — 위치를 못 찾은 것도 같은 자리에 나온다', () {
      final line = unmarkedNotice([
        '지금 남아 있는 빚 2건은 리포트에 반영됐지만, 사진에서 위치를 찾지 못했어요 — 리포트의 근거 카드에서 확인하세요',
      ]);
      expect(line, contains('찾지 못했어요'));
    });

    test('여러 사유가 있으면 한 줄로 잇는다', () {
      final line = unmarkedNotice([
        '근저당 1건은 말소된 것으로 확인해 표시하지 않았어요',
        '빚 표시는 이번엔 생략했어요 — 위 안내를 확인해 주세요',
      ]);
      expect(line!.split(' · ').length, 2);
    });

    test('표시하지 못한 것이 없으면 줄 자체가 사라진다', () {
      expect(
        unmarkedNotice([
          '집주인 이름 1곳 — 사진에서 찾아 표시했어요',
          '지금 남아 있는 빚 3건을 표시했어요',
          '압류·가압류·신탁 같은 표시는 없었어요',
        ]),
        isNull,
      );
      expect(unmarkedNotice(const []), isNull);
    });
  });

  group('위치 레일', () {
    final layout = RegistryDocumentLayout.fromSizes(
      sizes: _realPageSizes,
      pageWidth: 344,
    );

    testWidgets('쪽 번호가 쪽 수만큼 나온다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: RegistryPositionRail(
                layout: layout,
                marks: [_h(page: 1), _h(badge: 2, kind: 'mortgage', page: 3)],
                offset: 0,
                viewport: 500,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      for (var i = 1; i <= 5; i++) {
        expect(find.koText('$i'), findsOneWidget);
      }
    });

    testWidgets('레일을 누르면 그 비율로 이동을 요청한다', (tester) async {
      double? seeked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: RegistryPositionRail(
                layout: layout,
                marks: [_h()],
                offset: 0,
                viewport: 500,
                onSeek: (f) => seeked = f,
              ),
            ),
          ),
        ),
      );
      // 레일의 터치 영역(트랙 폭 = 레일 폭 − 좌우 패딩) 기준으로 눌러야 한다.
      final track = tester.getRect(
        find
            .descendant(
              of: find.byType(RegistryPositionRail),
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      await tester.tapAt(
        Offset(track.left + track.width * 0.75, track.center.dy),
      );
      expect(seeked, isNotNull);
      expect(seeked, closeTo(0.75, 0.02));
    });

    testWidgets('표시가 없어도, 뷰포트를 몰라도 예외 없이 그린다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: RegistryPositionRail(
                layout: layout,
                marks: const [],
                offset: 0,
                viewport: 0,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('모델 파싱', () {
    test('서버가 highlights를 안 보내도 빈 목록으로 동작한다', () {
      final report = AnalysisReport.fromJson(_reportJson());
      expect(report.highlights, isEmpty);
    });

    test('highlights를 보내면 그대로 읽는다', () {
      final json = _reportJson();
      json['highlights'] = [
        {
          'id': 'owner-0',
          'page': 1,
          'kind': 'owner',
          'badge': 2,
          'box': {'x': 0.6, 'y': 0.5, 'w': 0.05, 'h': 0.02},
          'title': '집주인 이름 · 홍길동',
          'body': '확인하세요',
          'caution': '이 집은 2명 공동명의입니다.',
          'source': '등기부 갑구 — 이 앱이 사진에서 직접 찾은 위치',
        },
      ];
      final report = AnalysisReport.fromJson(json);
      expect(report.highlights.length, 1);
      final h = report.highlights.first;
      expect(h.page, 1);
      expect(h.badge, 2);
      expect(h.isOwner, isTrue);
      expect(h.box.x, closeTo(0.6, 1e-9));
      expect(h.caution, contains('공동명의'));
      expect(h.source, contains('갑구'));
    });

    test('checkedNotes와 highlightNotice를 읽는다', () {
      final json = _reportJson();
      json['checkedNotes'] = ['집주인 이름 2곳 — 사진에서 찾아 표시했어요', '빚은 없었어요'];
      json['highlightNotice'] = '등기부 5쪽 중 2쪽만 올리셨어요.';
      final report = AnalysisReport.fromJson(json);
      expect(report.checkedNotes.length, 2);
      expect(report.highlightNotice, contains('5쪽 중 2쪽'));
    });

    test('구버전 서버(필드 없음)에서도 빈 값으로 동작한다', () {
      final report = AnalysisReport.fromJson(_reportJson());
      expect(report.checkedNotes, isEmpty);
      expect(report.highlightNotice, isNull);
    });

    test('등기부 열람일시를 읽는다 — 분석일과 다른 날짜다', () {
      final json = _reportJson();
      json['registryViewedAt'] = '2026.07.09';
      final report = AnalysisReport.fromJson(json);
      expect(report.registryViewedAt, '2026.07.09');
      // 열람일(7/9)과 분석일(7/27)은 다른 값이다 — 이 간극이 이 필드의 존재 이유다.
      // 그 사이에 근저당이 새로 잡혔을 수 있고, 계약 직전 근저당 설정은 실제 수법이다.
      expect(report.registryViewedAt, isNot(contains('07.27')));
    });

    test('열람일시를 못 읽으면 null이다 (분석일로 대체하지 않는다)', () {
      final report = AnalysisReport.fromJson(_reportJson());
      expect(report.registryViewedAt, isNull);
    });
  });

  group('사진 저장소 (세션 한정)', () {
    setUp(() => RegistryPhotoStore.instance.clear());

    test('등록한 적 없는 리포트는 사진이 없다 → 진입점이 숨는다', () {
      expect(RegistryPhotoStore.instance.hasPhotos('없는-id'), isFalse);
    });

    test('파일이 실제로 없으면 전부 없는 것으로 친다', () {
      // 한 장이라도 사라지면 page 인덱스가 밀려 엉뚱한 사진에 그려진다.
      // 영구 저장으로 바뀐 뒤에도 이 규칙은 그대로다 — 사용자가 저장소를 비웠을 수 있다.
      RegistryPhotoStore.instance.register('r1', [
        '/tmp/사라진_1.jpg',
        '/tmp/사라진_2.jpg',
      ]);
      expect(RegistryPhotoStore.instance.pathsFor('r1'), isEmpty);
      expect(RegistryPhotoStore.instance.hasPhotos('r1'), isFalse);
    });

    test('보관이 실패해도 예외를 밖으로 던지지 않는다', () async {
      // 테스트 환경에는 path_provider·SharedPreferences 플러그인이 없다.
      // 보관은 편의 기능이라, 실패했다고 분석이 깨져서는 안 된다.
      await RegistryPhotoStore.instance.restore();
      await RegistryPhotoStore.instance.keep(
        'r2',
        ['/tmp/없는_1.jpg'],
        reportJson: '{"id":"r2"}',
      );
      expect(await RegistryPhotoStore.instance.cachedReportJson('r2'), isNull);
    });

    test('보관 실패와 무관하게 세션 등록은 그대로 남는다', () async {
      RegistryPhotoStore.instance.register('r3', ['/tmp/없는_1.jpg']);
      await RegistryPhotoStore.instance.keep('r3', ['/tmp/없는_1.jpg']);
      // 파일이 없으니 pathsFor는 비어 있지만, 등록 자체가 예외로 날아가지는 않는다
      expect(RegistryPhotoStore.instance.pathsFor('r3'), isEmpty);
    });
  });

  _crossCheckNoteVisibility();
}

/// 흰 종이 위에 검은 글자 한 줄이 인쇄된 것을 흉내 낸다(폰트 렌더링에 의존하지 않게
/// 직접 칠한다 — 플랫폼마다 글꼴이 달라 픽셀 검사가 흔들리는 것을 막는다).
class _FakePaperPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawRect(
      Rect.fromLTRB(0, size.height * 0.45, size.width, size.height * 0.55),
      Paint()..color = const Color(0xFF000000),
    );
  }

  @override
  bool shouldRepaint(_FakePaperPainter old) => false;
}

Map<String, dynamic> _reportJson() => {
  'id': 'analysis-1',
  'alias': '신정동 행복아파트',
  'address': '서울특별시 양천구 신정동 1234',
  'analyzedAt': '2026-07-27T02:00:00+09:00',
  'grade': '확인 필요',
  'gaugeProgress': 0.5,
  'headline': '확인이 필요해요',
  'nextAction': '등기부를 다시 확인하세요',
  'topRiskSummary': '선순위 채권',
  'deposit': 300000000,
  'marketPrice': null,
  'seniorDebtAmount': 0,
  'evidences': <Map<String, dynamic>>[],
};

void _crossCheckNoteVisibility() {
  group('교차검증·고지 문장이 화면에 실제로 나오는가 (2026-07-28)', () {
    // 백엔드가 만드는 문장을 그대로 옮겨 온 표본. 이 중 하나라도 필터에서 탈락하면
    // 사용자는 그 사실을 **영영 알 수 없다** — "침묵 금지" 설계가 화면에서 깨진다.
    const serverNotes = [
      '집주인 이름 1곳 — 사진에서 찾아 표시했어요',
      '빚은 7건 중 큰 것부터 5건만 사진에 표시했어요. 나머지 2건은 화면이 가려져서 표시하지 않았어요 — 리포트의 근거 카드에는 7건 다 들어 있어요',
      '사진 순서가 등기부 쪽수와 달라 자동으로 맞췄어요 — 다시 올리지 않으셔도 돼요',
      '서류 내용을 2가지 방법으로 교차 확인했어요 — 빚(근저당) 3건 일치',
      '압류는 AI가 서로 다른 두 방법으로 읽었더니 개수가 달랐어요(3건 / 1건). 위험 계산은 더 많이 잡은 3건 기준으로 했어요. 그중 2건은 위치를 짚지 못해 사진에 표시하지 않았어요',
      '이번엔 한 가지 방법으로만 읽었어요 — 두 번째 확인은 하지 못했어요 (분석 결과에는 영향이 없어요)',
      '못 본 쪽이 있어서 빚(근저당)이 없다고는 말할 수 없어요 — 위 안내를 확인해 주세요',
    ];

    test('상한 생략 고지가 화면에 나온다', () {
      expect(unmarkedNotice([serverNotes[1]]), isNotNull);
    });

    test('자동 정렬 고지가 화면에 나온다', () {
      expect(unmarkedNotice([serverNotes[2]]), isNotNull);
    });

    test('교차검증 일치 문장이 화면에 나온다 (불안만 남기지 않는다)', () {
      expect(unmarkedNotice([serverNotes[3]]), isNotNull);
    });

    test('교차검증 불일치 문장이 화면에 나온다', () {
      expect(unmarkedNotice([serverNotes[4]]), isNotNull);
    });

    test('두 번째 확인 실패 고지가 화면에 나온다', () {
      expect(unmarkedNotice([serverNotes[5]]), isNotNull);
    });

    test('"없다고 말할 수 없어요" 고지가 화면에 나온다', () {
      expect(unmarkedNotice([serverNotes[6]]), isNotNull);
    });

    test('평범한 진행 문장은 여전히 걸러진다 (회색 줄이 길어지지 않게)', () {
      expect(unmarkedNotice([serverNotes[0]]), isNull);
    });
  });
}
