/// 장별 재촬영 안내 (P1-1, 2026-10-22) — "몇 쪽이 왜 문제인지 + 그 장만 다시 찍어 바꾼 뒤 다시 보내기".
///
/// 서버는 사진 품질이 심하게 나쁘면 분석 전에 400 + `captureCheck`로 거절하고(크레딧 0원),
/// 가벼우면 분석한 뒤 리포트에 `captureCheck`를 싣는다(api-contract §9.9). 여기서 못 박는 것:
/// 1. 400 본문의 `captureCheck`를 [ApiException]이 읽는다
/// 2. 로딩 화면은 실패 화면 대신 **촬영 화면으로 돌아가** 장별 안내를 띄운다
/// 3. [그 장만 다시 찍기] → 그 자리만 바뀌고 나머지 장·순서는 그대로 → 다시 보내면 바뀐 사진이 간다
/// 4. 리포트에 '확인 필요' 장이 있으면 같은 안내 + [다시 찍어 새로 분석]
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeonse_ai/design_system/components/photo_tray.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/screens/loading/analysis_loading_screen.dart';
import 'package:jeonse_ai/screens/report/report_screen.dart';
import 'package:jeonse_ai/screens/search/capture_issue_panel.dart';
import 'package:jeonse_ai/screens/search/capture_loop_route.dart';
import 'package:jeonse_ai/screens/search/property_search_screen.dart';
import 'package:jeonse_ai/services/api_client.dart';
import 'package:jeonse_ai/state/registry_photo_store.dart';
import 'package:provider/provider.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneHeight, kPhoneWidth;

/// 1x1 PNG — Image.file이 디코드할 수 있는 진짜 파일.
final List<int> _onePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

const CaptureCheck _rejected = CaptureCheck(
  ok: false,
  pages: [
    CapturePageIssue(
      index: 1,
      issues: ['blurry'],
      severe: true,
      tip: '글자 테두리가 번져 있어요. 휴대폰을 종이와 나란히 들고 초점을 맞춘 뒤 찍어 주세요.',
    ),
  ],
);

const String _rejectMessage = '2쪽이 흐려요 — 다시 찍어 주세요 (글자 테두리가 번져 있어요)';

/// 분석을 부르면 정해진 순서로 답하는 가짜 저장소. 받은 요청을 기록한다.
class _ScriptedRepository extends AnalysisRepository {
  _ScriptedRepository(this.script);

  /// 차례대로 던지거나(ApiException) 돌려준다(AnalysisReport).
  final List<Object> script;
  final List<AnalysisRequest> requests = [];

  @override
  Future<AnalysisReport> analyze(AnalysisRequest request) async {
    requests.add(request);
    final next = script.removeAt(0);
    if (next is ApiException) throw next;
    return next as AnalysisReport;
  }

  @override
  Future<List<AnalysisReport>> getHistory() async => const [];

  @override
  Future<AnalysisReport?> getReport(String id) async => null;

  @override
  Future<void> deleteReport(String id) async {}

  @override
  Future<CompareResult> compareRegistry(String reportId, List<String> imagePaths) =>
      throw UnimplementedError();
}

AnalysisReport _report({String id = 'r-new', CaptureCheck? capture}) => AnalysisReport(
  id: id,
  alias: '샘플빌라',
  address: '서울특별시 샘플구 샘플동 1-1',
  analyzedAt: DateTime(2026, 10, 22),
  grade: RiskGrade.caution,
  headline: '확인이 필요해요',
  nextAction: '확인하세요',
  topRiskSummary: '선순위 채권',
  deposit: 120000000,
  marketPrice: null,
  seniorDebtAmount: 0,
  gaugeProgress: 0.5,
  evidences: const [],
  captureCheck: capture,
);

