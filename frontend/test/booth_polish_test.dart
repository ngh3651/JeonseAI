/// 결선 부스 다듬기 (2026-10-23) — 리뷰 3개(디자인·지수·서연)에서 나온 "고장/가짜처럼 보이는 것".
///
///   ① 리포트 공유 = 글자 요약을 공유 창으로 (이름은 기본으로 가림) — "곧 제공" 가짜 버튼이 아니다
///   ② 오래된 리포트의 [재분석] → [다시 떼서 대조]
///   ③ 근거 카드의 [시세 입력하기]는 사진이 이 폰에 있을 때만 (누를 수 없는 버튼을 두지 않는다)
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
import 'package:jeonse_ai/screens/report/report_screen.dart';
import 'package:jeonse_ai/screens/report/report_share.dart';
import 'package:jeonse_ai/services/kakao_login_gateway.dart';
import 'package:jeonse_ai/services/session_credentials.dart';
import 'package:jeonse_ai/services/session_storage.dart';
import 'package:jeonse_ai/services/text_share.dart';
import 'package:jeonse_ai/state/app_session.dart';
import 'package:jeonse_ai/state/booth_mode.dart';
import 'package:jeonse_ai/state/registry_photo_store.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneHeight, kPhoneWidth;

AnalysisReport _shareReport({List<String> personNames = const ['홍길동']}) => AnalysisReport(
  id: 'r-share',
  alias: '샘플빌라',
  address: '서울특별시 샘플구 샘플동 1-1',
  analyzedAt: DateTime(2026, 10, 22, 10),
  grade: RiskGrade.danger,
  headline: '보증금을 지키기 어려울 수 있어요',
  nextAction: '상담부터 받으세요',
  topRiskSummary: '선순위 채권',
  deposit: 120000000,
  marketPrice: null,
  seniorDebtAmount: 0,
  gaugeProgress: 0.9,
  registryViewedAt: '2026.07.09',
  personNames: personNames,
  evidences: const [
    EvidenceItem(
      id: 'insurance',
      title: '보증보험에 가입할 수 있나요?',
      termSubtitle: '전세보증금 반환보증',
      grade: RiskGrade.ok,
      easyExplanation: '',
    ),
    EvidenceItem(
      id: 'senior_debt',
      title: '나보다 먼저 돈 받아갈 빚이 있나요?',
      termSubtitle: '선순위 채권',
      grade: RiskGrade.danger,
      easyExplanation: '',
    ),
    EvidenceItem(
      id: 'ownership',
      title: '집주인 홍길동 소유권에 이상 신호가 있나요?',
      termSubtitle: '압류',
      grade: RiskGrade.caution,
      easyExplanation: '',
    ),
    EvidenceItem(
      id: 'blacklist',
      title: '집주인이 위험 명단에 있나요?',
      termSubtitle: '악성임대인 공개 명단',
      grade: RiskGrade.caution,
      statusLabel: '명단 대조 아직 안 됨',
      easyExplanation: '',
    ),
  ],
);

