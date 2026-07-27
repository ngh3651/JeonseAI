/// 리포트의 '내가 올린 사진에서 보기' 진입 카드.
///
/// 설명 문장 대신 **실제 표시 미리보기**를 보여 준다 — "사진 위에 표시했어요"라고 쓰는
/// 것보다, 자기 등기부에 형광펜이 그어진 조각을 한 번 보여 주는 쪽이 훨씬 강하다.
///
/// 뱃지와 부제는 **세는 대상이 다르다.** 둘 다 있어야 앞뒤가 맞는다:
/// - 뱃지 `위험 3곳` = 위험 톤 표시 개수 (이름은 위험이 아니라 대조할 곳이라 빠진다)
/// - 부제 `집주인 이름 1곳과 빚 3건…` = 전체 내역 (뷰어에 뱃지가 4개인 이유)
/// 뱃지만 두면 "3곳이라더니 뷰어엔 4개"가 되고, 부제만 두면 위험이 몇 건인지 흐려진다.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../design_system/components/mascot_safe.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../models/registry_mark_kind.dart';
import 'registry_document_layout.dart' show kFallbackPageAspect;
import 'registry_mark_stripe.dart';

/// 미리보기 스트립 높이.
///
/// 시안은 106dp였는데 실기기에서 띠가 너무 얇아 "무엇을 보여 주는 것인지" 읽히지
/// 않았다(2026-07-27). 140dp면 표시 줄 위아래로 이웃 줄이 한 줄씩 더 들어와
/// **표에서 어디쯤인지**가 보인다.
const double kPreviewStripHeight = 140;

/// 스트립에서 표시 줄이 **이 높이로 보이도록** 사진을 키운다.
///
/// 시안은 `left:-384, top:-712, width:853` 이라는 오프셋을 그대로 적어 두었지만 그건
/// 시안 샘플 사진 한 장에서만 맞는 값이다. 대신 "글자가 읽히는 크기"를 기준으로 삼는다 —
/// 표시 bbox 높이가 곧 그 줄의 글자 높이이므로, 여기서 역산하면 촬영본이 달라져도
/// 같은 가독성이 나온다. (샘플로 계산하면 사진 폭 849dp ≈ 시안의 853dp)
const double kPreviewTextHeight = 24;

/// 사진을 무한정 키우지 않는다 — bbox가 비정상적으로 얇으면 배율이 폭주한다.
const double kPreviewMaxZoom = 4;

/// 미리보기 하나 때문에 원본 해상도를 통째로 디코딩하지 않는다.
/// 폰 촬영본은 3000px가 넘어 스트립 하나에 30MB 이상이 잡힌다.
const int kPreviewMaxDecodeWidth = 1600;

/// 진입 카드 마스코트 — **앱이 이미 쓰는 에셋**을 그대로 쓴다.
///
/// 시안 번들의 `mascot-search.png`는 투명 배경 체크무늬가 **픽셀로 구워져** 있어
/// 앱에 얹으면 회색 격자가 그대로 보인다(2026-07-27 실기기). 같은 돋보기 포즈가
/// [MascotState.caution]으로 이미 있고 그쪽은 배경이 깨끗하다.
const MascotState kEntryMascotState = MascotState.caution;

// ══════════════════════════════════════════════════════════════════════════
// 미리보기 crop 계산 (순수 — 위젯 없이 테스트한다)
// ══════════════════════════════════════════════════════════════════════════

/// 스트립 안에 사진을 어떤 크기로 어디에 놓을지.
class PreviewCrop {
  const PreviewCrop({required this.imageSize, required this.offset});

  /// 스트립 안에서 사진을 그릴 크기 (스트립보다 크다 — 확대해서 일부만 보인다)
  final Size imageSize;

  /// 스트립 좌상단 기준 사진 좌상단 위치 (보통 음수)
  final Offset offset;

  /// 정규화 bbox → 스트립 좌표계의 사각형.
  Rect markRect(HighlightBox box) => Rect.fromLTWH(
    offset.dx + box.x * imageSize.width,
    offset.dy + box.y * imageSize.height,
    box.w * imageSize.width,
    box.h * imageSize.height,
  );
}

