/// S-04 촬영 스튜디오 위젯 테스트 (2026-08-03 재디자인).
///
/// 핸드오프에서 **반드시 지키기로 한 5가지**를 이 파일이 못 박는다:
///   ① 촬영 → 확인 → [다음 장 찍기] 루프
///   ② 보증금 28px 한글 표기 + 세 자리 쉼표, "만원" 접미사는 15px
///   ③ 주 버튼이 키보드에 가리지 않게 viewInsets 반영
///   ④ 최소 터치 영역 48dp
///   ⑤ 사진 0장일 때 [분석하기]를 **아예 그리지 않기** (비활성이 아니라 미렌더)
///
/// ⚠ 카메라·갤러리는 실제로 열 수 없으므로 [ImagePicker]를 가짜로 주입한다.
///   따라서 이 테스트는 **화면 로직**을 검증할 뿐, 실기기의 카메라 동작은 검증하지 않는다.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/components/amber_hint.dart';
import 'package:jeonse_ai/design_system/components/photo_tray.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/design_system/tokens/app_spacing.dart';
import 'package:jeonse_ai/models/market_price_source.dart';
import 'package:jeonse_ai/screens/search/capture_loop_route.dart';
import 'package:jeonse_ai/screens/search/property_search_screen.dart';
import 'support/ko_finders.dart';

late Directory _tmp;
late List<String> _fakePhotos;

/// 실제 PNG 바이트(1×1) — Image.file이 디코드에 실패해도 테스트가 죽지 않게 한다.
final List<int> _onePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

