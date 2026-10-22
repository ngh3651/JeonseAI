/// 요금제·결제 승인·내 패스 저장소 (계약 §3.12~§3.14 — 2026-10-22, P2-1).
///
/// 화면은 이 인터페이스에만 의존한다. 실제 주입은 [ApiPaymentRepository](서버), 위젯 테스트는 가짜.
/// 토스 결제위젯 자체는 여기 없다 — services/payment_gateway.dart.
library;

import '../models/pricing.dart';
import '../services/api_client.dart';

abstract class PaymentRepository {
  /// 요금제 (가격은 예시 — [Pricing.label]).
  Future<Pricing> pricing();

  /// 결제위젯이 성공으로 돌려준 값 → 서버 승인 → 패스. 서버가 **요금제 가격으로 금액을 검사**한다.
  ///
  /// 같은 [orderId]로 다시 부르면 서버는 토스를 다시 부르지 않고 같은 패스를 돌려준다
  /// (응답이 끊겼을 때 [다시 확인하기]가 안전한 이유).
  Future<GuardianPass> confirm({
    required String planId,
    required String orderId,
    required String paymentKey,
    required int amount,
  });

  /// 이 기기의 패스. 없으면 null.
  Future<GuardianPass?> myPass();
}

class ApiPaymentRepository implements PaymentRepository {
  ApiPaymentRepository({ApiClient? client}) : _api = client ?? ApiClient();

  final ApiClient _api;

  /// 서버가 토스 승인을 최대 30초 기다린다 — 앱은 그보다 조금 더 기다린다.
  static const Duration _confirmTimeout = Duration(seconds: 45);

  @override
  Future<Pricing> pricing() async =>
      Pricing.fromJson(await _api.getJson('/api/pricing') as Map<String, dynamic>);

  @override
  Future<GuardianPass> confirm({
    required String planId,
    required String orderId,
    required String paymentKey,
    required int amount,
  }) async {
    final body =
        await _api.postJson('/api/payments/confirm', {
              'planId': planId,
              'orderId': orderId,
              'paymentKey': paymentKey,
              'amount': amount,
            }, timeout: _confirmTimeout)
            as Map<String, dynamic>;
    return GuardianPass.fromJson(body['pass'] as Map<String, dynamic>);
  }

  @override
  Future<GuardianPass?> myPass() async {
    final body = await _api.getJson('/api/me/pass') as Map<String, dynamic>;
    final raw = body['pass'];
    if (body['active'] != true || raw is! Map<String, dynamic>) return null;
    return GuardianPass.fromJson(raw);
  }
}
