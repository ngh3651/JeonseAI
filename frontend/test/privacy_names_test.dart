/// 화면엔 실명, 서버엔 가린 사본 — 앱 쪽 (2026-10-22 규혁 결정 "폰엔 원본, 서버엔 가린 사본").
///
/// 지키는 것:
/// 1. 이름 가리기 규칙이 **서버와 같다**(첫 글자 + 나머지 ○, 긴 이름부터, 주소·등급 칸은 그대로).
/// 2. '사진 속 이름 가리기'가 켜지면 리포트 JSON을 모델로 바꾸는 **한 곳**(`AnalysisReport.fromJson`)에서
///    모든 글자의 `personNames`를 가린다. 스위치를 바꾸면 열려 있는 화면도 바로 바뀐다.
/// 3. **폰 원본 보관**: 리포트를 열 때(기록 목록·같은 사진 캐시 적중 포함) 이 폰의 원본(실명)을 서버 사본보다
///    먼저 쓴다. 캐시 적중이면 원본 + 새 별칭. 기록을 지우면 폰 사본도 지운다.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/api_analysis_repository.dart';
import 'package:jeonse_ai/screens/report/registry_viewer_screen.dart';
import 'package:jeonse_ai/services/api_client.dart';
import 'package:jeonse_ai/services/device_id.dart';
import 'package:jeonse_ai/services/registry_upload_service.dart';
import 'package:jeonse_ai/state/privacy_settings.dart';
import 'package:jeonse_ai/state/registry_photo_store.dart';
import 'package:jeonse_ai/utils/name_mask.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart';

/// 서버 응답 모양의 리포트 JSON. [owner]가 집주인 이름 표시 제목에 들어간다(실명 또는 가린 꼴).
Map<String, dynamic> reportJson({
  String id = 'r1',
  String owner = '홍길동',
  String alias = '홍길동 아저씨 집',
  String address = '서울특별시 샘플구 샘플로 1',
  List<String>? personNames,
}) => {
  'id': id,
  'alias': alias,
  'address': address,
  'analyzedAt': '2026-10-22T10:00:00+09:00',
  'grade': '확인 필요',
  'gaugeProgress': 0.5,
  'headline': '확인이 필요해요',
  'nextAction': '집주인 $owner 씨 신분증을 확인하세요',
  'topRiskSummary': '선순위 채권',
  'deposit': 120000000,
  'marketPrice': null,
  'seniorDebtAmount': 36000000,
  'evidences': [
    {
      'id': 'senior_debt',
      'title': '선순위 채권',
      'termSubtitle': '먼저 받아 가는 빚',
      'grade': '확인 필요',
      'easyExplanation': '근저당권자 주식회사하나은행, 채무자 $owner',
    },
  ],
  'highlights': [
    {
      'id': 'owner-1',
      'page': 0,
      'kind': 'owner',
      'badge': 1,
      'box': {'x': 0.5, 'y': 0.3, 'w': 0.2, 'h': 0.02},
      'title': '집주인 이름 · $owner',
      'body': '계약 자리에 나온 사람의 신분증이 이 이름과 같은지 확인하세요.',
    },
  ],
  'checkedNotes': ['집주인 이름 1곳 — 사진에서 찾아 표시했어요'],
  'privacyMasks': [
    {'page': 0, 'x': 0.5, 'y': 0.3, 'w': 0.2, 'h': 0.02},
  ],
  'privacyMasksReady': true,
  'personNames': personNames ?? [owner],
};

/// 서버 기록 사본(가린 이름) — 캐시 적중·기록 API가 돌려주는 모양.
Map<String, dynamic> storedCopy({String id = 'r1', String alias = '홍○○ 아저씨 집'}) =>
    reportJson(id: id, owner: '홍○○', alias: alias, personNames: const ['홍○○']);

/// 변환 없이 그 파일을 그대로 보낸다 — 위젯 테스트에는 이미지 변환 플러그인이 없다.
class _PassThroughUploader extends RegistryUploadService {
  @override
  Future<File?> convertToJpeg(String sourcePath, {String tag = ''}) async => File(sourcePath);
}

