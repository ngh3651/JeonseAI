/// 결제위젯 경계 — 화면은 이것만 안다 (2026-10-22, P2-1).
///
/// 진짜는 토스페이먼츠 결제위젯([TossPaymentGateway], toss_payment_gateway.dart — SDK를 부르는 **유일한 곳**),
/// 위젯 테스트는 가짜를 넣는다(토스 위젯은 웹뷰라 테스트에서 그릴 수 없다).
library;

import 'package:flutter/widgets.dart';

/// 결제창이 돌려준 결과. 성공이면 [paymentKey]·[orderId]·[amount], 실패면 [errorCode]·[errorMessage].
class PaymentOutcome {
  const PaymentOutcome.success({
    required String this.paymentKey,
    required String this.orderId,
    required int this.amount,
  }) : errorCode = null,
       errorMessage = null;

  const PaymentOutcome.failure({
    required String this.errorCode,
    required String this.errorMessage,
  }) : paymentKey = null,
       orderId = null,
       amount = null;

  final String? paymentKey;
  final String? orderId;
  final int? amount;
  final String? errorCode;
  final String? errorMessage;

  bool get ok => paymentKey != null;

  /// 사용자가 결제창을 닫았다(토스 `PAY_PROCESS_CANCELED`) — 오류가 아니라 취소다.
  bool get canceled => errorCode == 'PAY_PROCESS_CANCELED';
}

abstract class PaymentGateway {
  /// 결제 수단·약관 자리. [render]보다 **먼저** 화면에 붙어 있어야 한다.
  Widget buildForm();

  /// 결제 수단·약관을 그린다. [amount]는 서버가 준 요금제 가격.
  Future<void> render({required int amount});

  /// 결제창을 띄우고 결과를 기다린다.
  Future<PaymentOutcome> requestPayment({
    required String orderId,
    required String orderName,
  });
}

/// 결제위젯을 만드는 함수 — 결제 화면이 받는다(테스트는 가짜를 만드는 함수를 넘긴다).
typedef PaymentGatewayFactory =
    PaymentGateway Function({
      required String clientKey,
      required String customerKey,
    });