/// 표시 하나가 **읽히는 배율로 스트립 가운데**에 오도록 사진을 배치한다.
///
/// 사진이 스트립을 항상 덮게 하고(빈 곳이 생기지 않게), 가장자리 표시를 중앙에 두려다
/// 사진 밖이 드러나지 않도록 오프셋을 클램프한다.
PreviewCrop previewCropFor({
  required HighlightBox box,
  required Size pageSize,
  required Size strip,
  double targetTextHeight = kPreviewTextHeight,
  double maxZoom = kPreviewMaxZoom,
}) {
  final aspect = pageSize.width > 0 && pageSize.height > 0
      ? pageSize.height / pageSize.width
      : kFallbackPageAspect;
  final wanted = box.h > 0
      ? targetTextHeight / (box.h * aspect)
      : strip.width * maxZoom;
  var w = wanted.clamp(strip.width, strip.width * maxZoom).toDouble();
  var h = w * aspect;
  if (h < strip.height) {
    // 세로가 모자라면 스트립을 덮을 때까지 키운다 (가로로 잘려도 빈 곳보다 낫다)
    h = strip.height;
    w = h / aspect;
  }
  final cx = (box.x + box.w / 2) * w;
  final cy = (box.y + box.h / 2) * h;
  return PreviewCrop(
    imageSize: Size(w, h),
    offset: Offset(
      (strip.width / 2 - cx).clamp(strip.width - w, 0.0).toDouble(),
      (strip.height / 2 - cy).clamp(strip.height - h, 0.0).toDouble(),
    ),
  );
}

/// 미리보기에 쓸 표시를 고른다 — **첫 번째 위험 표시**, 없으면 첫 표시, 그것도 없으면 null.
RegistryHighlight? previewMarkOf(List<RegistryHighlight> marks) {
  for (final m in marks) {
    if (m.markKind.isRisk) return m;
  }
  return marks.isEmpty ? null : marks.first;
}

// ══════════════════════════════════════════════════════════════════════════
// 카드
// ══════════════════════════════════════════════════════════════════════════

/// 미리보기 스트립에 필요한 재료. 하나라도 없으면 스트립 없이 하단 행만 나온다.
class RegistryPreviewSource {
  const RegistryPreviewSource({
    required this.path,
    required this.mark,
    required this.examineCount,
    required this.totalCount,
  });

  /// 그 표시가 있는 쪽의 **서버로 보낸 그 JPEG** 경로
  final String path;
  final RegistryHighlight mark;

  /// 뱃지에 적을 **따져볼 곳** 개수 (이름·주소 같은 '대조할 곳'은 빠진다)
  final int examineCount;

  /// 전체 표시 개수 — 따져볼 곳이 0건일 때 뱃지 문구를 바꾸는 데 쓴다
  final int totalCount;
}

class RegistryEntryCard extends StatelessWidget {
  const RegistryEntryCard({
    super.key,
    required this.subtitle,
    required this.onTap,
    this.preview,
    this.title = '내가 올린 사진에서 보기',
  });

  final String title;

  /// 제목 아래 한 줄. null이면 그 줄 자체가 사라진다.
  ///
  /// 지금은 **등기부 열람일**이 들어온다 — 등기부는 열람 시점의 스냅샷이고, 그 뒤에
  /// 잡힌 근저당은 이 서류에 없다. 계약 직전 근저당 설정이 실제 전세사기 수법이라
  /// "언제 뗀 서류인가"가 개수보다 먼저 알아야 할 사실이다.
  /// ⚠ 분석일로 대체하지 않는다 — 그러면 "오늘 서류"로 믿게 만들어 더 나빠진다.
  final String? subtitle;

  /// null이면 잠긴 상태 — 카드는 **사라지지 않고** 왜 못 여는지를 말한다.
  /// 조용히 없애면 "어제는 있었는데 = 앱이 고장 났다"로 읽힌다(2026-07-27 서연 리뷰).
  final VoidCallback? onTap;

