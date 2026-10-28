/// 손실 예상 (계약 §3.22 — 2026-10-28). 서버가 **규칙으로** 계산한다 — 앱은 받은 숫자를 그리기만 한다.
///
/// 매각가율 = 그 지역·용도에서 최근 경매로 팔린 값 ÷ 법원 감정가 (대법원 법원경매정보 매각통계).
library;

enum LossStatus {
  /// 계산함
  ok,

  /// 먼저 갚을 빚 ≥ 집값 — 매각가율과 상관없이 돌려받기 어렵다
  debtExceeds,

  /// 시세가 없어 계산하지 않음
  noPrice,

  /// 그 용도의 매각가율 자료가 아직 없음
  noRate;

  /// 모르는 값은 가장 말을 아끼는 쪽(자료 없음)으로 — 지어낸 숫자를 그리지 않게
  static LossStatus fromWire(String? v) => switch (v) {
    'ok' => LossStatus.ok,
    'debt_exceeds' => LossStatus.debtExceeds,
    'no_price' => LossStatus.noPrice,
    _ => LossStatus.noRate,
  };
}

class LossEstimate {
  const LossEstimate({
    required this.status,
    required this.deposit,
    this.basePrice,
    this.seniorDebt = 0,
    this.ratePct,
    this.region,
    this.regionFallback = false,
    this.use,
    this.useGuessed = false,
    this.soldCount,
    this.period,
    this.source,
    this.expectedSale,
    this.expectedReturn,
    this.expectedLoss,
  });

  final LossStatus status;
  final int deposit;

  /// 기준가 = 판정에 쓴 시세 (감정가 대신)
  final int? basePrice;

  /// 먼저 갚을 빚 (채권최고액 합계)
  final int seniorDebt;

  /// 매각가율 % (소수 1자리)
  final double? ratePct;

  /// 매각가율을 가져온 지역 — '서울' · '전국'
  final String? region;
  final bool regionFallback;

  /// 매각가율을 가져온 용도 — '연립다세대' 등
  final String? use;
  final bool useGuessed;
  final int? soldCount;

  /// '2025.11~2026.10'
  final String? period;
  final String? source;
  final int? expectedSale;
  final int? expectedReturn;
  final int? expectedLoss;

  factory LossEstimate.fromJson(Map<String, dynamic> j) => LossEstimate(
    status: LossStatus.fromWire(j['status'] as String?),
    deposit: (j['deposit'] as num?)?.toInt() ?? 0,
    basePrice: (j['basePrice'] as num?)?.toInt(),
    seniorDebt: (j['seniorDebt'] as num?)?.toInt() ?? 0,
    ratePct: (j['ratePct'] as num?)?.toDouble(),
    region: j['region'] as String?,
    regionFallback: j['regionFallback'] as bool? ?? false,
    use: j['use'] as String?,
    useGuessed: j['useGuessed'] as bool? ?? false,
    soldCount: (j['soldCount'] as num?)?.toInt(),
    period: j['period'] as String?,
    source: j['source'] as String?,
    expectedSale: (j['expectedSale'] as num?)?.toInt(),
    expectedReturn: (j['expectedReturn'] as num?)?.toInt(),
    expectedLoss: (j['expectedLoss'] as num?)?.toInt(),
  );
}
