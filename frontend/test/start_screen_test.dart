/// 시작 화면 리디자인 (2026-10-26, 시안 A) — 앱 쪽에서 못 박는 것:
///
/// 1. 카카오 키 있음: [카카오로 시작하기] + 테두리 버튼 [로그인 없이 둘러보기] + 개인정보 처리방침.
/// 2. 카카오 키 없음: 카카오 버튼이 위젯 트리에 **없고**, 둘러보기가 꽉 찬 버튼(FilledButton).
/// 3. 로그인 중: 카카오 버튼에 기다림 표시, 둘러보기·링크는 누를 수 없다, 뒤로 가기 막힘.
/// 4. 반복 애니메이션(손 흔들기·반짝이)이 돌아도 오류·넘침 없음 — 작은 화면(360×640)도.
/// 5. 폰의 '애니메이션 제거' 설정이면 반복이 돌지 않는다.
/// 6. 아이디·비밀번호 입력칸이 없다.
///
/// 카카오 SDK·서버는 가짜다.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeonse_ai/repositories/auth_repository.dart';
import 'package:jeonse_ai/screens/auth/kakao_login_button.dart';
import 'package:jeonse_ai/screens/auth/start_screen.dart';
import 'package:jeonse_ai/services/device_id.dart';
import 'package:jeonse_ai/services/kakao_login_gateway.dart';
import 'package:jeonse_ai/services/session_credentials.dart';
import 'package:jeonse_ai/services/session_storage.dart';
import 'package:jeonse_ai/state/app_session.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';

/// 로그인이 [finish]를 부를 때까지 끝나지 않는 가짜 카카오 — '로그인 중' 화면을 본다.
class _SlowKakao implements KakaoLoginGateway {
  // 로그인할 때 만든다 — 테스트의 가짜 시간 안에서 만들어야 끝냈을 때 이어서 돈다
  Completer<String> pending = Completer<String>();
  int logins = 0;

  void finish() => pending.complete('kakao-access-token-1');

  @override
  Future<String> login() {
    logins++;
    pending = Completer<String>();
    return pending.future;
  }

  @override
  Future<void> logout() async {}

  @override
  Future<void> unlink() async {}
}

class _FakeAuth implements AuthRepository {
  @override
  Future<SavedSession> loginWithKakao(String kakaoAccessToken) async =>
      SavedSession(
        token: 'session-token-1',
        expiresAt: DateTime.utc(2099, 1, 1),
        customerKey: 'acct_0123456789abcdef0123456789abcdef01234567',
      );

  @override
  Future<MeStatus> me() async => const MeStatus(loggedIn: true);

  @override
  Future<MeStatus> setDisplayName(String name) async =>
      const MeStatus(loggedIn: true);

  @override
  Future<void> logout(String sessionToken) async {}

  @override
  Future<void> deleteAccount() async {}
}

Widget _app(AppSession session, {bool reduceMotion = false}) {
  final router = GoRouter(
    initialLocation: '/start',
    routes: [
      GoRoute(path: '/start', builder: (_, _) => const StartScreen()),
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('홈 화면')),
      ),
      GoRoute(
        path: '/privacy',
        builder: (_, _) => const Scaffold(body: Text('처리방침')),
      ),
    ],
  );
  return ChangeNotifierProvider<AppSession>.value(
    value: session,
    child: MaterialApp.router(
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
    ),
  );
}

