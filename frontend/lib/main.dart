/// 전세AI프 앱 엔트리.
///
/// - 디자인 시스템: lib/design_system/ (토큰·테마·컴포넌트·갤러리)
/// - 화면은 Repository 인터페이스에만 의존: lib/repositories/
/// - **D-3부터 실제 주입은 서버 구현(Api*)이다.** 서버가 꺼져 있으면 화면이 에러를
///   보여준다(더미 폴백 없음 — 연결이 진짜임을 확인하기 위한 원칙).
///   Dummy*는 위젯 테스트에서만 주입한다(아래 생성자 오버라이드).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'app/router.dart';
import 'design_system/text/app_text.dart';
import 'design_system/theme.dart';
import 'repositories/analysis_repository.dart';
import 'repositories/api_analysis_repository.dart';
import 'repositories/api_content_repository.dart';
import 'repositories/chat_history_repository.dart';
import 'repositories/content_repository.dart';
import 'repositories/payment_repository.dart';
import 'state/app_session.dart';
import 'state/booth_mode.dart';
import 'services/api_client.dart';
import 'services/device_id.dart';
import 'services/journey_reminder_service.dart';
import 'state/journey_progress_store.dart';
import 'state/journey_schedule_store.dart';
import 'state/pass_store.dart';
import 'state/privacy_settings.dart';
import 'state/registry_photo_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 세로 고정 — 시연 안정성 (user-scenario.md §5)
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // 지난 세션에 이 폰에 남긴 등기부 사진·원본 리포트 목록을 메모리로 올린다.
  // (keepOriginalsOnPhone이 false면 남겨 둔 것까지 지운다 → 메모리 전용 동작)
  await RegistryPhotoStore.instance.restore();
  // 계약 일정(잔금일 등)은 **이 기기에만** 있다 — 여정 화면과 홈 D-1 배너가 곧바로
  // 그릴 수 있게 먼저 올린다(첫 프레임에 배너가 깜빡이며 나타나지 않도록).
  await JourneyScheduleStore.instance.restore();
  // 여정 진행 기록(단계 완료·대조 기록·알림 켜짐 여부, 2026-10-26) — 이 기기에만
  await JourneyProgressStore.instance.restore();
  // '사진 속 이름 가리기'를 첫 화면부터 저장된 값으로 그린다(켜 둔 채 껐다 켰는데 이름이 한 번 비치면 안 된다).
  await PrivacySettings.instance.restore();
  // 부스 모드(2026-10-23) — 켜져 있으면 첫 화면부터 로그아웃·회원 탈퇴·기록 지우기를 숨긴다.
  await BoothMode.instance.restore();
  // 기기 id를 미리 만들어 둔다 — 첫 서버 요청이 저장소를 기다리지 않게. 실패해도 요청 때 다시 만든다.
  await DeviceId.instance.get();
  // 카카오 로그인 세션(2026-10-22) — 폰의 보안 저장소에 남긴 세션을 올린다(만료면 지운다).
  // 서버 확인(GET /api/me)은 아래에서 뒤로 돌린다 — 끝난 세션이면 401 → 지우고 "다시 로그인해 주세요".
  final session = AppSession.instance;
  await session.restore();
  session.onSessionExpired = _showSessionExpired;
  // 계약 지킴이 알림 (P1-2) — 알림을 누르면 그 집의 여정 화면으로 간다.
  // 권한은 여기서 묻지 않는다(잔금일·이사일을 저장하는 순간 이유와 함께 묻는다).
  final reminders = JourneyReminderService.instance;
  reminders.navigate = appRouter.go;
  await reminders.init();
  final String? launchedFrom = await reminders.launchPayload();
  // 앱을 강제 종료하면 안드로이드가 걸어 둔 알림을 지운다 → 켤 때마다 저장된 일정으로 다시 건다.
  // 계약 지킴이 패스(P2-1)를 먼저 물어 알림에도 '지킴이 패스' 표시를 붙인다(표시만 — 기능은 막지 않는다).
  // 로그인·로그아웃·탈퇴로 주인이 바뀌면 패스 표시와 알림 머리줄을 다시 맞춘다(패스가 계정으로 옮겨 간다).
  session.onAccountChanged = () async {
    await PassStore.instance.refresh(ApiPaymentRepository());
    await reminders.resyncAll(JourneyScheduleStore.instance);
  };
  unawaited(() async {
    await session.verify();
    await PassStore.instance.refresh(ApiPaymentRepository());
    await reminders.resyncAll(JourneyScheduleStore.instance);
  }());
  runApp(const JeonseSafeApp());
  // 알림을 눌러 앱이 켜졌으면 첫 화면이 그려진 뒤 그 집의 여정으로 간다.
  if (launchedFrom != null) {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => reminders.openPayload(launchedFrom),
    );
  }
}

