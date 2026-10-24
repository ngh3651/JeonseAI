/// S-08 판례 매칭 — IA.md §6. (사용자 노출 명칭: "판례" 유지 — 실제 법원 판결이라는 신뢰 무게.)
///
/// 2026-10-24 디자인 확정안(규칙 문서·시안 ①~⑤)으로 다시 짰다:
/// 헤드라인(한 줄) → "이 매물에서 눈에 띈 위험" 2칸 표 → "대법원 판례 N건" → 판례 카드(첫 장만 펼침)
/// → 0건이면 흰 상자. 부품은 `case_card.dart`, 글자·색은 **새 체계(시범)** `app_typography_next.dart`.
/// ('판례' 뜻 풀이 밑줄은 2026-10-23 규혁 요청으로 뺐다 — "판례 뜻 모르는 사람 없다".)
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/analysis_report.dart';
import '../../models/content_models.dart';
import '../../repositories/analysis_repository.dart';
import '../../repositories/content_repository.dart';
import '../../services/api_client.dart';
import 'case_card.dart';

export 'case_card.dart' show kRiskTagLabel, riskTagLabel, kMaxCardTags;

class CaseMatchScreen extends StatefulWidget {
  const CaseMatchScreen({super.key, required this.reportId});

  final String reportId;

  @override
  State<CaseMatchScreen> createState() => _CaseMatchScreenState();
}

class _CaseMatchScreenState extends State<CaseMatchScreen> {
  String get reportId => widget.reportId;

  late Future<(AnalysisReport?, List<CaseMatch>)> _future;

  /// 판례 창고 상태 — 안내 줄 옆 "2026.10.24 기준". 판례 목록과 따로 받아 화면을 막지 않는다.
  late final Future<PrecedentStatus?> _status = context.read<ContentRepository>().precedentStatus();

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
      appBar: AppBar(title: AppText('판례 매칭', style: AppTypographyNext.title)),
      body: FutureBuilder<(AnalysisReport?, List<CaseMatch>)>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _error(context, retryable: true, error: snapshot.error);
          }
          final (report, cases) = snapshot.data!;
          if (report == null) {
            return _error(context);
          }
          final labels = [for (final p in report.riskLabels) riskTagLabel(p)];

          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenPadding,
              AppSpacing.md,
              AppSpacing.screenPadding,
              AppSpacing.xxxl,
            ),
            children: [
              FutureBuilder<PrecedentStatus?>(
                future: _status,
                builder: (_, s) => CaseMatchHeader(asOf: s.data?.asOfLabel),
              ),
              const SizedBox(height: AppSpacing.xxl),
              CaseRiskBox(labels: labels),
              const SizedBox(height: AppSpacing.xxxl),
              if (cases.isEmpty)
                const CaseEmptyBox()
              else ...[
                AppText(caseCountTitle(cases), style: AppTypographyNext.title),
                const SizedBox(height: AppSpacing.md),
                for (int i = 0; i < cases.length; i++) ...[
                  CaseCard(match: cases[i]), // 전부 닫힌 채로 시작(2026-10-24 규혁)
                  const SizedBox(height: AppSpacing.md),
                ],
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _error(BuildContext context, {bool retryable = false, Object? error}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppText(
            retryable
                ? '데이터를 불러오지 못했어요\n'
                      '${apiErrorHint(error, fallback: '서버 연결을 확인해 주세요')}'
                : '리포트를 불러올 수 없어요',
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

/// "대법원 판례 N건" — 지방법원 판례가 섞이면 "판례 N건"(대법원이라고 부풀리지 않는다).
String caseCountTitle(List<CaseMatch> cases) {
  final allSupreme = cases.every((c) => c.caseNo.trim().startsWith('대법원'));
  return '${allSupreme ? '대법원 판례' : '판례'} ${cases.length}건';
}

/// 화면 맨 위 — 제목(24, **한 줄 고정**: 넘치면 줄바꿈 대신 그 줄만 살짝 줄인다) + 안내(15).
class CaseMatchHeader extends StatelessWidget {
  const CaseMatchHeader({super.key, this.asOf});

  /// "2026.10.24 기준" — 서버가 알려 준 마지막 판례 업데이트 날짜. 모르면 null → 날짜를 뺀다.
  final String? asOf;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: AppText(
            '비슷한 상황의 판례를 모았어요',
            maxLines: 1,
            style: AppTypographyNext.headline,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        // 한 줄에 다 안 들어가면 날짜가 통째로 다음 줄로 간다(어절 단위 줄바꿈)
        AppText.rich(
          TextSpan(
            style: AppTypographyNext.caption,
            children: [
              const TextSpan(text: '판례 데이터는 계속 추가되고 있어요'),
              if (asOf != null) TextSpan(text: ' · $asOf'),
            ],
          ),
        ),
      ],
    );
  }
}
