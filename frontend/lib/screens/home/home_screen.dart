/// S-03 홈 (2026-10-30 홈 리뉴얼 — 캔버스 'N-1+ · 휴대폰 그림' 확정안).
///
/// 위에서 아래로:
/// 1. 인사 — 손 흔드는 세이프 + "OO님 안녕하세요"(24) + "오늘도 안전한 전세 계약을 도와드릴게요" · 오른쪽 종(오늘 일정 수)
/// 2. "매물 분석 시작하기" — 흰 카드(초록 빛이 테두리를 돈다): "**등기부만** 찍으세요 / 위험 신호는 / 저희가 찾을게요"
///    + 휴대폰 그림 · [촬영하기][갤러리] · "등기부가 없나요? 인터넷등기소 ↗"
/// 3. "내 집 N곳 · 전체 보기" — 집 카드를 옆으로 넘긴다(아래 점). 카드 = 리포트로, 연초록 줄 = 그 집 여정으로.
///    끝에 [새로 분석]. 집이 없으면 같은 높이의 흐린 미리보기 카드.
/// 4. "궁금한 건 바로 물어보세요" — 챗봇 입력칸 모양(누르면 챗봇 + 키보드) + 챗봇 빈 화면과 같은 질문 4개(누르면 바로 물어봄)
///
/// 오늘 일정은 종 하나로만 알린다 — 홈에 큰 배너를 띄우지 않는다 (2026-10-27 홈_종버튼_시안).
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/analysis_report.dart';
import '../../models/content_models.dart';
import '../../models/property_reports.dart';
import '../../repositories/analysis_repository.dart';
import '../../repositories/content_repository.dart';
import '../../services/api_client.dart';
import '../../state/app_session.dart';
import '../../state/chat_handoff.dart';
import '../../state/journey_key_migration.dart';
import '../../state/journey_progress_store.dart';
import '../../state/journey_schedule_store.dart';
import '../chatbot/glossary_chatbot_screen.dart'
    show kChatHint, kSuggestedQuestions;
import '../common/analyze_gate.dart';
import '../common/house_card.dart';
import 'today_schedule_sheet.dart';

