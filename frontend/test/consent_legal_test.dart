/// 고지·동의·폰 정리 (2026-10-30 보안·개인정보).
///
///   ① 시작 시트 — 필수 두 줄(약관·만 14세)을 다 골라야 [동의하고 시작하기]가 열린다 · 모두 동의 · 한 번 동의하면 다시 묻지 않는다
///      개인정보는 체크가 아니라 **안내**(세 줄 + 처리방침 링크) — 필수 동의 관행 개선(개인정보 보호법 제22조 제3항)
///   ② 시트를 닫으면 하려던 일(둘러보기)을 하지 않는다
///   ③ '보기'로 약관·처리방침 전문이 열린다
///   ④ 문서(처리방침·약관·데이터 출처)는 대시(—) 없이, 법이 정한 항목을 담는다
///   ⑤ 마이의 약관·정책 줄 — 처리방침은 굵게(다른 줄과 구별)
///   ⑥ 회원 탈퇴 때 이 폰의 원본·일정·대화·동의를 지운다 · 앱을 켤 때 임시 사진 사본을 지운다
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/chat_history.dart';
import 'package:jeonse_ai/models/content_models.dart' show JourneyDateKey;
import 'package:jeonse_ai/repositories/chat_history_repository.dart';
import 'package:jeonse_ai/screens/legal/consent_sheet.dart';
import 'package:jeonse_ai/screens/legal/data_sources_content.dart';
import 'package:jeonse_ai/screens/legal/legal_doc.dart';
import 'package:jeonse_ai/screens/legal/notices.dart';
import 'package:jeonse_ai/screens/legal/privacy_content.dart';
import 'package:jeonse_ai/screens/legal/terms_content.dart';
import 'package:jeonse_ai/screens/my/my_settings.dart';
import 'package:jeonse_ai/services/phone_wipe.dart';
import 'package:jeonse_ai/state/consent_store.dart';
import 'package:jeonse_ai/state/journey_progress_store.dart';
import 'package:jeonse_ai/state/journey_schedule_store.dart';
import 'package:jeonse_ai/state/registry_photo_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';

