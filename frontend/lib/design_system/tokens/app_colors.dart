/// 색 토큰 — 초록 톤 + 마스코트 '세이프' 무드 (docs/draft/컨셉목업_초안.png 기준).
///
/// 규칙:
/// - 화면·컴포넌트는 이 토큰만 참조한다. `Colors.green` 같은 직접 참조 금지.
/// - 등급(RiskGrade) 색은 [gradeColor]/[gradeSoftColor]로만 매핑한다.
library;

import 'package:flutter/material.dart';

import '../../models/registry_mark_kind.dart';
import '../../models/risk_grade.dart';

abstract final class AppColors {
  // ── 밝게 / 어둡게 (2026-10-30 다크 모드) ─────────────────────────
  // 화면은 예전처럼 `AppColors.primary`만 쓴다. 값은 지금 고른 팔레트([AppPalette])에서 온다.
  // 바꾸는 곳은 [apply] 한 곳 — 앱 맨 위(`ThemeController`)가 부르고 화면 전체를 다시 그린다.
  static AppPalette _p = AppPalette.light;

  /// 지금 어두운 팔레트인가
  static bool get isDark => identical(_p, AppPalette.dark);

  /// 밝게/어둡게를 바꾼다. 바꿨으면 true.
  static bool apply(Brightness brightness) {
    final next = brightness == Brightness.dark ? AppPalette.dark : AppPalette.light;
    if (identical(next, _p)) return false;
    _p = next;
    return true;
  }

  /// 진한 색 바탕(초록·빨강·앰버) 위 글자·아이콘 — 밝게는 흰색, 어둡게는 아주 진한 초록
  /// (어둡게의 밝은 초록·빨강 위 흰 글자는 대비가 모자라다)
  static Color get onPrimary => _p.onPrimary;

  /// 뒤집힌 바탕(진한 글자색 바탕 — 지난 리포트 띠·열린 종·열린 '자세히') 위 글자.
  /// 밝게는 흰색, 어둡게는 바탕이 밝은 회색이 되므로 아주 진한 색.
  static Color get onInverse =>
      isDark ? const Color(0xFF0D1210) : const Color(0xFFFFFFFF);

  /// 회색 데이터 칩(실제 판례 · 실제 경매 통계 · 법이 정한 서류) 바탕 / 글자 — 화면마다 따로 두던 #ECEFED·#3C4842
  static Color get chipBg =>
      isDark ? const Color(0xFF26302B) : const Color(0xFFECEFED);
  static Color get chipFg =>
      isDark ? const Color(0xFFC9D3CE) : const Color(0xFF3C4842);

  /// 빈 막대(손실 막대 바탕) — 화면마다 따로 두던 #E3E7E5
  static Color get barIdle =>
      isDark ? const Color(0xFF2A3530) : const Color(0xFFE3E7E5);

  /// 연앰버 바탕 위 진한 앰버 글자(말로만 · 특약 복사) — 화면마다 따로 두던 #7A4A05
  static Color get cautionStrong =>
      isDark ? const Color(0xFFF5CB78) : const Color(0xFF7A4A05);

  /// 진한 초록 **글자** — 밝게는 [primaryDeep]과 같고 어둡게는 연한 초록(어두운 바탕 위 진한 초록 글자는 안 보인다).
  /// [primaryDeep]은 이제 **바탕** 전용이다.
  static Color get primaryStrong => _p.primaryStrong;

  // ── 브랜드 그린 ──────────────────────────────────────────────
  /// 주 브랜드 색 (버튼·활성 탭·강조)
  static Color get primary => _p.primary;

  /// 딥 그린 — 온보딩/시작 화면 배경, 헤더 (목업의 짙은 초록 무드)
  static Color get primaryDeep => _p.primaryDeep;

  /// 밝은 포인트 그린 — 게이지 진행선, 아이콘 포인트
  static Color get primaryBright => _p.primaryBright;

  /// 연한 민트 서피스 — 강조 카드 배경, 선택 상태
  static Color get primarySoft => _p.primarySoft;

  // ── 시맨틱 (등급·상태) ───────────────────────────────────────
  // 각 색은 텍스트/뱃지 글자로 쓰일 때 WCAG AA(4.5:1)를 만족해야 한다.
  // 2026-07-09 팀 피드백 F11(더 맑고 밝은 색) 반영: 대비 통과 범위에서 최대한 밝게 조정.
  // (밝은 색은 대비가 떨어지므로 "글자 테두리" 제안은 반려하고 AA 통과 색으로 해결.)
  /// 위험 — 글자용 (흰카드 4.98:1 / dangerSoft 4.28:1 / F5 배경 4.57:1)
  static Color get danger => _p.danger;
  static Color get dangerSoft => _p.dangerSoft;

