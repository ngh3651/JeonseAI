/// go_router 설정 (IA.md §2·§3·§7).
///
/// - 메인 셸(하단 탭 4개): 홈만 실화면, 여정/챗봇/마이는 C-3에서 교체될 탭 스텁
/// - 리포트·시뮬레이터는 셸 밖 push (탭이 아닌 분석 종속 화면 — IA §2)
/// - /gallery: 디자인 시스템 카탈로그 (제품 진입점 없음, 개발·팀 공유용)
library;

import 'package:go_router/go_router.dart';

import '../design_system/gallery/component_gallery_screen.dart';
import '../screens/common/coming_soon_screen.dart';
import '../screens/home/home_screen.dart';
import '../screens/report/report_screen.dart';
import '../screens/shell/main_shell.dart';
import '../screens/simulator/loss_simulator_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/home',
  routes: [
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
            GoRoute(
              path: '/journey',
              builder: (_, _) => const ComingSoonScreen(
                title: '계약 여정 체크리스트',
                message:
                    '계약 전부터 보증금 반환까지 단계별 할 일을 알려드려요.\n'
                    '곧 만나볼 수 있어요.',
                showBack: false,
              ),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/chatbot',
              builder: (_, _) => const ComingSoonScreen(
                title: '용어 챗봇',
                message:
                    '어려운 부동산 용어를 쉽게 설명해 드려요.\n'
                    '곧 만나볼 수 있어요.',
                showBack: false,
              ),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/my',
              builder: (_, _) => const ComingSoonScreen(
                title: '마이',
                message:
                    '분석 이력 관리와 설정이 들어올 자리예요.\n'
                    '곧 만나볼 수 있어요.',
                showBack: false,
              ),
            ),
          ],
        ),
      ],
    ),

    // ── 분석 종속 화면 (셸 밖 push) ────────────────────────────
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

    // ── C-3 교체 예정 스텁 ─────────────────────────────────────
    GoRoute(
      path: '/analyze',
      builder: (_, _) => const ComingSoonScreen(
        title: '매물 분석',
        message:
            '등기부등본 사진 업로드와 보증금 입력이 들어올 자리예요.\n'
            '곧 만나볼 수 있어요.',
      ),
    ),
    GoRoute(
      path: '/guide',
      builder: (_, _) => const ComingSoonScreen(
        title: '등기부 발급 가이드',
        message:
            '등기부등본을 처음 떼어 보는 분을 위한 단계별 안내가 들어올 자리예요.\n'
            '곧 만나볼 수 있어요.',
      ),
    ),
    GoRoute(
      path: '/soon',
      builder: (_, state) => ComingSoonScreen(
        title: state.uri.queryParameters['title'] ?? '준비 중',
        message: state.uri.queryParameters['message'] ?? '곧 만나볼 수 있어요.',
      ),
    ),

    // ── 디자인 시스템 카탈로그 ─────────────────────────────────
    GoRoute(
      path: '/gallery',
      builder: (_, _) => const ComponentGalleryScreen(),
    ),
  ],
);
