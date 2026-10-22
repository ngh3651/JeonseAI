/// 요금제 화면 (`/pricing` — 2026-10-22, P2-1).
///
/// 무료(분석) · **계약 지킴이 패스**(알림·재대조) · 기관용(문의). 가격은 서버(`GET /api/pricing`)가 준다.
///
/// ⚠ 가격은 팀 확정 전 **예시**다 — 맨 위 안내 + 가격마다 "예시" 표시. 결제는 **테스트 결제**다.
/// ⚠ 패스가 없어도 기능은 막지 않는다 — 이 화면은 "무엇을 파는가"를 보여 줄 뿐이다.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/components/app_pill.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/pricing.dart';
import '../../repositories/payment_repository.dart';
import '../../services/api_client.dart';
import '../../state/pass_store.dart';

class PricingScreen extends StatefulWidget {
  const PricingScreen({super.key});

  @override
  State<PricingScreen> createState() => _PricingScreenState();
}

class _PricingScreenState extends State<PricingScreen> {
  late Future<Pricing> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = context.read<PaymentRepository>().pricing();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const AppText('요금제')),
      body: FutureBuilder<Pricing>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || snapshot.data == null) {
            return _error(snapshot.error);
          }
          return _plans(snapshot.data!);
        },
      ),
    );
  }

  Widget _error(Object? error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppText(
              '요금제를 불러오지 못했어요\n'
              '${apiErrorHint(error, fallback: '서버 연결을 확인해 주세요')}',
              style: AppTypography.body,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            AppCompactButton(
              label: '다시 시도',
              icon: Icons.refresh,
              onPressed: () => setState(_load),
            ),
          ],
        ),
      ),
    );
  }

  Widget _plans(Pricing pricing) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        _notice(pricing),
        const SizedBox(height: AppSpacing.lg),
        for (final plan in pricing.plans) ...[
          _planCard(pricing, plan),
          const SizedBox(height: AppSpacing.md),
        ],
        const SizedBox(height: AppSpacing.md),
        AppText(
          '패스가 없어도 알림과 다시 대조는 그대로 쓸 수 있어요(결선 시연 기간).',
          style: AppTypography.caption,
        ),
        const SizedBox(height: AppSpacing.xxxl),
      ],
    );
  }

  /// 맨 위 — 가격은 예시, 결제는 테스트 결제.
  Widget _notice(Pricing pricing) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.cautionSoft,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline,
            size: AppSize.iconSm,
            color: AppColors.caution,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  '가격은 예시예요 · ${pricing.label}',
                  style: AppTypography.bodyStrong.copyWith(
                    color: AppColors.caution,
                  ),
                ),
                const SizedBox(height: 2),
                AppText(
                  pricing.testMode
                      ? '결제는 ${pricing.testNotice}'
                      : '결제 전에 가격을 꼭 확인하세요',
                  style: AppTypography.caption,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _planCard(Pricing pricing, PricingPlan plan) {
    final bool isPass = plan.id == kGuardianPassPlanId;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      plan.name,
                      style: AppTypography.title.copyWith(
                        color: isPass ? AppColors.primary : null,
                      ),
                    ),
                    if (plan.tagline.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      AppText(plan.tagline, style: AppTypography.caption),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  AppText(plan.priceText, style: AppTypography.title),
                  if (plan.period != null)
                    AppText(plan.period!, style: AppTypography.caption),
                ],
              ),
            ],
          ),
          // 가격이 있는 요금제(0원 포함)에는 가격 바로 밑에 '예시' — 확정 가격처럼 읽히지 않게
          if (plan.price != null) ...[
            const SizedBox(height: AppSpacing.sm),
            AppPill(
              label: '예시 가격 · ${pricing.label}',
              color: AppColors.caution,
              background: AppColors.cautionSoft,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          for (final feature in plan.features) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Icon(
                    Icons.check,
                    size: AppSize.iconXs,
                    color: isPass ? AppColors.primary : AppColors.textMuted,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: AppText(feature, style: AppTypography.body)),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
          if (plan.purchasable && plan.price != null) ...[
            const SizedBox(height: AppSpacing.md),
            _buyButton(plan),
          ],
        ],
      ),
    );
  }

  Widget _buyButton(PricingPlan plan) {
    return ListenableBuilder(
      listenable: PassStore.instance,
      builder: (context, _) {
        if (PassStore.instance.active) {
          return const AppPill(
            label: '패스가 있어요 · $kTestPaymentNotice',
            icon: Icons.verified_user_outlined,
            color: AppColors.primary,
            background: AppColors.primarySoft,
          );
        }
        return AppPrimaryButton(
          label: '테스트 결제로 패스 열기',
          icon: Icons.lock_open,
          onPressed: () => context.push('/checkout?plan=${plan.id}'),
        );
      },
    );
  }
}
