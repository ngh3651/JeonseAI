/// 마이 화면 맨 아래 **앱 버전·빌드 번호** 한 줄 (2026-10-23).
///
/// 부스에서 "이 폰에 최신 APK가 깔렸나"를 바로 확인하려고 둔다(빌드 번호 = CI 실행 번호 — NOW.md 6-2).
/// 이 줄을 **7번 연속** 누르면 부스 모드를 켜고 끈다([BoothMode]). `package_info_plus`를 부르는 곳은 이 파일뿐이다.
library;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../state/booth_mode.dart';

/// 부스 모드를 켜고 껐을 때의 토스트 — 무엇이 숨겨지는지까지 말한다.
const String kBoothModeOnMessage = '부스 모드를 켰어요 — 로그아웃·회원 탈퇴·기록 지우기 버튼을 숨겨요';
const String kBoothModeOffMessage = '부스 모드를 껐어요';

class AppVersionLine extends StatefulWidget {
  const AppVersionLine({super.key, this.boothMode});

  /// 테스트가 넣는다. 없으면 앱 전체의 [BoothMode.instance].
  final BoothMode? boothMode;

  @override
  State<AppVersionLine> createState() => _AppVersionLineState();
}

class _AppVersionLineState extends State<AppVersionLine> {
  late final Future<PackageInfo?> _info = _load();

  BoothMode get _booth => widget.boothMode ?? BoothMode.instance;

  static Future<PackageInfo?> _load() async {
    try {
      return await PackageInfo.fromPlatform();
    } catch (e) {
      debugPrint('[앱 버전] 읽지 못했어요 (${e.runtimeType})');
      return null;
    }
  }

  Future<void> _onTap() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final bool? toggled = await _booth.registerTap();
    if (toggled == null) return;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: AppText(toggled ? kBoothModeOnMessage : kBoothModeOffMessage)),
      );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo?>(
      future: _info,
      builder: (context, snapshot) {
        final info = snapshot.data;
        final String version = info == null
            ? '앱 버전 확인 중'
            : '앱 버전 ${info.version} (빌드 ${info.buildNumber})';
        return ListenableBuilder(
          listenable: _booth,
          builder: (context, _) => Semantics(
            label: version,
            child: InkWell(
              key: const ValueKey('app-version-line'),
              onTap: _onTap,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: AppSize.minTouchTarget),
                child: Center(
                  child: AppText(
                    _booth.on ? '$version · 부스 모드' : version,
                    textAlign: TextAlign.center,
                    style: AppTypography.caption.copyWith(color: AppColors.textMuted),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
