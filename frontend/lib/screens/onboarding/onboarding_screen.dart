/// S-01 스플래시 & 온보딩 — IA.md §6.
///
/// 3장: ① 왜 위험한지 ② 우리는 뭐가 다른지(차별화 3종 프레이밍) ③ 등기부만 있으면 됨.
/// 마지막에 [시작하기] → S-02. 우상단 [건너뛰기] 상시. 마스코트는 플레이스홀더.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/mascot_safe.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';

class _Page {
  const _Page(this.title, this.body);
  final String title;
  final String body;
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _pages = [
    _Page('전세 계약, 도장 찍기 전에', '전세사기·깡통전세는 계약 전에 등기부등본만 제대로 봐도 상당 부분 걸러낼 수 있어요.'),
    _Page(
      '무엇을 조심할지까지 알려드려요',
      '실제 판례로 위험을 증명하고, 손실액을 숫자로 계산하고, 중개사에게 뭘 물어봐야 하는지까지 챙겨드려요.',
    ),
    _Page('등기부등본 사진만 있으면 돼요', '어려운 말은 저희가 쉽게 풀어드릴게요. 등기부등본이 없어도 발급 방법을 안내해 드려요.'),
  ];

  final PageController _controller = PageController();
  int _index = 0;

  bool get _isLast => _index == _pages.length - 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_isLast) {
      context.go('/start');
    } else {
      _controller.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 2·3장에서 시스템 백 → 이전 장으로, 첫 장에서는 종료 허용 (IA §7)
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _controller.previousPage(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => context.go('/start'),
                  child: const Text('건너뛰기'),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _pages.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) => _pageView(_pages[i], i),
                ),
              ),
              _dots(),
              const SizedBox(height: AppSpacing.xl),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.screenPadding,
                ),
                child: AppPrimaryButton(
                  label: _isLast ? '시작하기' : '다음',
                  onPressed: _next,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              if (_isLast)
                TextButton(
                  onPressed: () => context.push('/guide'),
                  child: const Text('등기부등본이 없다면? 발급 방법 보기'),
                )
              else
                const SizedBox(height: AppSize.buttonHeight - AppSpacing.md),
              const SizedBox(height: AppSpacing.lg),
            ],
          ),
        ),
      ),
    );
  }

  /// 온보딩 3장에 맞춘 마스코트: 인사 → (우리가) 검토 → 준비 완료
  static const _pageMascots = [
    MascotState.home, // "도장 찍기 전에" — 인사
    MascotState.analyzing, // "무엇을 조심할지 알려드려요" — 검토하는 세이프
    MascotState.complete, // "등기부등본만 있으면 돼요" — 집 든 세이프
  ];

  Widget _pageView(_Page page, int i) {
    final state = _pageMascots[i.clamp(0, _pageMascots.length - 1)];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxxl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          MascotSafe(size: 120, state: state),
          const SizedBox(height: AppSpacing.xxxl),
          Text(
            page.title,
            style: AppTypography.headline,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            page.body,
            style: AppTypography.body,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _dots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < _pages.length; i++)
          Container(
            width: i == _index ? 20 : 8,
            height: 8,
            margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            decoration: BoxDecoration(
              color: i == _index ? AppColors.primary : AppColors.line,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
      ],
    );
  }
}