Widget _host({required VoidCallback onAgreed, required VoidCallback onRefused}) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                if (await ensureConsent(context)) {
                  onAgreed();
                } else {
                  onRefused();
                }
              },
              child: const Text('시작'),
            ),
          ),
        ),
      ),
    ],
  );
  return MaterialApp.router(theme: buildAppTheme(), routerConfig: router);
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ConsentStore.instance.debugReset(); // 이 파일은 '아직 동의 안 함'에서 시작한다
  });

  group('① 시작 동의 시트', () {
    testWidgets('필수 두 줄을 다 골라야 버튼이 열리고, 동의하면 다시 묻지 않는다', (tester) async {
      _phone(tester);
      var agreed = 0;
      await tester.pumpWidget(_host(onAgreed: () => agreed++, onRefused: () {}));
      await tester.tap(find.text('시작'));
      await tester.pumpAndSettle();

      expect(find.byType(ConsentSheet), findsOneWidget);
      FilledButton button() =>
          tester.widget<FilledButton>(find.byKey(const ValueKey('consent-agree')));
      expect(button().onPressed, isNull, reason: '아무것도 안 골랐으면 잠김');

      await tester.tap(find.byKey(const ValueKey('consent-terms')));
      await tester.pumpAndSettle();
      expect(button().onPressed, isNull, reason: '만 14세 확인이 남았다');

      await tester.tap(find.byKey(const ValueKey('consent-age')));
      await tester.pumpAndSettle();
      expect(button().onPressed, isNotNull);

      await tester.tap(find.byKey(const ValueKey('consent-agree')));
      await tester.pumpAndSettle();
      expect(agreed, 1);
      expect(ConsentStore.instance.hasCurrent, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ConsentStore.prefsKey), contains(kConsentVersion));

      // 두 번째는 시트 없이 바로
      await tester.tap(find.text('시작'));
      await tester.pumpAndSettle();
      expect(find.byType(ConsentSheet), findsNothing);
      expect(agreed, 2);
    });

    testWidgets('모두 동의 한 번이면 두 줄이 다 골라지고, 다시 누르면 다 풀린다', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_host(onAgreed: () {}, onRefused: () {}));
      await tester.tap(find.text('시작'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('consent-all')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(find.byKey(const ValueKey('consent-agree'))).onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('consent-all')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(find.byKey(const ValueKey('consent-agree'))).onPressed,
        isNull,
      );
    });

    testWidgets('② 시트를 닫으면 하려던 일을 하지 않고 동의도 남지 않는다', (tester) async {
      _phone(tester);
      var refused = 0;
      await tester.pumpWidget(_host(onAgreed: () => fail('동의하지 않았다'), onRefused: () => refused++));
      await tester.tap(find.text('시작'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 20)); // 시트 바깥
      await tester.pumpAndSettle();
      expect(refused, 1);
      expect(ConsentStore.instance.hasCurrent, isFalse);
    });

    testWidgets('③ 보기를 누르면 이용약관 전문이 열린다', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_host(onAgreed: () {}, onRefused: () {}));
      await tester.tap(find.text('시작'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('consent-open-terms')));
      await tester.pumpAndSettle();
      expect(find.byType(LegalDocScreen), findsOneWidget);
      expect(find.koText('이 약관은'), findsOneWidget);
    });

    testWidgets('개인정보는 체크 없이 안내만 — 세 줄 + 처리방침 링크(굵은 초록)', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_host(onAgreed: () {}, onRefused: () {}));
      await tester.tap(find.text('시작'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('consent-privacy')), findsNothing, reason: '개인정보 동의 체크는 없다');
      expect(find.koText('개인정보 수집·이용 동의'), findsNothing);
      for (final h in kPrivacyAtAGlance) {
        expect(find.koText(h.text), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('consent-open-privacy')));
      await tester.pumpAndSettle();
      expect(find.byType(LegalDocScreen), findsOneWidget);
      expect(find.koText('받는 정보와 쓰는 곳'), findsOneWidget);
    });

    testWidgets('작은 폰 · 어둡게 · 글자 크게에서도 넘치지 않는다', (tester) async {
      tester.view.physicalSize = const Size(720, 1280); // 360×640
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: _host(onAgreed: () {}, onRefused: () {}),
        ),
      );
      await tester.tap(find.text('시작'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('consent-agree')), findsOneWidget);
    });
  });

  group('④ 문서', () {
    final docs = {
      '처리방침': privacyPolicyDoc(),
      '약관': termsDoc(),
      '데이터 출처': dataSourcesDoc(),
    };

    test('대시(—) 없이 쓴다 · 리포트 한 줄도 마찬가지', () {
      for (final e in docs.entries) {
        expect(e.value.plainText, isNot(contains('—')), reason: e.key);
      }
      expect(kReportNotice, isNot(contains('—')));
      expect(kBlacklistCheckNotice, isNot(contains('—')));
    });

    test('처리방침 — 서버 나라·받는 곳 연락처·보호책임자·문의·구제 기관 4곳', () {
      final text = privacyPolicyDoc().plainText;
      expect(text, contains('보관하는 나라 싱가포르'));
      expect(text, contains('Railway Corp.'));
      expect(text, contains('privacy@railway.com'), reason: '국외 이전 — 받는 자의 연락처(제28조의8 제2항)');
      expect(text, contains('제28조의8 제1항 제3호'));
      expect(text, contains('팀 동크크'));
      expect(text, contains('namgh3651@gmail.com'));
      for (final org in ['개인정보분쟁조정위원회', '개인정보침해신고센터', '대검찰청', '경찰청']) {
        expect(text, contains(org));
      }
      expect(text, contains('만 14세 이상이 쓰는 앱이에요'));
      expect(text, contains('처리를 멈춰 달라고 할 수 있어요'), reason: '등기부 속 사람의 권리(제20조)');
    });

    test('처리방침 — 동의 대신 근거를 밝히고, 필수 동의 문구는 쓰지 않는다', () {
      final text = privacyPolicyDoc().plainText;
      expect(text, contains('동의를 따로 받는 대신 이렇게 알려 드려요(개인정보 보호법 제15조 제1항 제4호)'));
      expect(text, contains('제15조 제1항 제6호'), reason: '등기부 속 다른 사람의 정보');
      expect(text, isNot(contains('동의하지 않으면 분석을 시작할 수 없어요')));
      expect(text, isNot(contains('다시 동의를 받아요')));
    });

    test('처리방침 — 보관 기간은 서버가 지키는 숫자와 같다(1년·24시간·2시간·30일·5건)', () {
      final text = privacyPolicyDoc().plainText;
      expect(text, contains('마지막으로 분석하거나 결제한 날부터 1년이 지나면 지워요'));
      expect(text, contains('해시값을 24시간 써요'));
      expect(text, contains('Railway의 접속 기록에는 90일'), reason: 'Railway 가장자리 접속 기록(IP)은 끌 수 없다 — 숨기지 않는다');
      expect(text, contains('2시간 안에 버려요'));
      expect(text, contains('30일 뒤 끝나요'));
      expect(text, contains('최근 5건'));
      expect(text, contains('촬영 위치 같은 정보는 지우고 보내요'));
    });

    test('처리방침 — AI 쓰는 방식(학습 안 함·입력 주의·알리는 곳)', () {
      final text = privacyPolicyDoc().plainText;
      expect(text, contains('이용자 정보로 AI를 학습시키지 않아요'));
      expect(text, contains(kUpstageRetentionNote));
      expect(text, contains('챗봇에는 이름, 주민등록번호, 계좌번호 같은 정보를 쓰지 말아 주세요'));
    });

    test('약관 — 강점 먼저 · 참고 자료 · 법률 자문 아님 · 고의·중과실 책임은 빼지 않는다 · AI 고지 · 변경 절차', () {
      final text = termsDoc().plainText;
      expect(text, contains("'양호' 대신 '확인 필요'"));
      expect(text, contains('참고 자료'));
      expect(text, contains('법률 자문'));
      expect(text, contains('고의나 중대한 과실로 손해가 생기면 법에 따라 책임져요'));
      expect(text, contains('생성형 AI를 써요'), reason: '인공지능 기본법 — 미리 알린다');
      expect(text, contains('만 14세 이상만 쓸 수 있어요'));
      expect(text, contains('7일 전'));
      expect(text, contains('30일 전'));
    });

    test('문단 끝 낱말 묶기 — 마지막 한 낱말이 혼자 떨어지지 않게, 긴 묶음은 잇지 않는다', () {
      expect(noOrphan('쓸 수 있어요.'), '쓸\u00A0수\u00A0있어요.');
      expect(noOrphan('서버에는 남기지 않아요.'), '서버에는 남기지\u00A0않아요.');
      expect(noOrphan('한낱말'), '한낱말');
      // 두 줄짜리는 줄마다 따로
      expect(noOrphan('가 나다\n라 마바'), '가\u00A0나다\n라\u00A0마바');
      // 합쳐 10자를 넘는 꼬리는 잇지 않는다(좁은 화면에서 잘려 나가지 않게)
      expect(noOrphan('아주아주긴낱말입니다 그리고또긴낱말'), '아주아주긴낱말입니다 그리고또긴낱말');
    });

    test('리포트 한 줄 — 근거·할 일·전문가, 약점처럼 들리는 말은 없다', () {
      expect(kReportNotice, contains('근거'));
      expect(kReportNotice, contains('잔금 전'));
      expect(kReportNotice.split('\n'), hasLength(3), reason: '낱말 묶음이 갈라지지 않게 세 줄로');
      expect(kReportNotice, contains('전문가'));
      for (final weak in ['참고용', '참고 자료', '법적 효력', '보증하지', '책임지지']) {
        expect(kReportNotice, isNot(contains(weak)), reason: weak);
      }
    });

    testWidgets('문서 화면 — 어둡게에서도 넘침 없이 그린다', (tester) async {
      _phone(tester);
      for (final doc in docs.values) {
        await tester.pumpWidget(
          MaterialApp(theme: buildAppTheme(), home: LegalDocScreen(doc: doc)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(LegalDocScreen), findsOneWidget);
      }
    });
  });

  testWidgets('⑤ 마이 약관·정책 줄 — 처리방침은 굵게', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(body: PolicySettingsRows()),
      ),
    );
    for (final label in ['이용약관', '개인정보 처리방침', '데이터 출처', '오픈소스 라이선스']) {
      expect(find.koText(label), findsOneWidget);
    }
    final policy = tester.widget<SettingsRow>(
      find.ancestor(of: find.koText('개인정보 처리방침'), matching: find.byType(SettingsRow)),
    );
    expect(policy.strong, isTrue);
    final terms = tester.widget<SettingsRow>(
      find.ancestor(of: find.koText('이용약관'), matching: find.byType(SettingsRow)),
    );
    expect(terms.strong, isFalse);
  });

  group('⑥ 폰 정리', () {
    test('회원 탈퇴 — 원본 사진·일정·여정 기록·챗봇 대화·동의 기록을 지운다', () async {
      final tmp = Directory.systemTemp.createTempSync('wipe');
      addTearDown(() => tmp.deleteSync(recursive: true));
      RegistryPhotoStore.rootForTest = () async => Directory('${tmp.path}/registry_photos');
      addTearDown(() => RegistryPhotoStore.rootForTest = null);
      final photoDir = Directory('${tmp.path}/registry_photos/r1')..createSync(recursive: true);
      File('${photoDir.path}/page_1.jpg').writeAsBytesSync([1, 2, 3]);
      RegistryPhotoStore.instance.register('r1', ['${photoDir.path}/page_1.jpg']);

      JourneyScheduleStore.instance.resetForTest();
      await JourneyScheduleStore.instance.save(
        'house-1',
        JourneySchedule(dates: {JourneyDateKey.balance: DateTime(2026, 11, 20)}),
      );
      await JourneyProgressStore.instance.setCheckedThrough('house-1', 2);
      final chats = MemoryChatHistoryRepository();
      await chats.save(
        ChatConversation(
          id: 'c1',
          title: '근저당이 뭐예요',
          createdAt: DateTime(2026, 10, 30),
          updatedAt: DateTime(2026, 10, 30),
          entries: const [],
        ),
      );
      await ConsentStore.instance.agree();

      await wipeThisPhone(chats: chats);

      expect(Directory('${tmp.path}/registry_photos').existsSync(), isFalse);
      expect(RegistryPhotoStore.instance.pathsFor('r1'), isEmpty);
      expect(JourneyScheduleStore.instance.scheduledKeys, isEmpty);
      expect(await chats.list(), isEmpty);
      expect(ConsentStore.instance.hasCurrent, isFalse);
    });

    test('앱을 켤 때 — 우리 임시 사진 사본만 지우고 다른 파일은 그대로', () async {
      final tmp = Directory.systemTemp.createTempSync('sweep');
      addTearDown(() => tmp.deleteSync(recursive: true));
      File('${tmp.path}/upload_1793300000000.jpg').writeAsBytesSync([1]);
      File('${tmp.path}/3f2b8c1e-9a4d-4e7b-b1c2-0d9e8f7a6b5c.jpg').writeAsBytesSync([1]);
      Directory('${tmp.path}/9a4d4e7b-0000-4e7b-b1c2-0d9e8f7a6b5c').createSync();
      Directory('${tmp.path}/share').createSync();
      File('${tmp.path}/flutter_engine.log').writeAsBytesSync([1]);

      final removed = await RegistryPhotoStore.sweepTempCopies(tempDir: tmp);
      expect(removed, 4);
      expect(
        tmp.listSync().map((e) => e.path.split(Platform.pathSeparator).last),
        ['flutter_engine.log'],
      );
    });
  });
}
