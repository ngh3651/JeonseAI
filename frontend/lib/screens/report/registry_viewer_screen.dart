/// S-07b 원본에서 보기 — 내가 올린 등기부 사진 위에 확인할 곳을 표시한다.
///
/// 목적: 사용자가 **손에 든 등기부 종이와 화면을 대조**할 수 있게 하는 것.
/// 은행원이 색연필로 동그라미 치듯, 확인해야 할 항목의 위치를 짚어 준다.
///
/// ⚠ 표시 전용이다. 등급·점수를 바꾸지 않는다.
/// ⚠ 화면에 띄우는 이미지는 반드시 **서버로 보낸 그 JPEG**여야 한다. 갤러리 원본을
///   띄우면 해상도·회전이 달라 좌표가 전부 어긋난다(RegistryPhotoStore 참조).
/// ⚠ 좌표가 없으면 사진만 보여주고 조용히 넘어간다. 에러 문구를 띄우지 않는다 —
///   "AI가 못 읽었다"는 인상을 주는 것보다 사진을 그냥 보여주는 편이 낫다.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../repositories/analysis_repository.dart';
import '../../state/registry_photo_store.dart';

// ── 표시 규격 ──────────────────────────────────────────────────────────────
/// 이름 형광펜 — 종이에 노란 형광펜을 그은 느낌. 글자가 비쳐 보여야 한다.
const Color kOwnerFill = Color(0x66FFD400);
const Color kOwnerStroke = Color(0xFFB98900);

/// 위험 항목 — 빨간 타원(동그라미 치기)
const Color kRiskStroke = AppColors.danger;

/// 뱃지 지름(논리 픽셀). 색만으로 정보를 전달하지 않기 위해 ①②③ 번호를 붙인다.
const double kBadgeDiameter = 22;

/// 최소 터치 영역 — 등기부 글자는 작아서 bbox 그대로면 손가락으로 못 누른다.
const double kMinTouchSize = AppSize.minTouchTarget;

/// 정규화 좌표(0~1) × 화면에 그린 이미지 크기 → 실제 그릴 사각형.
///
/// 순수 함수로 떼어 둔 이유: 좌표 변환이 이 기능에서 가장 잘 틀리는 곳이라
/// 위젯 없이 바로 테스트할 수 있어야 한다.
Rect highlightRect(HighlightBox box, Size displaySize) => Rect.fromLTWH(
  box.x * displaySize.width,
  box.y * displaySize.height,
  box.w * displaySize.width,
  box.h * displaySize.height,
);

/// 탭 판정용 영역 — 너무 작으면 최소 터치 크기까지 넓힌다(가운데 기준).
Rect touchRect(HighlightBox box, Size displaySize) {
  final r = highlightRect(box, displaySize);
  final dx = (kMinTouchSize - r.width).clamp(0.0, double.infinity) / 2;
  final dy = (kMinTouchSize - r.height).clamp(0.0, double.infinity) / 2;
  return r.inflate(0).inflateXY(dx, dy);
}

extension on Rect {
  Rect inflateXY(double dx, double dy) =>
      Rect.fromLTRB(left - dx, top - dy, right + dx, bottom + dy);
}

// ══════════════════════════════════════════════════════════════════════════
// 화면
// ══════════════════════════════════════════════════════════════════════════

class RegistryViewerScreen extends StatefulWidget {
  const RegistryViewerScreen({super.key, required this.reportId});

  final String reportId;

  @override
  State<RegistryViewerScreen> createState() => _RegistryViewerScreenState();
}

class _RegistryViewerScreenState extends State<RegistryViewerScreen> {
  final PageController _pageController = PageController();
  int _page = 0;

  /// 개발용 — 켜면 매칭된 모든 좌표를 굵게 그리고 번호·비율을 함께 찍는다.
  /// 아침에 "좌표가 어긋났다"를 눈으로 진단하기 위한 스위치다.
  bool _debug = false;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<AnalysisRepository>();
    final paths = RegistryPhotoStore.instance.pathsFor(widget.reportId);

    return FutureBuilder<AnalysisReport?>(
      future: repo.getReport(widget.reportId),
      builder: (context, snapshot) {
        final report = snapshot.data;
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (report == null || paths.isEmpty) {
          // 진입점을 숨기므로 정상 흐름에서는 오지 않는다(딥링크 등 예외 대비).
          return Scaffold(
            appBar: AppBar(title: const Text('원본에서 보기')),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Text(
                  '이 분석에 쓴 사진이 남아 있지 않아요.\n새로 분석하면 다시 볼 수 있어요.',
                  textAlign: TextAlign.center,
                  style: AppTypography.body,
                ),
              ),
            ),
          );
        }

