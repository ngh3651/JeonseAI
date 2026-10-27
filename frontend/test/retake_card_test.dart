/// 리포트 — 다시 올리기 안내 카드 (2026-10-27 다시찍기_안내_시안 ①·②).
///
///   ① 1장: "1쪽이 잘 안 읽혔어요" + 알약 "1쪽 아래가 잘림" + [다시 찍기][갤러리에서 고르기]
///   ② 여러 장: "2장이 잘 안 읽혔어요" + 알약 여러 개(넘치면 다음 줄)
///   ③ 빠진 쪽: "1쪽 빠짐" 알약 · 긴 설명·쪽마다 버튼은 없다
///   ④ 360 폭에서 버튼 두 개가 나란히, 글자 130%에서도 넘치지 않는다(넘치면 위아래로)
///   ⑤ [다시 찍기] → 알약 순서대로 찍고 → 같은 보증금·별칭으로 새로 분석
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/screens/report/report_screen.dart';
import 'package:jeonse_ai/screens/report/retake_notice_card.dart';
import 'package:jeonse_ai/state/registry_photo_store.dart';
import 'package:provider/provider.dart';

import 'support/ko_finders.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

AnalysisReport _report({
  String id = 'r1',
  CaptureCheck? capture,
  List<int> missing = const [],
  List<int?> pageNumbers = const [],
}) => AnalysisReport(
  id: id,
  alias: '우리 집 2',
  address: '서울특별시 서초구 서초동 1557-8',
  analyzedAt: DateTime(2026, 10, 27),
  grade: RiskGrade.caution,
  headline: '확인이 필요해요',
  nextAction: '확인하세요',
  topRiskSummary: '선순위 채권',
  deposit: 200000000,
  marketPrice: null,
  seniorDebtAmount: 0,
  gaugeProgress: 0.5,
  evidences: const [],
  captureCheck: capture,
  missingPages: missing,
  pageNumbers: pageNumbers,
);

class _Repo extends AnalysisRepository {
  _Repo(this.report);
  final AnalysisReport report;

  @override
  Future<AnalysisReport> analyze(AnalysisRequest request) async => report;
  @override
  Future<List<AnalysisReport>> getHistory() async => [report];
  @override
  Future<AnalysisReport?> getReport(String id) async => report;
  @override
  Future<void> deleteReport(String id) async {}
  @override
  Future<CompareResult> compareRegistry(String reportId, List<String> imagePaths) =>
      throw UnimplementedError();
}

const _cut1 = CapturePageIssue(index: 0, issues: ['cut_off'], tip: '맨 아래 쪽 번호가 보이지 않아요');
const _blur2 = CapturePageIssue(index: 2, issues: ['blurry'], tip: '글자 테두리가 번져 있어요');

