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

  /// 카드 기본 패딩 (2026-07-09 F5: 가로 18 / 세로 16 — 글자와 여백 확보)
  static const double cardPadH = 18;
  static const double cardPadV = 16;
}

abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;

  /// 알약형 (뱃지·칩)
  static const double pill = 999;

  /// 하단 시트 상단 모서리 (2026-07-27 뷰어 재디자인 시안)
  static const double sheet = 22;

  /// 사진 뷰어 카드 — 캐러셀 카드 15 / 리포트 진입 카드 18
  static const double viewerCard = 15;
  static const double viewerEntryCard = 18;

  // ── 버튼 전용 라운드 (2026-07-09 F2: 신뢰감 위해 각지게) ──
  // 카드(lg=16)와 달리 버튼만 더 각지게 분리한다. 카드 radius는 유지.
  /// 일반 버튼 라운드
  static const double button = 8;

  /// 미니(컴팩트) 버튼 라운드
  static const double buttonMini = 7;
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
