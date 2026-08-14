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
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'app/router.dart';
import 'design_system/theme.dart';
import 'repositories/analysis_repository.dart';
import 'repositories/api_analysis_repository.dart';
import 'repositories/api_content_repository.dart';
import 'repositories/content_repository.dart';
import 'state/app_session.dart';
import 'state/journey_schedule_store.dart';
import 'state/registry_photo_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 세로 고정 — 시연 안정성 (user-scenario.md §5)
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // 지난 세션에 보관해 둔 등기부 사진 목록을 메모리로 올린다.
  // (devKeepRegistryPhotos가 false면 아무 일도 하지 않는다 → 예전 메모리 전용 동작)
  await RegistryPhotoStore.instance.restore();
  // 계약 일정(잔금일 등)은 **이 기기에만** 있다 — 여정 화면과 홈 D-1 배너가 곧바로
  // 그릴 수 있게 먼저 올린다(첫 프레임에 배너가 깜빡이며 나타나지 않도록).
  await JourneyScheduleStore.instance.restore();
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
        // 계약 일정 — 기기 로컬 저장. 여정 화면과 홈 배너가 같은 값을 본다.
        ChangeNotifierProvider<JourneyScheduleStore>.value(
          value: JourneyScheduleStore.instance,
        ),
      ],
      child: MaterialApp.router(
        title: '전세AI프',
        theme: buildAppTheme(),
        routerConfig: appRouter,
        debugShowCheckedModeBanner: false,
        // 달력·기본 위젯 문구를 한국어로 (날짜 선택이 'CANCEL/OK'로 뜨지 않게)
        locale: const Locale('ko', 'KR'),
        supportedLocales: const [Locale('ko', 'KR')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
      ),
    );
  }
}
