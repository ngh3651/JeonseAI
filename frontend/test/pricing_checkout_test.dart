/// 요금제 · 계약 지킴이 패스 **테스트 결제** (P2-1) — 돈이 걸린 화면이라 못 박는다.
///
///   ① 가격은 어디서나 "예시", 결제는 어디서나 "테스트 결제 — 실제 청구 없음"
///   ② 결제위젯은 **서버가 준 요금제 가격**으로 그린다. 승인은 서버가 한다(앱은 결과를 넘길 뿐)
///   ③ 취소·실패·확인 끊김을 다 말로 알려 준다. 확인이 끊기면 같은 주문으로 [다시 확인하기]
///   ④ 실제 키(`live_`)로 빌드된 앱은 결제를 열지 않는다
///   ⑤ 패스가 생기면 "지킴이 패스" 표시만 붙는다(기능은 막지 않는다)
///   ⑥ 주인 키는 한 곳 — 기기 id를 결제사에 그대로 넘기지 않는다
///
/// 토스 결제위젯은 웹뷰라 테스트에서 그릴 수 없다 → 가짜 [PaymentGateway]를 넣는다.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/pricing.dart';
import 'package:jeonse_ai/repositories/payment_repository.dart';
import 'package:jeonse_ai/screens/pricing/checkout_screen.dart';
import 'package:jeonse_ai/screens/pricing/guardian_pass_widgets.dart';
import 'package:jeonse_ai/screens/pricing/pricing_screen.dart';
import 'package:jeonse_ai/services/api_client.dart';
import 'package:jeonse_ai/services/journey_reminders.dart';
import 'package:jeonse_ai/services/payment_gateway.dart';
import 'package:jeonse_ai/state/journey_schedule_store.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/state/pass_store.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneHeight, kPhoneWidth;

const _pricing = Pricing(
  label: '예시 가격(확정 전)',
  plans: [
    PricingPlan(
      id: 'free',
      name: '무료',
      tagline: '등기부 분석',
      price: 0,
      priceText: '0원',
      features: ['등기부 사진으로 위험 분석'],
    ),
    PricingPlan(
      id: 'guardian_pass',
      name: '계약 지킴이 패스',
      tagline: '계약부터 입주 다음 날까지',
      price: 9900,
      priceText: '9,900원',
      period: '계약 1건',
      purchasable: true,
      features: ['잔금 하루 전·당일·입주 다음 날 휴대폰 알림'],
    ),
    PricingPlan(
      id: 'institution',
      name: '기관용',
      tagline: '중개사무소·지자체',
      priceText: '문의',
      contact: true,
      features: ['도입 문의는 팀에 직접'],
    ),
  ],
);

/// 서버 대신 — 승인 요청을 기록한다. [failConfirmTimes]번은 "확인 끊김"으로 실패한다.
class _FakePayments implements PaymentRepository {
  _FakePayments({this.failConfirmTimes = 0});

  int failConfirmTimes;
  final List<Map<String, Object>> confirms = [];

  @override
  Future<Pricing> pricing() async => _pricing;

  @override
  Future<GuardianPass> confirm({
    required String planId,
    required String orderId,
    required String paymentKey,
    required int amount,
  }) async {
    confirms.add({
      'planId': planId,
      'orderId': orderId,
      'paymentKey': paymentKey,
      'amount': amount,
    });
    if (failConfirmTimes > 0) {
      failConfirmTimes--;
      throw const ApiException(
        '결제를 확인하지 못했어요. 잠시 후 다시 시도해 주세요',
        statusCode: 502,
      );
    }
    return GuardianPass(
      planId: planId,
      planName: '계약 지킴이 패스',
      orderId: orderId,
      amount: amount,
      method: '카드',
      approvedAt: DateTime(2026, 10, 22, 21, 5),
    );
  }

  @override
  Future<GuardianPass?> myPass() async => null;
}

/// 토스 결제위젯 대신 — 결제창 결과를 정해 둔다.
class _FakeGateway implements PaymentGateway {
  _FakeGateway(this.next);

  /// 결제창이 돌려줄 결과 (주문번호를 받아 만든다)
  PaymentOutcome Function(String orderId) next;
  final List<int> rendered = [];
  final List<String> orders = [];

  @override
  Widget buildForm() => const Text('결제 수단 자리 (가짜)');

  @override
  Future<void> render({required int amount}) async => rendered.add(amount);

