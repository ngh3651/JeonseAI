/// 분석 중 [중단] = 결과 버리기 (2026-10-29 규혁 결정 — 크레딧 아끼는 쪽).
///
/// 지키는 것:
/// 1. [중단]을 누르면 보내던 분석 요청을 **끊는다**(`abortTrigger`) — 서버가 남은 IE·OCR·Solar를 건너뛴다.
/// 2. 끊었는데도 응답이 뒤늦게 오면 **버린다** — 폰 원본 보관·대신한 리포트 정리(replaces)·홈 갱신 알림 없음.
/// 3. 로딩 화면은 중단 뒤 늦게 온 답으로 리포트를 열지 않는다.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/api_analysis_repository.dart';
import 'package:jeonse_ai/screens/loading/analysis_loading_screen.dart';
import 'package:jeonse_ai/services/api_client.dart';
import 'package:jeonse_ai/services/device_id.dart';
import 'package:jeonse_ai/services/registry_upload_service.dart';
import 'package:jeonse_ai/state/registry_photo_store.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';

Map<String, dynamic> _reportJson(String id) => {
  'id': id,
  'alias': '샘플빌라',
  'address': '서울특별시 샘플구 샘플로 1',
  'analyzedAt': '2026-10-29T10:00:00+09:00',
  'grade': '확인 필요',
  'headline': '확인이 필요해요',
  'nextAction': '직접 확인',
  'topRiskSummary': '예시',
  'deposit': 120000000,
  'marketPrice': null,
  'seniorDebtAmount': 0,
  'gaugeProgress': 0.5,
  'evidences': <Object>[],
};

/// 답을 [gate]가 열릴 때까지 붙잡는 서버. [honorAbort]면 진짜 http 클라이언트처럼 끊기 신호를 받으면 바로 끊긴다.
class _SlowServer extends http.BaseClient {
  _SlowServer({required this.honorAbort});

  final bool honorAbort;
  final Completer<void> gate = Completer<void>();
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final trigger = request is http.Abortable ? request.abortTrigger : null;
    if (request.method == 'POST') {
      if (honorAbort && trigger != null) {
        var aborted = false;
        await Future.any([gate.future, trigger.then((_) => aborted = true)]);
        if (aborted) throw http.RequestAbortedException(request.url);
      } else {
        await gate.future;
      }
      return _json(_reportJson('r-new'));
    }
    return _json({'detail': '없어요'}, status: 404); // GET /api/reports/old — 대신한 리포트 확인
  }

  http.StreamedResponse _json(Object body, {int status = 200}) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(body))),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
}

/// 변환 없이 그 파일을 그대로 보낸다 — 위젯 테스트에는 이미지 변환 플러그인이 없다.
class _PassThroughUploader extends RegistryUploadService {
  @override
  Future<File?> convertToJpeg(String sourcePath, {String tag = ''}) async =>
      File(sourcePath);
}

