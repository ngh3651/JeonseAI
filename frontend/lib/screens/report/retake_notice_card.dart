/// 리포트의 **다시 올리기 안내** 카드 (2026-10-27, 다시찍기_안내_시안 ①·②).
///
/// 예전 카드(`CaptureIssuePanel`)는 문장 4개 + 쪽마다 긴 설명 + 쪽마다 버튼이라 어수선했다.
/// 이제는 "몇 쪽이 이상한가"만 보이고 바로 다시 올린다:
///   윗줄(흰 원 + 카메라 · 제목 · 부제) → 쪽 알약들("1쪽 아래가 잘림") → [다시 찍기][갤러리에서 고르기].
///
/// 문제의 출처는 둘이다 — 서버가 준 그대로 쓴다.
/// - `captureCheck.pages` — 흐림·어두움·빛 번짐·잘림 … (업로드 순서 `index`)
/// - `missingPages` — 꼬리말 쪽 번호(N/M)로 본 **빠진 쪽** (문서 쪽 번호)
///
/// 찍는 요령("종이 네 모서리와 맨 아래 쪽 번호…")은 카드가 아니라 촬영 화면에 한 줄로 나온다.
/// ⚠ 판정이 아니라 **사진** 안내다 — 주의(앰버) 톤, 위험(빨강)을 쓰지 않는다.
library;

import 'package:flutter/material.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/analysis_report.dart';

/// 쪽 알약 하나 — 어느 쪽이 왜.
@immutable
class RetakePill {
  const RetakePill({
    required this.pageNumber,
    required this.reason,
    this.uploadIndex,
    this.tip = '',
  });

  /// 화면에 쓰는 문서 쪽 번호 (1부터)
  final int pageNumber;

  /// 짧은 이유 — "아래가 잘림" · "흐림" · "빛 번짐" · "빠짐" …
  final String reason;

  /// 올린 사진 순서(0부터). **null이면 빠진 쪽** — 바꿀 사진이 없고 새로 더 올린다.
  final int? uploadIndex;

  /// 그 장의 문제 + 다시 찍는 법(서버 문장) — 촬영 화면에 한 줄로
  final String tip;

  bool get missing => uploadIndex == null;
}

/// 문제 종류 → 알약의 짧은 말. 여럿이면 먼저 고칠 것 하나(서버 우선순위와 같은 순서).
String retakeReason(List<String> issues) {
  const order = [
    ('no_text', '글자 없음'),
    ('too_dark', '어두움'),
    ('too_bright', '빛 번짐'),
    ('blurry', '흐림'),
    ('low_contrast', '흐릿함'),
    ('low_resolution', '너무 작음'),
    // 빚 금액(채권최고액) 칸을 끝내 못 읽은 장 (2026-10-29) — 그 쪽을 다시 찍으면 금액이 채워진다
    ('amount_unread', '금액 못 읽음'),
    // OCR이 맨 아래 쪽 번호(N/M)를 못 찾은 장 — 아래가 잘렸을 때 생긴다
    ('cut_off', '아래가 잘림'),
  ];
  for (final (code, label) in order) {
    if (issues.contains(code)) return label;
  }
  return '잘 안 읽힘';
}

/// 리포트 → 알약 목록 (쪽 번호 순). 문제가 없으면 빈 목록.
///
/// [fallbackPageNumber]: 서버가 그 장의 쪽 번호를 못 읽었을 때 쓸 번호(올린 순서·정렬 순서로).
List<RetakePill> retakePillsFor(
  AnalysisReport report, {
  required int Function(int index) fallbackPageNumber,
}) {
  final pills = <RetakePill>[
    for (final p in report.captureCheck?.pages ?? const <CapturePageIssue>[])
      RetakePill(
        pageNumber: report.pageNumberAt(p.index) ?? fallbackPageNumber(p.index),
        reason: retakeReason(p.issues),
        uploadIndex: p.index,
        tip: p.tip,
      ),
    for (final n in report.missingPages)
      RetakePill(
        pageNumber: n,
        reason: '빠짐',
        tip: '빠진 $n쪽을 찍어 주세요 — 종이 네 모서리와 맨 아래 쪽 번호가 나오게',
      ),
  ]..sort((a, b) => a.pageNumber.compareTo(b.pageNumber));
  return pills;
}

