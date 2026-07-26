/// 원본 사진 하이라이트 — **좌표 변환**과 표시 규칙 테스트.
///
/// 좌표 변환은 이 기능에서 가장 잘 틀리는 곳이다. 실기기에서 "형광펜이 엉뚱한 데
/// 칠해졌다"가 나오면 원인은 대개 ⑴ 정규화 좌표를 잘못 곱했거나 ⑵ 화면에 그린
/// 이미지 크기와 곱한 크기가 다르거나 ⑶ 서버로 보낸 사진과 화면 사진이 다른 것이다.
/// 여기서는 ⑴을 잡는다(⑵·⑶은 앱 로그 + docs/morning-check.md 절차로 확인).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/screens/report/registry_viewer_screen.dart';
import 'package:jeonse_ai/state/registry_photo_store.dart';

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
  title: '집주인 이름 · 소유자D',
  body: '계약서의 임대인 이름과 상대방 신분증이 이 이름과 같은지 확인하세요. 다르면 계약을 진행하지 마세요.',
  caution: caution,
);

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
      // 3.png 실측: 이름 '소유자D' bbox (531,597)-(575,613), 원본 878x1030px.
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
      expect(find.textContaining('실패'), findsNothing);
      expect(find.textContaining('오류'), findsNothing);
    });

    testWidgets('디버그 모드에서도 예외 없이 그린다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 500,
            child: RegistryHighlightOverlay(
              highlights: [_h()],
              debug: true,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
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
          'title': '집주인 이름 · 소유자D',
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
  });

  group('사진 저장소 (세션 한정)', () {
    setUp(() => RegistryPhotoStore.instance.clear());

    test('등록한 적 없는 리포트는 사진이 없다 → 진입점이 숨는다', () {
      expect(RegistryPhotoStore.instance.hasPhotos('없는-id'), isFalse);
    });

    test('파일이 실제로 없으면 전부 없는 것으로 친다', () {
      // 한 장이라도 사라지면 page 인덱스가 밀려 엉뚱한 사진에 그려진다.
      RegistryPhotoStore.instance.register('r1', [
        '/tmp/사라진_1.jpg',
        '/tmp/사라진_2.jpg',
      ]);
      expect(RegistryPhotoStore.instance.pathsFor('r1'), isEmpty);
      expect(RegistryPhotoStore.instance.hasPhotos('r1'), isFalse);
    });
  });
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
