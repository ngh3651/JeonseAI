/// 요금제 · 계약 지킴이 패스 (계약 §3.12~§3.14 — 2026-10-22, P2-1).
///
/// - 가격은 팀 확정 전까지 **예시**다 — 서버가 준 [Pricing.label]을 가격 옆 어디에나 붙인다.
/// - 결제는 토스페이먼츠 **테스트 결제**다 — [kTestPaymentNotice]를 결제 화면·영수증 어디에나 붙인다.
/// - 금액은 서버가 정한다. 앱은 서버가 준 [PricingPlan.price]로 결제위젯을 열 뿐이다.
library;

/// 결제 화면·영수증 어디에나 붙이는 말. 서버 응답의 `testNotice`·`notice`와 같다.
const String kTestPaymentNotice = '테스트 결제 — 실제 청구 없음';

/// 가격 옆에 붙이는 말 — 서버가 `label`을 안 주면(옛 서버) 이것.
const String kExamplePriceLabel = '예시 (팀 확정 전)';

/// 계약 지킴이 패스 요금제 id (`data/pricing.json`).
const String kGuardianPassPlanId = 'guardian_pass';

/// 결제 금액 표기 — "9,900원". (보증금용 `formatWon`은 만원 단위로 줄여서 쓰지 않는다 — 14,900원이 "1만원"이 된다)
String formatPriceWon(int won) {
  final String digits = won.abs().toString();
  final buf = StringBuffer(won < 0 ? '-' : '');
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  buf.write('원');
  return buf.toString();
}

class PricingPlan {
  const PricingPlan({
    required this.id,
    required this.name,
    required this.tagline,
    required this.priceText,
    this.price,
    this.period,
    this.purchasable = false,
    this.contact = false,
    this.features = const [],
  });

  final String id;
  final String name;
  final String tagline;

  /// 원. null이면 결제할 수 없다(문의).
  final int? price;

  /// 화면에 그대로 쓰는 값 ("9,900원" · "문의")
  final String priceText;
  final String? period;
  final bool purchasable;
  final bool contact;
  final List<String> features;

  factory PricingPlan.fromJson(Map<String, dynamic> json) => PricingPlan(
    id: json['id'] as String,
    name: json['name'] as String,
    tagline: json['tagline'] as String? ?? '',
    price: json['price'] as int?,
    priceText: json['priceText'] as String? ?? '',
    period: json['period'] as String?,
    purchasable: json['purchasable'] as bool? ?? false,
    contact: json['contact'] as bool? ?? false,
    features: [
      for (final f in (json['features'] as List? ?? const [])) f as String,
    ],
  );
}

class Pricing {
  const Pricing({
    required this.plans,
    this.label = kExamplePriceLabel,
    this.currency = 'KRW',
    this.testMode = true,
    this.testNotice = kTestPaymentNotice,
  });

  /// "예시 (팀 확정 전)"
  final String label;
  final String currency;
  final bool testMode;
  final String testNotice;
  final List<PricingPlan> plans;

  PricingPlan? plan(String id) {
    for (final p in plans) {
      if (p.id == id) return p;
    }
    return null;
  }

  factory Pricing.fromJson(Map<String, dynamic> json) => Pricing(
    label: json['label'] as String? ?? kExamplePriceLabel,
    currency: json['currency'] as String? ?? 'KRW',
    // 서버가 testMode를 안 주면 테스트로 본다(보수적으로 — "실제 청구 없음"을 빼먹지 않게)
    testMode: json['testMode'] as bool? ?? true,
    testNotice: json['testNotice'] as String? ?? kTestPaymentNotice,
    plans: [
      for (final p in (json['plans'] as List? ?? const []))
        PricingPlan.fromJson(p as Map<String, dynamic>),
    ],
  );
}

/// 계약 지킴이 패스 한 장 = 결제 기록 한 건. 카드 번호·영수증 주소는 없다(서버가 버린다).
class GuardianPass {
  const GuardianPass({
    required this.planId,
    required this.planName,
    required this.orderId,
    required this.amount,
    this.method,
    this.approvedAt,
    this.testMode = true,
  });

  final String planId;
  final String planName;
  final String orderId;
  final int amount;

  /// "카드" · "간편결제" 등 (토스가 준 값)
  final String? method;

  /// 토스 승인 시각
  final DateTime? approvedAt;
  final bool testMode;

  factory GuardianPass.fromJson(Map<String, dynamic> json) => GuardianPass(
    planId: json['planId'] as String,
    planName: json['planName'] as String? ?? '계약 지킴이 패스',
    orderId: json['orderId'] as String,
    amount: json['amount'] as int? ?? 0,
    method: json['method'] as String?,
    approvedAt: DateTime.tryParse(json['approvedAt'] as String? ?? '')?.toLocal(),
    testMode: json['testMode'] as bool? ?? true,
  );
}