  /// 확인 필요 — 글자용, 앰버 (흰카드 4.92:1 / cautionSoft 4.36:1 / F5 배경 4.52:1)
  /// 앰버는 더 밝히면 4.5:1이 깨지므로 이 값이 "노랑 계열" 하한이다.
  static Color get caution => _p.caution;
  static Color get cautionSoft => _p.cautionSoft;

  /// 양호 — 글자용 (흰카드 5.43:1 / okSoft 4.76:1 / F5 배경 4.98:1)
  static Color get ok => _p.ok;
  static Color get okSoft => _p.okSoft;

  // ── 게이지 호(그래픽) 전용 — 텍스트보다 한 단계 밝게 (F11) ─────
  // 그래픽 요소라 3:1 기준. 게이지 호는 흰카드/F5 배경/트랙(line) 위에 그려진다.
  /// 위험 호 (흰 4.40 / F5 4.03 / 트랙 3.53 — 모두 ≥3:1)
  static Color get dangerArc => _p.dangerArc;

  /// 확인 필요 호 — 앰버는 밝히면 3:1이 깨져 글자용과 동일 유지 (F5 4.52 / 트랙 ≈4:1)
  static Color get cautionArc => caution;

  /// 양호 호 (흰 4.02 / F5 3.69 / 트랙 3.23 — 모두 ≥3:1)
  static Color get okArc => _p.okArc;

  // ── 중립 ─────────────────────────────────────────────────────
  static Color get textStrong => _p.textStrong; // 제목·결론
  static Color get textBody => _p.textBody; // 본문
  static Color get textMuted => _p.textMuted; // 보조·캡션 (background 위 ≈5.1:1)
  static Color get line => _p.line; // 구분선·테두리(챗봇 말풍선 등)
  static Color get surface => _p.surface; // 카드 표면
  // 화면 배경 — 흰 카드와 대비되는 중립 회색 (2026-07-09 F1: 초록 틴트 제거)
  static Color get background => _p.background;
  static Color get dim => _p.dim; // 바텀시트 딤

  // ── 촬영 스튜디오 (S-04 재디자인 · 2026-08-03 디자인 핸드오프) ─────────────
  // 핸드오프 명세에 있는데 토큰에 없던 값만 추가한다. 나머지(primary·primaryDeep·
  // primaryBright·primarySoft·viewerBackdrop·caution·cautionSoft·line·surface…)는
  // 전부 기존 토큰을 그대로 쓴다 — 새 색 계열을 만들지 않는다.

  /// 카메라 프리뷰·사진 뷰어의 전면 배경. 검정(#000)이 아니라 아주 어두운 초록기다 —
  /// 앱 전체가 초록 톤이라 순수 검정은 이 앱의 화면처럼 안 보인다.
  /// 흰 글자 대비 18.6:1로 AA 충족.
  static const Color cameraBackdrop = Color(0xFF0C100E);

  /// 비활성 주 버튼 — 배경 rgba(22,33,27,.12) / 글자 rgba(22,33,27,.38).
  /// ⚠ 글자 대비가 낮은 것은 **의도**다(비활성임을 알려야 한다). 대신 사진 0장일 때는
  ///   버튼을 아예 그리지 않고, 비활성일 때는 '무엇이 모자란지'를 체크 2개로 보여준다.
  static Color get buttonDisabledBg => _p.buttonDisabledBg;
  static Color get buttonDisabledFg => _p.buttonDisabledFg;

  /// 사진 트레이 썸네일 그림자 — rgba(16,24,20,.22) (2026-10-23 D7: photo_tray.dart의 hex를 토큰으로)
  static Color get thumbShadow => _p.thumbShadow;

  /// 사진 트레이 확대 칩 바탕 — rgba(11,26,22,.55). 흰 아이콘이 사진 위에서도 보이게
  static const Color thumbChipScrim = Color(0x8C0B1A16);

