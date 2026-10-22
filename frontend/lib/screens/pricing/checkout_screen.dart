/// 계약 지킴이 패스 **테스트 결제** (`/checkout` — 2026-10-22, P2-1).
///
/// 흐름: 요금제(서버 가격) → 토스 결제위젯(결제 수단·약관) → [테스트 결제하기] → 결제창 →
/// 성공 값을 서버로(`POST /api/payments/confirm`) → 서버가 **요금제 가격으로 금액 검사** + 토스 승인 →
/// 패스 → 영수증.
///
/// ⚠ 화면·영수증 어디에나 "테스트 결제 — 실제 청구 없음". 클라이언트 키가 테스트 키가 아니면 결제를 열지 않는다.
/// ⚠ 승인 확인이 끊기면 [다시 확인하기] — 같은 주문번호로 다시 물어도 서버는 두 번 승인하지 않는다.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/config.dart';
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
import '../../services/journey_reminder_service.dart';
import '../../services/payment_gateway.dart';
import '../../services/toss_payment_gateway.dart';
import '../../state/journey_schedule_store.dart';
import '../../state/pass_store.dart';
import '../../utils/money_format.dart';

/// 토스 주문번호 — 영문·숫자·`-_` 6~64자. 추측할 수 없게 `Random.secure()`.
String newOrderId([Random? random]) {
  final rng = random ?? Random.secure();
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final tail = List.generate(20, (_) => chars[rng.nextInt(chars.length)]).join();
  return 'jsp_$tail';
}

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({
    super.key,
    this.planId = kGuardianPassPlanId,
    this.clientKey = tossClientKey,
    this.gatewayFactory = TossPaymentGateway.create,
    this.ownerKey = passOwnerKey,
  });

  final String planId;

  /// 토스 클라이언트 키 — `test_`로 시작해야 결제를 연다.
  final String clientKey;

  /// 결제위젯을 만드는 함수 (테스트는 가짜).
  final PaymentGatewayFactory gatewayFactory;

  /// 결제 주인 키(토스 customerKey) — 앱에서는 [passOwnerKey] 한 곳.
  final Future<String> Function() ownerKey;

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

enum _Phase { loading, ready, paying, confirming, done, failed }

class _CheckoutScreenState extends State<CheckoutScreen> {
  _Phase _phase = _Phase.loading;
  PricingPlan? _plan;
  String _priceLabel = kExamplePriceLabel;
  PaymentGateway? _gateway;
  GuardianPass? _receipt;

  /// 실패 문구 (결제창·승인 확인)
  String? _error;

  /// 결제창은 성공했는데 승인 확인이 끊겼을 때 다시 보낼 값
  PaymentOutcome? _pendingConfirm;