/// 앱 어디서나 한 줄 안내를 띄우는 자리 — 세션이 서버에서 끝났을 때(401) 어느 화면에 있든 알린다.
final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// 세션이 끝났다(만료·다른 폰에서 탈퇴 등) — 세션은 이미 지워졌다. 다시 로그인하거나 둘러보기로 계속한다.
void _showSessionExpired() {
  rootMessengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: const AppText(kSessionExpiredMessage),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: '로그인',
          onPressed: () => appRouter.push('/login'),
        ),
      ),
    );
}

class JeonseSafeApp extends StatelessWidget {
  const JeonseSafeApp({
    super.key,
    this.analysisRepository,
    this.contentRepository,
    this.paymentRepository,
    this.chatHistoryRepository,
    this.appSession,
  });

  /// 테스트 전용 오버라이드 (null이면 서버 구현 사용). 프로덕션은 항상 Api*.
  final AnalysisRepository? analysisRepository;
  final ContentRepository? contentRepository;
  final PaymentRepository? paymentRepository;

  /// 챗봇 지난 대화(이 폰에만). null이면 폰 저장(shared_preferences).
  final ChatHistoryRepository? chatHistoryRepository;

  /// 테스트 전용 — 가짜 카카오·저장소를 넣은 세션. null이면 앱 전체 세션([AppSession.instance]).
  final AppSession? appSession;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // 세션(카카오 로그인 / 로그인 없이 둘러보기) — 앱 생애 동안 유지 (main이 restore한 그 세션)
        ChangeNotifierProvider<AppSession>.value(
          value: appSession ?? AppSession.instance,
        ),
        // 저장소 주입 — 서버 구현 (docs/api-contract.md 계약을 호출)
        // 이력 변화(분석·삭제)를 홈이 구독하도록 ChangeNotifierProvider 사용
        ChangeNotifierProvider<AnalysisRepository>(
          create: (_) => analysisRepository ?? ApiAnalysisRepository(),
        ),
        Provider<ContentRepository>(
          create: (_) => contentRepository ?? ApiContentRepository(),
        ),
        // 요금제·테스트 결제·내 패스 (2026-10-22, P2-1)
        Provider<PaymentRepository>(
          create: (_) => paymentRepository ?? ApiPaymentRepository(),
        ),
        // 챗봇 지난 대화 — 이 폰에만 저장 (챗봇 v2, 2026-10-24)
        Provider<ChatHistoryRepository>(
          create: (_) => chatHistoryRepository ?? PrefsChatHistoryRepository(),
        ),
        // 계약 일정 — 기기 로컬 저장. 여정 화면과 홈 배너가 같은 값을 본다.
        ChangeNotifierProvider<JourneyScheduleStore>.value(
          value: JourneyScheduleStore.instance,
        ),
        // 여정 진행 기록 — 단계 완료·등기부 대조 기록 (이 기기에만)
        ChangeNotifierProvider<JourneyProgressStore>.value(
          value: JourneyProgressStore.instance,
        ),
      ],
      child: MaterialApp.router(
        title: '전세AI프',
        scaffoldMessengerKey: rootMessengerKey,
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