        // 사진 장수보다 큰 page 인덱스는 버린다 — 엉뚱한 사진에 그리지 않기 위함.
        final usable = [
          for (final h in report.highlights)
            if (h.page >= 0 && h.page < paths.length) h,
        ];
        final onThisPage = [
          for (final h in usable)
            if (h.page == _page) h,
        ];

        return Scaffold(
          appBar: AppBar(
            title: const Text('원본에서 보기'),
            actions: [
              IconButton(
                icon: Icon(_debug ? Icons.bug_report : Icons.bug_report_outlined),
                tooltip: _debug ? '좌표 진단 끄기' : '좌표 진단 켜기',
                onPressed: () => setState(() => _debug = !_debug),
              ),
            ],
          ),
          body: Column(
            children: [
              _pageHeader(paths.length, usable.length),
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: paths.length,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (_, i) => _RegistryPage(
                    path: paths[i],
                    pageIndex: i,
                    highlights: [
                      for (final h in usable)
                        if (h.page == i) h,
                    ],
                    debug: _debug,
                    onTapHighlight: (h) => _showSheet(context, h),
                  ),
                ),
              ),
              _legend(onThisPage),
            ],
          ),
        );
      },
    );
  }

  Widget _pageHeader(int total, int highlightCount) {
    return Container(
      width: double.infinity,
      color: AppColors.primarySoft,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Text('${_page + 1} / $total', style: AppTypography.bodyStrong),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              total > 1 ? '좌우로 넘기고, 손가락 두 개로 확대할 수 있어요' : '손가락 두 개로 확대할 수 있어요',
              style: AppTypography.caption,
            ),
          ),
          if (highlightCount > 0)
            Text('표시 $highlightCount곳', style: AppTypography.caption),
        ],
      ),
    );
  }

  /// 화면 아래 목록 — 줌하지 않아도 무엇이 표시됐는지 글로 읽을 수 있게 한다.
  /// (작은 글씨 위 형광펜만으로는 무엇을 짚었는지 알 수 없다)
  Widget _legend(List<RegistryHighlight> onThisPage) {
    if (onThisPage.isEmpty) {
      return const SizedBox(height: AppSpacing.md);
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('이 사진에서 확인할 곳', style: AppTypography.caption),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              for (final h in onThisPage)
                _HighlightChip(
                  highlight: h,
                  onTap: () => _showSheet(context, h),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _showSheet(BuildContext context, RegistryHighlight highlight) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.surface,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl,
            0,
            AppSpacing.xl,
            AppSpacing.xxl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _BadgeCircle(
                    number: highlight.badge,
                    color: highlight.isOwner ? kOwnerStroke : kRiskStroke,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(highlight.title, style: AppTypography.title),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text(highlight.body, style: AppTypography.body),
              if (highlight.caution != null) ...[
                const SizedBox(height: AppSpacing.md),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: AppColors.cautionSoft,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Text(highlight.caution!, style: AppTypography.body),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// 사진 1장 (이미지 + 오버레이)
// ══════════════════════════════════════════════════════════════════════════

class _RegistryPage extends StatelessWidget {
  const _RegistryPage({
    required this.path,
    required this.pageIndex,
    required this.highlights,
    required this.debug,
    required this.onTapHighlight,
  });

  final String path;
  final int pageIndex;
  final List<RegistryHighlight> highlights;
  final bool debug;
  final void Function(RegistryHighlight) onTapHighlight;

  /// 파일 헤더만 읽어 원본 픽셀 크기를 구한다(전체 디코딩 없이).
  /// 좌표가 어긋나는 원인 1순위가 "서버로 보낸 이미지와 화면에 띄운 이미지가 다름"이라
  /// 이 값을 로그에 반드시 남긴다.
  static Future<Size> _intrinsicSize(String path) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size = Size(
      descriptor.width.toDouble(),
      descriptor.height.toDouble(),
    );
    descriptor.dispose();
    return size;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Size>(
      future: _intrinsicSize(path),
      builder: (context, snapshot) {
        final intrinsic = snapshot.data;
        if (intrinsic == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            // 이미지를 '가운데 맞춤(contain)'했을 때의 실제 표시 크기를 직접 계산한다.
            // Image 위젯에 맡기면 그려진 사각형을 알 수 없어 오버레이가 어긋난다.
            final display = _fitted(intrinsic, constraints.biggest);
            if (debug) {
              debugPrint(
                '[하이라이트] 사진 ${pageIndex + 1} — 원본 ${intrinsic.width.toInt()}x'
                '${intrinsic.height.toInt()}px / 표시 ${display.width.toStringAsFixed(1)}x'
                '${display.height.toStringAsFixed(1)} / 좌표 ${highlights.length}건',
              );
              for (final h in highlights.take(3)) {
                final r = highlightRect(h.box, display);
                debugPrint(
                  '[하이라이트]   ${h.badge}. ${h.kind} 정규화(${h.box.x.toStringAsFixed(4)}, '
                  '${h.box.y.toStringAsFixed(4)}) → 표시(${r.left.toStringAsFixed(1)}, '
                  '${r.top.toStringAsFixed(1)}) 크기 ${r.width.toStringAsFixed(1)}x'
                  '${r.height.toStringAsFixed(1)}',
                );
              }
            }
            return InteractiveViewer(
              minScale: 1,
              maxScale: 6,
              child: Center(
                child: SizedBox(
                  width: display.width,
                  height: display.height,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) {
                      for (final h in highlights) {
                        if (touchRect(h.box, display)
                            .contains(details.localPosition)) {
                          onTapHighlight(h);
                          return;
                        }
                      }
                    },
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(File(path), fit: BoxFit.fill),
                        RegistryHighlightOverlay(
                          highlights: highlights,
                          debug: debug,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// BoxFit.contain과 동일한 결과 크기.
  static Size _fitted(Size source, Size box) {
    if (source.width <= 0 || source.height <= 0) return Size.zero;
    final scale = (box.width / source.width) < (box.height / source.height)
        ? box.width / source.width
        : box.height / source.height;
    return Size(source.width * scale, source.height * scale);
  }
}

/// 사진 위에 그리는 표시 레이어 — 위젯 테스트에서 단독으로 띄울 수 있게 분리했다.
class RegistryHighlightOverlay extends StatelessWidget {
  const RegistryHighlightOverlay({
    super.key,
    required this.highlights,
    this.debug = false,
  });

  final List<RegistryHighlight> highlights;
  final bool debug;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: HighlightPainter(highlights: highlights, debug: debug),
      // 좌표가 없으면 아무것도 그리지 않는다 — 에러 문구 없이 사진만 보인다.
      child: const SizedBox.expand(),
    );
  }
}

class HighlightPainter extends CustomPainter {
  HighlightPainter({required this.highlights, this.debug = false});

  final List<RegistryHighlight> highlights;
  final bool debug;

  @override
  void paint(Canvas canvas, Size size) {
    for (final h in highlights) {
      final rect = highlightRect(h.box, size);
      if (h.isOwner) {
        _paintHighlighter(canvas, rect);
      } else {
        _paintCircle(canvas, rect);
      }
      if (debug) {
        canvas.drawRect(
          touchRect(h.box, size),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = const Color(0xFF0066FF),
        );
      }
      _paintBadge(canvas, rect, h);
    }
  }

  /// 노란 형광펜 — 글자가 비쳐 보이도록 반투명으로 칠하고 테두리를 얇게 준다.
  void _paintHighlighter(Canvas canvas, Rect rect) {
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(3));
    canvas.drawRRect(rrect, Paint()..color = kOwnerFill);
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = kOwnerStroke,
    );
  }

  /// 빨간 타원 — 은행원이 동그라미 치듯.
  void _paintCircle(Canvas canvas, Rect rect) {
    canvas.drawOval(
      rect.inflate(4),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = kRiskStroke,
    );
  }

  /// ①②③ 번호 뱃지 — 색만으로 정보를 전달하지 않기 위함(접근성).
  void _paintBadge(Canvas canvas, Rect rect, RegistryHighlight h) {
    final color = h.isOwner ? kOwnerStroke : kRiskStroke;
    final center = Offset(
      rect.left - kBadgeDiameter / 2 + 2,
      rect.top - kBadgeDiameter / 2 + 2,
    );
    canvas.drawCircle(center, kBadgeDiameter / 2, Paint()..color = color);
    canvas.drawCircle(
      center,
      kBadgeDiameter / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white,
    );
    final painter = TextPainter(
      text: TextSpan(
        text: '${h.badge}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(HighlightPainter old) =>
      old.highlights != highlights || old.debug != debug;
}

// ══════════════════════════════════════════════════════════════════════════
// 작은 부품
// ══════════════════════════════════════════════════════════════════════════

class _BadgeCircle extends StatelessWidget {
  const _BadgeCircle({required this.number, required this.color});

  final int number;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: kBadgeDiameter,
      height: kBadgeDiameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        '$number',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _HighlightChip extends StatelessWidget {
  const _HighlightChip({required this.highlight, required this.onTap});

  final RegistryHighlight highlight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = highlight.isOwner ? kOwnerStroke : kRiskStroke;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: Container(
        constraints: const BoxConstraints(minHeight: kMinTouchSize),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _BadgeCircle(number: highlight.badge, color: color),
            const SizedBox(width: AppSpacing.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                highlight.title,
                style: AppTypography.bodyStrong,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