  // ── 원본 사진 마킹 (S-07b 하이라이트 전용) ────────────────────
  // ⚠ 판정 색과 **계보를 분리**해 둔다. 지금은 값이 같아도, 판정 색을 바꿀 때
  //   마킹까지 따라 바뀌면 안 된다 (마킹은 '위치 안내'이지 '위험도 판정'이 아니다 —
  //   api-contract §9.6 "표시와 판정 완전 분리").
  //
  // 형광펜 채움 — 흰 종이 위 합성색 #FFEE99. 종이 대비는 1.17:1로 낮지만
  // **검은 인쇄 글자 대비가 17.9:1**이라 칠한 글자를 그대로 읽을 수 있다.
  // (불투명하게 칠하면 정작 그 글자를 못 읽는 최악이 된다 — 2026-07-27 디자인 리뷰)
  static const Color markerFill = Color(0x66FFD400);
  // 형광펜 테두리 — 채움만으로는 종이와 경계가 안 생기므로 테두리가 유일한 경계다.
  // caution(#A16207)을 쓴다: 흰 배경 4.92:1로 AA 통과 + 앱 앰버 계열 통일.
  static Color get markerStroke => caution;
  // 위험 마킹 — 등기부 원본의 빨간 취소선(#FF0000)과 대비 1.24:1로 사실상 같은 색이다.
  // **색으로 구분할 수 없으므로 흰 halo를 함께 그려 '앱이 얹은 것'임을 형태로 알린다.**
  static Color get markerAttention => danger;
  static const Color markerHalo = Color(0xD9FFFFFF);

  // ── 사진 뷰어 재디자인 (2026-07-27 디자인 핸드오프 · **채택 미확정**) ──
  // 위 마킹 토큰(markerFill·markerAttention…)을 **덮어쓰지 않고 나란히 둔다.**
  // 재디자인이 반려되면 예전 화면이 그대로 살아 있어야 하기 때문이다.
  // 빨간 타원 → 형광펜으로 바뀌면서 "원본 빨간 말소선과 색이 겹친다"는 문제 자체가
  // 사라져, 여기에는 halo 계열 토큰이 없다.

  /// 종이 뒤 배경 — 흰 종이를 띄우기 위한 옅은 초록. 크롬(앱바·레일)은 흰색을 유지한다.
  static Color get viewerBackdrop => _p.viewerBackdrop;

  /// 위치 레일 트랙
  static Color get viewerRailTrack => _p.viewerRailTrack;

  /// 진입 카드 테두리 / 미리보기 스트립 경계선
  static Color get viewerEntryBorder => _p.viewerEntryBorder;
  static Color get viewerEntryDivider => _p.viewerEntryDivider;

  // 형광펜 — **불투명하게 칠하지 않는다.** BlendMode.multiply로 겹쳐 글자가 비쳐
  // 보여야 한다(칠한 글자를 못 읽으면 대조라는 목적 자체가 무너진다).
  /// 따져볼 곳(주황) — 기본 / 선택
  static const Color markHighlightRisk = Color(0x80FF9F40); // rgba(255,159,64,.5)
  static const Color markHighlightRiskOn = Color(0xB8FF8A00); // rgba(255,138,0,.72)

  /// 대조할 곳(초록) — 기본 / 선택
  static const Color markHighlightVerify = Color(0x6B2DA46E); // rgba(45,164,110,.42)
  static const Color markHighlightVerifyOn = Color(0xB82DA46E); // rgba(45,164,110,.72)

  /// 번호 뱃지·카드 강조 (불투명) — 주황은 흰 배경 5.7:1로 AA 통과
  static const Color markSolidRisk = Color(0xFFB54708);
  static const Color markSolidVerify = Color(0xFF14724B);

  /// '사진 속 이름 가리기' 상자 — **완전 불투명**(알파 FF). 형광펜과 정반대로 글자가 절대 비치면 안 된다.
  /// 앱의 가장 진한 글자색([textStrong])과 같은 잉크라 사진 위에서 "먹으로 지운 칸"으로 읽힌다.
  static const Color markRedaction = Color(0xFF16211B);

  /// 위치 레일의 표시 점 — 8dp 트랙 위 12dp 원이라 글자가 아닌 그래픽 기준(3:1)
  static const Color markDotRisk = Color(0xFFF79441);
  static const Color markDotVerify = Color(0xFF2DA46E);

  // 그림자 — 전부 같은 잉크색 rgba(16,24,20,*)에서 불투명도만 다르다.
  /// 종이 한 장 (0 1 6, .12) · 선택된 카드 (0 2 12, .12)
  static Color get viewerShadowInk => _p.viewerShadowInk;

  /// 번호 뱃지 (0 1 4, .28) — 흰 종이 위에서 뱃지가 떠 보이게
  static Color get viewerShadowBadge => _p.viewerShadowBadge;

