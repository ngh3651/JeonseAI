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
import '../../design_system/text/app_text.dart';

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
    this.emphasis,
    this.tone = AmberHintTone.amber,
    this.icon,
  });

  final String text;

  /// [text] 안에서 **굵게** 칠할 부분 문자열. 없거나 [text]에 없으면 전부 같은 굵기다.
  ///
  /// 스팬 목록이 아니라 부분 문자열로 받는 이유:
  /// ⑴ 호출부에서 문구가 **한 줄로 읽혀야** 한다 — 조각으로 쪼개 적으면 문장을
  ///    눈으로 확인할 수 없고, 조사가 어느 조각에 붙는지 헷갈린다.
  /// ⑵ [text]가 원문 그대로 남아야 스크린 리더·테스트가 볼 것이 하나로 유지된다.
  ///
  /// ⚠ 굵게 해도 **줄 수는 변하지 않는다.** Pretendard 한글은 굵기와 무관하게 글자
  ///   폭이 같고, 조각 경계는 [AppText.rich]가 어절째 이어 붙인다(`keepAllSpan`).
  final String? emphasis;

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

  /// 12px/1.4 — 핸드오프 명세. label(12/w600)보다 가볍게 읽히도록 w400.
  TextStyle get _base => AppTypography.label.copyWith(
    color: _fg,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );

  Widget _label() {
    final String mark = emphasis ?? '';
    // 강조할 말이 없거나 문장에서 못 찾으면 **통짜로 그린다.** 못 찾은 것을 알리려고
    // 화면을 비우거나 예외를 내지 않는다 — 힌트 한 줄이 사라지는 쪽이 더 나쁘다.
    final int at = mark.isEmpty ? -1 : text.indexOf(mark);
    if (at < 0) return AppText(text, style: _base);

    return AppText.rich(
      TextSpan(
        style: _base,
        children: [
          if (at > 0) TextSpan(text: text.substring(0, at)),
          TextSpan(text: mark, style: _base.copyWith(fontWeight: FontWeight.w700)),
          TextSpan(text: text.substring(at + mark.length)),
        ],
      ),
      // 부호도 조각도 없는 원문을 낭독한다.
      semanticsLabel: text,
    );
  }

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
          Expanded(child: _label()),
        ],
      ),
    );
  }
}
