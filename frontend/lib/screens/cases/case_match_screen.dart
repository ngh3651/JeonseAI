/// S-08 판례 매칭 — IA.md §6. (사용자 노출 명칭: "판례" 유지 — 실제 법원 판결이라는
/// 신뢰 무게가 플래그십 차별화의 핵심. 화면 첫 등장에 '법원의 실제 판결' 툴팁만 붙임.)
///
/// 현재 매물의 위험 패턴 칩(쉬운 말) → 패턴별 큐레이션 판례 카드.
/// 판례가 있든 없든 하단에 "질문 챙기기" 다음 행동을 상시 둔다 (공포 뒤 행동 짝짓기).
/// 판례는 전부 예시(E-3에서 큐레이션·출처 확정).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_callout.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/components/app_pill.dart';
import '../../design_system/components/term_tooltip_sheet.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../models/content_models.dart';
import '../../repositories/analysis_repository.dart';
import '../../repositories/content_repository.dart';
import '../../design_system/text/app_text.dart';

/// 위험 태그(백엔드 `RISK_TAGS` 어휘) → 화면 라벨.
///
/// **상단 칩과 판례 카드 소제목이 같은 표를 쓴다.** 둘이 다른 말로 나오면
/// "이 판례가 위 칩 중 무엇에 대한 것인지"를 사용자가 머릿속에서 번역해야 한다 —
/// 카드에 소제목을 붙이는 이유 자체가 그 번역을 없애는 것이다.
///
/// 표에 없는 태그(압류·가압류, 경매, 임차권등기, 대항력)는 **법률 용어 그대로** 둔다.
/// 검수받지 않은 쉬운 말을 여기서 지어내면, 화면 문구를 사람이 확정한다는 원칙이
/// 이 화면에서만 깨진다. 쉬운 말이 필요하면 용어 사전(terms.json)에 먼저 넣는다.
const Map<String, String> kRiskTagLabel = {
  '선순위 채권': '먼저 갚을 빚',
  '신탁등기': '소유권을 맡긴 집',
  '전세가율': '보증금 비율',
  '보증보험': '보증보험',
};

String riskTagLabel(String tag) => kRiskTagLabel[tag] ?? tag;

/// 카드 한 장에 붙일 소제목 최대 개수. 겹친 태그가 많아도 뱃지 줄이 길어지면
/// "한눈에"라는 목적 자체가 사라진다.
const int kMaxCardTags = 3;

class CaseMatchScreen extends StatefulWidget {
  const CaseMatchScreen({super.key, required this.reportId});

  final String reportId;

  @override
  State<CaseMatchScreen> createState() => _CaseMatchScreenState();
}

class _CaseMatchScreenState extends State<CaseMatchScreen> {
  String get reportId => widget.reportId;