http.Response _json(Object body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PrivacySettings.instance.resetForTest();
  });

  tearDown(() => PrivacySettings.instance.resetForTest());

  group('이름 가리기 규칙 — 서버와 같다', () {
    test('첫 글자 + 나머지 ○ (띄어 쓴 이름은 공백까지 센다)', () {
      expect(maskPersonName('홍길동'), '홍○○');
      expect(maskPersonName('남궁민수'), '남○○○');
      expect(maskPersonName('홍 길동'), '홍○○○');
      expect(maskPersonName('김'), '김');
      expect(maskPersonName(''), '(이름없음)');
    });

    test('긴 이름부터 바꾼다 — 짧은 이름이 긴 이름 일부를 먼저 먹지 않게', () {
      expect(maskNamesInText('김철수와 철수', ['철수', '김철수']), '김○○와 철○');
    });

    test('리포트 JSON의 모든 글자에서 가리고, 주소·등급은 그대로 둔다', () {
      final source = reportJson(address: '서울특별시 샘플구 홍길동로 1');
      final masked = maskNamesInReportJson(source);
      final text = jsonEncode({...masked, 'address': ''});
      expect(text, isNot(contains('홍길동')));
      expect(masked['alias'], '홍○○ 아저씨 집');
      expect((masked['highlights'] as List).single['title'], '집주인 이름 · 홍○○');
      expect((masked['evidences'] as List).single['easyExplanation'], '근저당권자 주식회사하나은행, 채무자 홍○○');
      expect(masked['address'], '서울특별시 샘플구 홍길동로 1'); // 주소는 이름 칸이 아니다
      expect(masked['grade'], '확인 필요');
      expect(source['alias'], '홍길동 아저씨 집', reason: '원본 JSON은 바뀌지 않는다(깊은 사본)');
      expect((source['highlights'] as List).single['title'], '집주인 이름 · 홍길동');
    });

    test('이름 목록이 없으면(옛 서버·옛 기록) 그대로 — 그때는 서버가 이미 가렸다', () {
      final old = reportJson()..remove('personNames');
      expect(identical(maskNamesInReportJson(old), old), isTrue);
    });
  });

  group('모델로 바꾸는 한 곳 — AnalysisReport.fromJson', () {
    test('끄면(기본) 실명 그대로 — 실제 만난 계약자와 맞춰 본다', () {
      final report = AnalysisReport.fromJson(reportJson());
      expect(report.highlights.single.title, '집주인 이름 · 홍길동');
      expect(report.personNames, ['홍길동']);
      expect(report.namesHidden, isFalse);
    });

    test('켜면 화면의 모든 글자에서 사람 이름을 가린다 — 회사·은행 이름은 그대로', () async {
      await PrivacySettings.instance.setHideNamesInPhotos(true);
      final report = AnalysisReport.fromJson(reportJson());
      expect(report.highlights.single.title, '집주인 이름 · 홍○○');
      expect(report.alias, '홍○○ 아저씨 집');
      expect(report.nextAction, '집주인 홍○○ 씨 신분증을 확인하세요');
      expect(report.evidences.single.easyExplanation, contains('주식회사하나은행'));
      expect(report.evidences.single.grade, RiskGrade.caution);
      expect(report.namesHidden, isTrue);
    });

    test('스위치를 바꾸면 같은 원본에서 다시 만든다 (열려 있는 화면이 부른다)', () async {
      final shown = AnalysisReport.fromJson(reportJson());
      await PrivacySettings.instance.setHideNamesInPhotos(true);
      final hidden = shown.withCurrentPrivacy();
      expect(hidden.highlights.single.title, '집주인 이름 · 홍○○');
      expect(identical(shown.withCurrentPrivacy(), hidden), isTrue, reason: '다시 그릴 때마다 새로 만들지 않는다');
      await PrivacySettings.instance.setHideNamesInPhotos(false);
      expect(identical(shown.withCurrentPrivacy(), shown), isTrue);
    });

    test('스위치를 바꾸면 저장소가 알린다 — 목록 화면(홈·여정·마이)이 다시 읽는다', () async {
      final repo = FakeAnalysisRepository(buildFixtureReport());
      var notified = 0;
      repo.addListener(() => notified++);
      await PrivacySettings.instance.setHideNamesInPhotos(true);
      expect(notified, 1);
      repo.dispose();
      // 버린 저장소에는 더 알리지 않는다(버린 뒤 알리면 오류)
      await PrivacySettings.instance.setHideNamesInPhotos(false);
    });
  });

  group('폰 원본 보관 — 서버 사본보다 먼저', () {
    late Directory temp;
    late String photo;
    late List<http.Request> calls;

    setUp(() async {
      DeviceId.instance.resetForTest();
      RegistryPhotoStore.instance.clear();
      temp = await Directory.systemTemp.createTemp('phone_originals');
      RegistryPhotoStore.rootForTest = () async => Directory('${temp.path}/registry_photos');
      photo = (File('${temp.path}/sent_1.jpg')..writeAsBytesSync(const [0xFF, 0xD8, 0xFF, 0xD9])).path;
      calls = [];
    });

    tearDown(() async {
      RegistryPhotoStore.rootForTest = null;
      RegistryPhotoStore.instance.clear();
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    ApiAnalysisRepository repoWith(Future<http.Response> Function(http.Request request) server) =>
        ApiAnalysisRepository(
          client: ApiClient(
            client: MockClient((request) async {
              calls.add(request);
              return server(request);
            }),
          ),
          uploader: _PassThroughUploader(),
        );

    test('새 분석 응답(실명)을 이 폰에 원본으로 남긴다', () async {
      final repo = repoWith((_) async => _json(reportJson()));
      final report = await repo.analyze(AnalysisRequest(imagePaths: [photo], deposit: 120000000));
      expect(report.highlights.single.title, '집주인 이름 · 홍길동');
      final saved = await RegistryPhotoStore.instance.originalReport('r1');
      expect(jsonEncode(saved), contains('집주인 이름 · 홍길동'));
      expect(RegistryPhotoStore.instance.hasPhotos('r1'), isTrue);
    });

    test('같은 사진 캐시 적중(서버는 가린 사본) — 폰 원본을 쓰고 별칭만 새 것으로', () async {
      await RegistryPhotoStore.instance.keep('r1', [photo], reportJson: jsonEncode(reportJson(alias: '첫 별칭')));
      final repo = repoWith((_) async => _json(storedCopy(alias: '새 별칭')));
      final report = await repo.analyze(AnalysisRequest(imagePaths: [photo], deposit: 120000000, alias: '새 별칭'));
      expect(report.alias, '새 별칭');
      expect(report.highlights.single.title, '집주인 이름 · 홍길동');
      final saved = await RegistryPhotoStore.instance.originalReport('r1');
      expect(saved!['alias'], '새 별칭');
      expect((saved['highlights'] as List).single['title'], '집주인 이름 · 홍길동');
    });

    test('리포트를 열 때 폰 원본이 있으면 서버에 묻지도 않는다 — 없으면 서버 사본(가린 이름)', () async {
      await RegistryPhotoStore.instance.keep('r1', [photo], reportJson: jsonEncode(reportJson()));
      final repo = repoWith((request) async => _json(storedCopy(id: request.url.pathSegments.last)));
      final mine = await repo.getReport('r1');
      expect(mine!.highlights.single.title, '집주인 이름 · 홍길동');
      expect(calls, isEmpty);
      final other = await repo.getReport('r2');
      expect(other!.highlights.single.title, '집주인 이름 · 홍○○');
      expect(calls.single.url.path, '/api/reports/r2');
    });

    test('기록 목록도 폰 원본으로 바꿔 끼운다 (순서는 서버 목록 그대로)', () async {
      await RegistryPhotoStore.instance.keep('r1', [photo], reportJson: jsonEncode(reportJson()));
      final repo = repoWith((_) async => _json([storedCopy(id: 'r2'), storedCopy(id: 'r1')]));
      final history = await repo.getHistory();
      expect([for (final r in history) r.id], ['r2', 'r1']);
      expect(history[0].highlights.single.title, '집주인 이름 · 홍○○');
      expect(history[1].highlights.single.title, '집주인 이름 · 홍길동');
    });

    test('기록을 지우면 이 폰의 사진·원본 리포트도 지운다', () async {
      await RegistryPhotoStore.instance.keep('r1', [photo], reportJson: jsonEncode(reportJson()));
      final repo = repoWith((_) async => http.Response('', 204));
      await repo.deleteReport('r1');
      expect(calls.single.method, 'DELETE');
      expect(await RegistryPhotoStore.instance.originalReport('r1'), isNull);
      expect(RegistryPhotoStore.instance.hasPhotos('r1'), isFalse);
      expect(Directory('${temp.path}/registry_photos/r1').existsSync(), isFalse);
    });

    test('예시 리포트(403)처럼 서버가 지우지 않으면 폰 사본도 그대로 둔다', () async {
      await RegistryPhotoStore.instance.keep('r1', [photo], reportJson: jsonEncode(reportJson()));
      final repo = repoWith((_) async => _json({'detail': '예시 리포트는 지울 수 없어요'}, status: 403));
      await expectLater(repo.deleteReport('r1'), throwsA(isA<ApiException>()));
      expect(await RegistryPhotoStore.instance.originalReport('r1'), isNotNull);
    });
  });

  group('열려 있는 뷰어 — 스위치를 켜면 글자도 바로', () {
    late Directory temp;

    setUp(() async {
      RegistryPhotoStore.instance.clear();
      temp = await Directory.systemTemp.createTemp('privacy_names_viewer');
      RegistryPhotoStore.instance.register('r1', await writeFixturePhotos(temp, count: 1));
    });

    tearDown(() async {
      RegistryPhotoStore.instance.clear();
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    testWidgets('별칭·표시 제목 속 이름이 홍○○로 바뀌고, 끄면 다시 보인다', (tester) async {
      final repo = FakeAnalysisRepository(AnalysisReport.fromJson(reportJson()));
      tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AnalysisRepository>.value(
          value: repo,
          child: const MaterialApp(home: RegistryViewerScreen(reportId: 'r1')),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.koTextContaining('홍길동'), findsWidgets);
      expect(find.koTextContaining('홍○○'), findsNothing);

      await PrivacySettings.instance.setHideNamesInPhotos(true);
      await tester.pump();
      expect(find.koTextContaining('홍길동'), findsNothing);
      expect(find.koTextContaining('홍○○'), findsWidgets);

      await PrivacySettings.instance.setHideNamesInPhotos(false);
      await tester.pump();
      expect(find.koTextContaining('홍길동'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
