/// 분석 진입 가드 + 로그인 유도 바텀시트 (IA.md §4 · 2026-10-22 카카오 로그인).
///
/// 로그인 없이 둘러보는 사람이 분석(＋분석·홈 CTA)을 누르면 **로그인 유도** 바텀시트를 띄운다 — 지금까지의 규칙 그대로.
/// 달라진 것: 시트가 **진짜 카카오 로그인**으로 이어지고, 성공하면 원래 하려던 행동(분석)으로 간다
/// (user-scenario.md C5 — next로 연속). 그리고 **막다른 길이 아니다** — [로그인 없이 분석하기]로 그대로 분석한다.
/// 부스에서 카카오가 막혀도 분석은 돼야 하고, 키가 없는 빌드(카카오 개발자 앱 등록 전)에서는 로그인할 길이 없기 때문이다.
/// 키가 없는 빌드에서는 시트를 띄우지 않고 바로 분석으로 간다(누를 수 없는 로그인 안내 = 가짜 버튼).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../state/app_session.dart';
import '../auth/kakao_login_button.dart';
import '../legal/consent_sheet.dart';

/// 사진을 어디서 가져오나 — 홈 분석 카드의 두 버튼 · 분석 시작 시트의 두 줄.
enum AnalyzeStart {
  camera('camera'),
  gallery('gallery');

  const AnalyzeStart(this.query);

  /// `/analyze?start=…` 값
  final String query;

  static AnalyzeStart? fromQuery(String? value) => switch (value) {
    'camera' => AnalyzeStart.camera,
    'gallery' => AnalyzeStart.gallery,
    _ => null,
  };
}

/// 인터넷등기소 — 등기부가 없을 때 떼는 곳 (홈 분석 카드 · 분석 시작 시트)
const String kRegistryOfficeUrl = 'https://www.iros.go.kr/';

/// **새 집 분석의 문은 어디에 있든 같은 시트**(2026-10-30 홈 리뉴얼):
/// 아래 ＋ · 여정 '새로 분석' · 홈 '새로 분석' 카드 · 빈 화면 버튼 → "매물 분석 시작하기" 시트
/// [촬영하기] [갤러리] + "등기부가 없나요? 인터넷등기소 ↗".
/// 홈 분석 카드는 같은 두 버튼이 카드에 이미 있어 [startAnalysisWith]로 바로 간다.
Future<void> startAnalysis(BuildContext context) async {
  final AnalyzeStart? pick = await showAnalyzeStartSheet(context);
  if (pick == null || !context.mounted) return;
  await startAnalysisWith(context, pick);
}

/// 분석 시작 — 로그인했거나 카카오 키가 없는 빌드면 바로 S-04(카메라나 갤러리가 바로 열림), 둘러보는 중이면 로그인 유도.
///
/// 그 전에 이용약관·개인정보 동의가 없으면 동의 시트부터(2026-10-30) — 사진을 받기 전에 한 번.
Future<void> startAnalysisWith(BuildContext context, AnalyzeStart start) async {
  if (!await ensureConsent(context) || !context.mounted) return;
  final session = context.read<AppSession>();
  final String next = '/analyze?start=${start.query}';
  if (session.isGuest && session.kakaoAvailable) {
    showLoginSheet(context, next: next);
  } else {
    context.push(next);
  }
}

/// 인터넷등기소를 바깥 브라우저로 연다. 못 열면 한 줄 안내.
Future<void> openRegistryOffice(BuildContext context) async {
  bool ok = false;
  try {
    ok = await launchUrl(
      Uri.parse(kRegistryOfficeUrl),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: AppText('인터넷등기소를 열지 못했어요. iros.go.kr 로 들어가 주세요'),
        ),
      );
  }
}

/// "매물 분석 시작하기" 시트 — 고른 쪽을 돌려준다(닫으면 null). 인터넷등기소 줄은 시트를 닫지 않고 브라우저를 연다.
Future<AnalyzeStart?> showAnalyzeStartSheet(BuildContext context) {
  return showModalBottomSheet<AnalyzeStart>(
    context: context,
    showDragHandle: false,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) => AnalyzeStartSheet(
      onPick: (start) => Navigator.of(sheetContext).pop(start),
      onOffice: () => openRegistryOffice(sheetContext),
    ),
  );
}