void main() {
  group('저장소 — 끊고, 늦은 답은 버린다', () {
    late Directory temp;
    late String photo;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      DeviceId.instance.resetForTest();
      RegistryPhotoStore.instance.clear();
      temp = await Directory.systemTemp.createTemp('analysis_cancel');
      RegistryPhotoStore.rootForTest = () async =>
          Directory('${temp.path}/registry_photos');
      photo = (File(
        '${temp.path}/sent_1.jpg',
      )..writeAsBytesSync(const [0xFF, 0xD8, 0xFF, 0xD9])).path;
    });

    tearDown(() async {
      RegistryPhotoStore.rootForTest = null;
      RegistryPhotoStore.instance.clear();
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    Future<void> untilSent(_SlowServer server) async {
      for (var i = 0; i < 100 && server.requests.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(server.requests, isNotEmpty, reason: '분석 요청이 나가지 않았다');
    }

    const request = AnalysisRequest(
      imagePaths: [],
      deposit: 120000000,
      replacesReportId: 'old',
    );

    test('[중단]하면 보내던 요청을 끊는다 — 응답을 기다리지 않고 바로 끝난다', () async {
      final server = _SlowServer(honorAbort: true);
      final repo = ApiAnalysisRepository(
        client: ApiClient(client: server),
        uploader: _PassThroughUploader(),
      );
      var notified = 0;
      repo.addListener(() => notified++);
      final cancel = AnalysisCancelToken();

      final result = repo.analyzeCancellable(
        AnalysisRequest(
          imagePaths: [photo],
          deposit: request.deposit,
          replacesReportId: request.replacesReportId,
        ),
        cancel,
      );
      await untilSent(server);
      final sent = server.requests.single;
      expect(
        sent is http.Abortable && sent.abortTrigger != null,
        isTrue,
        reason: '끊을 수 있는 요청으로 보낸다',
      );

      cancel.cancel();
      await expectLater(result, throwsA(isA<AnalysisCancelledException>()));
      expect(server.gate.isCompleted, isFalse, reason: '서버 답을 기다리지 않았다');
      expect(server.requests, hasLength(1), reason: '대신한 리포트 확인(GET)도 안 한다');
      expect(notified, 0);
      repo.dispose();
    });

    test('끊었는데 답이 뒤늦게 오면 버린다 — 폰 저장·replaces 정리·홈 갱신 없음', () async {
      final server = _SlowServer(honorAbort: false); // 이미 오고 있던 답처럼 끊기 신호를 무시한다
      final repo = ApiAnalysisRepository(
        client: ApiClient(client: server),
        uploader: _PassThroughUploader(),
      );
      var notified = 0;
      repo.addListener(() => notified++);
      final cancel = AnalysisCancelToken();

      final result = repo.analyzeCancellable(
        AnalysisRequest(
          imagePaths: [photo],
          deposit: request.deposit,
          replacesReportId: request.replacesReportId,
        ),
        cancel,
      );
      await untilSent(server);
      cancel.cancel();
      server.gate.complete(); // 늦게 온 답

      await expectLater(result, throwsA(isA<AnalysisCancelledException>()));
      expect(await RegistryPhotoStore.instance.originalReport('r-new'), isNull);
      expect(RegistryPhotoStore.instance.hasPhotos('r-new'), isFalse);
      expect(
        server.requests.map((r) => r.method),
        ['POST'],
        reason: '대신한 리포트 정리(GET /api/reports/old)를 하지 않는다',
      );
      expect(notified, 0, reason: '홈·여정 목록을 다시 읽게 하지 않는다');
      repo.dispose();
    });

    test('중단하지 않으면 지금과 같다 — 폰에 남기고 알린다', () async {
      final server = _SlowServer(honorAbort: true);
      final repo = ApiAnalysisRepository(
        client: ApiClient(client: server),
        uploader: _PassThroughUploader(),
      );
      var notified = 0;
      repo.addListener(() => notified++);

      final result = repo.analyzeCancellable(
        AnalysisRequest(imagePaths: [photo], deposit: 120000000),
        AnalysisCancelToken(),
      );
      await untilSent(server);
      server.gate.complete();

      expect((await result).id, 'r-new');
      expect(RegistryPhotoStore.instance.hasPhotos('r-new'), isTrue);
      expect(notified, 1);
      repo.dispose();
    });
  });

  group('로딩 화면 — [중단] 뒤 늦게 온 답은 무시', () {
    testWidgets('중단 확인 → 요청 끊기 표시 · 검색 화면으로 · 늦은 답으로 리포트를 열지 않는다', (
      tester,
    ) async {
      final repo = _LateRepo();
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: TextButton(
                onPressed: () => context.push('/loading'),
                child: const Text('검색 화면'),
              ),
            ),
          ),
          GoRoute(
            path: '/loading',
            builder: (_, _) => const AnalysisLoadingScreen(
              request: AnalysisRequest(imagePaths: ['p0'], deposit: 1),
            ),
          ),
          GoRoute(
            path: '/home',
            builder: (_, _) => const Scaffold(body: Text('홈')),
          ),
          GoRoute(
            path: '/report/:id',
            builder: (_, s) =>
                Scaffold(body: Text('리포트 ${s.pathParameters['id']}')),
          ),
        ],
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AnalysisRepository>.value(
          value: repo,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('검색 화면'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(repo.token, isNotNull);

      // 시스템 뒤로 → 확인 창 (문구가 사실과 맞다: 결과를 버리니 처음부터 다시 해야 한다)
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.koText('분석을 중단할까요?'), findsOneWidget);
      expect(find.koText('처음부터 다시 해야 해요'), findsOneWidget);
      await tester.tap(find.koText('중단'));
      await tester.pump(const Duration(milliseconds: 500));

      expect(repo.token!.isCancelled, isTrue, reason: '보내던 요청을 끊는다');
      expect(find.text('검색 화면'), findsOneWidget);

      // 늦게 온 답
      repo.answer.complete(_report('r-late'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('리포트 r-late'), findsNothing);
      expect(find.text('홈'), findsNothing);
      expect(find.text('검색 화면'), findsOneWidget);
    });
  });
}

AnalysisReport _report(String id) => AnalysisReport(
  id: id,
  alias: '샘플빌라',
  address: '서울특별시 샘플구 샘플로 1',
  analyzedAt: DateTime(2026, 10, 29),
  grade: RiskGrade.caution,
  headline: '확인이 필요해요',
  nextAction: '직접 확인',
  topRiskSummary: '예시',
  deposit: 1,
  marketPrice: null,
  seniorDebtAmount: 0,
  gaugeProgress: 0.5,
  evidences: const [],
);

/// 답을 붙잡아 두고, 로딩 화면이 넘긴 중단 표시를 들고 있는 저장소 (기본 [analyzeCancellable] 그대로 씀)
class _LateRepo extends AnalysisRepository {
  final Completer<AnalysisReport> answer = Completer<AnalysisReport>();
  AnalysisCancelToken? token;

  @override
  Future<AnalysisReport> analyze(AnalysisRequest request) => answer.future;

  @override
  Future<AnalysisReport> analyzeCancellable(
    AnalysisRequest request,
    AnalysisCancelToken cancel,
  ) {
    token = cancel;
    return super.analyzeCancellable(request, cancel);
  }

  @override
  Future<List<AnalysisReport>> getHistory() async => const [];

  @override
  Future<AnalysisReport?> getReport(String id) async => null;

  @override
  Future<void> deleteReport(String id) async {}

  @override
  Future<CompareResult> compareRegistry(
    String reportId,
    List<String> imagePaths,
  ) => Completer<CompareResult>().future;
}
