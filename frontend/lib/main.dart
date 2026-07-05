/// 전세AI프 앱 엔트리.
///
/// - 디자인 시스템: lib/design_system/ (토큰·테마·컴포넌트·갤러리)
/// - 화면은 Repository 인터페이스에만 의존: lib/repositories/
/// - **D-3부터 실제 주입은 서버 구현(Api*)이다.** 서버가 꺼져 있으면 화면이 에러를
///   보여준다(더미 폴백 없음 — 연결이 진짜임을 확인하기 위한 원칙).
///   Dummy*는 위젯 테스트에서만 주입한다(아래 생성자 오버라이드).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app/router.dart';
import 'design_system/theme.dart';
import 'repositories/analysis_repository.dart';
import 'repositories/api_analysis_repository.dart';
import 'repositories/api_content_repository.dart';
import 'repositories/content_repository.dart';
import 'state/app_session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 세로 고정 — 시연 안정성 (user-scenario.md §5)
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const JeonseSafeApp());
}

class JeonseSafeApp extends StatelessWidget {
  const JeonseSafeApp({
    super.key,
    this.analysisRepository,
    this.contentRepository,
  });

  /// 테스트 전용 오버라이드 (null이면 서버 구현 사용). 프로덕션은 항상 Api*.
  final AnalysisRepository? analysisRepository;
  final ContentRepository? contentRepository;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // 세션(회원/비회원) — 앱 생애 동안 유지
        ChangeNotifierProvider(create: (_) => AppSession()),
        // 저장소 주입 — 서버 구현 (docs/api-contract.md 계약을 호출)
        // 이력 변화(분석·삭제)를 홈이 구독하도록 ChangeNotifierProvider 사용
        ChangeNotifierProvider<AnalysisRepository>(
          create: (_) => analysisRepository ?? ApiAnalysisRepository(),
        ),
        Provider<ContentRepository>(
          create: (_) => contentRepository ?? ApiContentRepository(),
        ),
      ],
      child: MaterialApp.router(
        title: '전세AI프',
        theme: buildAppTheme(),
        routerConfig: appRouter,
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
