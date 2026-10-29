/// **새 글자 크기·색 체계 (시범)** — 2026-10-24 디자인 확정안(판례 매칭 화면 규칙 문서 §5·§6).
///
/// 지금은 **판례 매칭 화면에만** 쓴다(규혁: "판례에만 먼저 적용하고 괜찮으면 다른 화면도").
/// 괜찮으면 이 값들을 `AppTypography`·`AppColors`로 옮기고 이 파일을 지운다 — 이름을 일부러 같게 맞춰 뒀다.
///
/// 규칙: 15보다 작은 글씨는 쓰지 않는다 · 단위 sp(폰 글자 크기를 따라감) · 흐린 글씨는 회색 배경 위에서도 #5E6B64.
/// ⚠ 굵기 800(ExtraBold)은 앱에 서체 파일이 없어 700으로 보인다(pubspec의 Pretendard는 400·500·600·700).
library;

import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_typography.dart';

/// 새 체계의 색 — 판례 매칭 화면 시범.
abstract final class AppColorsNext {
  /// 제목·카드 결과 문장
  static Color get textStrong =>
      AppColors.isDark ? const Color(0xFFEEF3F0) : const Color(0xFF1C2621);

  /// 본문
  static Color get textBody =>
      AppColors.isDark ? const Color(0xFFDCE4E0) : const Color(0xFF222B27);

  /// 흐린 글씨 (회색 배경 위에서도 대비 4.5:1)
  static Color get textMuted =>
      AppColors.isDark ? const Color(0xFF98A69E) : const Color(0xFF5E6B64);

  /// 연빨강(#FBEAE8) 위 빨강 글씨 — 태그·결과 형광펜 (대비 4.5:1)
  static Color get dangerText =>
      AppColors.isDark ? const Color(0xFFFF7A6E) : const Color(0xFFC62828);

  /// 연한 구분선
  static Color get divider =>
      AppColors.isDark ? const Color(0xFF26302B) : const Color(0xFFECEFED);

  /// '우리 매물과 공통점' 말풍선 바탕 (노랑 = 우리 집과 같은 점)
  static Color get sameSoft =>
      AppColors.isDark ? const Color(0xFF3A2F18) : const Color(0xFFFBF3E4);
}

/// 새 체계의 글자 — 이름은 `AppTypography`와 같다. 줄간격은 디자인 표의 px ÷ 글자 크기.
abstract final class AppTypographyNext {
  static const String _font = AppTypography.fontFamily;

  /// 결론 34 · 800 · 줄 44 · 자간 −3%
  static TextStyle get conclusion => TextStyle(
    fontFamily: _font,
    fontSize: 34,
    height: 44 / 34,
    letterSpacing: -1.02,
    fontWeight: FontWeight.w800,
    color: AppColorsNext.textStrong,
  );

  /// 큰 숫자 28 · 700 · 줄 36 · 자간 −2% · 숫자 폭 고정
  static TextStyle get numberLarge => TextStyle(
    fontFamily: _font,
    fontSize: 28,
    height: 36 / 28,
    letterSpacing: -0.56,
    fontWeight: FontWeight.w700,
    fontFeatures: [FontFeature.tabularFigures()],
    color: AppColorsNext.textStrong,
  );

  /// 화면 제목 24 · 700 · 줄 34 · 자간 −2%
  static TextStyle get headline => TextStyle(
    fontFamily: _font,
    fontSize: 24,
    height: 34 / 24,
    letterSpacing: -0.48,
    fontWeight: FontWeight.w700,
    color: AppColorsNext.textStrong,
  );

  /// 소제목 19 · 700 · 줄 28 · 자간 −1.5% (카드 결과 문장 · 앱바 제목)
  static TextStyle get title => TextStyle(
    fontFamily: _font,
    fontSize: 19,
    height: 28 / 19,
    letterSpacing: -0.285,
    fontWeight: FontWeight.w700,
    color: AppColorsNext.textStrong,
  );

  /// 본문 17 · 400 · 줄 27 · 자간 −1%
  static TextStyle get body => TextStyle(
    fontFamily: _font,
    fontSize: 17,
    height: 27 / 17,
    letterSpacing: -0.17,
    fontWeight: FontWeight.w400,
    color: AppColorsNext.textBody,
  );

  /// 굵은 본문 17 · 600 · 줄 27 · 자간 −1%
  static TextStyle get bodyStrong => TextStyle(
    fontFamily: _font,
    fontSize: 17,
    height: 27 / 17,
    letterSpacing: -0.17,
    fontWeight: FontWeight.w600,
    color: AppColorsNext.textBody,
  );

  /// 작은 글씨 15 · 500 · 줄 22 — 앱 최소 크기
  static TextStyle get caption => TextStyle(
    fontFamily: _font,
    fontSize: 15,
    height: 22 / 15,
    fontWeight: FontWeight.w500,
    color: AppColorsNext.textMuted,
  );

  /// 버튼 18 · 600 · 줄 26 · 자간 −1%
  static TextStyle get button => TextStyle(
    fontFamily: _font,
    fontSize: 18,
    height: 26 / 18,
    letterSpacing: -0.18,
    fontWeight: FontWeight.w600,
    color: AppColorsNext.textStrong,
  );
}
