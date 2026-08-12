/// 표시 카드 캐러셀 — 사진 아래 가로 스크롤 목록.
///
/// 왜 필요한가: 등기부 본문 글자는 화면 맞춤 배율에서 3~4px이라, 형광펜만으로는
/// **무엇이 표시됐는지 글로 읽을 수 없다.** 확대하지 않아도 목록으로 알 수 있어야 한다.
///
/// 탭 규칙이 두 겹이다(시안):
/// - **카드 본문** 탭 → 그 표시로 스크롤 + 형광펜 그어짐. **시트는 열리지 않는다.**
///   "어디 있는지"만 보고 싶은 사람을 시트로 막지 않기 위해서다.
/// - **`자세히 보기 ›`** 탭 → 위 동작 + 첫 탭에 바로 시트. 두 번 누르게 하지 않는다.
///
/// ⚠ 카드 문구는 전부 백엔드가 준 것이다(`title` / `body`의 첫 문장). 시안의
///   `oneLiner` 필드는 백엔드에 없어서 지어내지 않았다 — `RegistryHighlight.summary` 참고.
library;

import 'package:flutter/material.dart';

import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../design_system/text/app_text.dart';

/// 카드 폭 — 360dp 기준 210, 넓은 화면(≥412dp)에서 240 (시안 "폭 확장").
const double kCardWidth = 210;
const double kCardWidthWide = 240;
const double kWideScreenWidth = 400;

/// 카드 사이 간격 / 목록 좌우 여백
const double kCardGap = 9;
const double kCarouselPadH = 14;

/// 카드 번호 원 지름
const double kCardBadgeDiameter = 20;

/// `자세히 보기 ›`의 최소 터치 높이 — 접근성 하한.
const double kDetailTapHeight = AppSize.minTouchTarget;

double cardWidthFor(double screenWidth) =>
    screenWidth >= kWideScreenWidth ? kCardWidthWide : kCardWidth;

class RegistryMarkCarousel extends StatelessWidget {
  const RegistryMarkCarousel({
    super.key,
    required this.marks,
    required this.selectedId,
    required this.onTapCard,
    required this.onTapDetail,
    this.controller,
  });

  final List<RegistryHighlight> marks;
  final String? selectedId;

  /// 카드 본문 탭 — 스크롤 + 그어짐만.
  final ValueChanged<RegistryHighlight> onTapCard;

  /// `자세히 보기 ›` 탭 — 위 동작 + 시트.
  final ValueChanged<RegistryHighlight> onTapDetail;

  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    if (marks.isEmpty) return const SizedBox.shrink();
    final width = cardWidthFor(MediaQuery.sizeOf(context).width);
    return ColoredBox(
      color: AppColors.surface,
      // ListView(가로)가 아니라 SingleChildScrollView인 이유: 이 캐러셀은 높이가
      // 정해지지 않은 자리(하단 Column)에 놓인다. 가로 ListView는 세로로 무한히
      // 늘어나려 해서 그 자리에서 레이아웃이 터진다. SingleChildScrollView는 세로를
      // 자식에 맞추고, IntrinsicHeight가 카드들의 높이를 가장 큰 것으로 맞춰 준다.
      child: SingleChildScrollView(
        controller: controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(kCarouselPadH, 2, kCarouselPadH, 12),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < marks.length; i++) ...[
                if (i > 0) const SizedBox(width: kCardGap),
                _MarkCard(
                  mark: marks[i],
                  width: width,
                  selected: marks[i].id == selectedId,
                  onTapCard: () => onTapCard(marks[i]),
                  onTapDetail: () => onTapDetail(marks[i]),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 카드 한 장.
///
/// 높이는 제목·요약 줄 수(그리고 시스템 글꼴 크기)에 따라 달라지므로 **상수로 두지
/// 않는다.** 하단이 얼마나 차지하는지는 `test/registry_viewer_layout_test.dart`가
/// 360dp 기준으로 실제로 그려서 잰다.
class _MarkCard extends StatelessWidget {
  const _MarkCard({
    required this.mark,
    required this.width,
    required this.selected,
    required this.onTapCard,
    required this.onTapDetail,
  });

  final RegistryHighlight mark;
  final double width;
  final bool selected;
  final VoidCallback onTapCard;
  final VoidCallback onTapDetail;

  @override
  Widget build(BuildContext context) {
    final color = AppColors.markSolid(mark.markKind.tone);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTapCard,
      child: Container(
        width: width,
        decoration: BoxDecoration(
          color: AppColors.surface,
          // 선택 상태를 테두리 색 + 그림자로 알린다 — 사진 위 형광펜이 진해지는 것과 짝.
          border: Border.all(
            color: selected ? color : AppColors.line,
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(AppRadius.viewerCard),
          boxShadow: selected
              ? const [
                  BoxShadow(
                    color: AppColors.viewerShadowInk,
                    blurRadius: 12,
                    offset: Offset(0, 2),
                  ),
                ]
              : null,
        ),
        // 카드들은 IntrinsicHeight로 높이가 통일돼 있다. 본문을 Expanded로 감싸
        // 남는 공간을 흡수시키면 **`자세히 보기 ›`가 모든 카드에서 같은 높이(바닥)**에
        // 온다. 안 그러면 요약이 1줄인 카드는 링크가 위에, 2줄인 카드는 아래에 있어
        // 눈이 매번 링크를 다시 찾아야 한다(2026-07-27 실기기).
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(13, 11, 13, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _CardBadge(number: mark.badge, color: color),
                        const SizedBox(width: 7),
                        Expanded(
                          child: AppText(
                            mark.title,
                            // 제목이 잘리면 금액이 사라진다("집에 잡힌 빚 (근저당권) · 5억원"의
                            // 뒤쪽이 정보의 핵심이다). 그래서 두 줄까지 허용한다.
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.bodyStrong.copyWith(
                              fontSize: 13.5,
                              height: 1.25,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    AppText(
                      mark.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.body.copyWith(
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 별도 탭 타깃. 카드 본문 탭(스크롤만)과 구분되어야 하므로 안쪽 제스처가
            // 이기게 둔다(가장 안쪽 인식기가 아레나에서 이긴다).
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTapDetail,
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(minHeight: kDetailTapHeight),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.fromLTRB(13, 12, 13, 11),
                child: AppText(
                  '자세히 보기 ›',
                  style: AppTypography.label.copyWith(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CardBadge extends StatelessWidget {
  const _CardBadge({required this.number, required this.color});

  final int number;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: kCardBadgeDiameter,
      height: kCardBadgeDiameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: AppText(
        '$number',
        // 사진 위 뱃지와 동작을 맞춘다(그쪽은 캔버스라 시스템 글꼴 확대가 안 걸린다)
        textScaler: TextScaler.noScaling,
        style: AppTypography.label.copyWith(
          color: Colors.white,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
