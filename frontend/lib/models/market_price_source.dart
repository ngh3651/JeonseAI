/// 시세가 **어디서 왔는지** (api-contract.md §2.8 · 2026-08-03 추가).
///
/// 숫자만 보여 주면 사용자는 그 값을 믿을지 말지 판단할 수 없다. 이 앱의 원칙은
/// "결론은 크게, 근거는 항상 공개"이므로, 시세에도 출처·기준일이 늘 따라붙는다.
///
/// ⚠ 모르는 값이 오면 [MarketPriceSource.unknown]으로 떨어진다 — 하이라이트 종류와
///   같은 처리다. 앱이 구버전 서버와 붙어도 깨지지 않게 하기 위한 것.
library;

enum MarketPriceSource {
  /// 사용자가 S-04에서 직접 넣은 값
  manual('manual'),

  /// 국토교통부 실거래가 (실제 거래된 값 — 조작 가능성이 있다)
  actualTrade('actual_trade'),

  /// 국토교통부 공동주택 공시가격 × 140% (정부가 매긴 값)
  officialPrice('official_price'),

  /// 국세청 오피스텔 기준시가 (정부가 매긴 값)
  taxBase('tax_base'),

  /// 서버가 모르는 값을 보냈거나 출처가 없음
  unknown('');

  const MarketPriceSource(this.wire);

  /// 서버 계약 문자열
  final String wire;

  static MarketPriceSource fromWire(String? wire) {
    if (wire == null || wire.isEmpty) return MarketPriceSource.unknown;
    for (final s in MarketPriceSource.values) {
      if (s.wire == wire) return s;
    }
    return MarketPriceSource.unknown;
  }

  bool get isAuto =>
      this == MarketPriceSource.actualTrade ||
      this == MarketPriceSource.officialPrice ||
      this == MarketPriceSource.taxBase;
}

/// 채택되지 않은 시세 후보 — "왜 이 값을 썼나"를 밝히기 위한 것.
class MarketPriceAlternative {
  const MarketPriceAlternative({
    required this.source,
    required this.sourceName,
    required this.price,
    this.asOf,
    this.sampleCount,
    this.detail,
  });

  final MarketPriceSource source;
  final String sourceName;
  final int price;
  final String? asOf;
  final int? sampleCount;
  final String? detail;

  factory MarketPriceAlternative.fromJson(Map<String, dynamic> json) =>
      MarketPriceAlternative(
        source: MarketPriceSource.fromWire(json['source'] as String?),
        sourceName: (json['sourceName'] as String?) ?? '알 수 없는 출처',
        price: (json['price'] as num).toInt(),
        asOf: json['asOf'] as String?,
        sampleCount: json['sampleCount'] as int?,
        detail: json['detail'] as String?,
      );
}

/// 시세 칸·결과 화면에 붙는 **출처 라벨** 한 줄.
///
/// 문구 규칙 (2026-08-03 디자인 핸드오프 연결):
/// · 자동 조회면 "자동 조회 · <출처> (<기준일>)" — 어디서 언제 기준인지 늘 밝힌다.
/// · 직접 입력이면 그렇게 말한다 — 사용자가 자기가 넣은 값을 자동값으로 오해하면 안 된다.
/// · 조회 실패면 **못 했다고 말한다.** 빌라·희귀 평형은 실제로 조회가 안 되는 일이 잦다.
String marketPriceSourceLabel({
  required MarketPriceSource source,
  String? asOf,
  int? sampleCount,
  bool hasPrice = true,
}) {
  if (!hasPrice) {
    return '자동 조회가 안 됐어요 · 직접 넣으면 더 정확해요';
  }
  switch (source) {
    case MarketPriceSource.manual:
      return '직접 입력하신 값';
    case MarketPriceSource.actualTrade:
      final String period = _period(asOf);
      final String n = sampleCount != null ? ' · $sampleCount건' : '';
      return '자동 조회 · 국토부 실거래가${period.isEmpty ? '' : ' ($period$n)'}';
    case MarketPriceSource.officialPrice:
      return '자동 조회 · 공시가격 기준${_dateSuffix(asOf)}';
    case MarketPriceSource.taxBase:
      return '자동 조회 · 국세청 기준시가${_dateSuffix(asOf)}';
    case MarketPriceSource.unknown:
      return '출처를 알 수 없어요 · 직접 확인이 필요해요';
  }
}

/// '2025-01-01' → ' (2025.1.1)'. 못 읽으면 빈 문자열 — 없는 날짜를 지어내지 않는다.
String _dateSuffix(String? asOf) {
  if (asOf == null || asOf.isEmpty) return '';
  final List<String> parts = asOf.split('-');
  if (parts.length != 3) return ' ($asOf)';
  final int? y = int.tryParse(parts[0]);
  final int? m = int.tryParse(parts[1]);
  final int? d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return ' ($asOf)';
  return ' ($y.$m.$d)';
}

/// '2026-02~2026-07' → '2026.2~7'. 형태가 다르면 원문 그대로.
String _period(String? asOf) {
  if (asOf == null || asOf.isEmpty) return '';
  final List<String> range = asOf.split('~');
  if (range.length != 2) return asOf;
  final List<String> from = range[0].split('-');
  final List<String> to = range[1].split('-');
  if (from.length < 2 || to.length < 2) return asOf;
  final int? fy = int.tryParse(from[0]);
  final int? fm = int.tryParse(from[1]);
  final int? ty = int.tryParse(to[0]);
  final int? tm = int.tryParse(to[1]);
  if (fy == null || fm == null || ty == null || tm == null) return asOf;
  if (fy == ty) return '$fy.$fm~$tm';
  return '$fy.$fm~$ty.$tm';
}
