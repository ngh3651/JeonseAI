/// 타이포 토큰 — Pretendard 기반 스케일.
///
/// "결론(등급) 먼저 크게 → 근거는 펼쳐 보기" 원칙(IA.md §0)에 맞춰
/// 결론용 대형 스타일을 최상단에 둔다. 색은 기본값만 두고 화면에서 덮어쓸 수 있다.
library;

import 'package:flutter/material.dart';

import 'app_colors.dart';

abstract final class AppTypography {
  static const String fontFamily = 'Pretendard';

  /// 결론 헤더의 등급 표기 — 화면에서 가장 큰 글자 (S-07 결론 크게)
  static const TextStyle conclusion = TextStyle(
    fontFamily: fontFamily,
    fontSize: 34,
    height: 1.2,
    fontWeight: FontWeight.w700,
    color: AppColors.textStrong,
  );

  /// 큰 숫자 — 게이지 중앙, 손실 시뮬레이터 금액
  static const TextStyle numberLarge = TextStyle(
    fontFamily: fontFamily,
    fontSize: 28,
    height: 1.2,
    fontWeight: FontWeight.w700,
    color: AppColors.textStrong,
  );

  /// 화면 제목
  static const TextStyle headline = TextStyle(
    fontFamily: fontFamily,
    fontSize: 22,
    height: 1.3,
    fontWeight: FontWeight.w700,
    color: AppColors.textStrong,
  );

  /// 섹션·카드 제목
  static const TextStyle title = TextStyle(
    fontFamily: fontFamily,
    fontSize: 17,
    height: 1.4,
    fontWeight: FontWeight.w600,
    color: AppColors.textStrong,
  );

  /// 본문
  static const TextStyle body = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    height: 1.55,
    fontWeight: FontWeight.w400,
    color: AppColors.textBody,
  );

  /// 본문 강조
  static const TextStyle bodyStrong = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    height: 1.55,
    fontWeight: FontWeight.w600,
    color: AppColors.textStrong,
  );

  /// 보조 설명·캡션 (전문용어 부제, 출처 표기)
  static const TextStyle caption = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: AppColors.textMuted,
  );

  /// 버튼 라벨
  static const TextStyle button = TextStyle(
    fontFamily: fontFamily,
    fontSize: 16,
    height: 1.2,
    fontWeight: FontWeight.w600,
  );

  /// 뱃지·칩 라벨
  static const TextStyle label = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    height: 1.2,
    fontWeight: FontWeight.w600,
  );
}
