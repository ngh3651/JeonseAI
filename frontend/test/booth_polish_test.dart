/// 결선 부스 다듬기 (2026-10-23) — 리뷰 3개(디자인·지수·서연)에서 나온 "고장/가짜처럼 보이는 것".
///
///   ① 리포트 PDF로 저장 (2026-10-29, 글자 요약 공유를 대신함 — 이름은 기본으로 가림, 사진은 넣지 않음)
///   ② 오래된 리포트 — 맨 위 배너 없이 '뗀 지 N일' 한 줄 (2026-10-30)
///   ③ 근거 카드의 [시세 입력하기]는 숫자를 고칠 수 있을 때만 (서버 재료 또는 폰 사진 — 누를 수 없는 버튼을 두지 않는다)
///   ④ 앱 어디에도 "곧 제공되는 기능" 문구가 없다
///   ⑤ 부스 모드 — 앱 버전 줄 7번 연속 탭으로 켜고 끔, 켜면 로그아웃·회원 탈퇴·기록 지우기를 숨긴다
///   ⑥ '다시 뗀 등기부를 올려 주세요' 시트에서 막히지 않게 — [아직 안 뗐어요 — 떼는 법 보기] → 발급 가이드
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/auth_repository.dart';
import 'package:jeonse_ai/screens/my/account_section.dart';
import 'package:jeonse_ai/screens/my/app_version_line.dart';
import 'package:jeonse_ai/screens/journey/journey_actions.dart';
import 'package:jeonse_ai/screens/my/my_screen.dart';
import 'package:jeonse_ai/screens/my/my_settings.dart';
import 'package:jeonse_ai/screens/report/report_screen.dart';
import 'package:jeonse_ai/screens/report/report_inputs_sheet.dart';
import 'package:jeonse_ai/services/kakao_login_gateway.dart';
import 'package:jeonse_ai/services/session_credentials.dart';
import 'package:jeonse_ai/services/session_storage.dart';
import 'package:jeonse_ai/state/app_session.dart';
import 'package:jeonse_ai/state/booth_mode.dart';
import 'package:jeonse_ai/state/privacy_settings.dart';
import 'package:jeonse_ai/state/registry_photo_store.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneHeight, kPhoneWidth;