  /// 하단 시트 (0 -8 30, .20)
  static Color get viewerShadowSheet => _p.viewerShadowSheet;

  /// 리포트 진입 카드 (0 2 12, rgba(20,114,75,.10)) — 브랜드 그린 계열 그림자
  static Color get viewerEntryShadow => _p.viewerEntryShadow;

  /// 시트 뒤 딤 — rgba(17,26,22,.42). 앱 기본 [dim](검정 54%)보다 옅고 초록기가 있다.
  static Color get viewerSheetScrim => _p.viewerSheetScrim;

  /// 톤 → 형광펜 색. 선택된 표시는 진하게.
  static Color markHighlight(MarkTone tone, {required bool selected}) =>
      switch (tone) {
        MarkTone.verify => selected
            ? markHighlightVerifyOn
            : markHighlightVerify,
        MarkTone.risk => selected ? markHighlightRiskOn : markHighlightRisk,
      };

  /// 톤 → 뱃지·테두리 등 불투명 색.
  static Color markSolid(MarkTone tone) => switch (tone) {
    MarkTone.verify => markSolidVerify,
    MarkTone.risk => markSolidRisk,
  };

  /// 톤 → 위치 레일 점 색.
  static Color markDot(MarkTone tone) => switch (tone) {
    MarkTone.verify => markDotVerify,
    MarkTone.risk => markDotRisk,
  };

  // ── 등급 매핑 ────────────────────────────────────────────────
  static Color gradeColor(RiskGrade grade) => switch (grade) {
    RiskGrade.danger => danger,
    RiskGrade.caution => caution,
    RiskGrade.ok => ok,
  };

  static Color gradeSoftColor(RiskGrade grade) => switch (grade) {
    RiskGrade.danger => dangerSoft,
    RiskGrade.caution => cautionSoft,
    RiskGrade.ok => okSoft,
  };

  /// 게이지 호(그래픽) 전용 등급 색 — 텍스트 색보다 밝다 (F11).
  static Color gradeArcColor(RiskGrade grade) => switch (grade) {
    RiskGrade.danger => dangerArc,
    RiskGrade.caution => cautionArc,
    RiskGrade.ok => okArc,
  };
}


/// 한 벌의 색 — 밝게([light]) / 어둡게([dark]). 이름은 [AppColors]와 같다.
///
/// 어둡게 원칙(2026-10-30):
/// - 바탕은 순수 검정이 아니라 **아주 어두운 숲 초록**(앱이 초록 톤이라 검정은 남의 앱처럼 보인다).
/// - **위험은 더 또렷하게** — 어두운 바탕에서 빨강을 흐리게 바꾸면 "괜찮은 집"처럼 읽힌다.
///   위험 빨강은 양호 초록보다 바탕 대비가 높게, 글자 색은 모두 4.5:1 이상으로 맞췄다.
/// - 사진(종이) 위 형광펜·가림 상자는 바꾸지 않는다 — 종이는 어둡게에서도 흰 종이다.
final class AppPalette {
  const AppPalette({
    required this.primary,
    required this.onPrimary,
    required this.primaryDeep,
    required this.primaryStrong,
    required this.primaryBright,
    required this.primarySoft,
    required this.danger,
    required this.dangerSoft,
    required this.caution,
    required this.cautionSoft,
    required this.ok,
    required this.okSoft,
    required this.dangerArc,
    required this.okArc,
    required this.textStrong,
    required this.textBody,
    required this.textMuted,
    required this.line,
    required this.surface,
    required this.background,
    required this.dim,
    required this.buttonDisabledBg,
    required this.buttonDisabledFg,
    required this.thumbShadow,
    required this.viewerBackdrop,
    required this.viewerRailTrack,
    required this.viewerEntryBorder,
    required this.viewerEntryDivider,
    required this.viewerShadowInk,
    required this.viewerShadowBadge,
    required this.viewerShadowSheet,
    required this.viewerEntryShadow,
    required this.viewerSheetScrim,
  });

  final Color primary;
  final Color onPrimary;
  final Color primaryDeep;
  final Color primaryStrong;
  final Color primaryBright;
  final Color primarySoft;
  final Color danger;
  final Color dangerSoft;
  final Color caution;
  final Color cautionSoft;
  final Color ok;
  final Color okSoft;
  final Color dangerArc;
  final Color okArc;
  final Color textStrong;
  final Color textBody;
  final Color textMuted;
  final Color line;
  final Color surface;
  final Color background;
  final Color dim;
  final Color buttonDisabledBg;
  final Color buttonDisabledFg;
  final Color thumbShadow;
  final Color viewerBackdrop;
  final Color viewerRailTrack;
  final Color viewerEntryBorder;
  final Color viewerEntryDivider;
  final Color viewerShadowInk;
  final Color viewerShadowBadge;
  final Color viewerShadowSheet;
  final Color viewerEntryShadow;
  final Color viewerSheetScrim;

