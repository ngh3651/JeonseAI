/// 전세AI프 앱 엔트리.
///
/// Phase C 재구축 (docs/plan.md Phase C):
/// - 디자인 시스템: lib/design_system/ (토큰·테마·컴포넌트·갤러리)
/// - 화면은 Repository 인터페이스에만 의존: lib/repositories/
///   (Provider로 주입 — Dummy ↔ Api 교체 지점은 아래 한 곳)
/// - 검증된 업로드 자산: lib/services/registry_upload_service.dart
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app/router.dart';
import 'design_system/theme.dart';
import 'repositories/analysis_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 세로 고정 — 시연 안정성 (user-scenario.md §5)
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const JeonseSafeApp());
}

class JeonseSafeApp extends StatelessWidget {
  const JeonseSafeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Provider<AnalysisRepository>(
      // 더미↔실제 교체 지점: Phase D에서 ApiAnalysisRepository로 교체 (CLAUDE.md 4절)
      create: (_) => DummyAnalysisRepository(),
      child: MaterialApp.router(
        title: '전세AI프',
        theme: buildAppTheme(),
        routerConfig: appRouter,
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