Future<void> _pumpReport(WidgetTester tester, String reportId) async {
  tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AnalysisRepository>(
      create: (_) => DummyAnalysisRepository(),
      child: MaterialApp(
        theme: buildAppTheme(),
        home: ReportScreen(reportId: reportId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => RegistryPhotoStore.instance.clear());
  tearDown(() {
    RegistryPhotoStore.instance.clear();
    PrivacySettings.instance.resetForTest();
  });

  // ① 리포트 PDF로 저장 — 2026-11-01에 기능을 뺐다(쓰지 않고 구성도 아쉬웠다, 규혁). 버튼이 없는지만 본다.
  testWidgets('① 리포트 위에 PDF 버튼이 없다 — 시계 · 수정만', (tester) async {
    await _pumpReport(tester, 'dummy-danger');
    expect(find.byKey(const ValueKey('report-pdf-button')), findsNothing);
    expect(find.byKey(const ValueKey('report-history-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('report-edit-button')), findsOneWidget);
  });

  testWidgets('② 오래된 리포트에 맨 위 배너를 끼우지 않는다 — 등기부를 뗀 지 며칠인지만 한 줄로', (tester) async {
    await _pumpReport(tester, 'dummy-danger'); // 7일 전 분석 · 등기부 2026.07.09
    expect(find.koText('다시 떼서 대조'), findsNothing);
    expect(find.koText('재분석'), findsNothing);
    expect(find.koTextContaining('결과예요'), findsNothing);
    // 2026-10-31 결론 카드: "N일 전에 뗀 등기부예요" 줄 대신 홈 집 카드와 같은 시계 칩 "N일 전"
    expect(find.byKey(const ValueKey('report-registry-date')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('report-registry-date')),
        matching: find.koTextContaining('일 전'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('③ [시세 입력하기]는 사진이 이 폰에 있을 때만 그린다 (누를 수 없는 버튼을 두지 않는다)', (
    tester,
  ) async {
    // 시세 카드 하나뿐인 리포트
    final report = AnalysisReport(
      id: 'r-price',
      alias: '샘플빌라',
      address: '서울특별시 샘플구 샘플동 1-1',
      analyzedAt: DateTime.now(),
      grade: RiskGrade.caution,
      headline: '확인이 필요해요',
      nextAction: '시세를 넣어 보세요',
      topRiskSummary: '전세가율',
      deposit: 120000000,
      marketPrice: null,
      seniorDebtAmount: 0,
      gaugeProgress: 0.5,
      evidences: const [
        EvidenceItem(
          id: 'jeonse_ratio',
          title: '보증금이 집값에 비해 높지 않나요?',
          termSubtitle: '전세가율',
          grade: RiskGrade.caution,
          statusLabel: '확인 필요',
          easyExplanation: '시세를 몰라 비율을 계산하지 못했어요.',
          actionLabel: '시세 입력하기',
        ),
      ],
    );
    Future<void> pump() async {
      tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AnalysisRepository>(
          create: (_) => _OneReport(report),
          child: MaterialApp(
            theme: buildAppTheme(),
            home: ReportScreen(reportId: report.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pump();
    expect(
      find.koText('시세 입력하기', skipOffstage: false),
      findsNothing,
      reason: '사진이 없으면 다시 분석할 수 없다',
    );

    final tmp = Directory.systemTemp.createTempSync('booth_polish');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final photo = (File('${tmp.path}/p.png')..writeAsBytesSync(const [0])).path;
    RegistryPhotoStore.instance.register(report.id, [photo]);
    await tester.pumpWidget(const SizedBox.shrink());
    await pump();
    // 근거는 처음에 접혀 있다(2026-10-30) — 눌러 펼친다
    await tester.tap(find.koText('보증금이 집값에 비해 높지 않나요?'));
    await tester.pumpAndSettle();
    final button = find.koText('시세 입력하기', skipOffstage: false);
    expect(button, findsOneWidget);

    // 누르면 입력값 고치기 시트의 시세 칸이 열린다(2026-10-29 — 같은 리포트를 고친다)
    await tester.scrollUntilVisible(
      find.koText('시세 입력하기'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.koText('시세 입력하기'));
    await tester.pumpAndSettle();
    expect(find.koText('정보 수정'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('inputs-price-field')),
      '30000',
    );
    await tester.pumpAndSettle();
    expect(find.koText('저장하고 다시 판정'), findsOneWidget);
    Navigator.of(tester.element(find.byType(ReportInputsSheet))).pop();
    await tester.pumpAndSettle();
  });

  test('④ 앱 어디에도 "곧 제공되는 기능" 문구가 없다', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.readAsStringSync().contains('곧 제공되는 기능'))
        offenders.add(entity.path);
    }
    expect(offenders, isEmpty, reason: '누르면 "곧 제공"만 뜨는 버튼은 부스에서 고장처럼 보인다');
  });

  group('⑤ 부스 모드', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SessionCredentials.instance.resetForTest();
      BoothMode.instance.resetForTest();
      PackageInfo.setMockInitialValues(
        appName: '전세AI프',
        packageName: 'com.jeonseai.jeonse_ai',
        version: '1.0.0',
        buildNumber: '42',
        buildSignature: '',
      );
    });
    tearDown(() => BoothMode.instance.resetForTest());

    test('7번 연속이어야 켜진다 — 쉬었다 누르면 처음부터 센다', () async {
      final booth = BoothMode.instance;
      final t0 = DateTime(2026, 11, 3, 10);
      for (int i = 0; i < 6; i++) {
        expect(
          await booth.registerTap(now: t0.add(Duration(milliseconds: 300 * i))),
          isNull,
        );
      }
      // 3초 쉬고 누르면 1번째부터 다시
      expect(
        await booth.registerTap(now: t0.add(const Duration(seconds: 5))),
        isNull,
      );
      expect(booth.on, isFalse);
      for (int i = 1; i < 6; i++) {
        expect(
          await booth.registerTap(
            now: t0.add(Duration(seconds: 5, milliseconds: 300 * i)),
          ),
          isNull,
        );
      }
      expect(
        await booth.registerTap(now: t0.add(const Duration(seconds: 7))),
        isTrue,
      );
      expect(booth.on, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(BoothMode.prefsKey), isTrue, reason: '폰에만 저장');
    });

    Future<AppSession> loggedIn() async {
      final session = AppSession(
        storage: MemorySessionStorage(
          SavedSession(
            token: 'session-token-booth',
            expiresAt: DateTime.utc(2099, 1, 1),
            customerKey: 'acct_0123456789abcdef0123456789abcdef01234567',
          ),
        ),
        kakao: _FakeKakao(),
        auth: _FakeAuth(),
        kakaoEnabled: true,
      );
      await session.restore(now: DateTime.utc(2026, 11, 3));
      expect(session.isLoggedIn, isTrue);
      return session;
    }

    testWidgets('버전 줄을 7번 누르면 로그아웃·회원 탈퇴를 숨기고(토스트), 다시 7번이면 되돌린다', (
      tester,
    ) async {
      final session = await loggedIn();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppSession>.value(
          value: session,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: ListView(
                children: const [
                  AccountSection(),
                  PolicySettingsRows(),
                  AccountSettingsRows(),
                  AppVersionLine(),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.koText('앱 버전 1.0.0 (빌드 42)'), findsOneWidget);
      expect(find.koText('로그아웃'), findsOneWidget);
      expect(find.koText('회원 탈퇴'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('app-version-line'))).height,
        greaterThanOrEqualTo(48),
      );

      for (int i = 0; i < BoothMode.tapsToToggle; i++) {
        await tester.tap(find.byKey(const ValueKey('app-version-line')));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(BoothMode.instance.on, isTrue);
      expect(find.koText(kBoothModeOnMessage), findsOneWidget);
      expect(find.koText('로그아웃'), findsNothing);
      expect(find.koText('회원 탈퇴'), findsNothing);
      expect(find.koText('앱 버전 1.0.0 (빌드 42) · 부스 모드'), findsOneWidget);
      // 그 밖의 동작은 그대로 — 처리방침은 그대로 열 수 있다
      expect(find.koText('개인정보 처리방침'), findsOneWidget);

      for (int i = 0; i < BoothMode.tapsToToggle; i++) {
        await tester.tap(find.byKey(const ValueKey('app-version-line')));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(BoothMode.instance.on, isFalse);
      expect(find.koText('로그아웃'), findsOneWidget);
      expect(find.koText('회원 탈퇴'), findsOneWidget);
    });

    testWidgets('부스 모드에서는 분석 이력의 [삭제]도 숨긴다', (tester) async {
      tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final session = await loggedIn();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppSession>.value(value: session),
            ChangeNotifierProvider<AnalysisRepository>(
              create: (_) => DummyAnalysisRepository(),
            ),
          ],
          child: MaterialApp(theme: buildAppTheme(), home: const MyScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('삭제'), findsWidgets);

      BoothMode.instance.resetForTest(on: true);
      await tester.pumpAndSettle();
      expect(find.byTooltip('삭제'), findsNothing);
    });
  });

  testWidgets(
    '⑥ 사진 시트 — 촬영·갤러리 두 가지뿐, 인터넷등기소·700원·PDF 안내는 없다 (2026-10-26 시안)',
    (tester) async {
      List<String>? picked;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async =>
                      picked = await pickRegistryPhotos(context),
                  child: const Text('사진 올리기'),
                ),
              ),
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('사진 올리기'));
      await tester.pumpAndSettle();

      expect(find.koText(kComparePhotoSheetTitle), findsOneWidget);
      expect(find.koText(kCompareShootLabel), findsOneWidget);
      expect(find.koText(kCompareGalleryLabel), findsOneWidget);
      expect(find.textContaining('700원'), findsNothing);
      expect(find.textContaining('PDF'), findsNothing);
      // [나중에 할게요] — 시트만 닫는다
      await tester.tap(find.koText(kCompareLaterLabel));
      await tester.pumpAndSettle();
      expect(find.koText(kComparePhotoSheetTitle), findsNothing);
      expect(picked, isEmpty);
    },
  );
}

class _OneReport extends DummyAnalysisRepository {
  _OneReport(this.report);

  final AnalysisReport report;

  @override
  Future<AnalysisReport?> getReport(String id) async =>
      id == report.id ? report : null;
}

class _FakeKakao implements KakaoLoginGateway {
  @override
  Future<String> login() async => 'kakao-token';

  @override
  Future<void> logout() async {}

  @override
  Future<void> unlink() async {}
}

class _FakeAuth implements AuthRepository {
  @override
  Future<MeStatus> setDisplayName(String name) async => MeStatus(
    loggedIn: true,
    displayName: name.trim().isEmpty ? null : name.trim(),
  );

  @override
  Future<SavedSession> loginWithKakao(String kakaoAccessToken) async =>
      SavedSession(
        token: 'session-token-booth',
        expiresAt: DateTime.utc(2099, 1, 1),
        customerKey: 'acct_0123456789abcdef0123456789abcdef01234567',
      );

  @override
  Future<MeStatus> me() async => const MeStatus(loggedIn: true);

  @override
  Future<void> logout(String sessionToken) async {}

  @override
  Future<void> deleteAccount() async {}
}