  bool get _testKey => isTossTestKey(widget.clientKey);

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final pricing = await context.read<PaymentRepository>().pricing();
      final plan = pricing.plan(widget.planId);
      if (plan == null || !plan.purchasable || plan.price == null) {
        throw StateError('결제할 수 없는 요금제');
      }
      final String customerKey = await widget.ownerKey();
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _priceLabel = pricing.label;
        if (_testKey) {
          _gateway = widget.gatewayFactory(
            clientKey: widget.clientKey,
            customerKey: customerKey,
          );
        }
        _phase = _Phase.ready;
      });
      // 결제 수단 자리가 화면에 붙은 **뒤에** 그린다(토스 SDK가 자리를 먼저 찾는다).
      if (_gateway != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _render(plan.price!));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = e is ApiException ? e.message : '결제 정보를 불러오지 못했어요';
      });
    }
  }

  Future<void> _render(int amount) async {
    try {
      await _gateway?.render(amount: amount);
    } catch (e) {
      debugPrint('[결제] 결제 수단을 그리지 못했어요 (${e.runtimeType})');
      if (!mounted) return;
      setState(() => _error = '결제 수단을 불러오지 못했어요. 인터넷 연결을 확인해 주세요');
    }
  }

  Future<void> _pay() async {
    final plan = _plan;
    final gateway = _gateway;
    if (plan == null || gateway == null) return;
    setState(() {
      _phase = _Phase.paying;
      _error = null;
    });
    PaymentOutcome outcome;
    try {
      outcome = await gateway.requestPayment(
        orderId: newOrderId(),
        orderName: plan.name,
      );
    } catch (e) {
      debugPrint('[결제] 결제창을 열지 못했어요 (${e.runtimeType})');
      outcome = const PaymentOutcome.failure(
        errorCode: 'APP_ERROR',
        errorMessage: '결제창을 열지 못했어요. 다시 시도해 주세요',
      );
    }
    if (!mounted) return;
    if (!outcome.ok) {
      setState(() {
        _phase = _Phase.ready;
        _error = outcome.canceled
            ? '결제를 취소했어요'
            : (outcome.errorMessage ?? '결제를 마치지 못했어요');
      });
      return;
    }
    await _confirm(outcome);
  }

  /// 결제창 성공 → 서버 승인. 실패하면 같은 값으로 [다시 확인하기].
  Future<void> _confirm(PaymentOutcome outcome) async {
    final plan = _plan!;
    setState(() {
      _phase = _Phase.confirming;
      _error = null;
      _pendingConfirm = outcome;
    });
    try {
      final pass = await context.read<PaymentRepository>().confirm(
        planId: plan.id,
        orderId: outcome.orderId!,
        paymentKey: outcome.paymentKey!,
        // 결제창이 돌려준 금액 그대로 — 서버가 요금제 가격과 맞는지 검사한다(앱 금액을 믿지 않는다)
        amount: outcome.amount!,
      );
      PassStore.instance.set(pass);
      // 알림에도 '지킴이 패스' 표시를 붙여 다시 건다(표시만 — 알림 자체는 패스와 상관없이 울린다)
      unawaited(
        JourneyReminderService.instance.resyncAll(JourneyScheduleStore.instance),
      );
      if (!mounted) return;
      setState(() {
        _receipt = pass;
        _pendingConfirm = null;
        _phase = _Phase.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.ready;
        _error = e is ApiException ? e.message : '결제를 확인하지 못했어요';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: AppText(_phase == _Phase.done ? '영수증' : '테스트 결제'),
      ),
      body: switch (_phase) {
        _Phase.loading => const Center(child: CircularProgressIndicator()),
        _Phase.failed => _failedBody(),
        _Phase.done => _receiptBody(_receipt!),
        _ => _checkoutBody(),
      },
    );
  }

  // ── 결제 전 ────────────────────────────────────────────────────────────────

  Widget _checkoutBody() {
    final plan = _plan!;
    final bool busy = _phase == _Phase.paying || _phase == _Phase.confirming;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        const TestPaymentNotice(),
        const SizedBox(height: AppSpacing.lg),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(plan.name, style: AppTypography.title),
              if (plan.period != null) ...[
                const SizedBox(height: 2),
                AppText(plan.period!, style: AppTypography.caption),
              ],
              const SizedBox(height: AppSpacing.sm),
              AppText(plan.priceText, style: AppTypography.headline),
              const SizedBox(height: AppSpacing.xs),
              AppPill(
                label: '예시 가격 · $_priceLabel',
                color: AppColors.caution,
                background: AppColors.cautionSoft,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (!_testKey)
          // 실제 키(live_)로 빌드된 앱 — 결선은 테스트 결제만 한다
          const AppText(
            '이 앱은 테스트 결제만 지원해요. 실제 결제 키로는 결제를 열지 않아요',
            style: AppTypography.bodyStrong,
          )
        else ...[
          _gateway!.buildForm(),
          const SizedBox(height: AppSpacing.lg),
        ],
        if (_error != null) ...[
          AppText(
            _error!,
            style: AppTypography.bodyStrong.copyWith(color: AppColors.danger),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (_pendingConfirm != null && _phase == _Phase.ready) ...[
          // 결제창은 끝났는데 승인 확인이 끊겼다 — 같은 주문으로 다시 묻는다(두 번 승인되지 않는다)
          AppPrimaryButton(
            label: '다시 확인하기',
            icon: Icons.refresh,
            onPressed: () => _confirm(_pendingConfirm!),
          ),
          const SizedBox(height: AppSpacing.xs),
          const AppText(
            '결제창에서 결제를 마쳤다면 다시 확인하기를 눌러 주세요. 같은 결제가 두 번 승인되지 않아요',
            style: AppTypography.caption,
          ),
        ] else if (_testKey)
          AppPrimaryButton(
            label: _phase == _Phase.confirming ? '결제 확인 중…' : '테스트 결제하기',
            icon: Icons.lock_open,
            loading: busy,
            onPressed: busy ? null : _pay,
          ),
        const SizedBox(height: AppSpacing.xxxl),
      ],
    );
  }

  Widget _failedBody() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const TestPaymentNotice(),
            const SizedBox(height: AppSpacing.lg),
            AppText(
              _error ?? '결제 정보를 불러오지 못했어요',
              style: AppTypography.body,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            AppCompactButton(
              label: '다시 시도',
              icon: Icons.refresh,
              onPressed: () {
                setState(() {
                  _phase = _Phase.loading;
                  _error = null;
                });
                unawaited(_prepare());
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── 영수증 ────────────────────────────────────────────────────────────────

  Widget _receiptBody(GuardianPass pass) {
    final DateTime? approved = pass.approvedAt;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        const TestPaymentNotice(),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            const Icon(
              Icons.verified_user,
              size: AppSize.iconLg,
              color: AppColors.primary,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: AppText(
                '${pass.planName}가 열렸어요',
                style: AppTypography.headline.copyWith(color: AppColors.primary),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        AppCard(
          child: Column(
            children: [
              _receiptRow('요금제', pass.planName),
              _receiptRow('금액', '${formatPriceWon(pass.amount)} (예시 가격)'),
              if (pass.method != null) _receiptRow('결제 수단', pass.method!),
              if (approved != null)
                _receiptRow(
                  '승인 시각',
                  '${formatDate(approved)} '
                      '${approved.hour.toString().padLeft(2, '0')}:'
                      '${approved.minute.toString().padLeft(2, '0')}',
                ),
              _receiptRow('주문번호', pass.orderId),
              _receiptRow('청구', '없음 (테스트 결제)'),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        AppText(
          '잔금 하루 전·당일·입주 다음 날 알림과 다시 대조 화면에 "지킴이 패스" 표시가 붙어요.',
          style: AppTypography.caption,
        ),
        const SizedBox(height: AppSpacing.xl),
        AppPrimaryButton(
          label: '계약 여정으로 가기',
          icon: Icons.timeline,
          onPressed: () => context.go('/journey'),
        ),
        const SizedBox(height: AppSpacing.xxxl),
      ],
    );
  }

  Widget _receiptRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: AppText(label, style: AppTypography.caption),
          ),
          Expanded(child: AppText(value, style: AppTypography.bodyStrong)),
        ],
      ),
    );
  }
}

/// "테스트 결제 — 실제 청구 없음" 띠 — 결제 화면·영수증 맨 위에 늘 붙는다.
class TestPaymentNotice extends StatelessWidget {
  const TestPaymentNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.cautionSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.caution),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.science_outlined,
            size: AppSize.iconSm,
            color: AppColors.caution,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  kTestPaymentNotice,
                  style: AppTypography.bodyStrong.copyWith(
                    color: AppColors.caution,
                  ),
                ),
                const AppText(
                  '토스페이먼츠 테스트 환경이에요. 카드 정보를 넣어도 돈이 나가지 않아요',
                  style: AppTypography.caption,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
