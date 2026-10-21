/// 서버 통신 공용 클라이언트 — **모든 요청에 기기 id가 실리는가**, 그리고 서버가 막았을 때
/// 사용자가 **할 수 있는 일**을 말하는가 (2026-10-22, 앱 1단계 · api-contract §1.1-1·§1.3).
///
/// 왜 테스트로 못 박나: 기기 id가 한 요청에서라도 빠지면 그 요청은 서버의 공용 통로
/// (`legacy-device`)로 들어가 **방금 만든 내 리포트를 못 찾는다**(404). 화면에서는
/// "가끔 리포트가 안 열린다"로만 보여 원인을 찾기 어렵다. 그래서 헤더는 클라이언트 한 곳에서만
/// 붙이고, 여기서 JSON·삭제·멀티파트 세 길을 전부 확인한다.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jeonse_ai/app/config.dart';
import 'package:jeonse_ai/services/api_client.dart';
import 'package:jeonse_ai/services/device_id.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 서버가 받아 주는 형식과 같은 UUID v4 (소문자 16진수, 4번째 묶음 첫 글자 8·9·a·b).
final RegExp _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

http.Response _json(int status, Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceId.instance.resetForTest();
  });

  group('기기 id — 한 번 만들고 계속 같은 값', () {
    test('UUID v4 형식이고 서버 형식 검사([A-Za-z0-9-]{8,64})도 통과한다', () {
      for (var i = 0; i < 50; i++) {
        final id = generateUuidV4();
        expect(id, matches(_uuidV4));
        expect(id.length, 36);
        expect(isValidDeviceId(id), isTrue);
      }
    });

    test('같은 난수열이면 같은 값, 다른 난수열이면 다른 값 (버전·변형 비트는 고정)', () {
      expect(generateUuidV4(Random(1)), generateUuidV4(Random(1)));
      expect(generateUuidV4(Random(1)), isNot(generateUuidV4(Random(2))));
      expect(generateUuidV4(Random(3)), matches(_uuidV4));
    });

    test('서버가 거절하는 값은 쓰지 않는다 (공용 통로 이름·짧음·이상한 글자)', () {
      expect(isValidDeviceId(null), isFalse);
      expect(isValidDeviceId(''), isFalse);
      expect(isValidDeviceId('legacy-device'), isFalse);
      expect(isValidDeviceId('abc'), isFalse);
      expect(isValidDeviceId('has space-1234'), isFalse);
      expect(isValidDeviceId('x' * 65), isFalse);
      expect(isValidDeviceId('abcd-1234'), isTrue);
    });

    test('처음엔 새로 만들어 device_id_v1에 저장하고, 다음엔 저장본을 그대로 쓴다', () async {
      final first = await DeviceId.instance.get();
      expect(first, matches(_uuidV4));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(DeviceId.prefsKey), first);
      expect(DeviceId.prefsKey, 'device_id_v1');

      // 앱을 껐다 켠 것과 같다 — 메모리를 비워도 저장본이 이긴다.
      DeviceId.instance.resetForTest();
      expect(await DeviceId.instance.get(), first);
    });

    test('동시에 여러 요청이 물어도 id는 하나다', () async {
      final ids = await Future.wait([
        for (var i = 0; i < 5; i++) DeviceId.instance.get(),
      ]);
      expect(ids.toSet(), hasLength(1));
    });

    test('저장본이 깨져 있으면(서버가 400을 줄 값) 새로 만들어 덮어쓴다', () async {
      SharedPreferences.setMockInitialValues({DeviceId.prefsKey: 'legacy-device'});
      DeviceId.instance.resetForTest();
      final id = await DeviceId.instance.get();
      expect(id, matches(_uuidV4));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(DeviceId.prefsKey), id);
    });
  });

  group('헤더 — 한 곳에서 만든다', () {
    test('앱 키가 비어 있으면 X-App-Key를 아예 싣지 않는다', () {
      expect(buildApiHeaders(deviceId: 'abcd-1234'), {'X-Device-Id': 'abcd-1234'});
      expect(
        buildApiHeaders(deviceId: 'abcd-1234', appKey: ''),
        isNot(contains('X-App-Key')),
      );
    });

    test('앱 키가 있으면 두 헤더를 함께 싣는다', () {
      expect(buildApiHeaders(deviceId: 'abcd-1234', appKey: 'k-1'), {
        'X-Device-Id': 'abcd-1234',
        'X-App-Key': 'k-1',
      });
    });

    test('빌드 설정 — 아무것도 안 넣으면 예전 주소(adb reverse)와 빈 앱 키', () {
      // `flutter test`는 --dart-define 없이 돈다 → 기본값이 그대로 보여야 한다.
      expect(baseUrl, 'http://127.0.0.1:8000');
      expect(apiBaseUrl, 'http://127.0.0.1:8000');
      expect(appKey, isEmpty);
    });
  });

  group('모든 요청에 X-Device-Id (JSON · 삭제 · 멀티파트)', () {
    late List<http.BaseRequest> seen;
    late ApiClient api;

    setUp(() {
      seen = [];
      api = ApiClient(
        client: MockClient((req) async {
          seen.add(req);
          if (req.method == 'DELETE') return http.Response('', 204);
          return _json(200, req.url.path.endsWith('/reports') ? [] : {'ok': true});
        }),
      );
    });

    test('GET·DELETE·POST(멀티파트) 전부 같은 기기 id를 싣는다', () async {
      final id = await DeviceId.instance.get();

      await api.getJson('/api/reports');
      await api.getJson('/api/glossary/lookup', query: {'q': '근저당'});
      await api.delete('/api/reports/r1');
      await api.postMultipart(
        '/api/analyze',
        files: [
          http.MultipartFile.fromString('files', 'jpeg', filename: 'page_1.jpg'),
        ],
        fields: {'deposit': '100000000'},
      );

      expect(seen, hasLength(4));
      for (final r in seen) {
        expect(r.headers['X-Device-Id'], id, reason: '${r.method} ${r.url.path}');
        // flutter test는 APP_KEY 없이 돈다 → 빈 헤더를 싣지 않는다.
        expect(r.headers.containsKey('X-App-Key'), isFalse, reason: r.url.path);
      }
      // 멀티파트도 본래 내용(파일·필드)은 그대로 나간다 — 헤더만 더해졌다.
      expect(seen.last.headers['content-type'], startsWith('multipart/form-data'));
      expect(seen.last.url.toString(), 'http://127.0.0.1:8000/api/analyze');
    });
  });

  group('막혔을 때 — 사용자가 할 수 있는 일을 말한다', () {
    test('401 = 앱 인증 실패 → 최신 앱 설치 (다시 시도로 안 풀린다)', () {
      final e = apiExceptionFor(
        401,
        '앱 인증 정보가 맞지 않아요. 앱을 최신 버전으로 업데이트해 주세요',
      );
      expect(e.statusCode, 401);
      expect(e.message, kAppAuthFailedMessage);
      expect(e.message, contains('최신 앱을 설치해 주세요'));
      expect(e.needsAppUpdate, isTrue);
    });

    test('400 기기 정보 문제(형식·없음) → 최신 앱 설치', () {
      for (final detail in const [
        '기기 정보 형식이 올바르지 않아요',
        '기기 정보가 없어요. 앱을 최신 버전으로 업데이트해 주세요',
      ]) {
        final e = apiExceptionFor(400, detail);
        expect(e.message, kDeviceProblemMessage, reason: detail);
        expect(e.message, contains('기기 정보'));
        expect(e.needsAppUpdate, isTrue);
      }
    });

    test('다른 400(요약본 거부 등)은 서버 문구 그대로 — 사진 다시 고르기 안내가 살아 있어야 한다', () {
      const detail = '요약본은 분석할 수 없어요. 전체 등기부등본을 올려 주세요';
      final e = apiExceptionFor(400, detail);
      expect(e.message, detail);
      expect(e.needsAppUpdate, isFalse);
    });

    test('429 우리 서버의 횟수 제한 → 잠시 후 다시 + 1시간 횟수 제한 설명', () {
      final e = apiExceptionFor(429, '분석을 너무 자주 했어요. 한 시간쯤 뒤에 다시 시도해 주세요');
      expect(e.message, kRateLimitedMessage);
      expect(e.message, contains('잠시 후 다시 시도해 주세요'));
      expect(e.message, contains('1시간'));
      expect(e.needsAppUpdate, isFalse);
    });

    test('429 Upstage 한도는 서버 문구가 더 정확하다 — 덮지 않는다', () {
      const detail = '요청이 몰려 잠시 제한됐어요. 잠시 후 다시 시도해 주세요';
      expect(apiExceptionFor(429, detail).message, detail);
    });

    test('본문이 없으면 기본 문구', () {
      expect(apiExceptionFor(500, null).message, '잠깐 문제가 생겼어요. 다시 시도해 주세요');
      expect(apiExceptionFor(429, null).message, kRateLimitedMessage);
    });

    test('실제 응답 → ApiException (클라이언트가 위 규칙을 그대로 쓴다)', () async {
      final api = ApiClient(
        client: MockClient(
          (_) async => _json(401, {
            'detail': '앱 인증 정보가 맞지 않아요. 앱을 최신 버전으로 업데이트해 주세요',
          }),
        ),
      );
      await expectLater(
        api.getJson('/api/reports'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.message, 'message', kAppAuthFailedMessage)
              .having((e) => e.needsAppUpdate, 'needsAppUpdate', isTrue),
        ),
      );
    });

    test('목록 화면 한 줄 — 인증·기기 문제만 바꾸고 나머지는 원래 문구', () {
      const fallback = '서버 연결을 확인해 주세요';
      expect(
        apiErrorHint(apiExceptionFor(401, null), fallback: fallback),
        kAppAuthFailedMessage,
      );
      expect(
        apiErrorHint(apiExceptionFor(500, null), fallback: fallback),
        fallback,
      );
      expect(apiErrorHint(StateError('x'), fallback: fallback), fallback);
      expect(apiErrorHint(null, fallback: fallback), fallback);
    });
  });
}
