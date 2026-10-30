/// S-02 시작 (랜딩) — 앱을 처음 켰을 때·로그아웃했을 때 보이는 화면. 2026-10-26 리디자인(시안 A · 라이트).
///
/// - 카카오 키가 있는 빌드: [카카오로 시작하기] + [로그인 없이 둘러보기](테두리 버튼) + 개인정보 처리방침.
/// - 키가 없는 빌드: 카카오 버튼을 **아예 만들지 않는다**(가짜 버튼 금지) → [로그인 없이 둘러보기]가 꽉 찬 버튼.
/// - 카카오 로그인 중: 카카오 버튼에 기다림 표시, 다른 버튼·링크는 흐리게 잠금, 뒤로 가기 막음.
/// - 이미 로그인돼 있으면(드물다 — 앱을 켜면 바로 홈으로 간다): [시작하기] 하나.
/// 둘러보기 = 기기 id로 쓴다 — 분석도 된다(부스에서 카카오가 막혀도).
///
/// 위: 로고 + 앱 이름("AI"는 금색으로 직접 그린 글자) + 한 줄 소개 / 가운데: 아치 안의 세이프 / 아래: 흰 시트의 버튼.
/// 등장 애니메이션 1.3초 + 세이프 손 흔들기·반짝이 반복. 폰의 '애니메이션 제거' 설정이면 짧은 페이드만.
/// 새 패키지 없이 Flutter 기본 기능만 쓴다.
library;

import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../state/app_session.dart';
import '../../design_system/tokens/app_colors.dart';
import 'kakao_login_button.dart';

/// 시작 화면 색 — 이 화면에서만 쓴다(시안 A). 카카오 색은 [kKakaoYellow] 등 카카오 가이드 값 그대로.
abstract final class StartColors {
  static bool get _d => AppColors.isDark;
  static Color get bg => _d ? const Color(0xFF0D1210) : const Color(0xFFF6F4EC); // 화면 배경
  static Color get sheet => _d ? const Color(0xFF171F1B) : const Color(0xFFFFFFFF); // 하단 시트
  static Color get arch => _d ? const Color(0xFF173328) : const Color(0xFFE3EEE6); // 세이프 뒤 아치
  static const Color goldLine = Color(0xFFD2AE62); // 아치 안쪽 금색 선 · 반짝이
  static Color get nameGreen => _d ? const Color(0xFF6FD6A4) : const Color(0xFF135C3E); // 앱 이름 '전세' '프'
  static Color get sub => _d ? const Color(0xFFA9B7AF) : const Color(0xFF4F5E56); // 한 줄 소개
  static Color get primary => _d ? const Color(0xFF3DB580) : const Color(0xFF14724B); // 메인 버튼 · 링크 · 보조 버튼 글자
  static Color get onPrimary => _d ? const Color(0xFF04170E) : const Color(0xFFFFFFFF); // 메인 버튼 글자
  static Color get outline => _d ? const Color(0xFF2B4A3B) : const Color(0xFFB9D3C2); // 보조 버튼 테두리
  static Color get shadow => _d ? const Color(0xFF000000) : const Color(0xFF13422E); // 발 그림자 12% · 시트 그림자 6%
  static const Color aiGoldTop = Color(0xFFC99A3E); // 금색 "AI" 위
  static const Color aiGoldBottom = Color(0xFFA87A22); // 금색 "AI" 아래
}

/// 그림 파일 — 세이프는 앱에 있는 투명 PNG, 로고는 팀 로고 심볼을 밝은 배경용(초록 선)으로 옮긴 것.
const String kStartMascotAsset = 'assets/mascot/mascot_home.png';
const String kStartLogoAsset = 'assets/brand/logo_icon_light.png';

class StartScreen extends StatefulWidget {
  const StartScreen({super.key});

  static const String guestLabel = '로그인 없이 둘러보기';
  static const String title = '전세AI프';
  static const String tagline = 'AI가 지켜주는 안전한 전세 계약';
  static const String privacyLabel = '개인정보 처리방침';

  /// 반복 애니메이션(손 흔들기·반짝이)을 켤지 — null이면 자동(`flutter test`에서는 끔: pumpAndSettle이 끝나도록).
  @visibleForTesting
  static bool? idleAnimations;

  @override
  State<StartScreen> createState() => _StartScreenState();
}

