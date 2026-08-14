/// S-08 판례 매칭 — IA.md §6. (사용자 노출 명칭: "판례" 유지 — 실제 법원 판결이라는
/// 신뢰 무게가 플래그십 차별화의 핵심. 화면 첫 등장에 '법원의 실제 판결' 툴팁만 붙임.)
///
/// 헤드라인("…판례를 모았어요") → 갱신 안내 → 현재 매물의 위험 패턴 칩(쉬운 말)
/// → 패턴별 큐레이션 판례 카드. (2026-08-14 D18·D21: 하단 공통 CTA 콜아웃을 없애고
/// 맨 아래 있던 안내 문구를 헤드라인 밑으로 올렸다. "공포 뒤 행동"은 카드 안의
/// '이런 피해를 피하려면'(advice)이 카드별로 맡는다.)
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
              // ── [D21 · 2026-08-14] 화면 맨 위를 "무엇을 보고 있는가"로 연다 ──
              //
              // 예전에는 이 한 줄이 본문 크기(15)라 아래 칩·카드와 무게가 같아서,
              // 스크롤을 내리다 들어온 사람에게는 그냥 첫 문장으로 읽혔다. 화면 제목
              // 크기로 올려 **판례 화면의 헤드라인**이 되게 한다.
              // '판례' 첫 등장의 툴팁은 그대로 유지한다(용어는 유지 — 신뢰 무게가 핵심).
              AppText.rich(
                TextSpan(
                  style: AppTypography.headline,
                  children: [
                    const TextSpan(text: '이 매물의 위험과 비슷한 상황에서 나온 '),
                    termSpan(
                      context,
                      term: '판례',
                      description:
                          '법원의 실제 판결이에요. 실제로 이런 일이 일어나 '
                          '법정까지 갔다는 뜻이라, 위험을 훨씬 더 무겁게 봐야 해요.',
                      style: AppTypography.headline,
                    ),
                    const TextSpan(text: '를 모았어요'),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              // 스크롤 맨 아래에 있던 줄을 헤드라인 바로 밑으로 올렸다. 여기 있어야
              // "지금 보이는 게 전부는 아니다"를 **판례를 읽기 전에** 알 수 있다 —
              // 맨 아래에서는 카드를 다 믿고 내려온 뒤에야 만나는 말이었다.
              AppText('판례 데이터는 계속 추가되고 있어요', style: AppTypography.caption),
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
                  _caseCard(context, c),
                  const SizedBox(height: AppSpacing.md),
                ],
              // ── [D18 · 2026-08-14] 하단 공통 콜아웃을 통째로 뺐다 ────────────
              //
              // 있던 것: 연초록 박스(방패 아이콘 + '이런 피해를 피하려면' +
              // '중개사무소에 가기 전에…' + 초록 채움 버튼 '중개사에게 물어볼 질문 보기').
              // 원래 의도는 "공포 뒤에 행동을 붙인다"(2026-07-04 지수 리뷰)였다.
              //
              // 그 의도는 이미 **카드 안**에서 충족된다 — 카드마다 '이런 피해를 피하려면'
              // (`advice`)이 그 판례에 맞는 조언으로 붙는다. 같은 제목이 카드 안과 화면
              // 아래에 각각 있어서, 아래 박스가 카드의 조언을 덮어쓰는 총평처럼 읽혔다.
              // 판례 화면에서는 판례만 다루고, 질문으로 가는 길은 리포트의 2×2 그리드가 맡는다.
              //
              // ⚠ 카드 안의 '이런 피해를 피하려면'(`_caseCard`의 advice 행)은 **유지**다.
              //   지운 것은 카드 바깥의 공통 박스 하나뿐이다.
              const SizedBox(height: AppSpacing.xxxl),
            ],
          );
        },
      ),
    );
  }

  Widget _caseCard(BuildContext context, CaseMatch c) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _tagHeader(c),
          const SizedBox(height: AppSpacing.sm),
          // [D19 · 2026-08-14] 사건번호를 caption(13·보통)에서 body 크기·w700으로.
          // 이 줄이 "지어낸 이야기가 아니라 실제 판결"이라는 증거인데, 13px 회색
          // 보통 글씨라 영상에서 읽히지 않았다. **색은 그대로 두고**(대비 검증 완료)
          // 크기와 굵기만 올린다.
          AppText(
            c.caseNo,
            style: AppTypography.body.copyWith(
              fontWeight: FontWeight.w700,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppText(c.summary, style: AppTypography.bodyStrong),
          const SizedBox(height: AppSpacing.md),
          _row(context, c, '결과', 'result', c.result, AppColors.danger),
          const SizedBox(height: AppSpacing.sm),
          _row(
            context,
            c,
            '우리 매물과 공통점',
            'commonPoint',
            c.commonPoint,
            AppColors.textBody,
          ),
          if (c.advice != null && c.advice!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            _row(
              context,
              c,
              '이런 피해를 피하려면',
              'advice',
              c.advice!,
              AppColors.primary,
            ),
          ],
          // [D22 · 2026-08-14] 카드 맨 아래 '사람 검수 완료 · 판결문 원문 있음' 줄을
          // 화면에서 뺐다 (`_sourceLine`). 카드마다 반복돼 4장이 같은 꼬리를 달고 있었고,
          // 정작 봐야 할 사건번호·조언보다 눈에 먼저 들어왔다.
          //
          // ⚠ **데이터는 그대로다.** `curated`·`sourceUrl`은 응답에도 모델에도 남아 있고
          //   (content_models.dart), 서버 정렬은 여전히 `verified`를 동점 기준으로 쓴다
          //   (precedent/service.py). 지운 것은 이 줄의 렌더링뿐이라, 되돌리려면
          //   `_sourceLine`을 되살려 여기에 다시 넣으면 된다.
          // ⚠ 상단에 "전부 검수했어요" 같은 일괄 문구를 만들지 않는다 — 4건의 검수
          //   상태가 서로 달라, 한 줄로 뭉치면 사실이 아닌 말이 된다.
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

  /// 카드 안의 한 문단 — 소제목 + 본문.
  ///
  /// [D19 · 2026-08-14] 소제목('결과' · '우리 매물과 공통점' · '이런 피해를 피하려면')을
  /// w700로 올렸다. 소제목과 본문이 둘 다 보통 굵기라 문단 경계가 안 보였고, 카드가
  /// 회색 글씨 네 덩어리로 뭉쳐 보였다. **색은 그대로 둔다** — 대비는 이미 검증됐고,
  /// 여기서 색까지 건드리면 본문(빨강/검정/초록)과 소제목의 역할이 뒤섞인다.
  ///
  /// 이 소제목들은 서버가 주는 값이 아니라 **앱이 붙이는 라벨**이다(`_caseCard` 참고).
  ///
  /// [field]는 계약(§2.3)의 필드 이름 그대로 — `emphasis` 맵을 찾는 열쇠다.
  Widget _row(
    BuildContext context,
    CaseMatch c,
    String label,
    String field,
    String value,
    Color valueColor,
  ) {
    final TextStyle base = AppTypography.body.copyWith(color: valueColor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          label,
          style: AppTypography.caption.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        AppText.rich(
          _bodySpan(
            context,
            text: value,
            base: base,
            glossary: c.termGlossary,
            emphasis: c.emphasis[field] ?? const [],
          ),
        ),
      ],
    );
  }

  /// 카드 본문 한 문단 — **용어 툴팁(D20)과 중요 구절 굵게(D23)를 한 경로에서** 조립한다.
  ///
  /// 둘을 따로 그리면 같은 문장을 두 번 쪼개게 되고, 용어와 강조 구간이 겹칠 때
  /// 한쪽이 다른 쪽을 잘라 먹는다. 그래서 한 번만 훑으면서 둘 다 얹는다.
  ///
  /// 규칙 (근거 카드 `report_screen._explanationSpan`과 **같은 전제**):
  /// - 용어도 강조도 **본문에 글자 그대로 있어야** 붙는다(`indexOf`). 없으면 조용히
  ///   아무 일도 안 일어난다 — 본문 자체는 어떤 경우에도 바뀌지 않는다.
  /// - 같은 자리에서 시작하는 용어가 여럿이면 **긴 쪽**을 쓴다('근저당'이 '근저당권'을
  ///   반으로 자르는 것을 막는다. 서버도 같은 이유로 긴 표기를 우선한다 — terms.attach).
  /// - 용어 구간은 강조로 덧칠하지 않는다. 점선 밑줄 + 초록이 이미 충분히 눈에 띄고,
  ///   거기에 굵기까지 얹으면 "탭할 수 있는 곳"과 "중요한 곳"이 구분되지 않는다.
  InlineSpan _bodySpan(
    BuildContext context, {
    required String text,
    required TextStyle base,
    required Map<String, String> glossary,
    required List<String> emphasis,
  }) {
    // ① 굵게 칠할 자리를 글자 단위로 표시해 둔다 (구간이 겹쳐도 안전하다).
    final List<bool> bold = List<bool>.filled(text.length, false);
    for (final phrase in emphasis) {
      if (phrase.isEmpty) continue;
      final int at = text.indexOf(phrase);
      if (at < 0) continue; // 서버가 검증하지만, 못 찾으면 굵기만 없다
      for (int i = at; i < at + phrase.length; i++) {
        bold[i] = true;
      }
    }
    final TextStyle boldStyle = base.copyWith(fontWeight: FontWeight.w700);
    final List<InlineSpan> children = [];

    // ② 용어가 아닌 구간을 굵기 경계로 잘라 넣는다.
    void addPlain(int start, int end) {
      int i = start;
      while (i < end) {
        final bool on = bold[i];
        int j = i;
        while (j < end && bold[j] == on) {
          j++;
        }
        children.add(
          TextSpan(text: text.substring(i, j), style: on ? boldStyle : base),
        );
        i = j;
      }
    }

    // ③ 왼쪽부터 가장 먼저 나오는 용어를 집어 가며 훑는다.
    int cursor = 0;
    while (cursor < text.length) {
      int bestAt = -1;
      String? bestTerm;
      for (final term in glossary.keys) {
        if (term.isEmpty) continue;
        final int at = text.indexOf(term, cursor);
        if (at < 0) continue;
        if (bestAt == -1 ||
            at < bestAt ||
            (at == bestAt && term.length > bestTerm!.length)) {
          bestAt = at;
          bestTerm = term;
        }
      }
      if (bestTerm == null) {
        addPlain(cursor, text.length);
        break;
      }
      if (bestAt > cursor) addPlain(cursor, bestAt);
      children.add(
        termSpan(
          context,
          term: bestTerm,
          description: glossary[bestTerm]!,
          onAskChatbot: () => context.push('/chatbot'),
          style: base,
        ),
      );
      cursor = bestAt + bestTerm.length;
    }
    return TextSpan(style: base, children: children);
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
