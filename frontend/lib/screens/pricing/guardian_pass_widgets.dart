/// "지킴이 패스" 표시 + 요금제로 가는 입구 (2026-10-22, P2-1).
///
/// - [GuardianPassBadge]: 패스가 있을 때만 보이는 작은 표시. 알림 배너·대조 결과에 붙는다.
///   **표시만** 붙인다 — 패스가 없어도 알림·재대조는 그대로 돈다(시연에서 막히면 안 된다).
/// - [GuardianPassEntry]: 마이·계약 여정에서 요금제 화면(`/pricing`)으로 가는 카드.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design_system/components/app_card.dart';
import '../../design_system/components/app_pill.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/pricing.dart';
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
          child: const AppPill(
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

/// 요금제 화면으로 가는 카드. 패스가 있으면 "패스가 있어요"로 바뀐다.
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
        return AppCard(
          onTap: () => context.push('/pricing'),
          child: Row(
            children: [
              Icon(
                active ? Icons.verified_user : Icons.shield_outlined,
                size: AppSize.iconLg,
                color: AppColors.primary,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const AppText('계약 지킴이 패스', style: AppTypography.bodyStrong),
                    const SizedBox(height: 2),
                    AppText(
                      active
                          ? '패스가 있어요 · $kTestPaymentNotice'
                          // 돈을 내야 안전한 것처럼 읽히지 않게 — 지금은 무료로 다 된다는 사실부터(지수 #7·서연 #7)
                          : '지금은 무료로 모두 쓸 수 있어요 · 요금제 보기(예시 가격)',
                      style: AppTypography.caption,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textMuted),
            ],
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