  /// null이면 스트립 없이 하단 행만 (사진이 없거나 표시가 하나도 없을 때).
  final RegistryPreviewSource? preview;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.viewerEntryCard),
      child: Ink(
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.viewerEntryBorder, width: 1.5),
          borderRadius: BorderRadius.circular(AppRadius.viewerEntryCard),
          boxShadow: const [
            BoxShadow(
              color: AppColors.viewerEntryShadow,
              blurRadius: 12,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.viewerEntryCard),
          child: ClipRRect(
            // 스트립이 카드 모서리를 넘지 않게 — 사진이 각진 채 튀어나오면 싸구려로 보인다
            borderRadius: BorderRadius.circular(
              AppRadius.viewerEntryCard - 1.5,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (preview != null) _PreviewStrip(source: preview!),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
                  child: Row(
                    children: [
                      _mascot(enabled),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: AppTypography.bodyStrong.copyWith(
                                fontWeight: FontWeight.w700,
                                color: enabled
                                    ? AppColors.textStrong
                                    : AppColors.textMuted,
                              ),
                            ),
                            if (subtitle != null) ...[
                              const SizedBox(height: 2),
                              Text(subtitle!, style: AppTypography.caption),
                            ],
                          ],
                        ),
                      ),
                      if (enabled)
                        const Padding(
                          padding: EdgeInsets.only(left: AppSpacing.sm),
                          child: Icon(
                            Icons.chevron_right,
                            size: AppSize.iconMd,
                            color: AppColors.primary,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _mascot(bool enabled) => SizedBox(
    width: 38,
    height: 38,
    child: enabled
        ? const MascotSafe(size: 38, state: kEntryMascotState)
        : const Icon(
            Icons.lock_outline,
            size: AppSize.iconLg,
            color: AppColors.textMuted,
          ),
  );
}

/// 표시 한 곳을 확대해 보여 주는 띠.
///
/// 사진 원본 크기를 알아야 배율을 정할 수 있어 [StatefulWidget]이다 — Future는
/// initState에서 **한 번만** 만든다(build 안에서 만들면 재빌드마다 파일을 다시 연다).
class _PreviewStrip extends StatefulWidget {
  const _PreviewStrip({required this.source});

  final RegistryPreviewSource source;

  @override
  State<_PreviewStrip> createState() => _PreviewStripState();
}

class _PreviewStripState extends State<_PreviewStrip> {
  late Future<Size> _sizeFuture;

  @override
  void initState() {
    super.initState();
    _sizeFuture = _intrinsicSize(widget.source.path);
  }

  @override
  void didUpdateWidget(_PreviewStrip old) {
    super.didUpdateWidget(old);
    if (old.source.path != widget.source.path) {
      _sizeFuture = _intrinsicSize(widget.source.path);
    }
  }

  static Future<Size> _intrinsicSize(String path) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(path);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = Size(
        descriptor.width.toDouble(),
        descriptor.height.toDouble(),
      );
      descriptor.dispose();
      return size;
    } catch (_) {
      return Size.zero;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Size>(
      future: _sizeFuture,
      builder: (context, snapshot) {
        final pageSize = snapshot.data;
        // 크기를 못 읽었으면 스트립을 통째로 생략한다 — 배율을 모르는 채로 그리면
        // 엉뚱한 자리를 확대해 보여 주게 되고, 그건 없는 것만 못하다.
        if (pageSize == null || pageSize.width <= 0) {
          return const SizedBox.shrink();
        }
        return SizedBox(
          height: kPreviewStripHeight,
          child: LayoutBuilder(
            builder: (context, constraints) => _strip(
              context,
              pageSize,
              Size(constraints.maxWidth, kPreviewStripHeight),
            ),
          ),
        );
      },
    );
  }

  Widget _strip(BuildContext context, Size pageSize, Size strip) {
    final source = widget.source;
    final crop = previewCropFor(
      box: source.mark.box,
      pageSize: pageSize,
      strip: strip,
    );
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = math.min(
      math.min(pageSize.width.round(), kPreviewMaxDecodeWidth),
      (crop.imageSize.width * dpr).round(),
    );
    final markRect = crop.markRect(source.mark.box);

    return DecoratedBox(
      // ⚠ **foreground**여야 한다. 기본값(background)으로 두면 구분선을 먼저 그리고
      //   그 위에 사진을 덮어 그려서 선이 사라진다(2026-07-27 실기기에서 확인).
      position: DecorationPosition.foreground,
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.viewerEntryDivider),
        ),
      ),
      child: ClipRect(
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              left: crop.offset.dx,
              top: crop.offset.dy,
              width: crop.imageSize.width,
              height: crop.imageSize.height,
              child: Image.file(
                File(source.path),
                fit: BoxFit.fill,
                filterQuality: FilterQuality.medium,
                cacheWidth: cacheWidth > 0 ? cacheWidth : null,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
            Positioned.fromRect(
              rect: markRect,
              child: MarkStripe(tone: source.mark.markKind.tone),
            ),
            Positioned(left: 10, top: 10, child: _badge(source)),
          ],
        ),
      ),
    );
  }

  /// 좌상단 개수 뱃지.
  ///
  /// 문구는 **[MarkTone.legendVerb]에서 가져온다** — 뱃지와 범례가 같은 단어를 쓰게
  /// 강제하기 위해서다. 여기에 문자열을 직접 적으면 범례만 바뀌는 날 둘이 갈라진다.
  ///
  /// 2026-07-28 `위험 n곳` → `따져볼 곳 n곳`. "위험"은 등급 게이지의 어휘이고,
  /// 마킹이 같은 단어를 쓰면 "표시와 판정 완전 분리"(api-contract §9.6)를 화면에서
  /// 스스로 어긴다 — 사용자가 형광펜 개수를 등급의 근거로 읽게 된다.
  ///
  /// 따져볼 곳이 0건이면 `따져볼 곳 0곳`이 되어 사실과 어긋나므로 문구와 색을 함께
  /// 바꾼다 — 표시가 이름뿐인 등기부(근저당이 전부 말소된 경우)에서 실제로 일어난다.
  Widget _badge(RegistryPreviewSource source) {
    final risky = source.examineCount > 0;
    final tone = risky ? MarkTone.risk : MarkTone.verify;
    final count = risky ? source.examineCount : source.totalCount;
    final label = '${tone.legendVerb} $count곳';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.markSolid(risky ? MarkTone.risk : MarkTone.verify),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3),
        style: AppTypography.label.copyWith(
          color: Colors.white,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
