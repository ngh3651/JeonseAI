/// 간격·라운드·크기 토큰.
library;

abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;

  /// 화면 기본 좌우 패딩
  static const double screenPadding = 20;
}

abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;

  /// 알약형 (뱃지·칩)
  static const double pill = 999;
}

abstract final class AppSize {
  /// 주 버튼 높이 — 터치 영역 확보 (접근성 최소 48 이상)
  static const double buttonHeight = 52;

  /// 소형(컴팩트) 버튼 높이 — 인라인 액션용
  static const double compactButtonHeight = 44;

  /// 최소 터치 영역
  static const double minTouchTarget = 48;

  /// 하단 탭바 높이 (중앙 분석 버튼 제외)
  static const double bottomNavHeight = 64;

  /// 아이콘 크기
  static const double iconXs = 14;
  static const double iconSm = 20;
  static const double iconMd = 24;
  static const double iconLg = 28;

  /// 하단 바 중앙 분석 버튼 (일반 탭보다 크게 + 위로 띄움 — IA §2 중앙 강조)
  static const double analyzeButton = 56;
  static const double analyzeButtonLift = 10;
}