void main() {
  // 실제 앱 글꼴(Pretendard)로 잰다 — 테스트 기본 글꼴은 글자마다 1em이라 실제보다 훨씬 넓다
  setUpAll(() async {
    final loader = FontLoader('Pretendard');
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Pretendard-$w.otf'));
    }
    await loader.load();
  });

  late Directory tmp;
  late List<String> photos;
  late String newShot;
  final sent = <AnalysisRequest>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('retake_card_test');
    photos = [
      for (var i = 0; i < 3; i++) (File('${tmp.path}/p$i.png')..writeAsBytesSync(_png)).path,
    ];
    newShot = (File('${tmp.path}/new.png')..writeAsBytesSync(_png)).path;
    sent.clear();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> pump(
    WidgetTester tester,
    AnalysisReport report, {
    bool withPhotos = true,
    double width = 360,
    double textScale = 1.0,
    List<String> gallery = const [],
  }) async {
    tester.view.physicalSize = Size(width * 3, 1600 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    if (withPhotos) RegistryPhotoStore.instance.register(report.id, photos);
    final router = GoRouter(
      initialLocation: '/report/${report.id}',
      routes: [
        GoRoute(
          path: '/report/:id',
          builder: (_, s) => ReportScreen(
            reportId: s.pathParameters['id']!,
            captureOne: () async => newShot,
            pickMany: () async => gallery,
          ),
        ),
        GoRoute(
          path: '/loading',
          builder: (_, s) {
            sent.add(s.extra! as AnalysisRequest);
            return const Scaffold(body: Text('분석 중'));
          },
        ),
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AnalysisRepository>.value(
        value: _Repo(report),
        child: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 1600),
            textScaler: TextScaler.linear(textScale),
          ),
          child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('① 1장 — 제목·부제·알약 하나·버튼 두 개, 긴 설명은 없다', (tester) async {
    await pump(
      tester,
      _report(capture: const CaptureCheck(ok: false, pages: [_cut1]), pageNumbers: [1, 2, 3]),
    );
    expect(find.koText('1쪽이 잘 안 읽혔어요'), findsOneWidget);
    expect(find.koText(kRetakeSubtitle), findsOneWidget);
    expect(find.byKey(const ValueKey('retake-pill-1')), findsOneWidget);
    expect(find.koTextContaining('아래가 잘림'), findsOneWidget);
    expect(find.byKey(const ValueKey('retake-shoot')), findsOneWidget);
    expect(find.byKey(const ValueKey('retake-gallery')), findsOneWidget);
    expect(find.koTextContaining('결과가 달라질 수 있어요'), findsNothing);
    expect(find.koTextContaining('다시 찍으면 더 정확해요'), findsNothing);
    expect(find.koTextContaining('네 모서리'), findsNothing, reason: '찍는 요령은 촬영 화면에만');
    expect(find.koText('1쪽 다시 찍기'), findsNothing, reason: '쪽마다 버튼 없음');
  });

  testWidgets('② 여러 장 — "2장이 잘 안 읽혔어요" · 쪽 번호는 문서 쪽 번호', (tester) async {
    // 2·3·4쪽만 올렸다: 업로드 0번 = 2쪽, 2번 = 4쪽
    await pump(
      tester,
      _report(capture: const CaptureCheck(ok: false, pages: [_cut1, _blur2]), pageNumbers: [2, 3, 4]),
    );
    expect(find.koText('2장이 잘 안 읽혔어요'), findsOneWidget);
    expect(find.byKey(const ValueKey('retake-pill-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('retake-pill-4')), findsOneWidget);
  });

  testWidgets('③ 빠진 쪽 — "1쪽 빠짐" · 잘 안 읽힌 장과 섞이면 "N장을 다시 올려 주세요"', (tester) async {
    await pump(tester, _report(missing: const [1, 5], pageNumbers: [2, 3, 4]));
    expect(find.koText('2장이 빠졌어요'), findsOneWidget);
    expect(find.byKey(const ValueKey('retake-pill-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('retake-pill-5')), findsOneWidget);
    expect(find.koTextContaining('빠짐'), findsNWidgets(2));
  });

  testWidgets('알약이 많으면 다음 줄로 넘어가고 깨지지 않는다', (tester) async {
    await pump(
      tester,
      _report(
        capture: const CaptureCheck(ok: false, pages: [_cut1, _blur2]),
        missing: const [4, 5, 6, 7],
        pageNumbers: [1, 2, 3],
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.koText('6장을 다시 올려 주세요'), findsOneWidget);
    final first = tester.getRect(find.byKey(const ValueKey('retake-pill-1')));
    final last = tester.getRect(find.byKey(const ValueKey('retake-pill-7')));
    expect(last.top, greaterThan(first.top), reason: '다음 줄로 넘어감');
  });

  testWidgets('④ 360 폭이면 두 버튼이 나란히 · 130%에서도 넘치지 않는다', (tester) async {
    await pump(tester, _report(capture: const CaptureCheck(ok: false, pages: [_cut1])));
    var shoot = tester.getRect(find.byKey(const ValueKey('retake-shoot')));
    var gallery = tester.getRect(find.byKey(const ValueKey('retake-gallery')));
    expect(shoot.top, gallery.top, reason: '나란히');
    expect(shoot.width, closeTo(gallery.width, 0.5), reason: '같은 폭');

    await pump(tester, _report(id: 'r2', capture: const CaptureCheck(ok: false, pages: [_cut1])), textScale: 1.3);
    expect(tester.takeException(), isNull);
    shoot = tester.getRect(find.byKey(const ValueKey('retake-shoot')));
    gallery = tester.getRect(find.byKey(const ValueKey('retake-gallery')));
    final galleryText = tester.getRect(find.koText(kRetakeGalleryLabel));
    expect(galleryText.right, lessThanOrEqualTo(gallery.right + 0.5), reason: '글자가 버튼 밖으로 안 나감');
  });

  testWidgets('문제가 없으면 카드가 없다', (tester) async {
    await pump(tester, _report(capture: const CaptureCheck()));
    expect(find.byKey(const ValueKey('retake-card')), findsNothing);
  });

  testWidgets('⑤ [다시 찍기] → 그 장을 바꾸고 같은 보증금·별칭으로 새로 분석', (tester) async {
    await pump(tester, _report(capture: const CaptureCheck(ok: false, pages: [_blur2]), pageNumbers: [1, 2, 3]));
    await tester.tap(find.byKey(const ValueKey('retake-shoot')));
    await tester.pumpAndSettle();
    expect(find.koTextContaining('아까 사진: 글자 테두리가 번져 있어요'), findsOneWidget, reason: '요령은 촬영 화면에 한 줄');
    await tester.tap(find.koText('이 사진으로 바꾸기'));
    await tester.pumpAndSettle();
    expect(sent.single.imagePaths, [photos[0], photos[1], newShot]);
    expect(sent.single.deposit, 200000000);
    expect(sent.single.alias, '우리 집 2');
  });

  testWidgets('⑤ 빠진 쪽은 더해서 보낸다', (tester) async {
    await pump(tester, _report(missing: const [4], pageNumbers: [1, 2, 3]));
    await tester.tap(find.byKey(const ValueKey('retake-shoot')));
    await tester.pumpAndSettle();
    expect(find.koTextContaining('빠진 4쪽을 찍어 주세요'), findsOneWidget);
    await tester.tap(find.koText('완료 · 4장'));
    await tester.pumpAndSettle();
    expect(sent.single.imagePaths, [...photos, newShot]);
  });

  testWidgets('⑤ [갤러리에서 고르기] → 고른 사진을 알약 순서대로 끼운다', (tester) async {
    await pump(
      tester,
      _report(capture: const CaptureCheck(ok: false, pages: [_cut1]), missing: const [4], pageNumbers: [1, 2, 3]),
      gallery: [newShot, newShot],
    );
    await tester.tap(find.byKey(const ValueKey('retake-gallery')));
    await tester.pumpAndSettle();
    expect(sent.single.imagePaths, [newShot, photos[1], photos[2], newShot]);
  });
}