/// 손 흔드는 세이프 (홈 인사)
const String kHelloMascotAsset = 'assets/mascot/safe_hello.png';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// 계속 도는 움직임(손 흔들기 · 테두리 빛)을 켤까 — null이면 테스트에서만 끈다
  /// (멈추지 않는 애니메이션은 위젯 테스트의 pumpAndSettle을 끝나지 않게 한다. 시작 화면과 같은 방식).
  static bool? idleAnimations;

  static bool get idleOn {
    final forced = idleAnimations;
    if (forced != null) return forced;
    if (kIsWeb) return true;
    return !Platform.environment.containsKey('FLUTTER_TEST');
  }

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// 종 시트가 열려 있나 — 종 버튼이 진한 바탕이 된다
  bool _bellOpen = false;

  /// 여정 단계 — 집 카드의 연초록 줄("2단계 · 가계약금 보내기 전")에 쓴다
  late final Future<List<JourneyStage>> _stages = () async {
    try {
      return await context.read<ContentRepository>().journeyStages();
    } catch (_) {
      return const <JourneyStage>[];
    }
  }();

  Future<void> _openToday(List<TodayEvent> events) async {
    setState(() => _bellOpen = true);
    // 열어 봤으면 빨간 숫자를 끈다 — 오늘 새로 생긴 일정이 있을 때만 다시 켜진다 (2026-10-27)
    unawaited(TodayBellSeen.instance.markSeen(events));
    await showTodayScheduleSheet(context, events: events);
    if (mounted) setState(() => _bellOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    // watch: 분석·삭제로 이력이 바뀌면(notifyListeners) 홈이 다시 서버에서 불러온다
    final repo = context.watch<AnalysisRepository>();
    // 여정에서 날짜·체크를 바꾸고 오면 연초록 줄도 바뀐다
    final scheduleStore = context.watch<JourneyScheduleStore>();
    context.watch<JourneyProgressStore>();

    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<List<AnalysisReport>>(
          future: repo.getHistory(),
          builder: (context, snapshot) {
            // 같은 집은 최신 리포트 1개만 (2026-10-26 같은 집 덮어쓰기)
            final properties = groupByProperty(snapshot.data ?? const []);
            // 예전 열쇠(주소 띄어쓰기만 뺀 것)로 넣어 둔 일정을 새 열쇠로 (2026-10-27)
            adoptLegacyPropertyKeys(properties);
            final today = todayEvents(properties, scheduleStore);

            return ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.screenPadding,
                    28,
                    AppSpacing.screenPadding,
                    0,
                  ),
                  child: _greeting(context, today),
                ),
                _sectionTitle('매물 분석 시작하기', top: 26, bottom: 12),
                const Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.screenPadding,
                  ),
                  child: HomeAnalyzeCard(),
                ),
                _housesHeader(context, snapshot, properties),
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData)
                  const SizedBox(
                    height: 194,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (snapshot.hasError)
                  // 서버 연결 실패 — 빈 상태로 위장하지 않는다 (D-3: 더미 폴백 금지)
                  _loadError(context, snapshot.error)
                else if (properties.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.screenPadding,
                    ),
                    child: HomeEmptyHouses(),
                  )
                else
                  FutureBuilder<List<JourneyStage>>(
                    future: _stages,
                    builder: (context, stages) => HomeHouseCarousel(
                      properties: properties,
                      stages: stages.data ?? const [],
                    ),
                  ),
                _sectionTitle('궁금한 건 바로 물어보세요', top: 22, bottom: 10),
                const HomeAskEntry(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, {required double top, double bottom = 10}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        top,
        AppSpacing.screenPadding,
        bottom,
      ),
      child: AppText(text, style: AppTypographyNext.title),
    );
  }

  /// "내 집 2곳 · 전체 보기"
  Widget _housesHeader(
    BuildContext context,
    AsyncSnapshot<List<AnalysisReport>> snapshot,
    List<PropertyReports> properties,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        18,
        AppSpacing.screenPadding - 8,
        4,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AppText('내 집', style: AppTypographyNext.title),
          if (properties.isNotEmpty) ...[
            const SizedBox(width: 6),
            AppText(
              '${properties.length}곳',
              style: AppTypographyNext.caption.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const Spacer(),
          // 버튼 높이만큼 줄 높이를 맞춘다 — 집이 없을 때도 위치가 같게
          SizedBox(
            height: 44,
            child: properties.isEmpty
                ? null
                : TextButton(
                    key: const ValueKey('home-houses-all'),
                    onPressed: () => context.go('/my'),
                    child: AppText(
                      '전체 보기',
                      style: AppTypographyNext.caption.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 이력 로드 실패 — 인라인 에러 + [다시 시도] (user-scenario §5)
  Widget _loadError(BuildContext context, Object? error) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
      child: Container(
        constraints: const BoxConstraints(minHeight: 194),
        padding: const EdgeInsets.all(AppSpacing.xl),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(kHouseCardRadius),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.wifi_off,
              color: AppColors.textMuted,
              size: AppSize.iconMd,
            ),
            const SizedBox(height: AppSpacing.md),
            AppText('분석 이력을 불러오지 못했어요', style: AppTypography.bodyStrong),
            const SizedBox(height: AppSpacing.xs),
            AppText(
              apiErrorHint(error, fallback: '서버 연결을 확인해 주세요'),
              textAlign: TextAlign.center,
              style: AppTypography.caption.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppCompactButton(
              label: '다시 시도',
              icon: Icons.refresh,
              onPressed: () => setState(() {}), // 재빌드 → getHistory 재호출
            ),
          ],
        ),
      ),
    );
  }

  Widget _greeting(BuildContext context, List<TodayEvent> today) {
    final session = context.watch<AppSession>();
    // 카카오에서 이름을 받지 않는다(회원번호만). 사용자가 마이에서 **직접 정한** 이름만 쓴다 (2026-10-24).
    final String? name = session.displayName;
    final String hello = session.isGuest
        ? '안녕하세요'
        : (name != null && name.isNotEmpty ? '$name님 안녕하세요' : '반가워요');
    final bool unseen = TodayBellSeen.instance.hasUnseen(today);
    final bool guestLogin = session.isGuest && session.kakaoAvailable;

    // 종은 오른쪽 위에 따로 붙인다 — 부제가 종 아래까지 한 줄로 쓰이게(캔버스 N-1과 같은 배치)
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const WavingMascot(height: 72),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(right: guestLogin ? 100 : 44),
                    child: AppText(
                      hello,
                      maxLines: 2,
                      style: AppTypographyNext.headline,
                    ),
                  ),
                  AppText(
                    '오늘도 안전한 전세 계약을 도와드릴게요',
                    style: AppTypographyNext.caption,
                  ),
                ],
              ),
            ),
          ],
        ),
        Positioned(
          top: 0,
          right: -12,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 둘러보는 중엔 로그인 진입점 (user-scenario C1) — 카카오 키가 있는 빌드에서만(가짜 버튼 금지)
              if (guestLogin)
                TextButton(
                  onPressed: () => context.push('/login'),
                  child: const AppText('로그인'),
                ),
              TodayBellButton(
                hasToday: unseen,
                count: unseen ? today.length : 0,
                open: _bellOpen,
                onPressed: () => _openToday(today),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 손 흔드는 세이프 — 3.2초마다 한 번 살짝 흔든다(발끝 축). 휴대폰 '동작 줄이기'면 가만히.
class WavingMascot extends StatefulWidget {
  const WavingMascot({super.key, required this.height});

  final double height;

  @override
  State<WavingMascot> createState() => _WavingMascotState();
}

class _WavingMascotState extends State<WavingMascot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool still =
        MediaQuery.disableAnimationsOf(context) || !HomeScreen.idleOn;
    if (still) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// 0~60% 가만히 → 70% −6° → 80% +5° → 90% −3° → 100% 0°
  static double _angle(double t) {
    const pts = [(0.6, 0.0), (0.7, -6.0), (0.8, 5.0), (0.9, -3.0), (1.0, 0.0)];
    if (t <= pts.first.$1) return 0;
    for (var i = 1; i < pts.length; i++) {
      final (t1, a1) = pts[i];
      final (t0, a0) = pts[i - 1];
      if (t <= t1) {
        final f = Curves.easeInOut.transform((t - t0) / (t1 - t0));
        return (a0 + (a1 - a0) * f) * math.pi / 180;
      }
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) => Transform.rotate(
          angle: _angle(_c.value),
          alignment: const Alignment(0, 0.8),
          child: child,
        ),
        child: Image.asset(
          kHelloMascotAsset,
          key: const ValueKey('home-hello-mascot'),
          height: widget.height,
          // 그림 비율(134×220) — 그림을 읽기 전에도 자리를 잡아 글자가 옆으로 밀리지 않게
          width: widget.height * 134 / 220,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}

/// "매물 분석 시작하기" 카드 — 흰 카드 둘레를 초록 빛이 4초에 한 바퀴 돈다(분석 중 느낌).
class HomeAnalyzeCard extends StatefulWidget {
  const HomeAnalyzeCard({super.key});

  @override
  State<HomeAnalyzeCard> createState() => _HomeAnalyzeCardState();
}

class _HomeAnalyzeCardState extends State<HomeAnalyzeCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) || !HomeScreen.idleOn) {
      _spin.stop();
    } else if (!_spin.isAnimating) {
      _spin.repeat();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool still =
        MediaQuery.disableAnimationsOf(context) || !HomeScreen.idleOn;
    final Color ring = Color.lerp(
      AppColors.surface,
      AppColors.primarySoft,
      0.9,
    )!;
    final Color glow = Color.lerp(
      AppColors.surface,
      AppColors.primarySoft,
      0.6,
    )!;
    return DecoratedBox(
      key: const ValueKey('home-analyze-card'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: AppColors.isDark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x1A0B3D2A),
                  offset: Offset(0, 10),
                  blurRadius: 28,
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            // 테두리 바탕 + 도는 빛
            Positioned.fill(child: ColoredBox(color: ring)),
            if (!still)
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _spin,
                  builder: (context, _) => CustomPaint(
                    painter: _SpinGlowPainter(
                      turn: _spin.value,
                      color: AppColors.primaryBright,
                    ),
                  ),
                ),
              ),
            // 안쪽 흰 카드 (2 안쪽)
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: RadialGradient(
                      center: Alignment.topRight,
                      radius: 1.2,
                      colors: [glow, AppColors.surface],
                      stops: const [0, 0.55],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: AppText.rich(
                            TextSpan(
                              style: AppTypographyNext.headline,
                              children: [
                                TextSpan(
                                  text: '등기부만',
                                  style: TextStyle(color: AppColors.primary),
                                ),
                                const TextSpan(text: ' 찍으세요\n위험 신호는\n저희가 찾을게요'),
                              ],
                            ),
                            key: const ValueKey('home-analyze-headline'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const RegistryPhoneArt(),
                    ],
                  ),
                  const SizedBox(height: 14),
                  AnalyzeStartButtons(
                    onPick: (start) => startAnalysisWith(context, start),
                  ),
                  const SizedBox(height: 4),
                  RegistryOfficeLink(onTap: () => openRegistryOffice(context)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 둘레를 도는 초록 빛 — 부채꼴 그라데이션(250°~360° 사이만 빛)
class _SpinGlowPainter extends CustomPainter {
  _SpinGlowPainter({required this.turn, required this.color});

  final double turn;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final double r =
        math.sqrt(size.width * size.width + size.height * size.height) / 2;
    final rect = Rect.fromCircle(center: center, radius: r);
    final paint = Paint()
      ..shader = SweepGradient(
        colors: [
          color.withValues(alpha: 0),
          color.withValues(alpha: 0),
          color,
          Color.lerp(color, Colors.white, 0.55)!,
          color.withValues(alpha: 0),
        ],
        stops: const [0, 250 / 360, 320 / 360, 345 / 360, 1],
        transform: GradientRotation(turn * 2 * math.pi - math.pi / 2),
      ).createShader(rect);
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(_SpinGlowPainter old) =>
      old.turn != turn || old.color != color;
}

/// 휴대폰 그림 — 등기부가 뜬 화면(빨강·초록 줄 + 초록 스캔 선)을 6° 기울이고, 오른쪽 아래에 초록 체크.
class RegistryPhoneArt extends StatelessWidget {
  const RegistryPhoneArt({super.key});

  @override
  Widget build(BuildContext context) {
    Widget line(double w, Color c, {double h = 5, double top = 6}) => Container(
      margin: EdgeInsets.only(top: top),
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: c,
        borderRadius: BorderRadius.circular(3),
      ),
    );
    return ExcludeSemantics(
      child: SizedBox(
        key: const ValueKey('home-phone-art'),
        width: 96,
        height: 112,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 14,
              top: 0,
              child: Transform.rotate(
                angle: 6 * math.pi / 180,
                child: Container(
                  width: 68,
                  height: 112,
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C2621),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x2E101814),
                        offset: Offset(0, 8),
                        blurRadius: 18,
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.fromLTRB(7, 8, 7, 0),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              line(30, const Color(0xB31C2621), h: 6, top: 0),
                              line(44, const Color(0xFFD9DFDB)),
                              line(52, const Color(0xFFE4E9E6)),
                              line(36, const Color(0xFFFBEAE8)),
                              line(48, const Color(0xFFE4E9E6)),
                              line(30, const Color(0xFFE4F4EB)),
                            ],
                          ),
                          Positioned(
                            left: -3,
                            right: -3,
                            top: 22,
                            child: Container(
                              height: 2,
                              decoration: const BoxDecoration(
                                color: Color(0xFF2FA36F),
                                boxShadow: [
                                  BoxShadow(
                                    color: Color(0xFF2FA36F),
                                    blurRadius: 6,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 6,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.surface, width: 3),
                ),
                child: Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: AppColors.onPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 내 집 — 집 카드를 옆으로 넘긴다(폭 276, 사이 12) + 끝에 [새로 분석] + 아래 점.
class HomeHouseCarousel extends StatefulWidget {
  const HomeHouseCarousel({
    super.key,
    required this.properties,
    required this.stages,
  });

  final List<PropertyReports> properties;
  final List<JourneyStage> stages;

  @override
  State<HomeHouseCarousel> createState() => _HomeHouseCarouselState();
}

class _HomeHouseCarouselState extends State<HomeHouseCarousel> {
  final ScrollController _scroll = ScrollController();
  int _dot = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final n = widget.properties.length;
    if (n == 0) return;
    final max = _scroll.position.maxScrollExtent;
    // 끝까지 밀었으면 마지막 점
    final int i = max > 0 && _scroll.offset >= max - 4
        ? n - 1
        : ((_scroll.offset + (kHouseCardWidth + 12) / 2) ~/
                  (kHouseCardWidth + 12))
              .clamp(0, n - 1);
    if (i != _dot) setState(() => _dot = i);
  }

  @override
  Widget build(BuildContext context) {
    final props = widget.properties;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          key: const ValueKey('home-houses'),
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenPadding,
            4,
            AppSpacing.screenPadding,
            8,
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final p in props) ...[
                  HouseCard(
                    key: ValueKey('home-house-${p.key}'),
                    property: p,
                    width: kHouseCardWidth,
                    subline: houseAnalyzedLine(p),
                    onTap: () => context.push('/report/${p.latest.id}'),
                    footer: HouseJourneyButton(
                      property: p,
                      stages: widget.stages,
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                NewAnalysisCard(onTap: () => startAnalysis(context)),
              ],
            ),
          ),
        ),
        if (props.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              key: const ValueKey('home-houses-dots'),
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < props.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _dot ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _dot ? AppColors.primary : AppColors.line,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 집이 없을 때 — 집 카드와 같은 높이의 흐린 미리보기 + "분석한 집이 여기에 모여요".
class HomeEmptyHouses extends StatelessWidget {
  const HomeEmptyHouses({super.key});

  @override
  Widget build(BuildContext context) {
    final Color bone = AppColorsNext.divider;
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: bone,
        borderRadius: BorderRadius.circular(h / 2),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: ClipRRect(
        key: const ValueKey('home-houses-empty'),
        borderRadius: BorderRadius.circular(kHouseCardRadius),
        child: Container(
          color: AppColors.surface,
          constraints: const BoxConstraints(minHeight: 194),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Opacity(
                  opacity: 0.9,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [bar(52, 28), const Spacer(), bar(70, 12)]),
                      const SizedBox(height: 14),
                      bar(180, 14),
                      const SizedBox(height: 16),
                      Container(
                        height: 66,
                        decoration: BoxDecoration(
                          color: AppColors.background,
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppColors.surface.withValues(alpha: 0.2),
                        AppColors.surface.withValues(alpha: 0.92),
                      ],
                      stops: const [0, 0.55],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 20,
                child: Column(
                  children: [
                    AppText(
                      '분석한 집이 여기에 모여요',
                      textAlign: TextAlign.center,
                      style: AppTypographyNext.bodyStrong.copyWith(
                        color: AppColorsNext.textStrong,
                      ),
                    ),
                    AppText(
                      '같은 집을 다시 찍으면\n최신 등기부로 바뀌어요',
                      textAlign: TextAlign.center,
                      style: AppTypographyNext.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "궁금한 건 바로 물어보세요" — 챗봇 입력칸과 같은 모양(✦ · 같은 글 · 초록 ↑)과 챗봇 빈 화면 질문 4개.
///
/// 여기서 글을 쓰지 않는다 — 누르면 챗봇 탭으로 가서 입력칸에 커서를 두고 키보드를 연다.
/// 질문 칩은 챗봇으로 가서 그 질문을 **바로** 보낸다(챗봇 빈 화면의 질문 카드와 같은 동작).
class HomeAskEntry extends StatelessWidget {
  const HomeAskEntry({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenPadding,
          ),
          child: Material(
            color: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: AppColors.line, width: 1.5),
            ),
            child: InkWell(
              key: const ValueKey('home-ask-input'),
              borderRadius: BorderRadius.circular(16),
              onTap: () {
                ChatHandoff.focus();
                context.go('/chatbot');
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_awesome_outlined,
                      size: 20,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: AppText(
                        kChatHint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypographyNext.body.copyWith(
                          color: AppColorsNext.textMuted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.arrow_upward,
                        size: 24,
                        color: AppColors.onPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          key: const ValueKey('home-ask-chips'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenPadding,
          ),
          child: Row(
            children: [
              for (final q in kSuggestedQuestions) ...[
                Material(
                  color: AppColors.surface,
                  shape: StadiumBorder(side: BorderSide(color: AppColors.line)),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: () {
                      ChatHandoff.ask(q);
                      context.go('/chatbot');
                    },
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Center(
                          widthFactor: 1,
                          child: AppText(
                            q,
                            maxLines: 1,
                            style: AppTypographyNext.caption.copyWith(
                              fontWeight: FontWeight.w600,
                              color: AppColorsNext.textBody,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