  @override
  Future<PaymentOutcome> requestPayment({
    required String orderId,
    required String orderName,
  }) async {
    orders.add(orderId);
    return next(orderId);
  }
}

PaymentOutcome _paid(String orderId) =>
    PaymentOutcome.success(paymentKey: 'pk_test_0001', orderId: orderId, amount: 9900);

Future<void> _pumpCheckout(
  WidgetTester tester, {
  required _FakePayments payments,
  required _FakeGateway gateway,
  String clientKey = 'test_gck_docs_Ovk5rk1EwkEbP0W43n07xlzm',
  List<String>? createdFor,
}) async {
  tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final router = GoRouter(
    initialLocation: '/checkout',
    routes: [
      GoRoute(
        path: '/checkout',
        builder: (context, state) => CheckoutScreen(
          clientKey: clientKey,
          ownerKey: () async => 'device_owner_for_test',
          gatewayFactory: ({required String clientKey, required String customerKey}) {
            createdFor?.add(customerKey);
            return gateway;
          },
        ),
      ),
      GoRoute(
        path: '/journey',
        builder: (context, state) => const Scaffold(body: Text('여정 화면')),
      ),
    ],
  );
  await tester.pumpWidget(
    Provider<PaymentRepository>.value(
      value: payments,
      child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    JourneyScheduleStore.instance.resetForTest();
    PassStore.instance.resetForTest();
  });

  group('요금제 화면', () {
    Future<void> pumpPricing(WidgetTester tester, _FakePayments payments) async {
      tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        initialLocation: '/pricing',
        routes: [
          GoRoute(path: '/pricing', builder: (context, state) => const PricingScreen()),
          GoRoute(
            path: '/checkout',
            builder: (context, state) =>
                Scaffold(body: Text('결제 화면 ${state.uri.queryParameters['plan']}')),
          ),
        ],
      );
      await tester.pumpWidget(
        Provider<PaymentRepository>.value(
          value: payments,
          child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('세 가지 요금제 + 가격은 예시 + 결제는 테스트 결제', (tester) async {
      await pumpPricing(tester, _FakePayments());

      // 맨 위 첫 줄 = 지금은 무료로 다 된다(돈을 내야 안전한 것처럼 읽히지 않게)
      expect(find.koText(kPricingFreeNowLine), findsOneWidget);
      expect(find.koText('가격은 아직 정하지 않은 예시예요 · 결제는 테스트 결제(실제 청구 없음)'), findsOneWidget);
      expect(find.koText('무료'), findsOneWidget);
      expect(find.koText('계약 지킴이 패스'), findsOneWidget);
      // '예시'는 한 번씩만 — 돈을 받는 패스에만 짧은 꼬리표, 0원에는 없다. 내부 말('팀 확정 전'·'결선 시연 기간')은 없다
      expect(find.koText('예시 가격', skipOffstage: false), findsOneWidget);
      expect(find.koTextContaining('팀 확정 전', skipOffstage: false), findsNothing);
      expect(find.koTextContaining('결선 시연 기간', skipOffstage: false), findsNothing);
      expect(find.koText('기관용', skipOffstage: false), findsOneWidget);
      expect(find.koText('문의', skipOffstage: false), findsOneWidget);
    });

    testWidgets('패스의 [테스트 결제로 패스 열기]는 결제 화면으로 간다', (tester) async {
      await pumpPricing(tester, _FakePayments());

      await tester.scrollUntilVisible(
        find.koText('테스트 결제로 패스 열기'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.koText('테스트 결제로 패스 열기'));
      await tester.pumpAndSettle();

      expect(find.text('결제 화면 guardian_pass'), findsOneWidget);
    });

    testWidgets('이미 패스가 있으면 결제 버튼 대신 "패스가 있어요"', (tester) async {
      PassStore.instance.set(
        const GuardianPass(
          planId: 'guardian_pass',
          planName: '계약 지킴이 패스',
          orderId: 'jsp_already',
          amount: 9900,
        ),
      );
      await pumpPricing(tester, _FakePayments());

      expect(find.koText('테스트 결제로 패스 열기', skipOffstage: false), findsNothing);
      expect(
        find.koText('패스가 있어요 · 테스트 결제 — 실제 청구 없음', skipOffstage: false),
        findsOneWidget,
      );
    });
  });

  group('테스트 결제', () {
    testWidgets('결제위젯은 서버 가격으로 그리고, 결제가 끝나면 서버가 승인 → 영수증 + 패스', (tester) async {
      final payments = _FakePayments();
      final gateway = _FakeGateway(_paid);
      final created = <String>[];
      await _pumpCheckout(tester, payments: payments, gateway: gateway, createdFor: created);

      // 결제 전: 테스트 결제 표시 + 예시 가격 + 결제 수단 자리
      expect(find.koText(kTestPaymentNotice), findsOneWidget);
      // 진짜 카드를 넣으라는 말로 읽히지 않게(지수 #9)
      expect(find.koText(kTestPaymentPracticeLine), findsOneWidget);
      expect(find.koText('예시 가격(확정 전)'), findsOneWidget);
      expect(find.text('결제 수단 자리 (가짜)'), findsOneWidget);
      expect(gateway.rendered, [9900]); // 서버가 준 요금제 가격
      expect(created, ['device_owner_for_test']); // 주인 키(한 곳)로 결제위젯을 만든다

      await tester.tap(find.koText('테스트 결제하기'));
      await tester.pumpAndSettle();

      // 결제창 결과를 그대로 서버에 넘긴다 — 금액 검사는 서버 몫
      expect(payments.confirms, [
        {
          'planId': 'guardian_pass',
          'orderId': gateway.orders.single,
          'paymentKey': 'pk_test_0001',
          'amount': 9900,
        },
      ]);
      expect(RegExp(r'^[A-Za-z0-9_-]{6,64}$').hasMatch(gateway.orders.single), isTrue);

      // 영수증 — 어디에나 "테스트 결제 — 실제 청구 없음"
      expect(find.koText('계약 지킴이 패스가 열렸어요'), findsOneWidget);
      expect(find.koText(kTestPaymentNotice), findsOneWidget);
      expect(find.koText('9,900원 (예시 가격)'), findsOneWidget);
      expect(find.koText('없음 (테스트 결제)'), findsOneWidget);
      expect(find.koText(kPassIncludesLine, skipOffstage: false), findsOneWidget);
      expect(PassStore.instance.active, isTrue);

      // 글자가 커지면 버튼이 화면 아래로 밀린다 — 보이게 내린 뒤 누른다
      await tester.ensureVisible(find.koText('계약 여정으로 가기', skipOffstage: false));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('계약 여정으로 가기'));
      await tester.pumpAndSettle();
      expect(find.text('여정 화면'), findsOneWidget);
    });

    testWidgets('결제창을 닫으면 "결제를 취소했어요" — 서버에 승인을 요청하지 않는다', (tester) async {
      final payments = _FakePayments();
      final gateway = _FakeGateway(
        (_) => const PaymentOutcome.failure(
          errorCode: 'PAY_PROCESS_CANCELED',
          errorMessage: '사용자에 의해 결제가 취소되었습니다.',
        ),
      );
      await _pumpCheckout(tester, payments: payments, gateway: gateway);

      await tester.tap(find.koText('테스트 결제하기'));
      await tester.pumpAndSettle();

      expect(find.koText('결제를 취소했어요'), findsOneWidget);
      expect(payments.confirms, isEmpty);
      expect(PassStore.instance.active, isFalse);
      expect(find.koText('테스트 결제하기'), findsOneWidget); // 다시 할 수 있다
    });

    testWidgets('승인 확인이 끊기면 같은 주문으로 [다시 확인하기]', (tester) async {
      final payments = _FakePayments(failConfirmTimes: 1);
      final gateway = _FakeGateway(_paid);
      await _pumpCheckout(tester, payments: payments, gateway: gateway);

      await tester.tap(find.koText('테스트 결제하기'));
      await tester.pumpAndSettle();

      expect(find.koText('결제를 확인하지 못했어요. 잠시 후 다시 시도해 주세요'), findsOneWidget);
      expect(find.koText('다시 확인하기'), findsOneWidget);
      // 결제창을 다시 띄우지 않는다(두 번 결제되지 않게)
      expect(find.koText('테스트 결제하기'), findsNothing);

      await tester.tap(find.koText('다시 확인하기'));
      await tester.pumpAndSettle();

      expect(payments.confirms.length, 2);
      expect(payments.confirms[1]['orderId'], payments.confirms[0]['orderId']);
      expect(gateway.orders.length, 1);
      expect(find.koText('계약 지킴이 패스가 열렸어요'), findsOneWidget);
    });

    testWidgets('실제 키(live_)로 빌드된 앱은 결제를 열지 않는다', (tester) async {
      final created = <String>[];
      await _pumpCheckout(
        tester,
        payments: _FakePayments(),
        gateway: _FakeGateway(_paid),
        clientKey: 'live_gck_aaaaaaaaaaaaaaaa',
        createdFor: created,
      );

      expect(find.koTextContaining('테스트 결제만 지원해요'), findsOneWidget);
      expect(find.koText('테스트 결제하기'), findsNothing);
      expect(created, isEmpty); // 결제위젯을 만들지도 않는다
    });
  });

  group('지킴이 패스 표시 (표시만)', () {
    testWidgets('패스가 없으면 아무것도 그리지 않고, 생기면 "지킴이 패스"', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: const Scaffold(body: Center(child: GuardianPassBadge())),
        ),
      );
      expect(find.koText(kGuardianPassBadgeLabel), findsNothing);

      PassStore.instance.set(
        const GuardianPass(
          planId: 'guardian_pass',
          planName: '계약 지킴이 패스',
          orderId: 'jsp_badge_0001',
          amount: 9900,
        ),
      );
      await tester.pump();
      expect(find.koText(kGuardianPassBadgeLabel), findsOneWidget);
    });

    test('패스가 있으면 알림 머리줄에 "계약 지킴이 패스" — 울리는 때·문구는 같다', () {
      final schedule = const JourneySchedule().copyWith(
        JourneyDateKey.balance,
        DateTime(2026, 11, 5),
      );
      final now = DateTime(2026, 11, 1, 10);
      final plain = planJourneyReminders(
        propertyKey: 'k',
        alias: '',
        schedule: schedule,
        now: now,
      );
      final withPass = planJourneyReminders(
        propertyKey: 'k',
        alias: '',
        schedule: schedule,
        now: now,
        withPass: true,
      );
      expect(plain.every((r) => r.subText == null), isTrue);
      expect(withPass.every((r) => r.subText == kReminderPassSubText), isTrue);
      expect(withPass.map((r) => r.fireAt), plain.map((r) => r.fireAt));
      expect(withPass.map((r) => r.body), plain.map((r) => r.body));
    });
  });

  group('주인 키 · 금액 표기 · 서버 파일', () {
    test('주인 키는 기기 id에서 만들되 기기 id를 그대로 넘기지 않는다', () {
      const deviceId = '3f2b8c1e-9a4d-4e7b-b1c2-0d9e8f7a6b5c';
      final key = passOwnerKeyFor(deviceId);
      expect(key, passOwnerKeyFor(deviceId)); // 늘 같다
      expect(key, isNot(contains(deviceId)));
      expect(key, isNot(contains('3f2b8c1e')));
      // 토스 customerKey 규칙: 2~50자, 영문·숫자·-_=.@
      expect(RegExp(r'^[A-Za-z0-9\-_=.@]{2,50}$').hasMatch(key), isTrue, reason: key);
      expect(passOwnerKeyFor('another-device-0002'), isNot(key));
    });

    test('결제 금액은 원 단위 그대로 (만원으로 줄이지 않는다)', () {
      expect(formatPriceWon(9900), '9,900원');
      expect(formatPriceWon(14900), '14,900원');
      expect(formatPriceWon(0), '0원');
      expect(formatPriceWon(1234567), '1,234,567원');
    });

    test('주문번호는 토스 규칙에 맞고 매번 다르다', () {
      final a = newOrderId();
      final b = newOrderId();
      expect(RegExp(r'^[A-Za-z0-9_-]{6,64}$').hasMatch(a), isTrue);
      expect(a, isNot(b));
    });

    test('서버의 요금제 파일(backend/data/pricing.json)을 앱이 그대로 읽는다', () {
      final file = File('../backend/data/pricing.json');
      final pricing = Pricing.fromJson(
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
      );
      expect(pricing.label, '예시 가격(확정 전)');
      expect(pricing.testMode, isTrue); // 파일에 없으면 테스트로 본다
      expect(pricing.plans.map((p) => p.id), ['free', 'guardian_pass', 'institution']);
      final pass = pricing.plan(kGuardianPassPlanId)!;
      expect(pass.purchasable, isTrue);
      expect(pass.priceText, formatPriceWon(pass.price!));
    });
  });
}