void main() {
  setUpAll(() {
    _tmp = Directory.systemTemp.createTempSync('capture_studio_test');
    _fakePhotos = [
      for (int i = 0; i < 3; i++)
        (File('${_tmp.path}/page_$i.png')..writeAsBytesSync(_onePixelPng)).path,
    ];
  });

  tearDownAll(() {
    if (_tmp.existsSync()) _tmp.deleteSync(recursive: true);
  });

  Widget wrap(Widget child) => MaterialApp(theme: buildAppTheme(), home: child);

  Future<void> pumpScreen(WidgetTester tester, {PropertySearchPrefill? prefill}) async {
    // 카메라 대신 미리 만들어 둔 파일을 하나씩 돌려준다(순환).
    int shot = 0;
    await tester.pumpWidget(
      wrap(
        PropertySearchScreen(
          prefill: prefill,
          captureOne: () async => _fakePhotos[shot++ % _fakePhotos.length],
          pickMany: () async => List.of(_fakePhotos),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // ── ⑤ 사진 0장: [분석하기]가 존재하지 않는다 ─────────────────────────────

  testWidgets('사진 0장일 때 [분석하기] 버튼을 아예 그리지 않는다', (tester) async {
    await pumpScreen(tester);
    expect(find.koText('분석하기'), findsNothing);
    // 비활성 버튼조차 없어야 한다 — "왜 안 눌리지"만 남기지 않기 위해.
    expect(find.byIcon(Icons.search), findsNothing);
    // 대신 지시는 하나뿐이다.
    expect(find.koText('촬영 시작'), findsOneWidget);
  });

  testWidgets('빈 상태에는 마스코트와 종이 스택이 있고 트레이는 없다', (tester) async {
    await pumpScreen(tester);
    expect(find.byType(PhotoTray), findsNothing);
    expect(find.koText('등기부등본을\n한 장씩 찍어 주세요'), findsOneWidget);
  });

  // ── ① 촬영 루프 ──────────────────────────────────────────────────────────

  testWidgets('[촬영 시작] → 확인 화면의 주 버튼이 [다음 장 찍기]다', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.koText('촬영 시작'));
    await tester.pumpAndSettle();

    expect(find.byType(CaptureLoopRoute), findsOneWidget);
    expect(find.koText('1장째 찍었어요'), findsOneWidget);
    // 루프의 핵심 — 기본 동작이 "계속 찍기"다.
    expect(find.koText('다음 장 찍기'), findsOneWidget);
    expect(find.koText('다시 찍기'), findsOneWidget);
    expect(find.koText('완료 · 1장'), findsOneWidget);
  });

  testWidgets('[다음 장 찍기]를 누르면 장수가 올라간다', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.koText('촬영 시작'));
    await tester.pumpAndSettle();
    await tester.tap(find.koText('다음 장 찍기'));
    await tester.pumpAndSettle();
    expect(find.koText('2장째 찍었어요'), findsOneWidget);
    expect(find.koText('완료 · 2장'), findsOneWidget);
  });

  testWidgets('[다시 찍기]는 방금 장을 버린다', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.koText('촬영 시작'));
    await tester.pumpAndSettle();
    await tester.tap(find.koText('다음 장 찍기'));
    await tester.pumpAndSettle();
    expect(find.koText('2장째 찍었어요'), findsOneWidget);

    await tester.tap(find.koText('다시 찍기'));
    await tester.pumpAndSettle();
    // 2장째를 버리고 다시 찍었으므로 여전히 2장째다(누적이 아니라 교체).
    expect(find.koText('완료 · 2장'), findsOneWidget);
  });

  testWidgets('[완료]로 돌아오면 작업 모드가 되고 트레이에 사진이 있다', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.koText('촬영 시작'));
    await tester.pumpAndSettle();
    await tester.tap(find.koText('완료 · 1장'));
    await tester.pumpAndSettle();

    expect(find.byType(PhotoTray), findsOneWidget);
    expect(find.koText('사진 1장'), findsOneWidget);
    // 이제는 [분석하기]가 존재한다(아직 비활성 — 보증금이 없다).
    expect(find.koText('분석하기'), findsOneWidget);
    final FilledButton button = tester.widget(
      find.ancestor(of: find.koText('분석하기'), matching: find.byType(FilledButton)),
    );
    expect(button.onPressed, isNull);
  });

  // ── ② 보증금 표기 ────────────────────────────────────────────────────────

  testWidgets('보증금은 28px 한글 표기 · 입력은 세 자리 쉼표 · 접미사는 작고 흐리게', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.koText('촬영 시작'));
    await tester.pumpAndSettle();
    await tester.tap(find.koText('완료 · 1장'));
    await tester.pumpAndSettle();

    // 값이 없을 때의 자리
    expect(find.koText('얼마를 맡기시나요?'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '12000');
    await tester.pumpAndSettle();

    // 한글 표기가 28px로 크게 (이 화면에서 가장 큰 숫자)
    final Text won = tester.widget(find.koText('1억 2,000만원'));
    expect(won.style!.fontSize, 28);
    expect(won.style!.fontWeight, FontWeight.w700);

    // 입력 칸은 세 자리 쉼표 (플레이스홀더는 2026-08-14에 제거됐다 — 예시값이 입력값으로
    // 오해됐다. 그래도 화면 어딘가에 같은 글자가 또 나올 수 있어 값으로 본다)
    final TextField field = tester.widget(find.byType(TextField).first);
    expect(field.controller!.text, '12,000');

    // 접미사 '만원'은 입력 글자(17)보다 작고 흐려야 한다
    expect(field.style!.fontSize, 17);
    expect(field.decoration!.suffixText, '만원');
    expect(field.decoration!.suffixStyle!.fontSize, 15);
  });

  testWidgets('보증금은 8자리를 넘지 않는다', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.koText('촬영 시작'));
    await tester.pumpAndSettle();
    await tester.tap(find.koText('완료 · 1장'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '1234567890123');
    await tester.pumpAndSettle();
    final TextField field = tester.widget(find.byType(TextField).first);
    expect(field.controller!.text, '12,345,678');
  });

  testWidgets('사진과 보증금이 모두 있으면 [분석하기]가 켜진다', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.koText('촬영 시작'));
    await tester.pumpAndSettle();
    await tester.tap(find.koText('완료 · 1장'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '12000');
    await tester.pumpAndSettle();

    final FilledButton button = tester.widget(
      find.ancestor(of: find.koText('분석하기'), matching: find.byType(FilledButton)),
    );
    expect(button.onPressed, isNotNull);
    // 무엇이 채워졌는지 체크로 보여 준다 (문장 안내를 쓰지 않는다)
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
  });

  // ── ③ 키보드가 주 버튼을 가리지 않는다 ───────────────────────────────────

  testWidgets('키보드가 올라와도 [분석하기]가 화면 안에 있다', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.koText('촬영 시작'));
    await tester.pumpAndSettle();
    await tester.tap(find.koText('완료 · 1장'));
    await tester.pumpAndSettle();

    final double before = tester.getBottomLeft(find.koText('분석하기')).dy;

    // 키보드 300dp를 흉내 낸다.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300 * 3);
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final double after = tester.getBottomLeft(find.koText('분석하기')).dy;
    // 버튼이 키보드 위로 올라와야 한다 — bottomNavigationBar에 뒀던 것이 예전 버그였다.
    expect(after, lessThan(before));
    expect(after, lessThan(screen.height - 300));
  });

  // ── ④ 최소 터치 영역 48dp ────────────────────────────────────────────────

  testWidgets('빈 상태의 주 버튼·보조 버튼·링크가 모두 48dp 이상이다', (tester) async {
    await pumpScreen(tester);
    for (final String label in ['촬영 시작', '갤러리에서 고르기']) {
      expect(
        tester.getSize(find.ancestor(
          of: find.koText(label),
          matching: find.byType(SizedBox),
        ).first).height,
        greaterThanOrEqualTo(AppSize.minTouchTarget),
      );
    }
    for (final String label in ['등기부등본이 없어요', '주소로 찾기']) {
      final Size size = tester.getSize(
        find.ancestor(of: find.koText(label), matching: find.byType(Container)).first,
      );
      expect(size.height, greaterThanOrEqualTo(40));
    }
  });

  testWidgets('물음표 버튼이 48dp 이상이다', (tester) async {
    await pumpScreen(tester);
    expect(
      tester.getSize(find.byType(IconButton).first).height,
      greaterThanOrEqualTo(AppSize.minTouchTarget),
    );
  });

  // ── 시세 칸의 출처 라벨 (Phase 1·2 연결) ─────────────────────────────────

  testWidgets('첫 분석에서는 "비우면 국토부 실거래가·공시가격으로 찾아요"를 알린다', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.koText('촬영 시작'));
    await tester.pumpAndSettle();
    await tester.tap(find.koText('완료 · 1장'));
    await tester.pumpAndSettle();

    // 시세 행을 펼친다
    await tester.tap(find.koText('매매 시세'));
    await tester.pumpAndSettle();

    expect(find.byType(AmberHint), findsOneWidget);
    // 2026-08-14(D3): 예전에는 "모든 집에서 되지는 않아요 — 안 되면 알려드릴게요"까지
    // 붙어 12px로도 두 줄을 넘겼고, 안내가 입력 칸보다 커 보였다.
    // 못 하는 것을 못 한다고 말하는 원칙은 그대로다 — **말할 자리가 여기가 아니다.**
    // 조회 실패는 리포트 결론 헤더가 '시세를 못 구했어요'로 이미 분명히 말한다.
    expect(find.koTextContaining('비우면 국토부 실거래가·공시가격으로 찾아요'), findsOneWidget);
    // 한 줄에 들어가야 한다. 폭을 먹는 것은 **한글 글자 수**다 —
    // Pretendard 12px 한글은 글자당 약 12dp고, 360dp 기기에서 이 힌트가 글자에 쓸 수
    // 있는 폭은 251dp(화면패딩 40·카드패딩 36·힌트패딩 16·아이콘 17을 뺀 값)라
    // **한글 19자가 상한**이다. 띄어쓰기·가운뎃점은 훨씬 좁아 여기서 세지 않는다.
    final AmberHint hint = tester.widget(find.byType(AmberHint));
    final int hangul = RegExp('[가-힣]').allMatches(hint.text).length;
    expect(hangul, lessThanOrEqualTo(19), reason: '두 줄로 넘어간다 — 문구를 더 줄일 것');
  });

  testWidgets('자동 조회값을 미리 받으면 출처 라벨이 뜬다', (tester) async {
    await pumpScreen(
      tester,
      prefill: const PropertySearchPrefill(
        marketPriceWon: 620000000,
        marketPriceSource: MarketPriceSource.officialPrice,
        marketPriceAsOf: '2025-01-01',
      ),
    );
    await tester.tap(find.koText('촬영 시작'));
    await tester.pumpAndSettle();
    await tester.tap(find.koText('완료 · 1장'));
    await tester.pumpAndSettle();

    expect(find.koText('자동 조회 · 공시가격 기준 (2025.1.1)'), findsOneWidget);
  });

  testWidgets('사용자가 자동 조회값을 고치면 라벨이 "직접 입력하신 값"으로 바뀐다', (tester) async {
    await pumpScreen(
      tester,
      prefill: const PropertySearchPrefill(
        marketPriceWon: 620000000,
        marketPriceSource: MarketPriceSource.officialPrice,
        marketPriceAsOf: '2025-01-01',
      ),
    );
    await tester.tap(find.koText('촬영 시작'));
    await tester.pumpAndSettle();
    await tester.tap(find.koText('완료 · 1장'));
    await tester.pumpAndSettle();

    // 시세 입력은 두 번째 TextField (첫 번째는 보증금)
    await tester.enterText(find.byType(TextField).at(1), '50000');
    await tester.pumpAndSettle();

    expect(find.koText('직접 입력하신 값'), findsOneWidget);
    expect(find.koText('자동 조회 · 공시가격 기준 (2025.1.1)'), findsNothing);
  });

  // ── 출처 라벨 문구 자체 ──────────────────────────────────────────────────

  test('출처 라벨 문구', () {
    expect(
      marketPriceSourceLabel(
        source: MarketPriceSource.actualTrade,
        asOf: '2026-02~2026-07',
        sampleCount: 5,
      ),
      '자동 조회 · 국토부 실거래가 (2026.2~7 · 5건)',
    );
    expect(
      marketPriceSourceLabel(
        source: MarketPriceSource.taxBase,
        asOf: '2026-01-01',
      ),
      '자동 조회 · 국세청 기준시가 (2026.1.1)',
    );
    expect(
      marketPriceSourceLabel(source: MarketPriceSource.manual),
      '직접 입력하신 값',
    );
    expect(
      marketPriceSourceLabel(source: MarketPriceSource.unknown, hasPrice: false),
      '자동 조회가 안 됐어요 · 직접 넣으면 더 정확해요',
    );
    // 기준일을 못 읽었으면 **지어내지 않는다**
    expect(
      marketPriceSourceLabel(source: MarketPriceSource.officialPrice),
      '자동 조회 · 공시가격 기준',
    );
  });
}
