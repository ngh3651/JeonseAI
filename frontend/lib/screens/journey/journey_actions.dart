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

/// 사진 시트의 기본 제목·안내 (처음 대조할 때).
const String kComparePhotoSheetTitle = '다시 뗀 등기부를 올려 주세요';
const String kComparePhotoSheetSubtitle = '오늘 발급받은 등기부여야 지금 상태를 볼 수 있어요';

/// 사진 시트 맨 아래 — 아직 다시 떼지 않은 사람을 발급 가이드로.
const String kNotIssuedYetLabel = '아직 안 뗐어요 — 떼는 법 보기 (인터넷등기소 열람용 700원)';

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
///
/// [alreadyTaken]은 **이미 들고 있는 장수**다 — '빠진 쪽만 더 찍기'(대조 결과가 일부만 맞춰봤을 때)는
/// 먼저 찍은 장을 그대로 두고 새 장만 받으므로, 촬영 뱃지("4장째")와 상한(남은 칸)이 그 장수부터 센다.
/// 돌려주는 것은 **새로 고른 사진만**이다 — 먼저 찍은 장과 합치는 일은 부른 화면이 한다.
///
/// [captureOne]·[pickMany]는 카메라·앨범 주입 지점(테스트는 가짜 함수).
Future<List<String>> pickRegistryPhotos(
  BuildContext context, {
  String title = kComparePhotoSheetTitle,
  String subtitle = kComparePhotoSheetSubtitle,
  int alreadyTaken = 0,
  int maxPhotos = kCompareMaxPhotos,
  CaptureOne captureOne = defaultCaptureOne,
  PickMany pickMany = defaultPickMany,
}) async {
  final int room = maxPhotos - alreadyTaken;
  if (room <= 0) return const [];
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
                AppText(title, style: AppTypography.title),
                const SizedBox(height: AppSpacing.xs),
                AppText(subtitle, style: AppTypography.caption),
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
          // 다시 떼는 법을 몰라 여기서 막힌다(지수 리뷰 #10) — 발급 가이드로. 금액은 앱에 이미 있는 값
          // (촬영 화면 '등기부등본 발급 방법': 인터넷등기소 열람용 700원)
          ListTile(
            leading: const Icon(Icons.help_outline, color: AppColors.textMuted),
            title: const AppText(kNotIssuedYetLabel, style: AppTypography.body),
            onTap: () => Navigator.of(sheetContext).pop(_PhotoSource.guide),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return const [];

  if (source == _PhotoSource.guide) {
    context.push('/guide');
    return const [];
  }

  if (source == _PhotoSource.gallery) {
    try {
      final picked = await pickMany();
      return picked.take(room).toList();
    } catch (_) {
      return const [];
    }
  }

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

enum _PhotoSource { camera, gallery, guide }
