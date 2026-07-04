/// 시세 입력 소스 격리 (decisions.md 2026-07-03 "Phase B 시세 입력").
///
/// 데모: [ManualPriceSource] — 사용자가 S-04에서 직접 입력한 값을 쓴다.
/// 향후: MarketPriceApiSource — 국토부 실거래가 API로 자동 조회 (백로그 "시세 자동 계산").
/// 교체 시 화면·계산 로직은 바뀌지 않아야 한다.
library;

abstract class PriceSource {
  /// 해당 주소의 매매 시세(원). 알 수 없으면 null → 전세가율 카드는 "확인 필요" 상태.
  Future<int?> getMarketPrice({required String address});
}

/// 사용자 수동 입력 시세.
class ManualPriceSource implements PriceSource {
  ManualPriceSource({this.manualPrice});

  /// S-04 매물 검색 화면에서 사용자가 입력한 시세 (선택 입력 — 미입력이면 null).
  int? manualPrice;

  @override
  Future<int?> getMarketPrice({required String address}) async => manualPrice;
}