/// 등장 애니메이션 한 칸 — 시작·길이(ms)는 1300ms 묶음 안의 위치.
class _Beat {
  const _Beat(this.startMs, this.lengthMs, {this.curve = Curves.easeOutCubic});
  final int startMs;
  final int lengthMs;
  final Curve curve;

  Interval interval() => Interval(
    startMs / _kEntranceMs,
    (startMs + lengthMs) / _kEntranceMs,
    curve: curve,
  );
}

const int _kEntranceMs = 1300;
const _Beat _beatLogo = _Beat(0, 500);
const _Beat _beatTitle = _Beat(80, 500);
const _Beat _beatTagline = _Beat(160, 500);
const _Beat _beatArch = _Beat(280, 600);
const _Beat _beatSafe = _Beat(
  400,
  700,
  curve: Curves.linear,
); // 튀는 모양은 TweenSequence가 만든다
const _Beat _beatSheet = _Beat(600, 500);
const _Beat _beatKakao = _Beat(700, 450);
const _Beat _beatGuest = _Beat(780, 450);
const _Beat _beatLink = _Beat(860, 400, curve: Curves.easeOut);

class _StartScreenState extends State<StartScreen>
    with TickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _kEntranceMs),
  );
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  );
  late final List<AnimationController> _sparkles = List.generate(
    3,
    (_) => AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    ),
  );

  bool _started = false;

  /// 이 화면에서 카카오 로그인을 시작해 끝날 때까지(성공 뒤 홈으로 넘어가는 순간 포함) true —
  /// 로그인이 끝나 세션이 바뀌어도 [시작하기] 화면으로 잠깐 바뀌어 보이지 않게, 로그인 중 모습을 유지한다.
  bool _signingIn = false;
  bool _reduceMotion = false;

  bool get _idleOn {
    final forced = StartScreen.idleAnimations;
    if (forced != null) return forced;
    if (kIsWeb) return true;
    return !Platform.environment.containsKey('FLUTTER_TEST');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_reduceMotion) {
      // '애니메이션 제거' 설정 — 1~9는 200ms 페이드만, 반복은 끈다
      _entrance.duration = const Duration(milliseconds: 200);
      _entrance.forward();
      return;
    }
    _entrance.forward();
    if (!_idleOn) return;
    _later(1400, () => _wave.repeat());
    for (var i = 0; i < _sparkles.length; i++) {
      final c = _sparkles[i];
      // 100%에서 시작해 25%↔100%를 오간다(등장 끝의 선명함에서 끊김 없이 이어지게)
      _later(
        1300 + 800 * i,
        () => c
          ..value = 1
          ..repeat(reverse: true),
      );
    }
  }

  void _later(int ms, VoidCallback run) {
    Future<void>.delayed(Duration(milliseconds: ms), () {
      if (mounted) run();
    });
  }

  @override
  void dispose() {
    _entrance.dispose();
    _wave.dispose();
    for (final c in _sparkles) {
      c.dispose();
    }
    super.dispose();
  }

  void _browse(BuildContext context) {
    context.read<AppSession>().continueAsGuest();
    context.go('/home');
  }

  Future<void> _kakao(BuildContext context) async {
    setState(() => _signingIn = true);
    final ok = await runKakaoLogin(context);
    if (!context.mounted) return;
    if (!ok) {
      setState(() => _signingIn = false);
      return;
    }
    context.go('/home');
  }

  // ── 등장 애니메이션 도우미 ─────────────────────────────────────

  /// 아래 [dy]에서 제자리로 + (원하면) 투명 → 선명.
  Widget _rise(_Beat beat, Widget child, {double dy = 16, bool fade = true}) {
    final t = CurvedAnimation(
      parent: _entrance,
      curve: _reduceMotion ? Curves.linear : beat.interval(),
    );
    return AnimatedBuilder(
      animation: t,
      child: child,
      builder: (_, c) {
        final v = t.value;
        final offset = _reduceMotion ? 0.0 : (1 - v) * dy;
        Widget out = Transform.translate(offset: Offset(0, offset), child: c);
        if (fade || _reduceMotion) {
          out = Opacity(opacity: v.clamp(0.0, 1.0), child: out);
        }
        return out;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    // 로그인 중이면 세션이 이미 로그인으로 바뀌었어도 카카오 화면 그대로 (넘어가는 순간 깜빡임 방지)
    final loggedInView = session.isLoggedIn && !_signingIn;
    final kakao = !loggedInView && session.kakaoAvailable;
    final busy = session.busy || _signingIn;
    final topInset = MediaQuery.paddingOf(context).top;

    return PopScope(
      canPop: !busy, // 로그인 중 뒤로 가기 막기
      child: Scaffold(
        backgroundColor: StartColors.bg,
        body: Column(
          children: [
            SizedBox(height: topInset + (kakao ? 60 : 90)),
            _Header(rise: _rise),
            Expanded(child: _middle()),
            _rise(
              _beatSheet,
              _Sheet(
                children: _sheetChildren(
                  context,
                  session,
                  kakao: kakao,
                  busy: busy,
                ),
              ),
              dy: 40,
              fade: false,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _sheetChildren(
    BuildContext context,
    AppSession session, {
    required bool kakao,
    required bool busy,
  }) {
    final link = _rise(
      _beatLink,
      _Dimmed(
        dim: busy,
        child: SizedBox(
          height: 44,
          child: TextButton(
            onPressed: busy ? null : () => context.push('/privacy'),
            style: TextButton.styleFrom(
              foregroundColor: StartColors.primary,
              minimumSize: const Size(0, 44),
            ),
            child: AppText(
              StartScreen.privacyLabel,
              style: AppTypography.body.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: StartColors.primary,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ),
      fade: true,
      dy: 0,
    );

    if (session.isLoggedIn && !_signingIn) {
      return [
        _rise(
          _beatKakao,
          _GuestButton(
            label: '시작하기',
            filled: true,
            onPressed: () => context.go('/home'),
          ),
        ),
        const SizedBox(height: 10),
        link,
      ];
    }
    return [
      if (kakao) ...[
        _rise(
          _beatKakao,
          KakaoLoginButton(busy: busy, onPressed: () => _kakao(context)),
        ),
        const SizedBox(height: 10),
      ],
      _rise(
        kakao ? _beatGuest : _beatKakao,
        _Dimmed(
          dim: busy,
          child: _GuestButton(
            label: StartScreen.guestLabel,
            filled: !kakao,
            onPressed: busy ? null : () => _browse(context),
          ),
        ),
      ),
      const SizedBox(height: 10),
      link,
    ];
  }

  /// 가운데 — 아치 + 금색 선 + 반짝이 + 발 그림자 + 세이프. 자리가 308보다 낮으면 비율을 지켜 줄인다.
  Widget _middle() {
    final archIn = CurvedAnimation(
      parent: _entrance,
      curve: _reduceMotion ? Curves.linear : _beatArch.interval(),
    );
    final safeIn = CurvedAnimation(
      parent: _entrance,
      curve: _reduceMotion ? Curves.linear : _beatSafe.interval(),
    );
    // 아래 28 → 위로 4 살짝 튐(60%) → 제자리
    final safeDy = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(
          begin: 28.0,
          end: -4.0,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 60,
      ),
      TweenSequenceItem(
        tween: Tween(
          begin: -4.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 40,
      ),
    ]);
    // 손 흔들기(도) — 0 유지(64) → -5 → +4 → -4 → +2 → 0 (각 6) → 0 유지(6)
    final waveDeg = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(0.0), weight: 64),
      for (final (a, b) in const [
        (0.0, -5.0),
        (-5.0, 4.0),
        (4.0, -4.0),
        (-4.0, 2.0),
        (2.0, 0.0),
      ])
        TweenSequenceItem(
          tween: Tween(
            begin: a,
            end: b,
          ).chain(CurveTween(curve: Curves.easeInOut)),
          weight: 6,
        ),
      TweenSequenceItem(tween: ConstantTween(0.0), weight: 6),
    ]);

    final arch = AnimatedBuilder(
      animation: archIn,
      builder: (_, child) => Opacity(
        opacity: archIn.value.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: _reduceMotion ? 1 : 0.94 + 0.06 * archIn.value,
          alignment: Alignment.bottomCenter,
          child: child,
        ),
      ),
      child: const _Arch(),
    );

    final safe = AnimatedBuilder(
      animation: Listenable.merge([safeIn, _wave]),
      builder: (_, child) {
        final v = safeIn.value;
        final dy = _reduceMotion ? 0.0 : safeDy.transform(v.clamp(0.0, 1.0));
        final deg = _wave.isAnimating ? waveDeg.transform(_wave.value) : 0.0;
        return Opacity(
          opacity: (_reduceMotion ? v : math.min(1.0, v / 0.6)).clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, dy),
            child: Transform.rotate(
              angle: deg * math.pi / 180,
              alignment: Alignment.bottomCenter,
              child: child,
            ),
          ),
        );
      },
      child: Image.asset(
        kStartMascotAsset,
        width: 160,
        height: 250,
        fit: BoxFit.contain,
        semanticLabel: '손을 흔드는 마스코트 세이프',
      ),
    );

    Widget sparkle(int i, double left, double top, double size) => Positioned(
      left: left,
      top: top,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([_sparkles[i], archIn]),
          builder: (_, child) {
            final c = _sparkles[i];
            final looping = c.isAnimating || c.value > 0;
            final t = Curves.easeInOut.transform(c.value);
            final opacity = looping ? 0.25 + 0.75 * t : archIn.value;
            final scale = looping ? 0.7 + 0.3 * t : 1.0;
            return Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform.scale(scale: scale, child: child),
            );
          },
          child: SizedBox(
            width: size,
            height: size,
            child: const CustomPaint(painter: _SparklePainter()),
          ),
        ),
      ),
    );

    final group = SizedBox(
      width: _Arch.width,
      height: _Arch.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: arch),
          // 반짝이 3개 — 시안 좌표(가운데 영역 기준)를 아치 기준으로 옮긴 값
          sparkle(0, 30, 30, 14),
          sparkle(1, 192, 56, 10),
          sparkle(2, 204, 170, 12),
          // 발 그림자 — 바닥에 붙임
          Positioned(
            left: (_Arch.width - 120) / 2,
            bottom: 0,
            child: AnimatedBuilder(
              animation: safeIn,
              builder: (_, child) =>
                  Opacity(opacity: safeIn.value.clamp(0.0, 1.0), child: child),
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 1, sigmaY: 1),
                child: Container(
                  width: 120,
                  height: 14,
                  decoration: BoxDecoration(
                    color: StartColors.shadow.withValues(alpha: 0.12),
                    borderRadius: const BorderRadius.all(
                      Radius.elliptical(60, 7),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 세이프 — 발끝이 시트 윗선보다 4 위
          Positioned(
            left: (_Arch.width - 160) / 2,
            bottom: 4,
            child: RepaintBoundary(child: safe),
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (_, box) {
        final h = math.min(box.maxHeight, _Arch.height);
        return Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            height: h,
            child: FittedBox(
              fit: BoxFit.contain,
              alignment: Alignment.bottomCenter,
              child: group,
            ),
          ),
        );
      },
    );
  }
}

// ── 위: 로고 · 앱 이름 · 한 줄 소개 ─────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.rise});

  final Widget Function(_Beat beat, Widget child, {double dy, bool fade}) rise;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        rise(
          _beatLogo,
          Image.asset(
            kStartLogoAsset,
            width: 56,
            height: 62,
            excludeFromSemantics: true,
          ),
        ),
        const SizedBox(height: 8),
        rise(_beatTitle, const AppNameTitle()),
        const SizedBox(height: 8),
        rise(
          _beatTagline,
          AppText(
            StartScreen.tagline,
            textAlign: TextAlign.center,
            style: AppTypography.body.copyWith(
              fontSize: 15,
              height: 22 / 15,
              letterSpacing: -0.2,
              fontWeight: FontWeight.w500,
              color: StartColors.sub,
            ),
          ),
        ),
      ],
    );
  }
}

