/// S-07 AI 안전도 리포트 — 핵심 화면 (IA.md §6).
///
/// 구조: 결론 헤더(게이지 크게 + 의사결정 한 줄 + 보증금) → 지금 해야 할 일(+질문 버튼)
/// → 근거 카드(최고 심각도 1개 기본 펼침, 용어 툴팁) → 다음 행동(등급별 추천 강조).
/// 판례·질문 생성기·체크리스트·공유는 C-3에서 실화면 연결 (스텁 문구는 사용자 언어로).
/// 2026-07-04 C-2 리뷰 3종(design-reviewer·persona 2인) 반영.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

// [D4 · 2026-08-14] 시세 출처 칩을 렌더링에서 뺐다 → 이 두 import가 함께 놀게 됐다.
// 칩을 되살릴 때 같이 풀라고 지우지 않고 주석으로 남긴다 (_conclusionHeader 참고).
// import '../../design_system/components/amber_hint.dart';
// import '../../models/market_price_source.dart' show marketPriceSourceLabel;
import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_callout.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/components/mascot_safe.dart';
import '../../design_system/components/risk_badge.dart';
import '../../design_system/components/safety_gauge.dart';
import '../../design_system/components/term_tooltip_sheet.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../models/registry_mark_kind.dart';
import '../../models/risk_grade.dart';
import '../../repositories/analysis_repository.dart';
import '../../state/registry_photo_store.dart';
import '../../utils/money_format.dart';
import 'registry_entry_card.dart';
import '../../design_system/text/app_text.dart';

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key, required this.reportId});

  final String reportId;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  /// 리포트는 **한 번만** 불러온다.
  ///
  /// 예전에는 StatelessWidget의 build() 안에서 `getReport()`를 불렀다. 그때는 재빌드가
  /// 드물어 증상이 없었지만, 진입 카드에 사진 미리보기가 들어오면서 이미지 로딩·레이아웃
  /// 변화로 재빌드가 늘어난다. build마다 새 Future가 생기면 FutureBuilder가 로딩 분기로
  /// 되돌아가 화면이 깜빡이고 매번 서버 요청이 나간다(뷰어에서 실제로 겪은 문제다).
  late final Future<AnalysisReport?> _reportFuture;

  String get reportId => widget.reportId;

  @override
  void initState() {
    super.initState();
    _reportFuture = context.read<AnalysisRepository>().getReport(reportId);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AnalysisReport?>(
      future: _reportFuture,
      builder: (context, snapshot) {
        final AnalysisReport? report = snapshot.data;

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (report == null) {
          // 이력 손상/없음 (user-scenario.md §5) — 막다른 길 방지 CTA 포함
          return Scaffold(
            appBar: AppBar(title: const AppText('안전도 리포트')),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppText('이 리포트를 불러올 수 없어요', style: AppTypography.body),
                  const SizedBox(height: AppSpacing.lg),
                  AppCompactButton(
                    label: '홈으로',
                    onPressed: () => context.go('/home'),
                  ),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: AppText(report.alias),
            actions: [
              IconButton(
                icon: const Icon(Icons.ios_share),
                tooltip: '리포트 공유',
                onPressed: () => _stub(context),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            children: [
              if (_isStale(report)) _staleBanner(context, report),
              _conclusionHeader(report),
              const SizedBox(height: AppSpacing.xl),
              _nextActionCard(context, report),
              const SizedBox(height: AppSpacing.xl),
              _originPhotoEntry(context, report),
              const AppText('근거 살펴보기', style: AppTypography.title),
              const SizedBox(height: AppSpacing.xs),
              AppText('카드를 탭하면 쉬운 설명과 출처가 열려요', style: AppTypography.caption),
              const SizedBox(height: AppSpacing.md),
              ..._evidenceCards(context, report),
              // 판정이 아닌 **정보**라서 근거 카드 대열 밖, 바로 아래에 붙인다.
              ?_priceGapCard(report),
              const SizedBox(height: AppSpacing.xl),
              const AppText('다음 행동', style: AppTypography.title),
              const SizedBox(height: AppSpacing.md),
              ..._actionArea(context, report),
              const SizedBox(height: AppSpacing.xxl),
              _disclaimer(),
              const SizedBox(height: AppSpacing.xxxl),
            ],
          ),
        );
      },
    );
  }

  /// '내가 올린 사진에서 보기' 진입점.
  ///
  /// 사진이 없으면(보관을 끈 빌드·파일 소실·이력에서 다시 연 리포트) **카드를 조용히
  /// 없애지 않는다.** "어제는 있었는데 사라졌다 = 앱이 고장 났다"로 읽히기 때문이다
  /// (2026-07-27 서연 리뷰). 카드는 남기고 왜 못 여는지 한 줄로 바꾼다.
  ///
  /// 미리보기 스트립도 같은 원칙이다 — 표시가 없거나 사진을 못 읽으면 스트립만
  /// 사라지고 하단 행은 그대로 남는다.
  Widget _originPhotoEntry(BuildContext context, AnalysisReport report) {
    final paths = RegistryPhotoStore.instance.pathsFor(report.id);
    final hasPhotos = paths.isNotEmpty;

    // 그릴 수 있는 표시만 — 사진 장수를 넘는 page 인덱스는 버린다(뷰어와 같은 규칙).
    final marks = [
      for (final h in report.highlights)
        if (h.page >= 0 && h.page < paths.length) h,
    ];
    final preview = previewMarkOf(marks);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxxl),
      child: RegistryEntryCard(
        subtitle: hasPhotos
            ? _registryViewedLine(report)
            : '등기부 사진은 안전을 위해 저장하지 않아요. 다시 보려면 새로 분석해 주세요.',
        onTap: hasPhotos ? () => context.push('/registry/${report.id}') : null,
        preview: preview == null
            ? null
            : RegistryPreviewSource(
                path: paths[preview.page],
                mark: preview,
                // 뱃지는 **따져볼 곳만** 센다. 집주인 이름·주소는 위험이 아니라
                // 대조할 곳이라, 전체 개수를 적으면 사실과 다른 말이 된다.
                examineCount: MarkLegend.examineCount(marks.map((m) => m.markKind)),
                totalCount: marks.length,
              ),
      ),
    );
  }

  /// 진입 카드 부제 — **등기부를 언제 뗐는지**. 못 읽었으면 null(줄 자체가 사라진다).
  ///
  /// 왜 개수가 아니라 날짜인가: 등기부는 열람 시점의 스냅샷이다. 그 뒤에 근저당이
  /// 새로 잡혔을 수 있고, **계약 직전 근저당 설정은 실제 전세사기 수법**이다. 이 샘플은
  /// 열람 7/9 · 분석 7/27로 18일 차이가 나는데 화면 어디에도 그 사실이 없었다.
  /// ⚠ [AnalysisReport.analyzedAt](분석일)로 대체하지 않는다 — 리포트 상단의
  ///   "2026.07.27 분석"과 다른 날짜이고, 분석일을 넣으면 오히려 "오늘 서류"라고
  ///   믿게 만들어 지금보다 나빠진다.
  String? _registryViewedLine(AnalysisReport report) {
    final viewed = report.registryViewedAt;
    return viewed == null ? null : '※ $viewed 기준 등기부등본';
  }

  /// 무엇이 표시됐는지 **종류별 개수로** — `집주인 이름 1곳과 빚 3건을 사진 위에 표시했어요`.
  ///
  /// 지금은 진입 카드가 열람일을 쓰느라 화면에 나가지 않지만, 조립 로직은 남겨 둔다
  /// (종류가 늘면 그대로 따라오는 문구라 다시 쓸 자리가 있다 — 2026-07-27 사용자 지시).
  String originPhotoSummary(AnalysisReport report) {
    final phrase = MarkLegend.countPhrase(
      report.highlights.map((h) => h.markKind),
    );
    if (phrase.isEmpty) return '올린 사진을 다시 볼 수 있어요';
    return '$phrase${MarkLegend.eul(phrase)} 사진 위에 표시했어요';
  }

  bool _isStale(AnalysisReport report) =>
      DateTime.now().difference(report.analyzedAt).inDays >= 1;

  /// 등급 → 마스코트 상태 (양호=safe, 확인필요=caution, 위험=danger)
  MascotState _mascotForGrade(RiskGrade grade) => switch (grade) {
    RiskGrade.danger => MascotState.danger,
    RiskGrade.caution => MascotState.caution,
    RiskGrade.ok => MascotState.safe,
  };

  /// 오래된 분석 배너 — 컴팩트 한 줄 (결론을 밀어내지 않게, 서연 리뷰 반영)
  Widget _staleBanner(BuildContext context, AnalysisReport report) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.lg),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.cautionSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.history,
            size: AppSize.iconSm,
            color: AppColors.caution,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: AppText(
              '${formatDaysAgo(report.analyzedAt)} 결과예요 — 계약 직전엔 최신 등기부등본으로 재확인하세요',
              style: AppTypography.caption.copyWith(color: AppColors.caution),
            ),
          ),
          TextButton(onPressed: () => _stub(context), child: const AppText('재분석')),
        ],
      ),
    );
  }

  /// 결론 헤더 — 등급 크게 + 의사결정 한 줄 + 보증금 (IA §0 + 서연 리뷰 반영)
  Widget _conclusionHeader(AnalysisReport report) {
    // 2026-08-03: 시세가 자동 조회에서도 올 수 있게 되면서 "(입력값)"이 거짓이 될 수
    // 있다. 출처를 하드코딩하지 않고 서버가 알려 준 대로 말한다.
    final String priceText = report.marketPrice != null
        ? '보증금 ${formatWon(report.deposit)} · 시세 ${formatWon(report.marketPrice!)}'
        : '보증금 ${formatWon(report.deposit)} · 시세를 못 구했어요';

    return Column(
      children: [
        SafetyGauge(
          grade: report.grade,
          progress: report.gaugeProgress,
          caption: '${formatDate(report.analyzedAt)} 분석',
          size: 190,
        ),
        const SizedBox(height: AppSpacing.md),
        AppText(
          report.headline,
          style: AppTypography.headline,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.sm),
        // 진행/보류/회피 의사결정 대응 — 문구는 E-1에서 등급 체계와 함께 확정
        RiskBadge(
          grade: report.grade,
          labelOverride: report.grade.decisionLabel,
          large: true,
        ),
        const SizedBox(height: AppSpacing.md),
        // 등급별 마스코트 — 게이지(190)·헤드라인·배지 '뒤'에 작게 둔다.
        // 보수적 편향(decisions.md 2026-07-09): 위험할수록 마스코트를 더 작게 해
        // 경고(게이지·배지·문구)가 항상 주인공이게 한다 (페르소나 2인 리뷰 반영 —
        // 서연: 위험일수록 작게 / 지수: 걱정 표정이 경고를 보강하므로 유지).
        // danger를 가장 작게(경고 우선). 양호(safe)는 반짝이 축하 연출이 강해
        // '안전 단언' 인상을 줄 수 있어 크게 키우지 않는다(design-reviewer 지적 반영).
        MascotSafe(
          size: report.grade == RiskGrade.danger ? 40 : 48,
          state: _mascotForGrade(report.grade),
        ),
        const SizedBox(height: AppSpacing.md),
        AppText(
          report.address,
          style: AppTypography.caption,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.xs),
        AppText(
          priceText,
          style: AppTypography.caption.copyWith(
            color: AppColors.textBody,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        // ── [D4 · 2026-08-14] 시세 출처 칩을 화면에서 뺐다 ──────────────────────
        // 실기기에서 결론 바로 아래 "자동 조회 · 공시가격 기준 (2025.1.1)"이 붙으니,
        // 등급을 읽어야 할 자리에서 시선이 출처 문자열로 새 나갔다.
        //
        // ⚠ **출처 표기 자체를 버린 것이 아니다.** 서버 응답의 marketPriceSource ·
        //   marketPriceAsOf · marketPriceSampleCount는 그대로 살아 있고
        //   (analysis_report.dart), 모델·계약도 손대지 않았다. 여기 렌더링만 뺐다.
        //   되돌리려면 아래 주석을 그대로 살리고 파일 상단의
        //   `marketPriceSourceLabel` import 주석만 함께 풀면 된다.
        //
        // const SizedBox(height: AppSpacing.xs),
        // Center(
        //   child: AmberHint(
        //     tone: report.marketPrice == null
        //         ? AmberHintTone.amber
        //         : (report.marketPriceSource.isAuto
        //               ? AmberHintTone.positive
        //               : AmberHintTone.neutral),
        //     icon: report.marketPrice == null
        //         ? Icons.help_outline
        //         : (report.marketPriceSource.isAuto
        //               ? Icons.verified_outlined
        //               : Icons.edit_outlined),
        //     text: marketPriceSourceLabel(
        //       source: report.marketPriceSource,
        //       asOf: report.marketPriceAsOf,
        //       sampleCount: report.marketPriceSampleCount,
        //       hasPrice: report.marketPrice != null,
        //     ),
        //   ),
        // ),
      ],
    );
  }

  /// 시세 괴리 정보 카드 — 실거래가와 정부 공시 기준이 **둘 다** 있을 때만 나온다.
  ///
  /// 왜 이걸 보여 주나: 실거래가는 조작할 수 있지만 공시가격은 정부가 매긴다.
  /// 신축 빌라를 실제 가치보다 비싸게 매매한 것처럼 신고(자전거래)해 부풀린 실거래가를
  /// 근거로 보증금을 높게 받는 것이 빌라 전세사기의 전형이다.
  ///
  /// ⚠ **판정이 아니라 정보다.** 임계값의 권위 있는 출처가 없어 등급을 바꾸지 않는다.
  ///   그래서 근거 카드(`_evidenceCard`) 대열에 끼우지 않고 **아래에 따로** 붙이고,
  ///   등급 색(danger/caution)이 아니라 정보 톤(info)을 쓴다 — 새 컴포넌트를 만들지 않고
  ///   기존 `AppCallout`을 재사용해 과하지 않게 앉힌다.
  Widget? _priceGapCard(AnalysisReport report) {
    final int? gap = report.marketPriceGapPct;
    if (gap == null) return null;

    // 잠정 임계값 — 서버(price_resolver)와 같은 값이다. 실측 후 함께 조정한다.
    const int inflated = 50;
    const int depressed = -30;

    final String title;
    final String text;
    final CalloutTone tone;
    if (gap >= inflated) {
      tone = CalloutTone.caution;
      title = '실제 거래값이 공시 기준보다 $gap% 높아요';
      text =
          '값을 부풀려 신고한 뒤 그 값을 근거로 보증금을 높게 받는 수법이 있어요. '
          '중개사에게 이 가격이 어떻게 정해졌는지 꼭 물어보세요.';
    } else if (gap <= depressed) {
      tone = CalloutTone.caution;
      title = '공시 기준이 실제 거래값보다 높아요';
      text =
          '실거래가가 정부 공시 기준보다 ${gap.abs()}% 낮아요. 최근 시세가 내려가고 있을 수 있어요 — '
          '계약 시점의 시세를 한 번 더 확인하세요.';
    } else {
      tone = CalloutTone.info;
      title = '실제 거래값과 공시 기준이 비슷해요';
      text = '두 값의 차이는 $gap%예요. 시세가 특별히 부풀려졌다고 볼 신호는 없어요.';
    }

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg),
      child: AppCallout(
        tone: tone,
        icon: Icons.balance,
        title: title,
        // 이 카드는 '정보'라는 것을 문장으로도 못 박는다 — 등급이 바뀐 줄 알면 안 된다.
        text: '$text\n\n※ 이 비교는 참고 정보예요. 위험 등급 계산에는 들어가지 않아요.',
      ),
    );
  }

  Widget _nextActionCard(BuildContext context, AnalysisReport report) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.flag_outlined,
                color: AppColors.primary,
                size: AppSize.iconMd,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // D1: '근거 확인'보다 '그래서 뭘 해야 하나'가 사용자의 진짜 관심 —
                    // 제목을 label(12px)에서 title(17px)로 올려 위계를 강조.
                    AppText(
                      '지금 해야 할 일',
                      style: AppTypography.title.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    // G7: 결정적 영역이라 볼드 강조 (LLM 생성 아닌 결정적 템플릿 문장)
                    AppText(
                      report.nextAction,
                      style: AppTypography.bodyStrong.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // "아래 질문" 을 찾으러 헤매지 않게 바로가기 제공 (지수 리뷰 반영)
          if (report.grade != RiskGrade.ok) ...[
            const SizedBox(height: AppSpacing.md),
            AppCompactButton(
              label: '중개사 질문 모아 보기',
              icon: Icons.quiz_outlined,
              onPressed: () => context.push('/questions/${report.id}'),
            ),
          ],
        ],
      ),
    );
  }

  /// 근거 카드 목록 — 가장 심각한 카드 1개는 기본 펼침 (서연 리뷰 반영)
  List<Widget> _evidenceCards(BuildContext context, AnalysisReport report) {
    final int expandedIndex = _mostSevereIndex(report.evidences);
    return [
      for (int i = 0; i < report.evidences.length; i++) ...[
        _evidenceCard(
          context,
          report.evidences[i],
          initiallyExpanded: i == expandedIndex,
        ),
        const SizedBox(height: AppSpacing.md),
      ],
    ];
  }

  int _mostSevereIndex(List<EvidenceItem> evidences) {
    int severity(RiskGrade g) => switch (g) {
      RiskGrade.danger => 2,
      RiskGrade.caution => 1,
      RiskGrade.ok => 0,
    };
    int best = 0;
    for (int i = 1; i < evidences.length; i++) {
      if (severity(evidences[i].grade) > severity(evidences[best].grade)) {
        best = i;
      }
    }
    return best;
  }

  Widget _evidenceCard(
    BuildContext context,
    EvidenceItem evidence, {
    required bool initiallyExpanded,
  }) {
    return EvidenceCard(
      title: evidence.title,
      termSubtitle: evidence.termSubtitle,
      grade: evidence.grade,
      statusLabel: evidence.statusLabel,
      easyExplanation: evidence.easyExplanation,
      explanationSpan: _explanationSpan(context, evidence),
      detailText: evidence.detailText,
      sourceText: evidence.sourceText,
      initiallyExpanded: initiallyExpanded,
      action: evidence.actionLabel == null
          ? null
          // F3: 근거 카드는 흰 표면이므로 라인 대신 톤(연초록) 버튼
          : AppCompactButton(
              label: evidence.actionLabel!,
              tonal: true,
              onPressed: () => _onEvidenceAction(context, evidence),
            ),
    );
  }

  void _onEvidenceAction(BuildContext context, EvidenceItem evidence) {
    if (evidence.actionLabel == '중개사에게 물어볼 질문 보기') {
      context.push('/questions/$reportId');
    } else {
      // 예: "시세 입력하기" — 매물 검색 재진입은 C-3 범위 밖(재분석 흐름). 안내만.
      _stub(context);
    }
  }

  /// 쉬운 설명에 용어 툴팁(termSpan)을 심는다 (지수·design-reviewer 리뷰 반영).
  /// "챗봇에 더 물어보기" 연결은 챗봇 실화면과 함께 C-3에서.
  InlineSpan? _explanationSpan(BuildContext context, EvidenceItem evidence) {
    if (evidence.termGlossary.isEmpty) return null;

    final List<InlineSpan> children = [];
    String rest = evidence.easyExplanation;
    while (rest.isNotEmpty) {
      int bestIndex = -1;
      String? bestTerm;
      for (final term in evidence.termGlossary.keys) {
        final int idx = rest.indexOf(term);
        if (idx >= 0 && (bestIndex == -1 || idx < bestIndex)) {
          bestIndex = idx;
          bestTerm = term;
        }
      }
      if (bestTerm == null) {
        children.add(TextSpan(text: rest));
        break;
      }
      if (bestIndex > 0) {
        children.add(TextSpan(text: rest.substring(0, bestIndex)));
      }
      children.add(
        termSpan(
          context,
          term: bestTerm,
          description: evidence.termGlossary[bestTerm]!,
          onAskChatbot: () => context.push('/chatbot'),
        ),
      );
      rest = rest.substring(bestIndex + bestTerm.length);
    }
    return TextSpan(style: AppTypography.body, children: children);
  }

  /// 다음 행동 — 등급별 추천 1개 강조 + 나머지 그리드 (지수 리뷰 반영)
  List<Widget> _actionArea(BuildContext context, AnalysisReport report) {
    final bool recommendQuestions = report.grade != RiskGrade.ok;

    final recommended = recommendQuestions
        ? (
            icon: Icons.quiz_outlined,
            label: '질문 생성기',
            caption: '위험 요소별로 중개사에게 물어볼 질문을 만들어 드려요',
            onTap: () => context.push('/questions/${report.id}'),
          )
        : (
            icon: Icons.fact_check_outlined,
            label: '계약 여정 체크리스트',
            caption: '계약 전부터 보증금 반환까지 단계별 할 일을 확인하세요',
            onTap: () => context.push('/checklist'),
          );

    final others = [
      if (!recommendQuestions)
        (
          icon: Icons.quiz_outlined,
          label: '질문 생성기',
          onTap: () => context.push('/questions/${report.id}'),
        ),
      (
        icon: Icons.gavel_outlined,
        label: '판례 매칭', // A1: 화면 제목(판례 매칭)과 라벨 통일
        onTap: () => context.push('/cases/${report.id}'),
      ),
      (
        icon: Icons.calculate_outlined,
        label: '손실 시뮬레이터',
        onTap: () => context.push('/simulator/${report.id}'),
      ),
      if (recommendQuestions)
        (
          icon: Icons.fact_check_outlined,
          label: '체크리스트',
          onTap: () => context.push('/checklist'),
        ),
    ];

    return [
      // 추천 행동 — 전폭 강조 카드
      AppCard(
        onTap: recommended.onTap,
        child: Row(
          children: [
            Icon(
              recommended.icon,
              color: AppColors.primary,
              size: AppSize.iconMd,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AppText(recommended.label, style: AppTypography.bodyStrong),
                      const SizedBox(width: AppSpacing.sm),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primarySoft,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: AppText(
                          '추천',
                          style: AppTypography.label.copyWith(
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  AppText(recommended.caption, style: AppTypography.caption),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.textMuted),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.md),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: AppSpacing.md,
        crossAxisSpacing: AppSpacing.md,
        childAspectRatio: 2.4,
        children: [
          for (final action in others)
            AppCard(
              onTap: action.onTap,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: [
                  Icon(
                    action.icon,
                    color: AppColors.primary,
                    size: AppSize.iconMd,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: AppText(action.label, style: AppTypography.bodyStrong),
                  ),
                ],
              ),
            ),
        ],
      ),
    ];
  }

  /// D4: 전역 면책 안내 — 리포트 최하단 상시 노출(캡처 공유 시 자연 포함).
  /// AA 통과 색(textMuted)·가독 가능한 크기 유지 — 면책의 보호 목적을 지키기 위해
  /// 일부러 최소 크기로 줄이지 않는다.
  Widget _disclaimer() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: AppText(
        '위험도 분석 리포트는 공개 데이터와 입력 정보를 기반으로 산출된 참고 지표입니다. '
        '실제 법적 권리관계 및 계약의 안전성을 보증하지 않으며, 최종 판단은 공식 서류 '
        '확인과 전문가 상담을 통해 이루어져야 합니다.',
        style: AppTypography.caption.copyWith(color: AppColors.textMuted),
      ),
    );
  }

  void _stub(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: AppText('곧 제공되는 기능이에요')));
  }
}