  late Future<(AnalysisReport?, List<CaseMatch>)> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final analysisRepo = context.read<AnalysisRepository>();
    final contentRepo = context.read<ContentRepository>();
    _future = () async {
      // 칩(위험 패턴)은 리포트에서, 판례 목록은 서버 파생 결과에서 (계약 §2.2·§3.5)
      final report = await analysisRepo.getReport(reportId);
      if (report == null) return (null, const <CaseMatch>[]);
      final cases = await contentRepo.matchedCases(reportId);
      return (report, cases);
    }();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const AppText('판례 매칭')),
      body: FutureBuilder<(AnalysisReport?, List<CaseMatch>)>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _error(context, retryable: true);
          }
          final (report, cases) = snapshot.data!;
          if (report == null) {
            return _error(context);
          }
          final patterns = report.riskLabels;

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            children: [
              // '판례' 첫 등장에 툴팁으로 신뢰 무게를 짧게 설명 (용어는 유지)
              AppText.rich(
                TextSpan(
                  style: AppTypography.body,
                  children: [
                    const TextSpan(text: '이 매물의 위험과 비슷한 상황에서 나온 '),
                    termSpan(
                      context,
                      term: '판례',
                      description:
                          '법원의 실제 판결이에요. 실제로 이런 일이 일어나 '
                          '법정까지 갔다는 뜻이라, 위험을 훨씬 더 무겁게 봐야 해요.',
                    ),
                    const TextSpan(text: '를 모았어요.'),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              AppText('이 매물에서 눈에 띈 위험', style: AppTypography.title),
              const SizedBox(height: AppSpacing.sm),
              if (patterns.isEmpty)
                AppText('눈에 띄는 위험 패턴이 없어요', style: AppTypography.caption)
              else
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final p in patterns)
                      AppPill(
                        label: riskTagLabel(p),
                        color: AppColors.danger,
                        background: AppColors.dangerSoft,
                      ),
                  ],
                ),
              const SizedBox(height: AppSpacing.xl),
              if (cases.isEmpty)
                AppCallout(
                  tone: CalloutTone.neutral,
                  text:
                      '이 매물의 위험과 딱 맞는 판례가 아직 없어요. '
                      '위험이 없다는 뜻은 아니니, 중개사에게 확인할 질문을 챙겨 가세요.',
                )
              else
                for (final c in cases) ...[
                  _caseCard(c),
                  const SizedBox(height: AppSpacing.md),
                ],
              const SizedBox(height: AppSpacing.lg),
              // 사례 유무와 상관없이 "그래서 뭘 하라"를 상시로 (지수 리뷰: 공포 뒤 행동)
              AppCallout(
                tone: CalloutTone.info,
                icon: Icons.shield_outlined,
                title: '이런 피해를 피하려면',
                text: '중개사무소에 가기 전에, 꼭 물어봐야 할 질문을 챙겨 가세요.',
                action: AppPrimaryButton(
                  label: '중개사에게 물어볼 질문 보기',
                  icon: Icons.quiz_outlined,
                  onPressed: () => context.push('/questions/$reportId'),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppText('판례 데이터는 계속 추가되고 있어요', style: AppTypography.caption),
              const SizedBox(height: AppSpacing.xxxl),
            ],
          );
        },
      ),
    );
  }

  Widget _caseCard(CaseMatch c) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _tagHeader(c),
          const SizedBox(height: AppSpacing.sm),
          AppText(c.caseNo, style: AppTypography.caption),
          const SizedBox(height: AppSpacing.sm),
          AppText(c.summary, style: AppTypography.bodyStrong),
          const SizedBox(height: AppSpacing.md),
          _row('결과', c.result, AppColors.danger),
          const SizedBox(height: AppSpacing.sm),
          _row('우리 매물과 공통점', c.commonPoint, AppColors.textBody),
          if (c.advice != null && c.advice!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            _row('이런 피해를 피하려면', c.advice!, AppColors.primary),
          ],
          const SizedBox(height: AppSpacing.md),
          _sourceLine(c),
        ],
      ),
    );
  }

  /// 카드 맨 위 소제목 — "이 판례는 무엇에 대한 경고인가".
  ///
  /// 카드 본문이 요약·결과·공통점·조언 네 문단이라, 소제목 없이는 어느 카드가
  /// 어느 위험에 대한 것인지 다 읽어야 알 수 있었다(2026-08-12 실기기 확인).
  /// 상단 "이 매물에서 눈에 띈 위험" 칩과 **같은 라벨·같은 색**을 써서 눈으로
  /// 바로 이어지게 한다.
  Widget _tagHeader(CaseMatch c) {
    final tags = c.displayTags.take(kMaxCardTags).toList();
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: [
        for (final t in tags)
          AppPill(
            label: riskTagLabel(t),
            color: AppColors.danger,
            background: AppColors.dangerSoft,
          ),
      ],
    );
  }

  /// 출처 + 검수 상태 한 줄.
  ///
  /// 사건번호·법원은 어느 카드든 공식 DB(법제처)에서 확인된 값이지만, 쉬운 말 요약까지
  /// 사람이 읽은 판례는 아직 일부다. 그 차이를 화면에서 밝힌다 — 검수된 것과 안 된 것을
  /// 같은 얼굴로 내보내면, 나중에 한 건이라도 어긋났을 때 전부를 잃는다.
  Widget _sourceLine(CaseMatch c) {
    final label = c.curated ? '사람 검수 완료' : '문구 검수 전 · 출처는 확인됨';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          c.curated ? Icons.verified_outlined : Icons.info_outline,
          size: 14,
          color: AppColors.textMuted,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: AppText(
            c.sourceUrl == null ? label : '$label · 판결문 원문 있음',
            style: AppTypography.caption,
          ),
        ),
      ],
    );
  }

  Widget _row(String label, String value, Color valueColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(label, style: AppTypography.caption),
        const SizedBox(height: 2),
        AppText(value, style: AppTypography.body.copyWith(color: valueColor)),
      ],
    );
  }

  Widget _error(BuildContext context, {bool retryable = false}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppText(
            retryable ? '데이터를 불러오지 못했어요\n서버 연결을 확인해 주세요' : '리포트를 불러올 수 없어요',
            style: AppTypography.body,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.lg),
          if (retryable)
            AppCompactButton(
              label: '다시 시도',
              icon: Icons.refresh,
              onPressed: () => setState(_load),
            )
          else
            AppCompactButton(
              label: '홈으로',
              onPressed: () => context.go('/home'),
            ),
        ],
      ),
    );
  }
}
