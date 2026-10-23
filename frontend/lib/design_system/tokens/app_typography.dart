/// 타이포 토큰 — Pretendard 기반 스케일.
///
/// "결론(등급) 먼저 크게 → 근거는 펼쳐 보기" 원칙(IA.md §0)에 맞춰
/// 결론용 대형 스타일을 최상단에 둔다. 색은 기본값만 두고 화면에서 덮어쓸 수 있다.
///
/// ⚠ 2026-10-24 **미리보기**: 판례 화면에서 시범한 새 글자 체계(`app_typography_next.dart`)를 앱 전체에 적용.
///   규칙: 15보다 작은 글씨 없음 · 본문 17 · 줄간격 = 디자인 표 px ÷ 글자 크기. 이름은 그대로라 화면 코드는 안 바뀐다.
library;

import 'package:flutter/material.dart';

import 'app_colors.dart';

abstract final class AppTypography {
  static const String fontFamily = 'Pretendard';

  /// 결론 34 · 줄 44 · 자간 −3% — 결론 헤더의 등급 표기 (S-07 결론 크게)
  static const TextStyle conclusion = TextStyle(
    fontFamily: fontFamily,
    fontSize: 34,
    height: 44 / 34,
    letterSpacing: -1.02,
    fontWeight: FontWeight.w700,
    color: AppColors.textStrong,
  );

  /// 큰 숫자 28 · 줄 36 · 숫자 폭 고정 — 게이지 중앙, 손실 시뮬레이터 금액
  static const TextStyle numberLarge = TextStyle(
    fontFamily: fontFamily,
    fontSize: 28,
    height: 36 / 28,
    letterSpacing: -0.56,
    fontWeight: FontWeight.w700,
    fontFeatures: [FontFeature.tabularFigures()],
    color: AppColors.textStrong,
  );

  /// 화면 제목 24 · 줄 34
  static const TextStyle headline = TextStyle(
    fontFamily: fontFamily,
    fontSize: 24,
    height: 34 / 24,
    letterSpacing: -0.48,
    fontWeight: FontWeight.w700,
    color: AppColors.textStrong,
  );

  /// 섹션·카드 제목 19 · 줄 28
  static const TextStyle title = TextStyle(
    fontFamily: fontFamily,
    fontSize: 19,
    height: 28 / 19,
    letterSpacing: -0.285,
    fontWeight: FontWeight.w700,
    color: AppColors.textStrong,
  );

  /// 본문 17 · 줄 27
  static const TextStyle body = TextStyle(
    fontFamily: fontFamily,
    fontSize: 17,
    height: 27 / 17,
    letterSpacing: -0.17,
    fontWeight: FontWeight.w400,
    color: AppColors.textBody,
  );

  /// 본문 강조 17 · 600
  static const TextStyle bodyStrong = TextStyle(
    fontFamily: fontFamily,
    fontSize: 17,
    height: 27 / 17,
    letterSpacing: -0.17,
    fontWeight: FontWeight.w600,
    color: AppColors.textStrong,
  );

  /// 보조 설명·캡션 15 · 500 · 줄 22 — 앱 최소 크기
  static const TextStyle caption = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    height: 22 / 15,
    fontWeight: FontWeight.w500,
    color: AppColors.textMuted,
  );

  /// 버튼 라벨 18 · 600
  static const TextStyle button = TextStyle(
    fontFamily: fontFamily,
    fontSize: 18,
    height: 26 / 18,
    letterSpacing: -0.18,
    fontWeight: FontWeight.w600,
  );

  /// 소형(컴팩트) 버튼 라벨 16 · 600
  static const TextStyle buttonSmall = TextStyle(
    fontFamily: fontFamily,
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w600,
  );

  /// 뱃지·칩 라벨 15 · 600 (최소 크기)
  static const TextStyle label = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    height: 1.3,
    fontWeight: FontWeight.w600,
  );
}
