/// go_router 설정.
///
/// C-1 현재: 갤러리 화면만 등록 (승인 포인트 ① 확인용).
/// C-2에서 메인 셸(하단 탭 + IA.md §7 뒤로가기 정책)을 이곳에 구성한다.
library;

import 'package:go_router/go_router.dart';

import '../design_system/gallery/component_gallery_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/gallery', // TODO(C-2): 메인 셸 완성 시 '/'(스플래시)로 변경
  routes: [
    GoRoute(
      path: '/gallery',
      builder: (context, state) => const ComponentGalleryScreen(),
    ),
  ],
);
