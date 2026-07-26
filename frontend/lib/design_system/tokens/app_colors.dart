/// 색 토큰 — 초록 톤 + 마스코트 '세이프' 무드 (docs/draft/컨셉목업_초안.png 기준).
///
/// 규칙:
/// - 화면·컴포넌트는 이 토큰만 참조한다. `Colors.green` 같은 직접 참조 금지.
/// - 등급(RiskGrade) 색은 [gradeColor]/[gradeSoftColor]로만 매핑한다.
library;

import 'package:flutter/material.dart';

import '../../models/risk_grade.dart';

abstract final class AppColors {
  // ── 브랜드 그린 ──────────────────────────────────────────────
  /// 주 브랜드 색 (버튼·활성 탭·강조)
  static const Color primary = Color(0xFF14724B);

  /// 딥 그린 — 온보딩/시작 화면 배경, 헤더 (목업의 짙은 초록 무드)
  static const Color primaryDeep = Color(0xFF0B3D2A);

  /// 밝은 포인트 그린 — 게이지 진행선, 아이콘 포인트
  static const Color primaryBright = Color(0xFF2FA36F);

  /// 연한 민트 서피스 — 강조 카드 배경, 선택 상태
  static const Color primarySoft = Color(0xFFE7F3EC);

  // ── 시맨틱 (등급·상태) ───────────────────────────────────────
  // 각 색은 텍스트/뱃지 글자로 쓰일 때 WCAG AA(4.5:1)를 만족해야 한다.
  // 2026-07-09 팀 피드백 F11(더 맑고 밝은 색) 반영: 대비 통과 범위에서 최대한 밝게 조정.
  // (밝은 색은 대비가 떨어지므로 "글자 테두리" 제안은 반려하고 AA 통과 색으로 해결.)
  /// 위험 — 글자용 (흰카드 4.98:1 / dangerSoft 4.28:1 / F5 배경 4.57:1)
  static const Color danger = Color(0xFFD32F2F);
  static const Color dangerSoft = Color(0xFFFBEAE8);

  /// 확인 필요 — 글자용, 앰버 (흰카드 4.92:1 / cautionSoft 4.36:1 / F5 배경 4.52:1)
  /// 앰버는 더 밝히면 4.5:1이 깨지므로 이 값이 "노랑 계열" 하한이다.
  static const Color caution = Color(0xFFA16207);
  static const Color cautionSoft = Color(0xFFFBF0DD);

  /// 양호 — 글자용 (흰카드 5.43:1 / okSoft 4.76:1 / F5 배경 4.98:1)
  static const Color ok = Color(0xFF0E7A3D);
  static const Color okSoft = Color(0xFFE4F4EB);

  // ── 게이지 호(그래픽) 전용 — 텍스트보다 한 단계 밝게 (F11) ─────
  // 그래픽 요소라 3:1 기준. 게이지 호는 흰카드/F5 배경/트랙(line) 위에 그려진다.
  /// 위험 호 (흰 4.40 / F5 4.03 / 트랙 3.53 — 모두 ≥3:1)
  static const Color dangerArc = Color(0xFFDE3B30);

  /// 확인 필요 호 — 앰버는 밝히면 3:1이 깨져 글자용과 동일 유지 (F5 4.52 / 트랙 ≈4:1)
  static const Color cautionArc = caution;

  /// 양호 호 (흰 4.02 / F5 3.69 / 트랙 3.23 — 모두 ≥3:1)
  static const Color okArc = Color(0xFF1E9150);

  // ── 중립 ─────────────────────────────────────────────────────
  static const Color textStrong = Color(0xFF16211B); // 제목·결론
  static const Color textBody = Color(0xFF3C4842); // 본문
  static const Color textMuted = Color(
    0xFF5F6C65,
  ); // 보조·캡션 (background 위 ≈5.1:1)
  static const Color line = Color(0xFFE1E8E3); // 구분선·테두리(챗봇 말풍선 등)
  static const Color surface = Color(0xFFFFFFFF); // 카드 표면
  // 화면 배경 — 흰 카드와 대비되는 중립 회색 (2026-07-09 F1: 초록 틴트 제거)
  static const Color background = Color(0xFFF5F5F5);
  static const Color dim = Color(0x8A000000); // 바텀시트 딤

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
  static const Color markerStroke = caution;
  // 위험 마킹 — 등기부 원본의 빨간 취소선(#FF0000)과 대비 1.24:1로 사실상 같은 색이다.
  // **색으로 구분할 수 없으므로 흰 halo를 함께 그려 '앱이 얹은 것'임을 형태로 알린다.**
  static const Color markerAttention = danger;
  static const Color markerHalo = Color(0xD9FFFFFF);

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
