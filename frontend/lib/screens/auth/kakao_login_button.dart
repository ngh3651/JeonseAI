/// 카카오 로그인 버튼 + 로그인 한 번 돌리기 + 개인정보 한 줄 (2026-10-22, P2-1).
///
/// 버튼 모양은 카카오 로그인 디자인 가이드를 따른다: 노란 바탕 `#FEE500` · 검은 말풍선 심볼 · 검은 글자(85%) ·
/// 둥근 모서리 12. 심볼은 카카오 공식 Flutter SDK에 들어 있는 카카오톡 로그인 아이콘(`icon_talk_login.svg`)의
/// 모양을 그대로 그린다(그림 파일·새 패키지 없이).
/// ⚠ 이 버튼은 **카카오 키가 있는 빌드에서만** 화면에 나온다([AppSession.kakaoAvailable]) — 가짜 버튼 금지.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../state/app_session.dart';

/// 카카오 디자인 가이드 색.
const Color kKakaoYellow = Color(0xFFFEE500);
const Color kKakaoSymbol = Color(0xFF000000);
const Color kKakaoLabel = Color(0xD9000000); // 검정 85%

class KakaoLoginButton extends StatelessWidget {
  const KakaoLoginButton({
    super.key,
    required this.onPressed,
    this.busy = false,
  });

  static const String label = '카카오로 시작하기';

  final VoidCallback? onPressed;

  /// 로그인 진행 중 — 글자 대신 기다림 표시, 누를 수 없음.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: SizedBox(
        width: double.infinity,
        height: AppSize.buttonHeight,
        child: Material(
          color: kKakaoYellow,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: busy ? null : onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CustomPaint(painter: KakaoSymbolPainter()),
                  ),
                  Expanded(
                    child: Center(
                      child: busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: kKakaoLabel,
                              ),
                            )
                          : AppText(
                              label,
                              style: AppTypography.button.copyWith(
                                color: kKakaoLabel,
                              ),
                            ),
                    ),
                  ),
                  // 심볼과 같은 폭 — 글자가 버튼 한가운데 오게
                  const SizedBox(width: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 카카오 말풍선 심볼 — SDK 아이콘(19×20 상자)의 경로를 그대로 옮겼다.
class KakaoSymbolPainter extends CustomPainter {
  const KakaoSymbolPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(9.5005, 3.08081)
      ..cubicTo(13.2685, 3.08091, 16.3418, 5.72991, 16.3419, 9.03952)
      ..cubicTo(16.3419, 12.3424, 13.2685, 14.9915, 9.5005, 14.9916)
      ..cubicTo(9.1365, 14.9916, 8.77883, 14.9712, 8.42831, 14.924)
      ..lineTo(8.37397, 14.9134)
      ..lineTo(6.5079, 16.3004)
      ..cubicTo(5.91032, 16.7443, 5.06157, 16.3205, 5.05732, 15.5761)
      ..lineTo(5.04605, 13.5602)
      ..lineTo(5.03147, 13.549)
      ..cubicTo(3.36652, 12.3491, 2.68543, 11.2233, 2.65846, 9.16741)
      ..lineTo(2.65846, 9.03289)
      ..cubicTo(2.65846, 5.72993, 5.73244, 3.08081, 9.5005, 3.08081)
      ..close();
    canvas
      ..save()
      ..scale(size.width / 19, size.height / 20)
      ..drawPath(path, Paint()..color = kKakaoSymbol)
      ..restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 카카오 로그인을 한 번 돌리고 결과를 알린다. 성공하면 true(화면이 다음으로 간다).
///
/// 취소(사용자가 카카오 화면을 닫음)는 아무 말 없이 false. 실패는 쉬운 말 한 줄.
Future<bool> runKakaoLogin(BuildContext context) async {
  final session = context.read<AppSession>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final outcome = await session.signInWithKakao();
  if (outcome.ok) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: AppText('카카오로 로그인했어요. 기록이 계정에 남아요')),
      );
    return true;
  }
  if (outcome.result == LoginResult.failed ||
      outcome.result == LoginResult.unavailable) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: AppText(outcome.message ?? '로그인하지 못했어요')),
      );
  }
  return false;
}

/// 로그인 버튼 아래 한 줄 — 무엇을 받는지 + 개인정보 처리방침 들어가기.
class LoginPrivacyNote extends StatelessWidget {
  const LoginPrivacyNote({super.key});

  static const String text = '카카오에서는 회원번호만 받아요. 이름·이메일은 받지 않아요.';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AppText(
          text,
          style: AppTypography.caption.copyWith(color: AppColors.textMuted),
          textAlign: TextAlign.center,
        ),
        TextButton(
          onPressed: () => context.push('/privacy'),
          child: const AppText('개인정보 처리방침'),
        ),
      ],
    );
  }
}
