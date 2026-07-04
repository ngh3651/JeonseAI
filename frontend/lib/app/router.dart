/// go_router 설정 (IA.md §2·§3·§7).
///
/// - 진입: 온보딩 → 시작(S-02) → 메인 셸
/// - 메인 셸(하단 탭 4개): 홈·여정·챗봇·마이
/// - 분석 종속·진입 화면은 셸 밖 push (탭이 아닌 화면 — IA §2)
/// - 리포트에서 여는 체크리스트는 push(back=리포트)라 별도 /checklist 경로 사용 (gap-checker 반영)
/// - /gallery: 디자인 시스템 카탈로그 (제품 진입점 없음)
library;

import 'package:go_router/go_router.dart';

import '../design_system/gallery/component_gallery_screen.dart';
import '../models/analysis_report.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/start_screen.dart';
import '../screens/cases/case_match_screen.dart';
import '../screens/chatbot/glossary_chatbot_screen.dart';
import '../screens/common/coming_soon_screen.dart';
import '../screens/guide/registry_guide_screen.dart';
import '../screens/home/home_screen.dart';
import '../screens/journey/journey_screen.dart';
import '../screens/loading/analysis_loading_screen.dart';
import '../screens/my/my_screen.dart';
import '../screens/onboarding/onboarding_screen.dart';
import '../screens/questions/question_generator_screen.dart';
import '../screens/report/report_screen.dart';
import '../screens/search/property_search_screen.dart';
import '../screens/shell/main_shell.dart';
import '../screens/simulator/loss_simulator_screen.dart';

final appRouter = GoRouter(
  // 온보딩부터 전체 흐름 시연 (첫 실행 한정 처리는 향후 영속화 시 — Phase D/E)
  initialLocation: '/onboarding',
  routes: [
    GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
    GoRoute(path: '/start', builder: (_, _) => const StartScreen()),
    GoRoute(
      path: '/login',
      builder: (_, state) => LoginScreen(
        signup: state.uri.queryParameters['mode'] == 'signup',
        next: state.uri.queryParameters['next'],
      ),
    ),
    GoRoute(path: '/guide', builder: (_, _) => const RegistryGuideScreen()),

    // ── 메인 셸 (하단 탭) ──────────────────────────────────────
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          MainShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/journey', builder: (_, _) => const JourneyScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/chatbot',
              builder: (_, _) => const GlossaryChatbotScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/my', builder: (_, _) => const MyScreen())],
        ),
      ],
    ),

    // ── 진입·분석 종속 화면 (셸 밖 push) ───────────────────────
    GoRoute(path: '/analyze', builder: (_, _) => const PropertySearchScreen()),
    GoRoute(
      path: '/loading',
      builder: (_, state) =>
          AnalysisLoadingScreen(request: state.extra! as AnalysisRequest),
    ),
    GoRoute(
      path: '/report/:id',
      builder: (_, state) =>
          ReportScreen(reportId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/simulator/:id',
      builder: (_, state) =>
          LossSimulatorScreen(reportId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/cases/:id',
      builder: (_, state) =>
          CaseMatchScreen(reportId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/questions/:id',
      builder: (_, state) =>
          QuestionGeneratorScreen(reportId: state.pathParameters['id']!),
    ),
    // 리포트에서 여는 체크리스트 (push · back=리포트). 뒤로가기 버튼 노출.
    GoRoute(
      path: '/checklist',
      builder: (_, _) => const JourneyScreen(showBack: true),
    ),

    // ── 잔여 스텁 / 카탈로그 ───────────────────────────────────
    GoRoute(
      path: '/soon',
      builder: (_, state) => ComingSoonScreen(
        title: state.uri.queryParameters['title'] ?? '준비 중',
        message: state.uri.queryParameters['message'] ?? '곧 만나볼 수 있어요.',
      ),
    ),
    GoRoute(
      path: '/gallery',
      builder: (_, _) => const ComponentGalleryScreen(),
    ),
  ],
);