void _phone(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _SlowKakao kakao;

  AppSession session({bool kakaoEnabled = true}) => AppSession(
    storage: MemorySessionStorage(),
    kakao: kakao,
    auth: _FakeAuth(),
    kakaoEnabled: kakaoEnabled,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceId.instance.resetForTest();
    SessionCredentials.instance.resetForTest();
    kakao = _SlowKakao();
    StartScreen.idleAnimations = null;
  });

  tearDown(() => StartScreen.idleAnimations = null);

  testWidgets('카카오 키 있음 — 카카오 버튼 + 테두리 둘러보기 + 링크, 입력칸 없음', (tester) async {
    _phone(tester, const Size(360, 800));
    await tester.pumpWidget(_app(session()));
    await tester.pumpAndSettle();
    expect(find.byType(KakaoLoginButton), findsOneWidget);
    expect(find.koText(KakaoLoginButton.label), findsOneWidget);
    expect(
      find.ancestor(
        of: find.koText(StartScreen.guestLabel),
        matching: find.byType(OutlinedButton),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.koText(StartScreen.privacyLabel),
        matching: find.byType(TextButton),
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(StartScreen.title), findsOneWidget);
    expect(find.koText(StartScreen.tagline), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('카카오 키 없음 — 카카오 버튼이 트리에 없고 둘러보기가 꽉 찬 버튼', (tester) async {
    _phone(tester, const Size(360, 800));
    await tester.pumpWidget(_app(session(kakaoEnabled: false)));
    await tester.pumpAndSettle();
    expect(find.byType(KakaoLoginButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(
      find.ancestor(
        of: find.koText(StartScreen.guestLabel),
        matching: find.byType(FilledButton),
      ),
      findsOneWidget,
    );
    await tester.tap(find.koText(StartScreen.guestLabel));
    await tester.pumpAndSettle();
    expect(find.text('홈 화면'), findsOneWidget);
  });

  testWidgets('로그인 중 — 기다림 표시, 둘러보기·링크 잠금, 끝나면 홈으로', (tester) async {
    _phone(tester, const Size(360, 800));
    final s = session();
    await tester.pumpWidget(_app(s));
    await tester.pumpAndSettle();
    await tester.tap(find.koText(KakaoLoginButton.label));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(s.busy, isTrue);
    expect(
      find.descendant(
        of: find.byType(KakaoLoginButton),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    final guest = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.koText(StartScreen.guestLabel),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(guest.onPressed, isNull);
    final link = tester.widget<TextButton>(
      find.ancestor(
        of: find.koText(StartScreen.privacyLabel),
        matching: find.byType(TextButton),
      ),
    );
    expect(link.onPressed, isNull);
    final pop = tester.widget<PopScope>(
      find.byWidgetPredicate((w) => w is PopScope).first,
    );
    expect(pop.canPop, isFalse);

    kakao.finish();
    // 로그인이 끝나 홈으로 넘어가는 사이에 [시작하기] 화면이 잠깐 보이면 안 된다(깜빡임)
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.koText('시작하기'), findsNothing);
    }
    await tester.pumpAndSettle();
    expect(find.text('홈 화면'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing); // 성공하면 안내 문구 없이
  });

  for (final size in const [Size(360, 800), Size(360, 640)]) {
    testWidgets(
      '반복 애니메이션이 돌아도 오류·넘침 없음 (${size.width.toInt()}×${size.height.toInt()})',
      (tester) async {
        StartScreen.idleAnimations = true;
        _phone(tester, size);
        await tester.pumpWidget(_app(session()));
        // 등장 1.3초 + 손 흔들기·반짝이 몇 바퀴 — pumpAndSettle은 반복 때문에 끝나지 않으니 시간으로 민다
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(tester.takeException(), isNull);
        expect(find.byType(KakaoLoginButton), findsOneWidget);
        // 화면을 떠나면 반복이 멈추고(정리) 남는 타이머가 없다
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 4));
      },
    );
  }

  testWidgets("'애니메이션 제거' 설정이면 반복이 돌지 않는다", (tester) async {
    StartScreen.idleAnimations = true;
    _phone(tester, const Size(360, 800));
    await tester.pumpWidget(_app(session(), reduceMotion: true));
    await tester.pump(const Duration(seconds: 4));
    // 반복이 없으니 화면이 가라앉는다
    await tester.pumpAndSettle();
    expect(find.byType(KakaoLoginButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
