/// 토스페이먼츠 **결제위젯 SDK**를 부르는 유일한 곳 (2026-10-22, P2-1).
///
/// 공식 Flutter SDK(`tosspayments_widget_sdk_flutter`). 결제 수단·약관은 토스가 웹뷰로 그린다.
/// - 키는 **테스트 키만** 쓴다(config.dart `tossClientKey` — 기본값은 토스 문서 공개 테스트 키). 실제 청구 없음.
/// - 결제가 끝나도 여기서 승인하지 않는다 — 결과를 서버(`POST /api/payments/confirm`)로 넘겨
///   서버가 **요금제 가격으로 금액을 검사**한 뒤 토스에 승인을 요청한다.
library;

import 'package:flutter/material.dart';
import 'package:tosspayments_widget_sdk_flutter/model/payment_info.dart';
import 'package:tosspayments_widget_sdk_flutter/model/payment_widget_options.dart';
import 'package:tosspayments_widget_sdk_flutter/payment_widget.dart';
import 'package:tosspayments_widget_sdk_flutter/widgets/agreement.dart';
import 'package:tosspayments_widget_sdk_flutter/widgets/payment_method.dart';

import 'payment_gateway.dart';

class TossPaymentGateway implements PaymentGateway {
  TossPaymentGateway({required String clientKey, required String customerKey})
    : _widget = PaymentWidget(clientKey: clientKey, customerKey: customerKey);

  /// [PaymentGatewayFactory] 모양 — 결제 화면의 기본값.
  static PaymentGateway create({
    required String clientKey,
    required String customerKey,
  }) => TossPaymentGateway(clientKey: clientKey, customerKey: customerKey);

  final PaymentWidget _widget;

  static const String _methodsSelector = 'jeonseai-payment-methods';
  static const String _agreementSelector = 'jeonseai-agreement';

  @override
  Widget buildForm() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      PaymentMethodWidget(paymentWidget: _widget, selector: _methodsSelector),
      AgreementWidget(paymentWidget: _widget, selector: _agreementSelector),
    ],
  );

  @override
  Future<void> render({required int amount}) async {
    // 통화·국가는 SDK 기본값(KRW·KR)
    await _widget.renderPaymentMethods(
      selector: _methodsSelector,
      amount: Amount(value: amount),
    );
    await _widget.renderAgreement(selector: _agreementSelector);
  }

  @override
  Future<PaymentOutcome> requestPayment({
    required String orderId,
    required String orderName,
  }) async {
    final result = await _widget.requestPayment(
      paymentInfo: PaymentInfo(orderId: orderId, orderName: orderName),
    );
    final success = result.success;
    if (success != null) {
      return PaymentOutcome.success(
        paymentKey: success.paymentKey,
        orderId: success.orderId,
        amount: success.amount.toInt(),
      );
    }
    final fail = result.fail;
    if (fail != null) {
      return PaymentOutcome.failure(
        errorCode: fail.errorCode,
        errorMessage: fail.errorMessage,
      );
    }
    // 해외 간편결제처럼 '대기'로 끝난 경우 — 이 앱은 쓰지 않지만 성공으로 치지 않는다
    return const PaymentOutcome.failure(
      errorCode: 'PENDING',
      errorMessage: '결제가 아직 끝나지 않았어요. 잠시 후 다시 확인해 주세요',
    );
  }
}