/// 시트 안 — 손잡이 · 제목 · [촬영하기](초록) · [갤러리](흰) · 인터넷등기소 줄. 홈 분석 카드와 같은 버튼이다.
class AnalyzeStartSheet extends StatelessWidget {
  const AnalyzeStartSheet({
    super.key,
    required this.onPick,
    required this.onOffice,
  });

  final ValueChanged<AnalyzeStart> onPick;
  final VoidCallback onOffice;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenPadding,
          10,
          AppSpacing.screenPadding,
          16,
        ),
        child: Column(
          key: const ValueKey('analyze-start-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            AppText('매물 분석 시작하기', style: AppTypographyNext.title),
            const SizedBox(height: 18),
            AnalyzeStartButtons(onPick: onPick),
            const SizedBox(height: 8),
            RegistryOfficeLink(onTap: onOffice),
          ],
        ),
      ),
    );
  }
}

/// [촬영하기](초록) · [갤러리](흰) 두 칸 — 홈 분석 카드와 분석 시작 시트가 같이 쓴다.
class AnalyzeStartButtons extends StatelessWidget {
  const AnalyzeStartButtons({super.key, required this.onPick});

  final ValueChanged<AnalyzeStart> onPick;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    final Color top = Color.lerp(
      AppColors.primary,
      AppColors.primaryBright,
      0.25,
    )!;
    return Row(
      children: [
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [top, AppColors.primary],
                stops: const [0, 0.6],
              ),
              boxShadow: AppColors.isDark
                  ? null
                  : [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.28),
                        offset: const Offset(0, 6),
                        blurRadius: 14,
                      ),
                    ],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: const ValueKey('analyze-camera'),
                borderRadius: radius,
                onTap: () => onPick(AnalyzeStart.camera),
                child: _label(
                  Icons.photo_camera_outlined,
                  '촬영하기',
                  AppColors.onPrimary,
                  AppColors.onPrimary,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Material(
            color: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(color: AppColors.line, width: 1.5),
            ),
            child: InkWell(
              key: const ValueKey('analyze-gallery'),
              borderRadius: radius,
              onTap: () => onPick(AnalyzeStart.gallery),
              child: _label(
                Icons.photo_outlined,
                '갤러리',
                AppColors.primary,
                AppColorsNext.textStrong,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _label(IconData icon, String text, Color iconColor, Color textColor) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: iconColor),
            const SizedBox(width: 8),
            Flexible(
              child: AppText(
                text,
                maxLines: 1,
                style: AppTypographyNext.button.copyWith(color: textColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "등기부가 없나요?  **인터넷등기소** ↗" — 누르면 바깥 브라우저.
class RegistryOfficeLink extends StatelessWidget {
  const RegistryOfficeLink({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey('registry-office-link'),
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: AppText.rich(
                TextSpan(
                  style: AppTypographyNext.caption,
                  children: [
                    const TextSpan(text: '등기부가 없나요?  '),
                    TextSpan(
                      text: '인터넷등기소',
                      style: AppTypographyNext.caption.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColorsNext.textStrong,
                        decoration: TextDecoration.underline,
                        decorationColor: AppColorsNext.textStrong,
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.north_east, size: 18, color: AppColorsNext.textStrong),
          ],
        ),
      ),
    );
  }
}

/// 로그인 유도 바텀시트 — [카카오로 시작하기] → 로그인되면 [next]로 · [로그인 없이 분석하기] → 바로 [next]로.
void showLoginSheet(BuildContext context, {required String next}) {
  showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.screenPadding,
        right: AppSpacing.screenPadding,
        top: AppSpacing.xl,
        bottom: MediaQuery.paddingOf(sheetContext).bottom + AppSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText('로그인하면 분석 기록이 계정에 남아요', style: AppTypography.headline),
          const SizedBox(height: AppSpacing.xl),
          KakaoLoginButton(
            onPressed: () async {
              Navigator.of(sheetContext).pop();
              final ok = await runKakaoLogin(context);
              if (!context.mounted || !ok) return;
              context.push(next);
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          AppSecondaryButton(
            label: '로그인 없이 분석하기',
            onPressed: () {
              Navigator.of(sheetContext).pop();
              context.push(next);
            },
          ),
          const SizedBox(height: AppSpacing.xs),
          AppText(
            LoginPrivacyNote.text,
            style: AppTypography.caption,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}
