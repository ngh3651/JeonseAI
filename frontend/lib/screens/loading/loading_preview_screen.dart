/// 개발용 **로딩 화면 미리보기** (2026-10-23) — 마이 맨 아래 버튼(`kDevTools`일 때만)에서 연다.
///
/// 진짜 [AnalysisLoadingScreen]을 그대로 띄우되, 저장소를 **끝나지 않는 가짜**로 바꿔 끼운다.
/// 서버를 부르지 않으니 크레딧 0원이고, 로딩 화면이 계속 떠 있어 핫 리로드(`r`)로 고친 모습을 바로 본다.
/// 뒤로가기 → '중단'으로 나간다. 시연용 APK에는 진입 버튼이 없다(정리 대상 — NOW.md 11절).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/analysis_report.dart';
import '../../models/compare_result.dart';
import '../../repositories/analysis_repository.dart';
import 'analysis_loading_screen.dart';

class LoadingPreviewScreen extends StatelessWidget {
  const LoadingPreviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AnalysisRepository>(
      create: (_) => _NeverEndingRepository(),
      child: const AnalysisLoadingScreen(
        request: AnalysisRequest(imagePaths: [], deposit: 0),
      ),
    );
  }
}

/// 분석이 영영 끝나지 않는 가짜 저장소 — 미리보기 전용.
class _NeverEndingRepository extends AnalysisRepository {
  @override
  Future<AnalysisReport> analyze(AnalysisRequest request) =>
      Completer<AnalysisReport>().future;

  @override
  Future<List<AnalysisReport>> getHistory() async => const [];

  @override
  Future<AnalysisReport?> getReport(String id) async => null;

  @override
  Future<void> deleteReport(String id) async {}

  @override
  Future<CompareResult> compareRegistry(
    String reportId,
    List<String> imagePaths,
  ) => Completer<CompareResult>().future;
}
