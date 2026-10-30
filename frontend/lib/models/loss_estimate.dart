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

/// 최우선변제 상태 (2026-10-31 — 주택임대차보호법 제8조, 시행령 제10·11조). 옛 서버면 [none].
enum PriorityStatus {
  /// 더했다 — 낙찰가에서 가장 먼저 받는다
  ok,

  /// 보증금이 그 지역 상한보다 커서 못 받는다
  overCap,

  /// 이미 경매가 시작된 집 — 지금 들어가면 못 받는다
  blockedAuction,

  /// 단독·다가구 — 다른 소액임차인과 나눠 계산에 넣지 않았다
  shared,

  /// 빚 날짜를 못 읽어 표를 고르지 못했다
  unknownDate,

  /// 표가 없다·옛 서버
  none;

  static PriorityStatus fromWire(String? v) => switch (v) {
    'ok' => PriorityStatus.ok,
    'over_cap' => PriorityStatus.overCap,
    'blocked_auction' => PriorityStatus.blockedAuction,
    'shared' => PriorityStatus.shared,
    'unknown_date' => PriorityStatus.unknownDate,
    _ => PriorityStatus.none,
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
    this.priorityStatus = PriorityStatus.none,
    this.priorityAmount = 0,
    this.priorityLimit,
    this.priorityCap,
    this.priorityRegion,
    this.priorityRegionUnsure = false,
    this.priorityTableFrom,
    this.priorityBaseDate,
    this.priorityBaseKind,
    this.priorityHalfCapped = false,
    this.prioritySource,
    this.priorityTableStale = false,
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

  // ── 최우선변제 (2026-10-31) ──
  final PriorityStatus priorityStatus;

  /// 돌려받음에 실제로 더한 금액 (ok일 때만)
  final int priorityAmount;

  /// 그 표·지역에서 먼저 받는 한도(일정액)
  final int? priorityLimit;

  /// 그 표·지역의 보증금 상한
  final int? priorityCap;

  /// '서울특별시' · '수도권 과밀억제권역(서울 제외)' …
  final String? priorityRegion;
  final bool priorityRegionUnsure;

  /// 고른 표가 시작된 날 'YYYY-MM-DD'
  final String? priorityTableFrom;

  /// 그 표를 고른 날짜(가장 먼저 잡힌 담보) — 없으면 오늘 기준
  final String? priorityBaseDate;
  final String? priorityBaseKind;
  final bool priorityHalfCapped;
  final String? prioritySource;

  /// 법제처에서 시행령이 바뀐 걸 알아챘는데 금액표가 아직 그대로다 — '확인 중' 한 줄
  final bool priorityTableStale;

  /// 서버가 최우선변제를 따져 봤나 (옛 서버면 false — 줄을 그리지 않는다)
  bool get hasPriority => priorityStatus != PriorityStatus.none;

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
    priorityStatus: PriorityStatus.fromWire(j['priorityStatus'] as String?),
    priorityAmount: (j['priorityAmount'] as num?)?.toInt() ?? 0,
    priorityLimit: (j['priorityLimit'] as num?)?.toInt(),
    priorityCap: (j['priorityCap'] as num?)?.toInt(),
    priorityRegion: j['priorityRegion'] as String?,
    priorityRegionUnsure: j['priorityRegionUnsure'] as bool? ?? false,
    priorityTableFrom: j['priorityTableFrom'] as String?,
    priorityBaseDate: j['priorityBaseDate'] as String?,
    priorityBaseKind: j['priorityBaseKind'] as String?,
    priorityHalfCapped: j['priorityHalfCapped'] as bool? ?? false,
    prioritySource: j['prioritySource'] as String?,
    priorityTableStale: j['priorityTableStale'] as bool? ?? false,
  );
}
