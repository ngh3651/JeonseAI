/// 계약 여정에서 시작되는 행동들 — 등기부 다시 떼기, 일정 시트 열기.
///
/// 여정 화면·홈 배너·대조 결과 화면이 **같은 입구**를 쓰게 모아 둔다. 세 곳이 각자
/// 촬영 흐름을 열면, 한 곳만 고쳐졌을 때 어떤 경로로 들어왔느냐에 따라 다른 화면이 뜬다.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../design_system/text/app_text.dart';
import '../../models/analysis_report.dart';
import '../compare/compare_screen.dart';
import '../search/capture_loop_route.dart';

/// 대조에 올릴 수 있는 최대 장수 — 분석(S-04)과 같은 상한.
const int kCompareMaxPhotos = 10;

/// 사진 시트의 기본 제목·안내 (처음 대조할 때) — 확정 시안 7-1.
const String kComparePhotoSheetTitle = '새 등기부를 올려 주세요';
const String kComparePhotoSheetSubtitle = '지난 등기부와 비교해서 달라진 곳을 찾아 드려요';

/// 시트 버튼 이름
const String kCompareShootLabel = '촬영 시작';
const String kCompareGalleryLabel = '갤러리에서 고르기';
const String kCompareLaterLabel = '나중에 할게요';

/// 촬영·갤러리로 고른 뒤 한 번 더 보는 화면 (새 등기부 촬영 — 사진 트레이 + [N장으로 비교하기]).
/// [openCamera]면 그 화면이 열리자마자 카메라를 띄운다. 돌려준 목록이 최종 사진(취소면 null).
typedef ReviewPhotos =
    Future<List<String>?> Function(
      List<String> initial, {
      required bool openCamera,
    });

/// **이 화면의 핵심 행동**: 등기부를 다시 떼어 기준 서류와 맞춰본다.
///
/// 기준이 없는 리포트(이 기능 이전 이력·예시)는 **사진을 받기 전에** 대조 화면으로
/// 보낸다. 찍게 해 놓고 마지막에 "기준이 없어 못 한다"고 말하지 않기 위해서다.
Future<void> startRegistryCompare(
  BuildContext context,
  AnalysisReport report,
) async {
  if (!report.comparable) {
    context.push(
      '/compare/${report.id}',
      extra: CompareRequest(report: report),
    );
    return;
  }

  final List<String> paths = await pickRegistryPhotos(context);
  if (paths.isEmpty || !context.mounted) return;
  context.push(
    '/compare/${report.id}',
    extra: CompareRequest(report: report, imagePaths: paths),
  );
}

/// 등기부 사진 고르기 — [촬영 시작] 또는 [갤러리에서 고르기] (PDF는 받지 않는다). 취소하면 빈 목록.
///
/// [alreadyTaken]은 **이미 들고 있는 장수**다 — '빠진 쪽만 더 찍기'(대조 결과가 일부만 맞춰봤을 때)는
/// 먼저 찍은 장을 그대로 두고 새 장만 받으므로, 촬영 뱃지("4장째")와 상한(남은 칸)이 그 장수부터 센다.
/// 돌려주는 것은 **새로 고른 사진만**이다 — 먼저 찍은 장과 합치는 일은 부른 화면이 한다.
///
/// [review]가 있으면 찍거나 고른 뒤 그 화면(새 등기부 촬영)을 거친다.
/// [captureOne]·[pickMany]는 카메라·앨범 주입 지점(테스트는 가짜 함수).
Future<List<String>> pickRegistryPhotos(
  BuildContext context, {
  String title = kComparePhotoSheetTitle,
  String subtitle = kComparePhotoSheetSubtitle,
  int alreadyTaken = 0,
  int maxPhotos = kCompareMaxPhotos,
  CaptureOne captureOne = defaultCaptureOne,
  PickMany pickMany = defaultPickMany,
  ReviewPhotos? review,
}) async {
  final int room = maxPhotos - alreadyTaken;
  if (room <= 0) return const [];
  final source = await showModalBottomSheet<_PhotoSource>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenPadding,
          12,
          AppSpacing.screenPadding,
          16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Center(
              child: Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                  color: AppColors.primarySoft,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.upload_file,
                  size: 30,
                  color: AppColors.primary,
                ),
              ),
            ),
            const SizedBox(height: 12),
            AppText(
              title,
              textAlign: TextAlign.center,
              style: AppTypographyNext.headline,
            ),
            const SizedBox(height: 4),
            AppText(
              subtitle,
              textAlign: TextAlign.center,
              style: AppTypographyNext.caption,
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: () =>
                    Navigator.of(sheetContext).pop(_PhotoSource.camera),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.photo_camera_outlined),
                label: AppText(
                  kCompareShootLabel,
                  style: AppTypographyNext.button.copyWith(color: Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 56,
              child: OutlinedButton.icon(
                onPressed: () =>
                    Navigator.of(sheetContext).pop(_PhotoSource.gallery),
                style: OutlinedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: AppColors.primary, width: 1.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.photo_library_outlined),
                label: AppText(
                  kCompareGalleryLabel,
                  style: AppTypographyNext.button.copyWith(
                    color: AppColors.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.of(sheetContext).pop(),
              style: TextButton.styleFrom(
                foregroundColor: AppColorsNext.textMuted,
                minimumSize: const Size(0, 48),
              ),
              child: AppText(
                kCompareLaterLabel,
                style: AppTypographyNext.caption,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (source == null || !context.mounted) return const [];

  if (source == _PhotoSource.gallery) {
    List<String> picked;
    try {
      picked = (await pickMany()).take(room).toList();
    } catch (_) {
      return const [];
    }
    if (picked.isEmpty || !context.mounted) return const [];
    if (review == null) return picked;
    return (await review(picked, openCamera: false)) ?? const [];
  }

  if (review != null)
    return (await review(const [], openCamera: true)) ?? const [];

  final result = await Navigator.of(context).push<CaptureLoopResult>(
    MaterialPageRoute(
      builder: (_) => CaptureLoopRoute(
        alreadyTaken: alreadyTaken,
        maxPhotos: maxPhotos,
        captureOne: captureOne,
      ),
    ),
  );
  return (result?.newPaths ?? const <String>[]).take(room).toList();
}

enum _PhotoSource { camera, gallery }
