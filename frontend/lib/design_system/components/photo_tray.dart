/// 사진 트레이 — 찍은 등기부 사진을 가로로 늘어놓고 순서·확대·추가를 다루는 띠.
///
/// 설계 근거 (2026-08-03 디자인 핸드오프 "촬영 스튜디오"):
/// · 이 화면은 **서류를 찍는 도구**다. 사진이 주인공이라 트레이가 화면 맨 위에 온다.
/// · 트레이에는 제목 줄도 장수 뱃지도 없다 — 장수는 하단 체크에서 확인한다.
/// · 마지막 슬롯이 [이어서 찍기]라, 한 장 더 찍는 데 다른 곳을 볼 필요가 없다.
///
/// ⚠ **순서는 분석 정확도와 무관하다.** 서버가 여러 장을 한 문서로 묶어 읽기 때문이다
///   (`extraction.py` — PDF 병합 후 1회 호출). "순서를 맞춰야 분석된다"는 뉘앙스의
///   문구를 쓰면 안 된다. 순서 변경은 나중에 다시 볼 때 편하려는 것이다.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import '../../design_system/text/app_text.dart';

class PhotoTray extends StatelessWidget {
  const PhotoTray({
    super.key,
    required this.paths,
    required this.onTapPhoto,
    required this.onAddMore,
    required this.onReorder,
    this.canAddMore = true,
  });

  /// 사진 파일 경로 (표시 순서 = 목록 순서)
  final List<String> paths;

  /// 썸네일 탭 → 크게 보기
  final void Function(int index) onTapPhoto;

  /// 마지막 슬롯 [이어서 찍기]
  final VoidCallback onAddMore;

  /// 드래그로 순서 변경 (oldIndex, newIndex)
  final void Function(int oldIndex, int newIndex) onReorder;

  /// 10장을 채웠어도 슬롯을 **숨기지 않는다** — 눌렀을 때 토스트로 알린다.
  /// (버튼이 사라지면 사용자는 자기가 뭘 잘못했는지 모른다.)
  final bool canAddMore;

  static const double _thumbW = AppSize.trayThumbWidth;
  static const double _thumbH = AppSize.trayThumbHeight;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.viewerBackdrop,
      padding: const EdgeInsets.only(top: AppSpacing.lg, bottom: AppSpacing.md),
      child: SizedBox(
        height: _thumbH,
        child: ReorderableListView.builder(
          scrollDirection: Axis.horizontal,
          buildDefaultDragHandles: false,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
          itemCount: paths.length + 1, // 마지막은 [이어서 찍기]
          onReorder: (oldIndex, newIndex) {
            // 마지막 슬롯([이어서 찍기])은 움직이지도, 그 뒤로 끼워 넣지도 않는다.
            if (oldIndex >= paths.length) return;
            if (newIndex > paths.length) newIndex = paths.length;
            onReorder(oldIndex, newIndex);
          },
          proxyDecorator: (child, index, animation) =>
              Opacity(opacity: 0.4, child: child),
          itemBuilder: (context, i) {
            if (i == paths.length) {
              return Padding(
                key: const ValueKey('photo-tray-add'),
                padding: const EdgeInsets.only(left: AppSpacing.sm),
                child: _addSlot(),
              );
            }
            return Padding(
              key: ValueKey('photo-tray-${paths[i]}'),
              padding: EdgeInsets.only(left: i == 0 ? 0 : AppSpacing.sm),
              child: ReorderableDragStartListener(
                index: i,
                child: _thumb(i),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _thumb(int i) {
    return Semantics(
      button: true,
      label: '${i + 1}번째 사진, 탭하면 크게 보기',
      child: GestureDetector(
        onTap: () => onTapPhoto(i),
        child: SizedBox(
          width: _thumbW,
          height: _thumbH,
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.thumb),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.6)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x38101814), // rgba(16,24,20,.22)
                        blurRadius: 6,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.thumb),
                    child: Image.file(
                      File(paths[i]),
                      fit: BoxFit.cover,
                      // 파일이 사라졌을 때 앱이 죽지 않게 — 회색 자리로 남긴다.
                      errorBuilder: (_, _, _) => const ColoredBox(
                        color: AppColors.line,
                        child: Center(
                          child: Icon(
                            Icons.broken_image_outlined,
                            size: AppSize.iconSm,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 번호 뱃지 — 색이 아니라 **숫자**로 순서를 알린다(색맹 대비).
              Positioned(
                left: 5,
                top: 5,
                child: Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x47101814),
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  child: AppText(
                    '${i + 1}',
                    style: AppTypography.label.copyWith(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              // 확대 칩 — "탭하면 커진다"를 형태로 알린다.
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0x8C0B1A16), // rgba(11,26,22,.55)
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(
                    Icons.zoom_out_map,
                    size: AppSize.iconXs,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _addSlot() {
    return Semantics(
      button: true,
      label: '이어서 찍기',
      child: GestureDetector(
        onTap: onAddMore,
        child: Container(
          width: _thumbW,
          height: _thumbH,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.thumb),
            border: Border.all(
              color: AppColors.primaryDeep.withValues(alpha: 0.35),
              width: 1.5,
              // Flutter에는 점선 Border가 없다. 시각적으로 "임시 슬롯"임을 알리는 것이
              // 목적이므로 옅은 채움 + 가는 테두리로 같은 신호를 만든다.
            ),
            color: Colors.white.withValues(alpha: 0.35),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.add_a_photo,
                size: AppSize.iconMd,
                color: AppColors.primary,
              ),
              const SizedBox(height: AppSpacing.xs),
              AppText(
                '이어서\n찍기',
                textAlign: TextAlign.center,
                style: AppTypography.label.copyWith(
                  color: AppColors.primary,
                  fontSize: 11,
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
