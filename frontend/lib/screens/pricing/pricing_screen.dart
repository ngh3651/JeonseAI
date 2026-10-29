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
import '../../design_system/components/app_callout.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/pricing.dart';
import '../../repositories/payment_repository.dart';
import '../../services/api_client.dart';
import '../../state/pass_store.dart';
import 'guardian_pass_widgets.dart';

/// 요금제 화면 맨 위 첫 줄.
const String kPricingFreeNowLine = '지금은 돈을 내지 않아도 알림·다시 대조를 모두 쓸 수 있어요';

/// 맨 위 둘째 줄 — '예시'는 여기서 한 번, 가격 꼬리표에서 한 번.
const String kPricingExampleLine = '가격은 아직 정하지 않은 예시예요 · 결제는 테스트 결제(실제 청구 없음)';

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
        // '(결선 시연 기간)' 같은 내부 말은 뺐다 — 무료로 다 된다는 말은 맨 위 첫 줄이 한다
        const SizedBox(height: AppSpacing.xxxl),
      ],
    );
  }

  /// 맨 위 — **지금은 돈을 내지 않아도 다 쓴다**가 먼저, 그다음 가격은 예시·결제는 테스트 결제.
  ///
  /// 2026-10-23(지수 #7 · 서연 #7 · 디자인 #12): 예전 첫 줄 "가격은 예시예요 · 예시 (팀 확정 전)"은
  /// '돈을 내야 안전하다'처럼 읽혔고, '팀 확정 전'은 심사위원 눈에 미완성으로 보였다.
  Widget _notice(Pricing pricing) {
    // 새 안내 박스는 AppCallout(글자는 진한 색, 톤 색은 아이콘에만 — D8)
    return AppCallout(
      tone: CalloutTone.info,
      icon: Icons.info_outline,
      title: kPricingFreeNowLine,
      text: pricing.testMode
          ? kPricingExampleLine
          : '가격은 아직 정하지 않은 예시예요 · 결제 전에 가격을 꼭 확인하세요',
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
          // 돈을 받는 요금제에만 가격 바로 밑에 '예시 가격' — 확정 가격처럼 읽히지 않게(0원에는 붙이지 않는다)
          if ((plan.price ?? 0) > 0) ...[
            const SizedBox(height: AppSpacing.sm),
            const ExamplePriceTag(),
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
          // 알약(AppPill)은 줄바꿈이 안 돼 긴 문장이 넘친다 — 줄바꿈 되는 띠로
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.verified_user_outlined,
                  size: AppSize.iconSm,
                  color: AppColors.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: AppText(
                    '패스가 있어요 · $kTestPaymentNotice',
                    style: AppTypography.bodyStrong.copyWith(
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ],
            ),
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
