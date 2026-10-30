/// 카카오 로그인 (2026-10-22, P2-1) — 앱 쪽에서 못 박는 것:
///
/// 1. 카카오 키가 **없는** 빌드(지금 — 카카오 개발자 앱 등록 전)는 카카오 버튼을 아예 그리지 않는다. 둘러보기만.
/// 2. 키가 **있는** 빌드는 [카카오로 시작하기] + [로그인 없이 둘러보기]. 로그인하면 세션이 보안 저장소와 요청 헤더로.
/// 3. 모든 요청에 `Authorization: Bearer <세션>` (+ 기기 id 그대로).
/// 4. 서버가 세션을 거절하면(401 `invalid_token`) 세션을 지우고 "다시 로그인해 주세요". 앱 키 401은 세션을 건드리지 않는다.
/// 5. 회원 탈퇴는 확인을 받은 뒤 — 서버 삭제 먼저, 그다음 카카오 연결 끊기.
/// 6. 분석 게이트: 둘러보는 중이면 로그인 유도, 하지만 [로그인 없이 분석하기]로 그대로 간다(막다른 길 금지).
/// 7. 개인정보 처리방침: 정해지지 않은 값(서버 지역·문의처)은 줄을 뺀다.
///
/// 카카오 SDK·보안 저장소·서버는 전부 가짜다.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jeonse_ai/app/config.dart';
import 'package:jeonse_ai/repositories/auth_repository.dart';
import 'package:jeonse_ai/screens/auth/kakao_login_button.dart';
import 'package:jeonse_ai/screens/auth/login_screen.dart';
import 'package:jeonse_ai/screens/auth/start_screen.dart';
import 'package:jeonse_ai/screens/common/analyze_gate.dart';
import 'package:jeonse_ai/screens/my/account_section.dart';
import 'package:jeonse_ai/screens/my/privacy_policy_screen.dart';
import 'package:jeonse_ai/services/api_client.dart';
import 'package:jeonse_ai/services/device_id.dart';
import 'package:jeonse_ai/services/kakao_login_gateway.dart';
import 'package:jeonse_ai/services/session_credentials.dart';
import 'package:jeonse_ai/services/session_storage.dart';
import 'package:jeonse_ai/state/app_session.dart';
import 'package:jeonse_ai/state/pass_store.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';

class _FakeKakao implements KakaoLoginGateway {
  Object? loginError;
  Object? unlinkError;
  String token = 'kakao-access-token-1';
  int logins = 0;
  int logouts = 0;
  int unlinks = 0;

  @override
  Future<String> login() async {
    logins++;
    final error = loginError;
    if (error != null) throw error;
    return token;
  }

  @override
  Future<void> logout() async => logouts++;

  @override
  Future<void> unlink() async {
    unlinks++;
    final error = unlinkError;
    if (error != null) throw error;
  }
}

class _FakeAuth implements AuthRepository {
  @override
  Future<MeStatus> setDisplayName(String name) async => MeStatus(
    loggedIn: true,
    displayName: name.trim().isEmpty ? null : name.trim(),
  );

  final List<String> kakaoTokens = [];
  final List<String> loggedOut = [];
  int deletes = 0;
  Object? loginError;
  Object? deleteError;
  SavedSession session = SavedSession(
    token: 'session-token-1',
    expiresAt: DateTime.utc(2099, 1, 1),
    customerKey: 'acct_0123456789abcdef0123456789abcdef01234567',
  );

  @override
  Future<SavedSession> loginWithKakao(String kakaoAccessToken) async {
    kakaoTokens.add(kakaoAccessToken);
    final error = loginError;
    if (error != null) throw error;
    return session;
  }

  @override
  Future<MeStatus> me() async => const MeStatus(loggedIn: true);

  @override
  Future<void> logout(String sessionToken) async => loggedOut.add(sessionToken);

  @override
  Future<void> deleteAccount() async {
    deletes++;
    final error = deleteError;
    if (error != null) throw error;
  }
}

final SavedSession _valid = SavedSession(
  token: 'session-token-1',
  expiresAt: DateTime.utc(2099, 1, 1),
  customerKey: 'acct_0123456789abcdef0123456789abcdef01234567',
);

