/// 다크 모드 (2026-10-30) — 마이 → 설정 → 화면 모드(시스템 · 밝게 · 어둡게).
///
///   ① 고른 모드는 이 폰에 남고, 다음에 켜면 그 모드로 시작한다
///   ② 어둡게를 고르면 화면 전체가 그 자리에서 어두운 팔레트로 다시 그려진다(상태는 그대로)
///   ③ 어둡게에서도 위험을 안전한 척하지 않는다 — 위험 빨강은 양호 초록보다 바탕 대비가 높고, 글자색은 모두 4.5:1 이상
///   ④ 종이 사진 위 표시(형광펜·가림 상자·번호 뱃지)는 모드와 상관없이 같다
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/tokens/app_colors.dart';
import 'package:jeonse_ai/main.dart';
import 'package:jeonse_ai/models/registry_mark_kind.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/screens/my/my_settings.dart';
import 'package:jeonse_ai/state/theme_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThemeSettings.instance.debugReset();
    AppColors.apply(Brightness.light);
  });
  tearDown(() {
    ThemeSettings.instance.debugReset();
    AppColors.apply(Brightness.light);
  });

  test('① 고른 모드는 저장되고 다시 켜면 그대로 (기본은 시스템 따라)', () async {
    expect(ThemeSettings.instance.mode, ThemeMode.system);
    await ThemeSettings.instance.setMode(ThemeMode.dark);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeSettings.modeKey), 'dark');

    ThemeSettings.instance.debugReset();
    expect(ThemeSettings.instance.mode, ThemeMode.system);
    await ThemeSettings.instance.restore();
    expect(ThemeSettings.instance.mode, ThemeMode.dark);
  });

  testWidgets('② [어둡게]를 누르면 그 자리에서 화면 전체가 어두워지고, [밝게]면 돌아온다', (tester) async {
    await tester.pumpWidget(
      AppThemeHost(
        builder: (_) => MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const ThemeModeSelector(),
                // 테마를 거치지 않고 AppColors를 바로 읽는 위젯도 다시 그려져야 한다
                Builder(
                  builder: (_) => Container(
                    key: const ValueKey('probe'),
                    width: 10,
                    height: 10,
                    color: AppColors.surface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    Color probe() =>
        (tester.widget<Container>(find.byKey(const ValueKey('probe'))).color)!;
    expect(AppColors.isDark, isFalse);
    expect(probe(), AppPalette.light.surface);

    await tester.tap(find.byKey(const ValueKey('theme-mode-dark')));
    await tester.pumpAndSettle();
    expect(AppColors.isDark, isTrue);
    expect(probe(), AppPalette.dark.surface);
    expect(ThemeSettings.instance.mode, ThemeMode.dark);

    await tester.tap(find.byKey(const ValueKey('theme-mode-light')));
    await tester.pumpAndSettle();
    expect(AppColors.isDark, isFalse);
    expect(probe(), AppPalette.light.surface);
  });

  test('③ 어둡게에서도 위험이 더 또렷하다 — 위험 대비 > 양호 대비, 글자색 모두 4.5:1 이상', () {
    const d = AppPalette.dark;
    final onCard = {
      'danger': _contrast(d.danger, d.surface),
      'caution': _contrast(d.caution, d.surface),
      'ok': _contrast(d.ok, d.surface),
      'textMuted': _contrast(d.textMuted, d.surface),
      'primary': _contrast(d.primary, d.surface),
    };
    for (final e in onCard.entries) {
      expect(e.value, greaterThanOrEqualTo(4.5), reason: '${e.key} ${e.value}');
    }
    expect(onCard['danger']!, greaterThan(onCard['ok']!));
    expect(
      _contrast(d.dangerArc, d.surface),
      greaterThan(_contrast(d.okArc, d.surface)),
    );
    // 연한 등급 바탕 위 등급 글자, 초록 바탕 위 글자
    expect(_contrast(d.danger, d.dangerSoft), greaterThanOrEqualTo(4.5));
    expect(_contrast(d.caution, d.cautionSoft), greaterThanOrEqualTo(4.5));
    expect(_contrast(d.ok, d.okSoft), greaterThanOrEqualTo(4.5));
    expect(_contrast(d.onPrimary, d.primary), greaterThanOrEqualTo(4.5));

    // 등급 → 색 매핑은 모드와 상관없이 같은 뜻(위험 = 빨강 계열)
    AppColors.apply(Brightness.dark);
    expect(AppColors.gradeColor(RiskGrade.danger), d.danger);
    expect(AppColors.gradeColor(RiskGrade.ok), d.ok);
  });

  test('④ 종이 사진 위 표시는 모드와 상관없이 같다', () {
    final light = [
      AppColors.markRedaction,
      AppColors.markSolid(MarkTone.risk),
      AppColors.markSolid(MarkTone.verify),
      AppColors.markHighlight(MarkTone.risk, selected: false),
    ];
    AppColors.apply(Brightness.dark);
    final dark = [
      AppColors.markRedaction,
      AppColors.markSolid(MarkTone.risk),
      AppColors.markSolid(MarkTone.verify),
      AppColors.markHighlight(MarkTone.risk, selected: false),
    ];
    expect(dark, light);
  });
}
