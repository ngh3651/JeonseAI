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
  // 각 색은 해당 Soft 배경 위 텍스트로 쓰일 때 WCAG AA(4.5:1)를 만족해야 한다
  // (2026-07-04 design-reviewer 대비 감사 반영).
  /// 위험 (dangerSoft 위 ≈5.0:1)
  static const Color danger = Color(0xFFB93530);
  static const Color dangerSoft = Color(0xFFFBEAE8);

  /// 확인 필요 (cautionSoft 위 ≈5.2:1 — 주황 계열은 대비 확보를 위해 어둡게 유지)
  static const Color caution = Color(0xFF935700);
  static const Color cautionSoft = Color(0xFFFBF0DD);

  /// 양호 (okSoft 위 ≈5.3:1, 브랜드 그린과 구분되는 안정 그린)
  static const Color ok = Color(0xFF1B7049);
  static const Color okSoft = Color(0xFFE4F4EB);

  // ── 중립 ─────────────────────────────────────────────────────
  static const Color textStrong = Color(0xFF16211B); // 제목·결론
  static const Color textBody = Color(0xFF3C4842); // 본문
  static const Color textMuted = Color(
    0xFF5F6C65,
  ); // 보조·캡션 (background 위 ≈5.1:1)
  static const Color line = Color(0xFFE1E8E3); // 구분선·테두리
  static const Color surface = Color(0xFFFFFFFF); // 카드 표면
  static const Color background = Color(0xFFF5F8F6); // 화면 배경
  static const Color dim = Color(0x8A000000); // 바텀시트 딤

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
}
