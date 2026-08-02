/// S-09 손실 시뮬레이터 (IA.md §6) — 시연의 "기억에 남을 컷".
///
/// 슬라이더("집이 경매로 넘어가 이 가격에 팔린다면?")를 움직이면
/// 예상 손실액이 실시간으로 바뀌고, [보증보험 가입 시] 토글로 0원 대비를 보여준다.
///
/// ⚠ 아래 계산은 전부 **예시(자리표시)**다. 낙찰가율 기본값·계산식은
/// Phase E-4에서 출처(법원경매정보 통계 등) 확보 후 확정한다 (docs/plan.md E-4).
/// 2026-07-04 C-2 리뷰 반영: 기준가 고지, 보증보험 미확인 경고(보수적 편향),
/// 하단 다음 행동 CTA, 예시 배너 대비 강화.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/term_tooltip_sheet.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../models/risk_grade.dart';
import '../../repositories/analysis_repository.dart';
import '../../utils/money_format.dart';

class LossSimulatorScreen extends StatefulWidget {
  const LossSimulatorScreen({super.key, required this.reportId});

  final String reportId;

  @override
  State<LossSimulatorScreen> createState() => _LossSimulatorScreenState();
}

class _LossSimulatorScreenState extends State<LossSimulatorScreen> {
  /// 낙찰가율 슬라이더 값 (0.4~1.0). 초기값 0.7은 UI 배치용 —
  /// 실제 기본값은 E-4에서 통계 출처와 함께 확정.
  double _ratio = 0.7;

  /// 보증보험 가입 가정 토글
  bool _insured = false;

  late final Future<AnalysisReport?> _reportFuture;