/// 앱 이름 "전세AI프" — '전세'·'프'는 주아체 초록, "AI"는 금색으로 직접 그린 글자([AiGlyphPainter]).
/// 스크린 리더에는 "전세AI프" 통째로 읽힌다.
class AppNameTitle extends StatelessWidget {
  const AppNameTitle({super.key});

  static TextStyle get style => TextStyle(
    fontFamily: 'Jua',
    fontSize: 40,
    height: 48 / 40,
    letterSpacing: -0.5,
    color: StartColors.nameGreen,
  );

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: StartScreen.title,
      header: true,
      excludeSemantics: true,
      child: Text.rich(
        TextSpan(
          style: style,
          children: [
            const TextSpan(text: '전세'),
            WidgetSpan(
              // 글자 바닥줄(baseline)에 맞춘다 — 가운데 정렬 + 아래로 내리면 실기기 주아체에서 아래로 처져 보였다
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: const SizedBox(
                  width: 30,
                  height: 34,
                  child: CustomPaint(painter: AiGlyphPainter()),
                ),
              ),
            ),
            const TextSpan(text: '프'),
          ],
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

/// 금색 "AI" — 팀 로고의 둥근 글자(타원 + 세로 막대 + 꼬리). 35×40 좌표계로 그려 칸에 맞춰 줄인다.
class AiGlyphPainter extends CustomPainter {
  const AiGlyphPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 35, size.height / 40);
    // 그라데이션은 글자 전체 칸(y 0~40)으로 — 막대 하나 기준으로 잡으면 폭 0이라 안 칠해진다
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.2
      ..strokeCap = StrokeCap.round
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [StartColors.aiGoldTop, StartColors.aiGoldBottom],
      ).createShader(const Rect.fromLTWH(0, 0, 35, 40));
    canvas.drawOval(
      Rect.fromCenter(
        center: const Offset(11, 19.8),
        width: 7.9 * 2,
        height: 16.1 * 2,
      ),
      paint,
    );
    canvas.drawLine(const Offset(31.3, 3.1), const Offset(31.3, 36.9), paint);
    canvas.drawPath(
      Path()
        ..moveTo(18.4, 30.5)
        ..cubicTo(20.5, 36.5, 27.5, 37.5, 31.3, 34),
      paint,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ── 가운데: 아치 ──────────────────────────────────────────────────

class _Arch extends StatelessWidget {
  const _Arch();

  static const double width = 236;
  static const double height = 308;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: StartColors.arch,
        borderRadius: BorderRadius.vertical(top: Radius.circular(118)),
      ),
      child: CustomPaint(
        painter: _ArchLinePainter(),
        size: Size(width, height),
      ),
    );
  }
}