/// 화면 몇 개만 붙인 작은 앱 — 로그인 흐름이 어디로 가는지 본다.
Widget _app(AppSession session, {String initial = '/start'}) {
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(path: '/start', builder: (_, _) => const StartScreen()),
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('홈 화면')),
      ),
      GoRoute(
        path: '/login',
        builder: (_, state) =>
            LoginScreen(next: state.uri.queryParameters['next']),
      ),
      GoRoute(
        path: '/analyze',
        builder: (_, _) => const Scaffold(body: Text('분석 화면')),
      ),
      GoRoute(path: '/privacy', builder: (_, _) => const PrivacyPolicyScreen()),
      GoRoute(
        path: '/my',
        builder: (_, _) => const Scaffold(
          body: SingleChildScrollView(
            child: Column(children: [AccountSection(), AccountSettingsRows()]),
          ),
        ),
      ),
      GoRoute(
        path: '/gate',
        builder: (_, _) => Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => startAnalysis(context),
              child: const Text('분석 시작'),
            ),
          ),
        ),
      ),
    ],
  );
  return ChangeNotifierProvider<AppSession>.value(
    value: session,
    child: MaterialApp.router(routerConfig: router),
  );
}

http.Response _json(int status, Object body, {Map<String, String>? headers}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8', ...?headers},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeKakao kakao;
  late _FakeAuth auth;
  late MemorySessionStorage storage;

  AppSession newSession({bool kakaoEnabled = true}) => AppSession(
    storage: storage,
    kakao: kakao,
    auth: auth,
    kakaoEnabled: kakaoEnabled,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceId.instance.resetForTest();
    SessionCredentials.instance.resetForTest();
    kakao = _FakeKakao();
    auth = _FakeAuth();
    storage = MemorySessionStorage();
  });

  group('빌드 설정', () {
    test('flutter test는 카카오 키 없이 돈다 → 로그인 기능이 꺼진 상태가 기본', () {
      expect(kakaoNativeAppKey, isEmpty);
      expect(kakaoLoginAvailable, isFalse);
      expect(AppSession(storage: storage).kakaoAvailable, isFalse);
    });
  });

  group('키가 없는 빌드 — 카카오 버튼 없음, 둘러보기만', () {
    testWidgets('시작 화면에 카카오 버튼이 없고 [로그인 없이 둘러보기]로 홈에 간다', (tester) async {
      await tester.pumpWidget(_app(newSession(kakaoEnabled: false)));
      await tester.pumpAndSettle();
      expect(find.koText(KakaoLoginButton.label), findsNothing);
      expect(find.byType(KakaoLoginButton), findsNothing);
      await tester.tap(find.koText('로그인 없이 둘러보기'));
      await tester.pumpAndSettle();
      expect(find.text('홈 화면'), findsOneWidget);
      expect(kakao.logins, 0);
    });

    testWidgets('분석 게이트가 로그인 안내 없이 바로 분석으로 간다', (tester) async {
      await tester.pumpWidget(
        _app(newSession(kakaoEnabled: false), initial: '/gate'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('분석 시작'));
      await tester.pumpAndSettle();
      expect(find.text('분석 화면'), findsOneWidget);
    });

    testWidgets('마이의 계정 칸에도 카카오 버튼이 없다', (tester) async {
      await tester.pumpWidget(
        _app(newSession(kakaoEnabled: false), initial: '/my'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(KakaoLoginButton), findsNothing);
      expect(find.koText('로그인 없이 둘러보는 중'), findsOneWidget);
      expect(find.koText('개인정보 처리방침'), findsOneWidget);
    });
  });

  group('키가 있는 빌드 — 카카오로 시작하기', () {
    testWidgets('두 버튼이 있고, 로그인하면 세션이 저장소·요청 헤더로 들어가 홈으로 간다', (tester) async {
      final session = newSession();
      await tester.pumpWidget(_app(session));
      await tester.pumpAndSettle();
      expect(find.koText(KakaoLoginButton.label), findsOneWidget);
      expect(find.koText('로그인 없이 둘러보기'), findsOneWidget);
      expect(find.koText(StartScreen.privacyLabel), findsOneWidget);
      // 카카오가 있으면 둘러보기는 테두리(보조) 버튼
      expect(
        find.ancestor(
          of: find.koText('로그인 없이 둘러보기'),
          matching: find.byType(OutlinedButton),
        ),
        findsOneWidget,
      );

      await tester.tap(find.koText(KakaoLoginButton.label));
      await tester.pumpAndSettle();

      expect(kakao.logins, 1);
      expect(auth.kakaoTokens, ['kakao-access-token-1']); // 카카오 토큰은 서버로만
      expect(session.isLoggedIn, isTrue);
      expect(storage.saved?.token, 'session-token-1');
      expect(SessionCredentials.instance.token, 'session-token-1');
      expect(find.text('홈 화면'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing); // 성공하면 안내 없이 넘어간다
    });

    testWidgets('사용자가 카카오 화면을 닫으면 조용히 그대로 (오류 안내 없음)', (tester) async {
      kakao.loginError = const KakaoLoginCanceled();
      final session = newSession();
      await tester.pumpWidget(_app(session));
      await tester.pumpAndSettle();
      await tester.tap(find.koText(KakaoLoginButton.label));
      await tester.pumpAndSettle();
      expect(session.isGuest, isTrue);
      expect(auth.kakaoTokens, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.koText(KakaoLoginButton.label), findsOneWidget); // 시작 화면에 그대로
    });

    testWidgets('카카오·서버가 실패하면 쉬운 말 한 줄, 로그인 안 됨', (tester) async {
      auth.loginError = const ApiException(
        '카카오 로그인을 확인하지 못했어요. 다시 로그인해 주세요',
        statusCode: 401,
      );
      final session = newSession();
      await tester.pumpWidget(_app(session));
      await tester.pumpAndSettle();
      await tester.tap(find.koText(KakaoLoginButton.label));
      await tester.pumpAndSettle();
      expect(session.isGuest, isTrue);
      expect(storage.saved, isNull);
      expect(find.koText('카카오 로그인을 확인하지 못했어요. 다시 로그인해 주세요'), findsOneWidget);
    });

    testWidgets('이미 로그인돼 있으면(시연 폰) 시작 화면은 [시작하기] 하나', (tester) async {
      storage.saved = _valid;
      final session = newSession();
      await session.restore(now: DateTime.utc(2026, 10, 22));
      await tester.pumpWidget(_app(session));
      await tester.pumpAndSettle();
      expect(find.byType(KakaoLoginButton), findsNothing);
      await tester.tap(find.koText('시작하기'));
      await tester.pumpAndSettle();
      expect(find.text('홈 화면'), findsOneWidget);
    });
  });

  group('분석 게이트 — 로그인 유도, 하지만 막다른 길이 아니다', () {
    testWidgets('둘러보는 중이면 시트 → [로그인 없이 분석하기]로 그대로 분석', (tester) async {
      await tester.pumpWidget(_app(newSession(), initial: '/gate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('분석 시작'));
      await tester.pumpAndSettle();
      expect(find.koText('로그인하면 분석 기록이 계정에 남아요'), findsOneWidget);
      expect(find.koText(KakaoLoginButton.label), findsOneWidget);
      await tester.tap(find.koText('로그인 없이 분석하기'));
      await tester.pumpAndSettle();
      expect(find.text('분석 화면'), findsOneWidget);
      expect(kakao.logins, 0);
    });

    testWidgets('시트에서 카카오로 로그인하면 원래 하려던 분석으로 이어 간다', (tester) async {
      final session = newSession();
      await tester.pumpWidget(_app(session, initial: '/gate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('분석 시작'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText(KakaoLoginButton.label));
      await tester.pumpAndSettle();
      expect(session.isLoggedIn, isTrue);
      expect(find.text('분석 화면'), findsOneWidget);
    });

    testWidgets('로그인했으면 시트 없이 바로 분석', (tester) async {
      storage.saved = _valid;
      final session = newSession();
      await session.restore(now: DateTime.utc(2026, 10, 22));
      await tester.pumpWidget(_app(session, initial: '/gate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('분석 시작'));
      await tester.pumpAndSettle();
      expect(find.text('분석 화면'), findsOneWidget);
    });

    testWidgets('로그인 화면(next)에서 둘러보기를 골라도 원래 하려던 곳으로 간다', (tester) async {
      await tester.pumpWidget(
        _app(
          newSession(),
          initial: '/login?next=${Uri.encodeComponent('/analyze')}',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.koText('로그인 없이 둘러보기'));
      await tester.pumpAndSettle();
      expect(find.text('분석 화면'), findsOneWidget);
    });
  });

  group('세션 헤더 — 모든 요청에 Authorization: Bearer', () {
    test('세션이 있으면 기기 id와 함께 싣고, 없으면 싣지 않는다', () {
      expect(buildApiHeaders(deviceId: 'abcd-1234', sessionToken: 'tok-1'), {
        'X-Device-Id': 'abcd-1234',
        'Authorization': 'Bearer tok-1',
      });
      expect(buildApiHeaders(deviceId: 'abcd-1234', sessionToken: ''), {
        'X-Device-Id': 'abcd-1234',
      });
      expect(buildApiHeaders(deviceId: 'abcd-1234'), {
        'X-Device-Id': 'abcd-1234',
      });
    });

    test('로그인하면 GET·POST·DELETE·멀티파트 전부에 실린다', () async {
      final seen = <http.BaseRequest>[];
      final api = ApiClient(
        client: MockClient((req) async {
          seen.add(req);
          if (req.method == 'DELETE') return http.Response('', 204);
          return _json(200, {'ok': true});
        }),
      );
      final session = newSession();
      storage.saved = _valid;
      await session.restore(now: DateTime.utc(2026, 10, 22));

      await api.getJson('/api/reports');
      await api.postJson('/api/payments/confirm', {'a': 1});
      await api.delete('/api/reports/r1');
      await api.postMultipart(
        '/api/analyze',
        files: [
          http.MultipartFile.fromString(
            'files',
            'jpeg',
            filename: 'page_1.jpg',
          ),
        ],
        fields: {'deposit': '1'},
      );
      expect(seen, hasLength(4));
      final deviceId = await DeviceId.instance.get();
      for (final r in seen) {
        expect(
          r.headers['Authorization'],
          'Bearer session-token-1',
          reason: r.url.path,
        );
        expect(r.headers['X-Device-Id'], deviceId, reason: r.url.path);
      }
    });

    test('결제 주인 키 — 로그인했으면 계정 값, 아니면 기기 id 해시', () async {
      final guestKey = await passOwnerKey();
      expect(guestKey, startsWith('device_'));
      storage.saved = _valid;
      await newSession().restore(now: DateTime.utc(2026, 10, 22));
      expect(await passOwnerKey(), _valid.customerKey);
    });

    test('204(본문 없음)도 성공으로 받는다 — 로그아웃', () async {
      final api = ApiClient(
        client: MockClient((_) async => http.Response('', 204)),
      );
      expect(await api.postJson('/api/auth/logout', const {}), isNull);
    });
  });

  group('세션 401 — 지우고 다시 로그인 안내', () {
    test('서버가 세션을 거절하면(invalid_token) 세션을 지우고 needsLogin', () async {
      storage.saved = _valid;
      var expired = 0;
      final session = newSession()..onSessionExpired = () => expired++;
      await session.restore(now: DateTime.utc(2026, 10, 22));
      expect(session.isLoggedIn, isTrue);

      final api = ApiClient(
        client: MockClient(
          (_) async => _json(
            401,
            {'detail': '로그인이 끝났어요. 다시 로그인해 주세요'},
            headers: {'www-authenticate': 'Bearer error="invalid_token"'},
          ),
        ),
      );
      await expectLater(
        api.getJson('/api/reports'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.message, 'message', kSessionExpiredMessage)
              .having((e) => e.needsLogin, 'needsLogin', isTrue)
              .having((e) => e.needsAppUpdate, 'needsAppUpdate', isFalse),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(session.isGuest, isTrue);
      expect(SessionCredentials.instance.token, isNull);
      expect(storage.saved, isNull);
      expect(expired, 1);
      expect(
        apiErrorHint(
          apiExceptionFor(401, null, sessionRejected: true),
          fallback: 'x',
        ),
        kSessionExpiredMessage,
      );
    });

    test('앱 키 401은 세션을 건드리지 않는다(최신 앱 설치 안내)', () async {
      storage.saved = _valid;
      final session = newSession();
      await session.restore(now: DateTime.utc(2026, 10, 22));
      final api = ApiClient(
        client: MockClient(
          (_) async =>
              _json(401, {'detail': '앱 인증 정보가 맞지 않아요. 앱을 최신 버전으로 업데이트해 주세요'}),
        ),
      );
      await expectLater(
        api.getJson('/api/reports'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            kAppAuthFailedMessage,
          ),
        ),
      );
      expect(session.isLoggedIn, isTrue);
      expect(SessionCredentials.instance.token, 'session-token-1');
    });

    test('카카오 토큰 거절 같은 다른 401은 서버 문구 그대로', () {
      const detail = '카카오 로그인을 확인하지 못했어요. 다시 로그인해 주세요';
      final e = apiExceptionFor(401, detail);
      expect(e.message, detail);
      expect(e.needsAppUpdate, isFalse);
      expect(e.needsLogin, isFalse);
    });

    test('옛 요청의 401이 새로 로그인한 세션을 지우지 않는다', () {
      SessionCredentials.instance.set(token: 'new-session');
      var rejected = 0;
      SessionCredentials.instance.onRejected = () => rejected++;
      SessionCredentials.instance.reject('old-session');
      expect(SessionCredentials.instance.token, 'new-session');
      expect(rejected, 0);
    });

    test('켤 때 만료된 세션은 지우고 둘러보기로 시작한다', () async {
      storage.saved = SavedSession(
        token: 'old',
        expiresAt: DateTime.utc(2026, 10, 1),
        customerKey: 'acct_x',
      );
      final session = newSession();
      await session.restore(now: DateTime.utc(2026, 10, 22));
      expect(session.isGuest, isTrue);
      expect(storage.saved, isNull);
      expect(SessionCredentials.instance.token, isNull);
    });
  });

  group('로그아웃 · 회원 탈퇴', () {
    Future<AppSession> loggedIn() async {
      storage.saved = _valid;
      final session = newSession();
      await session.restore(now: DateTime.utc(2026, 10, 22));
      return session;
    }

    testWidgets('로그아웃하면 이 폰의 세션을 지우고 서버·카카오에 알린다', (tester) async {
      final session = await loggedIn();
      await tester.pumpWidget(_app(session, initial: '/my'));
      await tester.pumpAndSettle();
      expect(find.koText('카카오로 로그인했어요'), findsOneWidget);
      await tester.tap(find.koText('로그아웃'));
      await tester.pumpAndSettle();
      expect(session.isGuest, isTrue);
      expect(storage.saved, isNull);
      expect(SessionCredentials.instance.token, isNull);
      expect(auth.loggedOut, ['session-token-1']); // 지운 세션을 실어 서버에도 끝낸다
      expect(kakao.logouts, 1);
      // 로그아웃하면 시작 화면으로 간다 (2026-10-26)
      expect(find.byType(StartScreen), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing); // 안내 문구 없이 시작 화면으로
    });

    testWidgets('탈퇴는 확인을 받는다 — 취소하면 아무것도 지우지 않는다', (tester) async {
      final session = await loggedIn();
      await tester.pumpWidget(_app(session, initial: '/my'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('회원 탈퇴'));
      await tester.pumpAndSettle();
      expect(find.koText('회원 탈퇴할까요?'), findsOneWidget);
      expect(find.koText(kWithdrawExplanation), findsOneWidget);
      await tester.tap(find.koText('취소'));
      await tester.pumpAndSettle();
      expect(auth.deletes, 0);
      expect(kakao.unlinks, 0);
      expect(session.isLoggedIn, isTrue);
    });

    testWidgets('확인하면 서버 기록을 먼저 지우고 카카오 연결을 끊는다', (tester) async {
      final session = await loggedIn();
      await tester.pumpWidget(_app(session, initial: '/my'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('회원 탈퇴'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('탈퇴하기'));
      await tester.pumpAndSettle();
      expect(auth.deletes, 1);
      expect(kakao.unlinks, 1);
      expect(session.isGuest, isTrue);
      expect(storage.saved, isNull);
      expect(find.koText('탈퇴했어요. 서버의 기록을 모두 지웠어요'), findsOneWidget);
      expect(find.byType(StartScreen), findsOneWidget);
    });

    testWidgets('서버 삭제가 실패하면 카카오 연결을 끊지 않고 로그인도 그대로', (tester) async {
      auth.deleteError = const ApiException(
        '잠깐 문제가 생겼어요. 다시 시도해 주세요',
        statusCode: 500,
      );
      final session = await loggedIn();
      await tester.pumpWidget(_app(session, initial: '/my'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('회원 탈퇴'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('탈퇴하기'));
      await tester.pumpAndSettle();
      expect(kakao.unlinks, 0);
      expect(session.isLoggedIn, isTrue);
      expect(find.koText('잠깐 문제가 생겼어요. 다시 시도해 주세요'), findsOneWidget);
    });

    testWidgets('카카오 끊기만 실패하면 — 서버 기록은 지웠다고, 카카오는 직접 끊으라고 알린다', (tester) async {
      kakao.unlinkError = Exception('network');
      final session = await loggedIn();
      await tester.pumpWidget(_app(session, initial: '/my'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('회원 탈퇴'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('탈퇴하기'));
      await tester.pumpAndSettle();
      expect(auth.deletes, 1);
      expect(session.isGuest, isTrue);
      expect(find.koTextContaining('카카오 연결은 끊지 못했어요'), findsOneWidget);
    });
  });

  group('개인정보 처리방침', () {
    test('서버 지역·문의처가 비어 있으면 그 줄을 뺀다 (지어내지 않는다)', () {
      final empty = privacyPolicySections(serverRegion: '', contact: '');
      final lines = [for (final s in empty) ...s.lines];
      expect(lines.any((l) => l.contains('서버 지역')), isFalse);
      expect(empty.any((s) => s.title == '문의'), isFalse);

      final filled = privacyPolicySections(
        serverRegion: '싱가포르',
        contact: 'team@example.com',
      );
      final filledLines = [for (final s in filled) ...s.lines];
      expect(filledLines, contains('서버 지역 — 싱가포르'));
      expect(filled.last.title, '문의');
      expect(filled.last.lines, ['team@example.com']);
    });

    test('받는 것 — 회원번호(암호화 값)·기기 id·분석 기록, 이름·이메일은 안 받음', () {
      final all = [
        for (final s in privacyPolicySections()) ...s.lines,
      ].join('\n');
      expect(all, contains('카카오 회원번호'));
      expect(all, contains('암호화 값'));
      expect(all, contains('이름·이메일·닉네임·프로필 사진은 받지 않아요'));
      expect(all, contains('기기 id'));
      expect(all, contains('사진은 글자를 읽으려고 국내 AI(Upstage)에만 보내요'));
      expect(all, contains('Railway'));
      expect(all, contains('탈퇴하면'));
    });

    testWidgets('시작 화면에서 들어가 볼 수 있다', (tester) async {
      await tester.pumpWidget(_app(newSession()));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('개인정보 처리방침'));
      await tester.pumpAndSettle();
      expect(find.koText('받는 것'), findsOneWidget);
      expect(find.koTextContaining('카카오 회원번호'), findsOneWidget);
    });
  });

  group('이름 정하기 (2026-10-24) — "동크크 1님 안녕하세요"', () {
    test('로그인 전엔 정할 수 없고, 로그인 뒤 정하면 이름이 바뀌고, 로그아웃하면 사라진다', () async {
      final session = newSession();
      expect(await session.setDisplayName('동크크 1'), isNotNull);
      expect((await session.signInWithKakao()).ok, isTrue);
      expect(await session.setDisplayName(' 동크크 1 '), isNull);
      expect(session.displayName, '동크크 1');
      await session.signOut();
      expect(session.displayName, isNull);
    });

    testWidgets('마이 계정 칸에서 이름을 정하면 그 이름이 보인다', (tester) async {
      final session = newSession();
      await session.signInWithKakao();
      await tester.pumpWidget(_app(session, initial: '/my'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('이름 정하기'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '동크크 2');
      await tester.tap(find.koText('저장'));
      await tester.pumpAndSettle();
      expect(find.koText('동크크 2님'), findsOneWidget);
      expect(session.displayName, '동크크 2');
    });
  });
}