Future<void> _pumpReport(WidgetTester tester, String reportId) async {
  tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AnalysisRepository>(
      create: (_) => DummyAnalysisRepository(),
      child: MaterialApp(theme: buildAppTheme(), home: ReportScreen(reportId: reportId)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => RegistryPhotoStore.instance.clear());
  tearDown(() {
    RegistryPhotoStore.instance.clear();
    TextShare.debugOverride(null);
  });

  group('① 리포트 요약 공유', () {
    test('정해진 한 줄 — 별칭·주소·분석일(등기부 발급일)·등급 결정·근거 2~3개·규칙 기반', () {
      final text = reportShareText(_shareReport());
      expect(
        text,
        '[전세AI프] 샘플빌라 · 서울특별시 샘플구 샘플동 1-1 · 2026.10.22 분석(등기부 2026.07.09) · '
        '위험: ${RiskGrade.danger.decisionLabel} · '
        '근거: 나보다 먼저 돈 받아갈 빚이 있나요?, 집주인 홍○○ 소유권에 이상 신호가 있나요?, 보증보험에 가입할 수 있나요? · '
        '규칙 기반 판정',
      );
    });

    test('사람 이름은 기본으로 가리고, 끄면 그대로 — 명단 미구축 카드는 근거에 넣지 않는다', () {
      expect(reportShareText(_shareReport()), isNot(contains('홍길동')));
      expect(reportShareText(_shareReport(), hideNames: false), contains('홍길동'));
      expect(reportShareText(_shareReport()), isNot(contains('위험 명단')));
    });

    test('등기부 발급일을 못 읽었으면 지어내지 않는다', () {
      final r = _shareReport();
      final noDate = AnalysisReport(
        id: r.id,
        alias: r.alias,
        address: r.address,
        analyzedAt: r.analyzedAt,
        grade: r.grade,
        headline: r.headline,
        nextAction: r.nextAction,
        topRiskSummary: r.topRiskSummary,
        deposit: r.deposit,
        marketPrice: null,
        seniorDebtAmount: 0,
        gaugeProgress: 0.5,
        evidences: const [],
      );
      expect(reportShareText(noDate), contains('2026.10.22 분석(등기부 발급일 확인 필요)'));
    });

    testWidgets('공유 버튼 → 보낼 글자를 먼저 보여 주고(이름 가리기 켬) → 공유 창', (tester) async {
      final sent = <String>[];
      TextShare.debugOverride((text, {subject}) async => sent.add(text));
      await _pumpReport(tester, 'dummy-danger');

      await tester.tap(find.byTooltip('리포트 요약 보내기'));
      await tester.pumpAndSettle();
      expect(find.koText('리포트 요약 보내기'), findsOneWidget);
      final Switch toggle = tester.widget(find.byType(Switch));
      expect(toggle.value, isTrue, reason: '이름 가리기는 기본으로 켠다');
      expect(find.byKey(const ValueKey('report-share-preview')), findsOneWidget);

      await tester.tap(find.koText('공유 창 열기'));
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
      expect(sent.single, startsWith('[전세AI프] 역삼동 오피스텔'));
      expect(sent.single, endsWith('규칙 기반 판정'));
      expect(find.koText('곧 제공되는 기능이에요'), findsNothing);
    });

    testWidgets('공유 창을 못 열면 복사해 두고 그렇게 말한다', (tester) async {
      TextShare.debugOverride((text, {subject}) async => throw Exception('공유 창 없음 흉내'));
      // 테스트에는 진짜 클립보드가 없다(부르면 답이 오지 않는다) — 복사한 글자를 붙잡는다
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await _pumpReport(tester, 'dummy-danger');
      await tester.tap(find.byTooltip('리포트 요약 보내기'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('공유 창 열기'));
      await tester.pumpAndSettle();
      expect(find.koTextContaining('복사해 뒀어요'), findsOneWidget);
      expect(copied, startsWith('[전세AI프] 역삼동 오피스텔'));
    });
  });

  testWidgets('② 오래된 리포트 배너의 버튼은 [다시 떼서 대조] (가짜 [재분석]이 아니다)', (tester) async {
    await _pumpReport(tester, 'dummy-danger'); // 7일 전 분석
    expect(find.koText('다시 떼서 대조'), findsOneWidget);
    expect(find.koText('재분석'), findsNothing);
    // TextButton.icon은 TextButton의 하위 타입이라 byType으로는 안 잡힌다 — `is`로 찾는다
    final Size size = tester.getSize(
      find.ancestor(
        of: find.koText('다시 떼서 대조'),
        matching: find.byWidgetPredicate((w) => w is TextButton),
      ).first,
    );
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('③ [시세 입력하기]는 사진이 이 폰에 있을 때만 그린다 (누를 수 없는 버튼을 두지 않는다)', (tester) async {
    // 시세 카드 하나뿐인 리포트 — 가장 심각한 카드라 처음부터 펼쳐져 있다
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
          child: MaterialApp(theme: buildAppTheme(), home: ReportScreen(reportId: report.id)),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pump();
    expect(find.koText('시세 입력하기', skipOffstage: false), findsNothing, reason: '사진이 없으면 다시 분석할 수 없다');

    final tmp = Directory.systemTemp.createTempSync('booth_polish');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final photo = (File('${tmp.path}/p.png')..writeAsBytesSync(const [0])).path;
    RegistryPhotoStore.instance.register(report.id, [photo]);
    await tester.pumpWidget(const SizedBox.shrink());
    await pump();
    final button = find.koText('시세 입력하기', skipOffstage: false);
    expect(button, findsOneWidget);

    // 누르면 시세를 묻는다(같은 사진·같은 보증금으로 새로 분석)
    await tester.scrollUntilVisible(find.koText('시세 입력하기'), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.koText('시세 입력하기'));
    await tester.pumpAndSettle();
    expect(find.koText('매매 시세를 넣어 다시 분석할까요?'), findsOneWidget);
    final TextButton go = tester.widget(
      find.ancestor(of: find.koText('다시 분석하기'), matching: find.byType(TextButton)),
    );
    expect(go.onPressed, isNull, reason: '값을 넣기 전에는 누를 수 없다');
    await tester.enterText(find.byKey(const ValueKey('market-price-field')), '30000');
    await tester.pumpAndSettle();
    final TextButton ready = tester.widget(
      find.ancestor(of: find.koText('다시 분석하기'), matching: find.byType(TextButton)),
    );
    expect(ready.onPressed, isNotNull);
    await tester.tap(find.koText('취소'));
    await tester.pumpAndSettle();
  });

  test('④ 앱 어디에도 "곧 제공되는 기능" 문구가 없다', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.readAsStringSync().contains('곧 제공되는 기능')) offenders.add(entity.path);
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
        expect(await booth.registerTap(now: t0.add(Duration(milliseconds: 300 * i))), isNull);
      }
      // 3초 쉬고 누르면 1번째부터 다시
      expect(await booth.registerTap(now: t0.add(const Duration(seconds: 5))), isNull);
      expect(booth.on, isFalse);
      for (int i = 1; i < 6; i++) {
        expect(await booth.registerTap(now: t0.add(Duration(seconds: 5, milliseconds: 300 * i))), isNull);
      }
      expect(await booth.registerTap(now: t0.add(const Duration(seconds: 7))), isTrue);
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

    testWidgets('버전 줄을 7번 누르면 로그아웃·회원 탈퇴를 숨기고(토스트), 다시 7번이면 되돌린다', (tester) async {
      final session = await loggedIn();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppSession>.value(
          value: session,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: ListView(children: const [AccountSection(), AppVersionLine()]),
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
      expect(find.koText('부스 모드라 로그아웃·회원 탈퇴는 숨겼어요'), findsOneWidget);
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
            ChangeNotifierProvider<AnalysisRepository>(create: (_) => DummyAnalysisRepository()),
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

  testWidgets('⑥ 사진 시트의 [아직 안 뗐어요 — 떼는 법 보기]는 발급 가이드로 간다 (사진은 고르지 않는다)', (tester) async {
    List<String>? picked;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => picked = await pickRegistryPhotos(context),
                child: const Text('사진 올리기'),
              ),
            ),
          ),
        ),
        GoRoute(path: '/guide', builder: (_, _) => const Scaffold(body: Text('발급 가이드 화면'))),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(theme: buildAppTheme(), routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.text('사진 올리기'));
    await tester.pumpAndSettle();

    expect(find.koText(kNotIssuedYetLabel), findsOneWidget);
    expect(kNotIssuedYetLabel, contains('700원'), reason: '앱에 이미 있는 금액(촬영 화면 발급 안내)만 쓴다');
    await tester.tap(find.koText(kNotIssuedYetLabel));
    await tester.pumpAndSettle();
    expect(find.text('발급 가이드 화면'), findsOneWidget);
    expect(picked, isEmpty);
  });
}

class _OneReport extends DummyAnalysisRepository {
  _OneReport(this.report);

  final AnalysisReport report;

  @override
  Future<AnalysisReport?> getReport(String id) async => id == report.id ? report : null;
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
  Future<SavedSession> loginWithKakao(String kakaoAccessToken) async => SavedSession(
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
