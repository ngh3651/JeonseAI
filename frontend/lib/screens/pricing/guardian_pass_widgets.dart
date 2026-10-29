/// "지킴이 패스" 표시 + 요금제로 가는 입구 (2026-10-22, P2-1).
///
/// - [GuardianPassBadge]: 패스가 있을 때만 보이는 작은 표시. 알림 배너·대조 결과에 붙는다.
///   **표시만** 붙인다 — 패스가 없어도 알림·재대조는 그대로 돈다(시연에서 막히면 안 된다).
/// - [GuardianPassEntry]: 마이·계약 여정에서 요금제 화면(`/pricing`)으로 가는 카드.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design_system/components/app_pill.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../state/pass_store.dart';

/// 패스 표시 문구 — 알림·재대조·마이가 같은 말을 쓴다.
const String kGuardianPassBadgeLabel = '지킴이 패스';

/// 패스가 있으면 "지킴이 패스", 없으면 아무것도 그리지 않는다.
class GuardianPassBadge extends StatelessWidget {
  const GuardianPassBadge({super.key, this.store, this.padding = EdgeInsets.zero});

  /// 테스트가 넣는다. 없으면 앱 전체의 [PassStore.instance].
  final PassStore? store;

  /// 패스가 있을 때만 두르는 여백 — 없으면 자리도 차지하지 않는다.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final PassStore passes = store ?? PassStore.instance;
    return ListenableBuilder(
      listenable: passes,
      builder: (context, _) {
        if (!passes.active) return const SizedBox.shrink();
        return Padding(
          padding: padding,
          child: AppPill(
            label: kGuardianPassBadgeLabel,
            icon: Icons.verified_user_outlined,
            color: AppColors.primary,
            background: AppColors.primarySoft,
          ),
        );
      },
    );
  }
}

/// 요금제 화면으로 가는 띠(마이). 패스가 있으면 "패스 사용 중"으로 바뀐다.
///
/// 2026-10-30 마이 다시 그림: 회색 글줄 카드 → 진초록 띠 한 장(방패 · 이름 · '지금은 무료' 알약 · 꺾쇠).
/// 돈을 내야 안전한 것처럼 읽히지 않게 '지금은 무료'부터 말한다(지수 #7·서연 #7).
class GuardianPassEntry extends StatelessWidget {
  const GuardianPassEntry({super.key, this.store});

  final PassStore? store;

  @override
  Widget build(BuildContext context) {
    final PassStore passes = store ?? PassStore.instance;
    return ListenableBuilder(
      listenable: passes,
      builder: (context, _) {
        final bool active = passes.active;
        return Material(
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Ink(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: AppColors.isDark
                    ? const [Color(0xFF123F2C), Color(0xFF1B5A3F)]
                    : const [Color(0xFF0B3D2A), Color(0xFF14724B)],
              ),
            ),
            child: InkWell(
              key: const ValueKey('guardian-pass-entry'),
              onTap: () => context.push('/pricing'),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 14, 18),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.14),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        active ? Icons.verified_user : Icons.shield_outlined,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AppText(
                            '계약 지킴이 패스',
                            style: AppTypographyNext.title.copyWith(
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: AppText(
                              active ? '패스 사용 중 · 테스트 결제' : '지금은 무료',
                              style: AppTypographyNext.caption.copyWith(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: const Color(0xFFBFEBD3),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: Colors.white),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// "예시 가격" 꼬리표 — 가격 바로 밑에 붙는다. '예시'는 화면마다 **한 번씩만** 말한다(2026-10-23 디자인 #12):
/// 요금제 화면은 맨 위 안내가 이미 "예시예요"라고 해서 꼬리표는 짧게 `예시 가격`, 결제 화면은 서버 label 그대로.
/// 0원에는 꼬리표를 붙이지 않는다.
///
/// 알약([AppPill])은 줄바꿈이 안 돼 서버가 긴 label을 주면 넘친다 → 줄바꿈 되는 꼬리표로 그린다.
class ExamplePriceTag extends StatelessWidget {
  const ExamplePriceTag({super.key, this.label = '예시 가격'});

  /// 꼬리표 글자 — 기본 `예시 가격`, 결제 화면은 서버가 준 label("예시 가격(확정 전)")
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.cautionSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      // 연앰버 바탕 위 앰버 글자는 12px에서 대비가 모자라다(D8) — 글자는 진한 본문색
      child: AppText(
        label,
        style: AppTypography.label.copyWith(color: AppColors.textBody),
      ),
    );
  }
}
