/// 계약 여정에서 시작되는 행동들 — 등기부 다시 떼기, 일정 시트 열기.
///
/// 여정 화면·홈 배너·대조 결과 화면이 **같은 입구**를 쓰게 모아 둔다. 세 곳이 각자
/// 촬영 흐름을 열면, 한 곳만 고쳐졌을 때 어떤 경로로 들어왔느냐에 따라 다른 화면이 뜬다.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../design_system/text/app_text.dart';
import '../../models/analysis_report.dart';
import '../compare/compare_screen.dart';
import '../search/capture_loop_route.dart';

/// 대조에 올릴 수 있는 최대 장수 — 분석(S-04)과 같은 상한.
const int kCompareMaxPhotos = 10;

/// **이 화면의 핵심 행동**: 등기부를 다시 떼어 기준 서류와 맞춰본다.
///
/// 기준이 없는 리포트(이 기능 이전 이력·예시)는 **사진을 받기 전에** 대조 화면으로
/// 보낸다. 찍게 해 놓고 마지막에 "기준이 없어 못 한다"고 말하지 않기 위해서다.
Future<void> startRegistryCompare(
  BuildContext context,
  AnalysisReport report,
) async {
  if (!report.comparable) {
    context.push('/compare/${report.id}', extra: CompareRequest(report: report));
    return;
  }

  final List<String> paths = await pickRegistryPhotos(context);
  if (paths.isEmpty || !context.mounted) return;
  context.push(
    '/compare/${report.id}',
    extra: CompareRequest(report: report, imagePaths: paths),
  );
}

/// 등기부 사진 고르기 — 찍거나 앨범에서. 취소하면 빈 목록.
Future<List<String>> pickRegistryPhotos(BuildContext context) async {
  final source = await showModalBottomSheet<_PhotoSource>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenPadding,
              AppSpacing.sm,
              AppSpacing.screenPadding,
              AppSpacing.xs,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppText('다시 뗀 등기부를 올려 주세요', style: AppTypography.title),
                const SizedBox(height: AppSpacing.xs),
                AppText(
                  '오늘 발급받은 등기부여야 지금 상태를 볼 수 있어요',
                  style: AppTypography.caption,
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera, color: AppColors.primary),
            title: const AppText('사진 찍기', style: AppTypography.body),
            onTap: () => Navigator.of(sheetContext).pop(_PhotoSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library, color: AppColors.primary),
            title: const AppText('앨범에서 고르기', style: AppTypography.body),
            onTap: () => Navigator.of(sheetContext).pop(_PhotoSource.gallery),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return const [];

  if (source == _PhotoSource.gallery) {
    try {
      final picked = await defaultPickMany();
      return picked.take(kCompareMaxPhotos).toList();
    } catch (_) {
      return const [];
    }
  }

  final result = await Navigator.of(context).push<CaptureLoopResult>(
    MaterialPageRoute(
      builder: (_) => const CaptureLoopRoute(
        alreadyTaken: 0,
        maxPhotos: kCompareMaxPhotos,
      ),
    ),
  );
  return result?.newPaths ?? const [];
}

enum _PhotoSource { camera, gallery }