/// 카드 제목 — "1쪽이 잘 안 읽혔어요" · "2장이 잘 안 읽혔어요" · "5쪽이 빠졌어요" · "3장을 다시 올려 주세요"
String retakeTitle(List<RetakePill> pills) {
  final missing = pills.where((p) => p.missing).length;
  final misread = pills.length - missing;
  if (missing == 0) {
    return misread == 1
        ? '${pills.single.pageNumber}쪽이 잘 안 읽혔어요'
        : '$misread장이 잘 안 읽혔어요';
  }
  if (misread == 0) {
    return missing == 1
        ? '${pills.single.pageNumber}쪽이 빠졌어요'
        : '$missing장이 빠졌어요';
  }
  return '${pills.length}장을 다시 올려 주세요';
}

/// 사진이 폰에 없어 전체를 다시 찍을 때의 최대 장수 — 처음 분석 화면과 같은 10장
const int kRetakeMaxPhotos = 10;

const String kRetakeSubtitle = '다시 올리면 결과가 더 정확해요';
const String kRetakeShootLabel = '다시 찍기';
const String kRetakeGalleryLabel = '갤러리에서 고르기';

class RetakeNoticeCard extends StatelessWidget {
  const RetakeNoticeCard({
    super.key,
    required this.pills,
    required this.onShoot,
    required this.onGallery,
  });

  final List<RetakePill> pills;
  final VoidCallback onShoot;
  final VoidCallback onGallery;

  static const double _gap = 14;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('retake-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cautionSoft,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.photo_camera_outlined,
                  size: 22,
                  color: AppColors.caution,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      retakeTitle(pills),
                      key: const ValueKey('retake-title'),
                      style: AppTypographyNext.bodyStrong.copyWith(
                        color: AppColorsNext.textStrong,
                      ),
                    ),
                    AppText(
                      kRetakeSubtitle,
                      style: AppTypographyNext.caption.copyWith(
                        color: AppColorsNext.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: _gap),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final p in pills) _Pill(pill: p)],
          ),
          const SizedBox(height: _gap),
          _Buttons(onShoot: onShoot, onGallery: onGallery),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.pill});

  final RetakePill pill;

  @override
  Widget build(BuildContext context) {
    final base = AppTypographyNext.caption;
    return Container(
      key: ValueKey('retake-pill-${pill.pageNumber}'),
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(999),
      ),
      child: AppText.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${pill.pageNumber}쪽',
              style: base.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColorsNext.textStrong,
              ),
            ),
            const TextSpan(text: '  '),
            TextSpan(
              text: pill.reason,
              style: base.copyWith(color: AppColors.caution),
            ),
          ],
        ),
      ),
    );
  }
}

/// 버튼 두 개 — 같은 폭으로 나란히(사이 8). 글자가 커서 한 줄에 안 들어가면 위아래로 쌓는다.
class _Buttons extends StatelessWidget {
  const _Buttons({required this.onShoot, required this.onGallery});

  final VoidCallback onShoot;
  final VoidCallback onGallery;

  static const double _iconSize = 18;
  static const double _iconGap = 4;
  static const double _sidePad = 4;

  TextStyle get _label =>
      AppTypographyNext.caption.copyWith(fontWeight: FontWeight.w700);

  /// 아이콘 + 글자 + 좌우 여백이 [width] 안에 한 줄로 들어가나
  bool _fits(BuildContext context, String text, double width) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: _label),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return painter.width + _iconSize + _iconGap + _sidePad * 2 <= width;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final half = (box.maxWidth - 8) / 2;
        final sideBySide =
            _fits(context, kRetakeShootLabel, half) &&
            _fits(context, kRetakeGalleryLabel, half);
        final shoot = _button(
          key: const ValueKey('retake-shoot'),
          icon: Icons.photo_camera_outlined,
          label: kRetakeShootLabel,
          filled: true,
          onTap: onShoot,
        );
        final gallery = _button(
          key: const ValueKey('retake-gallery'),
          icon: Icons.image_outlined,
          label: kRetakeGalleryLabel,
          filled: false,
          onTap: onGallery,
        );
        if (sideBySide) {
          return Row(
            children: [
              Expanded(child: shoot),
              const SizedBox(width: 8),
              Expanded(child: gallery),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [shoot, const SizedBox(height: 8), gallery],
        );
      },
    );
  }

  Widget _button({
    required Key key,
    required IconData icon,
    required String label,
    required bool filled,
    required VoidCallback onTap,
  }) {
    final Color fg = filled ? AppColors.onPrimary : AppColors.caution;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: TextButton(
        key: key,
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor: filled ? AppColors.caution : AppColors.surface,
          foregroundColor: fg,
          padding: const EdgeInsets.symmetric(horizontal: _sidePad),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: _iconSize, color: fg),
            const SizedBox(width: _iconGap),
            Flexible(
              child: AppText(
                label,
                maxLines: 1,
                style: _label.copyWith(color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