/// 아치 안쪽 10 들인 금색 선 — 위·양옆만(아래 선 없음), 두께 1.5, 위 모서리 108.
class _ArchLinePainter extends CustomPainter {
  const _ArchLinePainter();

  @override
  void paint(Canvas canvas, Size size) {
    const inset = 10.0;
    final r = size.width / 2 - inset; // 108
    final path = Path()
      ..moveTo(inset, size.height)
      ..lineTo(inset, inset + r)
      ..arcTo(
        Rect.fromCircle(center: Offset(size.width / 2, inset + r), radius: r),
        math.pi,
        math.pi,
        false,
      )
      ..lineTo(size.width - inset, size.height);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = StartColors.goldLine,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 4갈래 반짝이 별 (12×12 기준 경로).
class _SparklePainter extends CustomPainter {
  const _SparklePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(6, 0)
      ..cubicTo(6.6, 3.6, 8.4, 5.4, 12, 6)
      ..cubicTo(8.4, 6.6, 6.6, 8.4, 6, 12)
      ..cubicTo(5.4, 8.4, 3.6, 6.6, 0, 6)
      ..cubicTo(3.6, 5.4, 5.4, 3.6, 6, 0)
      ..close();
    canvas
      ..save()
      ..scale(size.width / 12, size.height / 12)
      ..drawPath(path, Paint()..color = StartColors.goldLine)
      ..restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ── 아래: 흰 시트와 버튼 ────────────────────────────────────────────

class _Sheet extends StatelessWidget {
  const _Sheet({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: StartColors.sheet,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: StartColors.shadow.withValues(alpha: 0.06),
            offset: const Offset(0, -8),
            blurRadius: 24,
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 28, 24, 20 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

/// 로그인 중에 흐리게(1 → 0.4, 200ms).
class _Dimmed extends StatelessWidget {
  const _Dimmed({required this.dim, required this.child});

  final bool dim;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: dim ? 0.4 : 1,
    duration: const Duration(milliseconds: 200),
    child: child,
  );
}

/// [로그인 없이 둘러보기] — 카카오가 있으면 테두리 버튼(보조), 없으면 꽉 찬 초록 버튼(메인).
class _GuestButton extends StatelessWidget {
  const _GuestButton({
    required this.label,
    required this.filled,
    required this.onPressed,
  });

  final String label;
  final bool filled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
    );
    final text = AppText(
      label,
      style: AppTypography.button.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: filled ? StartColors.onPrimary : StartColors.primary,
      ),
    );
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: filled
          ? FilledButton(
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                backgroundColor: StartColors.primary,
                foregroundColor: StartColors.onPrimary,
                disabledBackgroundColor: StartColors.primary,
                shape: shape,
              ),
              child: text,
            )
          : OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                backgroundColor: StartColors.sheet,
                foregroundColor: StartColors.primary,
                side: BorderSide(color: StartColors.outline, width: 1.5),
                shape: shape,
              ),
              child: text,
            ),
    );
  }
}