  @override
  void initState() {
    super.initState();
    _reportFuture = context.read<AnalysisRepository>().getReport(
      widget.reportId,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('손실 시뮬레이터')),
      body: FutureBuilder<AnalysisReport?>(
        future: _reportFuture,
        builder: (context, snapshot) {
          final AnalysisReport? report = snapshot.data;
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (report == null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('리포트를 불러올 수 없어요', style: AppTypography.body),
                  const SizedBox(height: AppSpacing.lg),
                  AppCompactButton(
                    label: '홈으로',
                    onPressed: () => context.go('/home'),
                  ),
                ],
              ),
            );
          }
          return _body(report);
        },
      ),
    );
  }

  Widget _body(AnalysisReport report) {
    // ── 예시 계산 (E-4에서 출처 기반 계산식으로 교체) ──────────────
    // 기준가: 입력 시세, 없으면 보증금을 예시 기준가로 사용 (화면에 고지)
    final bool noMarketPrice = report.marketPrice == null;
    final int base = report.marketPrice ?? report.deposit;
    final int salePrice = (base * _ratio).round(); // 예상 낙찰가
    final int leftover = math.max(0, salePrice - report.seniorDebtAmount);
    final int recovered = math.min(report.deposit, leftover); // 돌려받는 금액
    final int loss = _insured ? 0 : report.deposit - recovered; // 예상 손실

    // 보증보험 카드가 '양호'가 아니면 가입 가능 여부 미확인 (보수적 편향 연동)
    final bool insuranceUnverified = report.evidences.any(
      (e) => e.id == 'insurance' && e.grade != RiskGrade.ok,
    );

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        _exampleBanner(),
        const SizedBox(height: AppSpacing.xl),
        Text(
          '${report.alias} · 보증금 ${formatWon(report.deposit)}',
          style: AppTypography.caption,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.xxl),

        // ── 슬라이더: 쉬운 말 라벨 + '낙찰가율' 툴팁 부제 ──
        const Text(
          '집이 경매로 넘어가 이 가격에 팔린다면?',
          style: AppTypography.title,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TermText(
              term: '낙찰가율',
              description:
                  '경매에서 집이 팔리는 가격이 원래 가치의 몇 %인지를 뜻해요. '
                  '예를 들어 낙찰가율 70%면, 2억짜리 집이 경매에서 1억 4천만원에 팔린다는 뜻이에요.',
              style: AppTypography.caption,
              onAskChatbot: () => context.push('/chatbot'),
            ),
            const SizedBox(width: AppSpacing.xs),
            Text('기준 (예시)', style: AppTypography.caption),
          ],
        ),
        Text(
          '${(_ratio * 100).round()}%',
          style: AppTypography.numberLarge.copyWith(color: AppColors.primary),
          textAlign: TextAlign.center,
        ),
        Slider(
          value: _ratio,
          min: 0.4,
          max: 1.0,
          divisions: 12,
          label: '${(_ratio * 100).round()}%',
          onChanged: (v) => setState(() => _ratio = v),
        ),
        const SizedBox(height: AppSpacing.xl),

        // ── 결론 크게: 예상 손실액 + 예상 반환금 병기 (C2) ──
        _lossCard(loss, recovered),
        const SizedBox(height: AppSpacing.lg),

        // ── 시세 미입력 고지 (기준가 무고지 방지 — 리뷰 공통 반영) ──
        if (noMarketPrice) _noMarketPriceNotice(),

        // ── 계산 내역 (기준가 명시) ──
        _detailRow(
          // 2026-08-03: 시세는 사용자 입력일 수도, 자동 조회일 수도 있다 —
          // "입력 시세"·"미입력"이라고 못 박으면 자동 조회가 붙은 뒤 거짓이 된다.
          noMarketPrice ? '기준가 (시세를 못 구해 보증금 기준)' : '기준가 (시세)',
          formatWon(base),
        ),
        _detailRow('예상 낙찰가 (${(_ratio * 100).round()}%)', formatWon(salePrice)),
        _detailRow(
          '먼저 갚아야 할 빚 (선순위 채권)',
          '- ${formatWon(report.seniorDebtAmount)}',
        ),
        _detailRow('예상 반환금', formatWon(recovered)), // C2: 문구 간결화
        const Divider(height: AppSpacing.xxxl),

        // ── 보증보험 대비 토글 ──
        SwitchListTile(
          value: _insured,
          onChanged: (v) => setState(() => _insured = v),
          // C3: 시뮬레이션임이 드러나는 제목 (feedback4 목업)
          title: const Text('보증보험 적용 시 시뮬레이션', style: AppTypography.bodyStrong),
          subtitle: Text(
            '가입 가능 여부를 확인하면 보험 적용 결과를 볼 수 있어요',
            style: AppTypography.caption,
          ),
          contentPadding: EdgeInsets.zero,
        ),
        if (_insured)
          insuranceUnverified
              // 가입 가능 미확인 매물: 0원을 안심 신호로 오독하지 않게 경고 우선 (보수적 편향)
              ? Container(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  decoration: BoxDecoration(
                    color: AppColors.cautionSoft,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '잠깐 — 이 매물은 보증보험 가입 가능 여부가 아직 확인되지 않았어요. '
                        '가입이 안 될 수도 있으니, 가입 요건부터 먼저 확인하세요.',
                        style: AppTypography.body.copyWith(
                          color: AppColors.caution,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      // C3: 무엇을 확인하는 버튼인지 명확화 (feedback4 목업)
                      AppSecondaryButton(
                        label: '보증보험 가입 가능 여부 확인하기',
                        icon: Icons.verified_user_outlined,
                        onPressed: () => context.pop(),
                      ),
                    ],
                  ),
                )
              : Container(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  decoration: BoxDecoration(
                    color: AppColors.okSoft,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Text(
                    '보증보험에 가입되어 있으면 보증기관이 보증금을 대신 돌려줘요. '
                    '예상 손실 0원 (예시)',
                    style: AppTypography.body.copyWith(color: AppColors.ok),
                  ),
                ),
        const SizedBox(height: AppSpacing.xxl),

        // ── 다음 행동 CTA — 불안만 남기고 끝나지 않게 (지수 리뷰 반영) ──
        AppPrimaryButton(
          label: '리포트로 돌아가 지금 해야 할 일 보기',
          onPressed: () => context.pop(),
        ),
        const SizedBox(height: AppSpacing.xxxl),
      ],
    );
  }

  /// "예시" 상시 배너 — 출처 확보 전 수치임을 명시 (출처 없는 수치 금지 원칙)
  Widget _exampleBanner() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface, // 배경과 구분되게 카드화 (design-reviewer 반영)
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline,
            size: AppSize.iconSm,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '아래 수치는 예시예요. 실제 계산 기준(낙찰가율 통계·계산식)은 '
              '공식 출처 확보 후 반영돼요.',
              style: AppTypography.caption,
            ),
          ),
        ],
      ),
    );
  }

  Widget _noMarketPriceNotice() {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.lg),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.cautionSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '시세가 입력되지 않아 보증금을 기준으로 계산한 예시예요. '
            '시세를 입력하면 더 정확해져요.',
            style: AppTypography.body.copyWith(color: AppColors.caution),
          ),
          const SizedBox(height: AppSpacing.md),
          // F3/F8: 라인 대신 톤(연초록 filled) 버튼 — 대표 적용례
          AppTonalButton(
            label: '시세 입력하기',
            onPressed: () {
              // 시세 입력은 매물 검색(S-04)과 함께 C-3에서 연결
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(const SnackBar(content: Text('곧 제공되는 기능이에요')));
            },
          ),
        ],
      ),
    );
  }

  Widget _lossCard(int loss, int recovered) {
    final bool safe = loss == 0;
    final Color color = safe ? AppColors.ok : AppColors.danger;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.xxl),
      decoration: BoxDecoration(
        color: safe ? AppColors.okSoft : AppColors.dangerSoft,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        children: [
          Text(
            '예상 손실액 (예시)',
            style: AppTypography.label.copyWith(color: color),
          ),
          const SizedBox(height: AppSpacing.sm),
          // G7: 결정적 결과 수치 볼드 강조
          Text(
            formatWon(loss),
            style: AppTypography.conclusion.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
          // C2: 손실액 옆에 예상 반환금도 함께 강조 — 하단 계산식만 보지 않게
          const SizedBox(height: AppSpacing.md),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('예상 반환금', style: AppTypography.caption),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  formatWon(recovered),
                  style: AppTypography.bodyStrong.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(label, style: AppTypography.body)),
          Text(value, style: AppTypography.bodyStrong),
        ],
      ),
    );
  }
}
