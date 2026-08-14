/// 판정/설명 주체 구분 라벨 — 가드레일 가시화 (IA.md §0).
///
/// 근거 카드 펼침 영역에서 "판정은 규칙 기반(출처), 설명 문장만 AI 생성"임을
/// 사용자·심사위원이 화면에서 인지할 수 있게 한다.
library;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import '../../design_system/text/app_text.dart';

/// 서버가 설명 출처를 알려주지 않을 때 쓰는 종전 라벨 (2026-07-09 결정).
///
/// 옛 이력 리포트에는 `explanationSource`가 없다. 그 문장을 모델이 썼는지 준비된
/// 문구였는지 **지금은 알 수 없으므로**, 둘 다 포괄하는 예전 말을 그대로 쓴다.
const String kLegacyExplanationSource = '자동 생성';

class VerdictSourceLabel extends StatelessWidget {
  const VerdictSourceLabel({
    super.key,
    this.verdictSource,
    this.explanationSource,
  });

  /// 판정 근거 출처 (예: "HUG 전세보증 기준"). null이면 출처 미표기.
  final String? verdictSource;

  /// 이 카드의 **설명 문장**을 누가 썼는가 (2026-08-14 D26).
  ///
  /// 서버가 카드마다 내려준다 — 모델이 썼으면 실제 모델 문자열(`solar-pro2`),
  /// 검증에 걸려 준비된 문장이 나갔으면 `준비된 문구`.
  /// null이면 옛 서버·옛 이력이므로 종전 라벨([kLegacyExplanationSource])을 쓴다.
  final String? explanationSource;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        _chip(
          icon: Icons.rule,
          text: verdictSource == null
              ? '판정 · 규칙 기반'
              : '판정 · 규칙 기반 ($verdictSource)',
          color: AppColors.primary,
          background: AppColors.primarySoft,
        ),
        _chip(
          icon: Icons.auto_awesome,
          // ── [D26 · 2026-08-14] '자동 생성' → 경로에 따라 실제 모델명 ─────────
          //
          // 2026-07-09에 'AI 생성'을 '자동 생성'으로 바꿨던 이유는 그대로 유효하다:
          // LLM이 실패하면 미리 준비한 문장이 나가는데 그때 'AI 생성'은 **거짓말**이다.
          // 그래서 그 결정을 되돌리지 않고 **조건부로 정밀화**한다 —
          //   · 모델이 쓴 카드  → 모델 문자열 그대로 ('설명 · solar-pro2')
          //   · 준비된 문구 카드 → '설명 · 준비된 문구'
          // 두 경우를 서버가 카드마다 갈라 주므로, 어느 쪽도 과대 표기되지 않는다.
          //
          // 옛 서버·옛 이력(필드 없음)은 종전 라벨을 그대로 쓴다 — 이력 화면이
          // 깨지지 않아야 하고, 그때의 문장이 무엇이었는지는 지금 알 수 없다.
          text: '설명 · ${explanationSource ?? kLegacyExplanationSource}',
          color: AppColors.textMuted,
          background: AppColors.background,
        ),
      ],
    );
  }

  Widget _chip({
    required IconData icon,
    required String text,
    required Color color,
    required Color background,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: AppSize.iconXs, color: color),
          const SizedBox(width: AppSpacing.xs),
          // Flexible: 출처가 길면 칩 안에서 줄바꿈 — 화면 밖 오버플로 방지
          Flexible(
            child: AppText(
              text,
              style: AppTypography.label.copyWith(color: color),
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }
}
