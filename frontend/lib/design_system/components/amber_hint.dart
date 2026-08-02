/// 인라인 앰버 힌트 — 물음표 토글로 켜지는 12px 한 줄 안내 (S-04 촬영 스튜디오).
///
/// 왜 바텀시트가 아니라 인라인인가 (2026-08-03 디자인 핸드오프):
/// 사진이 이미 있는 상태에서 물음표를 누르는 사람은 "이 화면을 떠나고 싶은" 게 아니라
/// "지금 이 칸이 뭔지" 알고 싶은 것이다. 시트를 띄우면 하던 일이 끊긴다.
///
/// 이 앱에서는 여기에 하나를 더 얹었다 — **시세 칸의 출처 라벨**.
/// 시세는 사용자가 넣을 수도, 우리가 공공데이터에서 찾아올 수도 있어서
/// "이 숫자가 어디서 왔는지"를 항상 말해야 한다(근거 전면 공개 원칙).
/// 그래서 [AmberHint]는 도움말이자 출처 표시다.
library;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// 힌트의 톤 — 색만 다르고 형태는 같다.
enum AmberHintTone {
  /// 앰버(기본) — 도움말·주의
  amber,

  /// 초록 — "자동으로 찾아왔다" 같은 긍정 정보
  positive,

  /// 회색 — "직접 넣은 값" 같은 중립 사실
  neutral,
}

class AmberHint extends StatelessWidget {
  const AmberHint({
    super.key,
    required this.text,
    this.tone = AmberHintTone.amber,
    this.icon,
  });

  final String text;
  final AmberHintTone tone;

  /// 없으면 아이콘 없이 글자만 (핸드오프 기본형)
  final IconData? icon;

  Color get _fg => switch (tone) {
    AmberHintTone.amber => AppColors.caution,
    AmberHintTone.positive => AppColors.ok,
    AmberHintTone.neutral => AppColors.textMuted,
  };

  Color get _bg => switch (tone) {
    AmberHintTone.amber => AppColors.cautionSoft,
    AmberHintTone.positive => AppColors.okSoft,
    AmberHintTone.neutral => AppColors.background,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: _fg),
            const SizedBox(width: AppSpacing.xs),
          ],
          Expanded(
            child: Text(
              text,
              // 12px/1.4 — 핸드오프 명세. label(12/w600)보다 가볍게 읽히도록 w400.
              style: AppTypography.label.copyWith(
                color: _fg,
                fontWeight: FontWeight.w400,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
