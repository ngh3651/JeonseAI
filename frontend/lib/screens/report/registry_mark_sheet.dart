/// 표시 하나의 자세히 보기 — 하단 시트.
///
/// ⚠ **문구는 전부 백엔드가 준 것이다.** 제목(`title`)·본문(`body`)·공동명의 안내
///   (`caution`)·출처(`source`) 어느 것도 앱에서 고치거나 덧붙이지 않는다. 이 화면의
///   설득력은 "앱이 지어낸 말이 하나도 없다"에서 나온다.
///
/// 시안(2a 통합안) 대비 하나 더 둔 것: `caution` 블록.
/// 시안에는 그 슬롯이 없지만 백엔드가 **공동명의 안내**를 여기로 보낸다
/// ("이 집은 4명이 함께 가진 집이에요…"). 슬롯을 없애면 실제 정보가 사라지므로 남긴다.
library;

import 'package:flutter/material.dart';

import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';

/// 시트 진입 시간 (시안: 260ms cubic-bezier(.22,1,.36,1))
const Duration kSheetEnterDuration = Duration(milliseconds: 260);

/// 시트 퇴장 시간 — Material 기본값과 같게 둔다(닫힘은 빠를수록 좋다).
const Duration kSheetExitDuration = Duration(milliseconds: 200);

/// 핸들바 — 38×4
const double kSheetHandleWidth = 38;
const double kSheetHandleHeight = 4;

/// 시트를 연다.
///
/// ⚠ **`transitionAnimationController`를 직접 만들어 넘기지 않는다.**
///   예전에는 260ms를 맞추려고 컨트롤러를 만들어 넘기고 `future.whenComplete`에서
///   버렸는데, 그 future는 **퇴장 애니메이션이 끝나기 전에**(`didPop`이 부르는
///   `didComplete` 시점에) 완료된다. 그래서 되감기는 도중에 컨트롤러가 죽고,
///   `dismissed` 상태가 오지 않아 `finalizeRoute`가 불리지 않는다 →
///   **시트가 화면에 그대로 남는다.** 닫는 길 셋(딤 탭·드래그·뒤로가기)이 전부
///   "컨트롤러를 reverse한다"로 시작하므로 셋이 한꺼번에 막혔다(2026-07-27 실기기).
///   시간 조절은 [AnimationStyle]로 한다 — 컨트롤러는 route가 만들고 route가 버린다.
Future<void> showRegistryMarkSheet(
  BuildContext context,
  RegistryHighlight mark,
) {
  return showModalBottomSheet<void>(
    context: context,
    // 핸들바를 시안 규격(38×4, 구분선 색)으로 직접 그리므로 기본 핸들은 끈다.
    showDragHandle: false,
    backgroundColor: AppColors.surface,
    barrierColor: AppColors.viewerSheetScrim,
    isScrollControlled: true,
    sheetAnimationStyle: AnimationStyle(
      duration: kSheetEnterDuration,
      reverseDuration: kSheetExitDuration,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    ),
    builder: (_) => RegistryMarkSheet(mark: mark),
  );
}

class RegistryMarkSheet extends StatelessWidget {
  const RegistryMarkSheet({super.key, required this.mark});

  final RegistryHighlight mark;

  @override
  Widget build(BuildContext context) {
    final color = AppColors.markSolid(mark.markKind.tone);
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          // 시안: padding 12 18 22
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: kSheetHandleWidth,
                  height: kSheetHandleHeight,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: AppColors.line,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SheetBadge(number: mark.badge, color: color),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      mark.title,
                      style: AppTypography.title.copyWith(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 11),
              Text(
                mark.body,
                style: AppTypography.body.copyWith(fontSize: 13.5, height: 1.62),
              ),
              if (mark.caution != null) ...[
                const SizedBox(height: AppSpacing.md),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: AppColors.cautionSoft,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Text(
                    mark.caution!,
                    style: AppTypography.body.copyWith(
                      fontSize: 13.5,
                      height: 1.62,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              // 출처 한 줄 — 이게 없으면 시트 문장이 "앱이 그냥 하는 말"로 읽힌다.
              Text(
                '${mark.source ?? '등기부 원본'} · 위치 안내이며 위험도 판정이 아닙니다',
                style: AppTypography.caption.copyWith(fontSize: 11.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 시트 제목 앞 번호 원 — 사진 위 뱃지·카드 번호와 같은 것임을 잇는 표식.
class _SheetBadge extends StatelessWidget {
  const _SheetBadge({required this.number, required this.color});

  final int number;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 23,
      height: 23,
      // 제목 첫 줄과 눈높이를 맞춘다 (16.5sp × 1.4 기준)
      margin: const EdgeInsets.only(top: 1),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        '$number',
        // 사진 위 뱃지와 동작을 맞춘다(그쪽은 캔버스라 시스템 글꼴 확대가 안 걸린다)
        textScaler: TextScaler.noScaling,
        style: AppTypography.label.copyWith(
          color: Colors.white,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