  /// 밝게 — 예전 값 그대로(설명은 [AppColors]의 각 항목 주석)
  static const AppPalette light = AppPalette(
    primary: Color(0xFF14724B),
    onPrimary: Color(0xFFFFFFFF),
    primaryDeep: Color(0xFF0B3D2A),
    primaryStrong: Color(0xFF0B3D2A),
    primaryBright: Color(0xFF2FA36F),
    primarySoft: Color(0xFFE7F3EC),
    danger: Color(0xFFD32F2F),
    dangerSoft: Color(0xFFFBEAE8),
    caution: Color(0xFFA16207),
    cautionSoft: Color(0xFFFBF0DD),
    ok: Color(0xFF0E7A3D),
    okSoft: Color(0xFFE4F4EB),
    dangerArc: Color(0xFFDE3B30),
    okArc: Color(0xFF1E9150),
    textStrong: Color(0xFF16211B),
    textBody: Color(0xFF3C4842),
    textMuted: Color(0xFF5F6C65),
    line: Color(0xFFE1E8E3),
    surface: Color(0xFFFFFFFF),
    background: Color(0xFFF5F5F5),
    dim: Color(0x8A000000),
    buttonDisabledBg: Color(0x1F16211B),
    buttonDisabledFg: Color(0x6116211B),
    thumbShadow: Color(0x38101814),
    viewerBackdrop: Color(0xFFD9E7DE),
    viewerRailTrack: Color(0xFFEBEFEC),
    viewerEntryBorder: Color(0xFFC9E2D4),
    viewerEntryDivider: Color(0xFFD7E8DE),
    viewerShadowInk: Color(0x1F101814),
    viewerShadowBadge: Color(0x47101814),
    viewerShadowSheet: Color(0x33101814),
    viewerEntryShadow: Color(0x1A14724B),
    viewerSheetScrim: Color(0x6B111A16),
  );

  /// 어둡게 — 숲 속 밤. 대비는 카드 바탕(surface #171F1B) 기준.
  /// 위험 #FF7A6E 6.6:1 > 양호 #3DB06F 6.1:1 (위험이 더 또렷하다) · 확인 필요 #F2B544 9.2:1 · 흐린 글씨 #98A69E 6.6:1 ·
  /// 초록 #3DB580 6.5:1(그 위 글자 #04170E 7.2:1) · 위험 호 #FF6A5C 6.0:1 > 양호 호 #35A867 5.6:1
  static const AppPalette dark = AppPalette(
    primary: Color(0xFF3DB580),
    onPrimary: Color(0xFF04170E),
    primaryDeep: Color(0xFF0F3A28),
    primaryStrong: Color(0xFF9BE3BE),
    primaryBright: Color(0xFF5AD69C),
    primarySoft: Color(0xFF173328),
    danger: Color(0xFFFF7A6E),
    dangerSoft: Color(0xFF3D1D1B),
    caution: Color(0xFFF2B544),
    cautionSoft: Color(0xFF3A2D13),
    ok: Color(0xFF3DB06F),
    okSoft: Color(0xFF15301F),
    dangerArc: Color(0xFFFF6A5C),
    okArc: Color(0xFF35A867),
    textStrong: Color(0xFFEEF3F0),
    textBody: Color(0xFFC9D3CE),
    textMuted: Color(0xFF98A69E),
    line: Color(0xFF2A3530),
    surface: Color(0xFF171F1B),
    background: Color(0xFF0D1210),
    dim: Color(0xB3000000),
    buttonDisabledBg: Color(0x24EEF3F0),
    buttonDisabledFg: Color(0x66EEF3F0),
    thumbShadow: Color(0x66000000),
    viewerBackdrop: Color(0xFF0A0F0D),
    viewerRailTrack: Color(0xFF26302B),
    viewerEntryBorder: Color(0xFF2B4A3B),
    viewerEntryDivider: Color(0xFF243A2F),
    viewerShadowInk: Color(0x66000000),
    viewerShadowBadge: Color(0x80000000),
    viewerShadowSheet: Color(0x99000000),
    viewerEntryShadow: Color(0x00000000),
    viewerSheetScrim: Color(0xB3000000),
  );
}