void main() {
  late Directory tmp;
  late List<String> original;
  late List<String> retakes;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('capture_retake_test');
    original = [
      for (var i = 0; i < 3; i++)
        (File('${tmp.path}/orig_$i.png')..writeAsBytesSync(_onePixelPng)).path,
    ];
    retakes = [
      for (var i = 0; i < 3; i++)
        (File('${tmp.path}/retake_$i.png')..writeAsBytesSync(_onePixelPng)).path,
    ];
    RegistryPhotoStore.instance.clear();
  });

  tearDown(() {
    RegistryPhotoStore.instance.clear();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('계약 — 400 본문의 captureCheck를 읽는다', () {
    test('사진 품질 거절이면 서버 문구 그대로 + 장별 안내', () {
      final e = apiExceptionFor(400, _rejectMessage, captureCheck: _rejected);
      expect(e.message, _rejectMessage);
      expect(e.statusCode, 400);
      expect(e.needsAppUpdate, isFalse);
      expect(e.captureCheck?.pages.single.index, 1);
    });

    test('리포트 JSON의 captureCheck를 읽고, 없으면 null', () {
      final base = <String, dynamic>{
        'id': 'r',
        'alias': 'a',
        'address': 'ad',
        'analyzedAt': '2026-10-22T10:00:00+09:00',
        'grade': '확인 필요',
        'headline': 'h',
        'nextAction': 'n',
        'topRiskSummary': 't',
        'deposit': 1,
        'seniorDebtAmount': 0,
        'gaugeProgress': 0.5,
        'evidences': <dynamic>[],
      };
      expect(AnalysisReport.fromJson(base).captureCheck, isNull);
      final json = jsonDecode(jsonEncode({
        ...base,
        'captureCheck': {
          'ok': false,
          'pages': [
            {'index': 0, 'issues': ['cut_off'], 'severe': false, 'tip': '맨 아래 쪽 번호가 안 보여요.'},
          ],
        },
      })) as Map<String, dynamic>;
      final check = AnalysisReport.fromJson(json).captureCheck!;
      expect(check.ok, isFalse);
      expect(check.issueFor(0)?.shortLabel, '잘림');
      expect(check.issueFor(1), isNull);
    });

    test('짧은 이름은 먼저 고칠 것 하나', () {
      expect(const CapturePageIssue(index: 0, issues: ['cut_off', 'blurry']).shortLabel, '흐림');
      expect(const CapturePageIssue(index: 0, issues: ['too_dark']).shortLabel, '어두움');
      expect(const CapturePageIssue(index: 0, issues: ['이상한값']).shortLabel, '확인 필요');
    });
  });

  group('촬영 루프 — 그 장만 바꾸기 모드', () {
    testWidgets('한 장만 찍고, 주 버튼이 [이 사진으로 바꾸기]다', (tester) async {
      CaptureLoopResult? got;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  got = await Navigator.of(context).push(
                    MaterialPageRoute<CaptureLoopResult>(
                      builder: (_) => CaptureLoopRoute(
                        alreadyTaken: 3,
                        maxPhotos: 3, // 꽉 찼어도 바꾸기는 된다
                        captureOne: () async => retakes.first,
                        replacePage: 1,
                        replaceTip: '글자 테두리가 번져 있어요.',
                      ),
                    ),
                  );
                },
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();

      expect(find.koText('2쪽을 새로 찍었어요'), findsOneWidget);
      expect(find.koText('글자 테두리가 번져 있어요.'), findsOneWidget);
      expect(find.koText('이 사진으로 바꾸기'), findsOneWidget);
      expect(find.koText('다음 장 찍기'), findsNothing);

      await tester.tap(find.koText('이 사진으로 바꾸기'));
      await tester.pumpAndSettle();
      expect(got?.newPaths, [retakes.first]);
    });

    testWidgets('[바꾸지 않기]면 아무것도 바꾸지 않는다', (tester) async {
      CaptureLoopResult? got;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  got = await Navigator.of(context).push(
                    MaterialPageRoute<CaptureLoopResult>(
                      builder: (_) => CaptureLoopRoute(
                        alreadyTaken: 3,
                        maxPhotos: 10,
                        captureOne: () async => retakes.first,
                        replacePage: 0,
                      ),
                    ),
                  );
                },
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('바꾸지 않기'));
      await tester.pumpAndSettle();
      expect(got?.newPaths, isEmpty);
    });
  });

  group('촬영 화면 — 거절 → 그 장만 바꾸기 → 다시 보내기', () {
    Future<_ScriptedRepository> pumpFlow(WidgetTester tester, List<Object> script) async {
      tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final repo = _ScriptedRepository(script);
      var gallery = 0;
      final router = GoRouter(
        initialLocation: '/analyze',
        routes: [
          GoRoute(path: '/home', builder: (_, _) => const Scaffold(body: Text('홈'))),
          GoRoute(
            path: '/analyze',
            builder: (_, _) => PropertySearchScreen(
              captureOne: () async => retakes[1],
              pickMany: () async => gallery++ == 0 ? List.of(original) : const [],
            ),
          ),
          GoRoute(
            path: '/loading',
            builder: (_, state) => AnalysisLoadingScreen(request: state.extra! as AnalysisRequest),
          ),
          GoRoute(
            path: '/report/:id',
            builder: (_, state) => Scaffold(body: Text('리포트 ${state.pathParameters['id']}')),
          ),
        ],
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AnalysisRepository>.value(
          value: repo,
          child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // 갤러리에서 3장 → 보증금 → 분석하기
      await tester.tap(find.koText('갤러리에서 고르기'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '12000');
      await tester.pumpAndSettle();
      await tester.tap(find.koText('분석하기'));
      // 로딩 화면은 최소 2.6초 연출을 기다린다
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      return repo;
    }

    testWidgets('거절되면 실패 화면 대신 촬영 화면에서 몇 쪽이 왜인지 보여 준다', (tester) async {
      final repo = await pumpFlow(tester, [
        ApiException(_rejectMessage, statusCode: 400, captureCheck: _rejected),
      ]);

      expect(find.byType(PropertySearchScreen), findsOneWidget, reason: '촬영 화면으로 돌아왔다');
      expect(find.koText('분석을 진행하지 못했어요'), findsNothing, reason: '실패 화면이 아니다');
      expect(find.byType(CaptureIssuePanel), findsOneWidget);
      expect(find.koText('사진을 다시 찍어야 분석할 수 있어요'), findsOneWidget);
      expect(find.koTextContaining(_rejectMessage), findsOneWidget);
      expect(find.koTextContaining('크레딧이 들지 않았어요'), findsOneWidget);
      expect(find.koText('2쪽 · 흐림'), findsOneWidget);
      expect(find.koText('2쪽 이 장만 다시 찍기'), findsOneWidget);
      // 트레이의 2번째 장에 표시
      expect(find.byKey(const ValueKey('photo-tray-issue-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('photo-tray-issue-0')), findsNothing);
      expect(repo.requests.single.imagePaths, original);
    });

    testWidgets('그 장만 다시 찍어 바꾸고, 다시 보내면 바뀐 장만 다르다', (tester) async {
      final repo = await pumpFlow(tester, [
        ApiException(_rejectMessage, statusCode: 400, captureCheck: _rejected),
        _report(),
      ]);

      await tester.tap(find.koText('2쪽 이 장만 다시 찍기'));
      await tester.pumpAndSettle();
      expect(find.koText('2쪽을 새로 찍었어요'), findsOneWidget);
      await tester.tap(find.koText('이 사진으로 바꾸기'));
      await tester.pumpAndSettle();

      // 바꾼 뒤: 트레이 표시가 사라지고, 다시 보내라는 안내
      expect(find.byKey(const ValueKey('photo-tray-issue-1')), findsNothing);
      expect(find.koText('바꿔 찍었어요 — 아래 [분석하기]로 다시 보내 주세요'), findsOneWidget);
      final tray = tester.widget<PhotoTray>(find.byType(PhotoTray));
      expect(tray.paths, [original[0], retakes[1], original[2]]);

      await tester.tap(find.koText('분석하기'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(repo.requests, hasLength(2));
      expect(repo.requests.last.imagePaths, [original[0], retakes[1], original[2]]);
      expect(repo.requests.last.deposit, 120000000);
      expect(find.koText('리포트 r-new'), findsOneWidget);
    });

    testWidgets('사진 순서를 바꾸면 "몇 쪽" 안내가 어긋나므로 접는다', (tester) async {
      await pumpFlow(tester, [
        ApiException(_rejectMessage, statusCode: 400, captureCheck: _rejected),
      ]);
      expect(find.byType(CaptureIssuePanel), findsOneWidget);
      tester.widget<PhotoTray>(find.byType(PhotoTray)).onReorder(0, 2);
      await tester.pumpAndSettle();
      expect(find.byType(CaptureIssuePanel), findsNothing);
    });

    testWidgets('사진 품질과 무관한 400은 예전처럼 실패 화면 (사진 다시 고르기)', (tester) async {
      await pumpFlow(tester, [
        const ApiException('요약본은 분석할 수 없어요', statusCode: 400),
      ]);
      expect(find.koText('분석을 진행하지 못했어요'), findsOneWidget);
      expect(find.koText('사진 다시 고르기'), findsOneWidget);
    });
  });

  group('리포트 — 가벼운 문제(확인 필요)', () {
    Future<void> pumpReport(WidgetTester tester, AnalysisReport report, {List<String>? photos}) async {
      tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      if (photos != null) RegistryPhotoStore.instance.register(report.id, photos);
      final repo = _OneReport(report);
      await tester.pumpWidget(
        ChangeNotifierProvider<AnalysisRepository>.value(
          value: repo,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: ReportScreen(reportId: report.id, captureOne: () async => retakes[0]),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    const soft = CaptureCheck(
      ok: false,
      pages: [
        CapturePageIssue(index: 2, issues: ['cut_off'], tip: '맨 아래 쪽 번호(예: 1/5)가 보이지 않아요. 네 모서리가 나오게 찍어 주세요.'),
      ],
    );

    testWidgets('문제가 있는 장을 알리고, 사진이 있으면 [다시 찍어 새로 분석]', (tester) async {
      await pumpReport(tester, _report(id: 'r1', capture: soft), photos: original);
      expect(find.koText('사진 확인이 필요한 장이 있어요'), findsOneWidget);
      expect(find.koText('3쪽 · 잘림 (확인 필요)'), findsOneWidget);
      expect(find.koTextContaining('네 모서리'), findsOneWidget);
      expect(find.koText('3쪽 다시 찍어 새로 분석'), findsOneWidget);
    });

    testWidgets('사진이 폰에 없으면 안내만 (버튼 없음)', (tester) async {
      await pumpReport(tester, _report(id: 'r2', capture: soft));
      expect(find.koText('사진 확인이 필요한 장이 있어요'), findsOneWidget);
      expect(find.koText('3쪽 다시 찍어 새로 분석'), findsNothing);
    });

    testWidgets('문제가 없으면 아무것도 안 그린다', (tester) async {
      await pumpReport(tester, _report(id: 'r3', capture: const CaptureCheck()));
      expect(find.byType(CaptureIssuePanel), findsNothing);
      await pumpReport(tester, _report(id: 'r4'));
      expect(find.byType(CaptureIssuePanel), findsNothing);
    });
  });
}

class _OneReport extends AnalysisRepository {
  _OneReport(this.report);

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
