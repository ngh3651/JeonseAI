/// S-05 등기부 발급 가이드 — IA.md §6.
///
/// 처음 등기부를 떼는 사람을 위한 단계별 안내. [준비됐어요, 분석 시작] → 분석 진입(가드).
///
/// NOTE(팀 피드백 대비): 인터넷등기소 열람 수수료(700원)는 프로토타입 예시 표기다.
/// 실제 금액·절차는 Phase F에서 인터넷등기소 고시 기준으로 재확인 후 확정한다.
library;

import 'package:flutter/material.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../common/analyze_gate.dart';
import '../../design_system/text/app_text.dart';

class _Step {
  const _Step(this.title, this.body);
  final String title;
  final String body;
}

class RegistryGuideScreen extends StatelessWidget {
  const RegistryGuideScreen({super.key});

  static const _steps = [
    _Step('인터넷등기소에 접속해요', '회원가입 없이도 이용할 수 있어요. (대법원 인터넷등기소)'),
    _Step(
      '주소를 넣고 ‘열람’을 골라요',
      '‘발급’ 대신 ‘열람’이면 분석에 충분해요. 열람 수수료는 700원이에요 (예시 — 실제 금액은 사이트에서 확인).',
    ),
    _Step('결제한 뒤 화면을 캡처하거나 출력물을 찍어요', '여러 페이지면 한 장씩 나눠서 준비해 주세요.'),
    _Step('앱에 사진을 올리면 끝이에요', '표제부·갑구·을구 페이지를 모두 올리면 더 정확해요.'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const AppText('등기부등본 발급 가이드')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          // B3: 정식 명칭은 이 발급 가이드 화면에서만 1회 괄호 병기 (신뢰감)
          AppText('등기부등본(등기사항전부증명서), 이렇게 떼면 돼요', style: AppTypography.headline),
          const SizedBox(height: AppSpacing.xl),
          for (int i = 0; i < _steps.length; i++) ...[
            _stepCard(i + 1, _steps[i]),
            const SizedBox(height: AppSpacing.md),
          ],
          const SizedBox(height: AppSpacing.lg),
          AppPrimaryButton(
            label: '준비됐어요, 분석 시작',
            onPressed: () => startAnalysis(context),
          ),
          const SizedBox(height: AppSpacing.xxxl),
        ],
      ),
    );
  }

  Widget _stepCard(int number, _Step step) {
    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
            ),
            child: AppText(
              '$number',
              style: AppTypography.label.copyWith(color: Colors.white),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(step.title, style: AppTypography.bodyStrong),
                const SizedBox(height: AppSpacing.xs),
                AppText(step.body, style: AppTypography.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
