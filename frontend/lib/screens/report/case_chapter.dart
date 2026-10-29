/// 리포트 3장 '판례 매칭' (2026-10-29 확정안 J10).
///
/// 「3 / 5 · 실제 판례(회색) · ✦ AI 매칭(초록)」 + "판례 매칭"
/// + 카드 [숯색 띠 "“ AI가 실제 판례 중 이 집에 맞춰 고른 N건" → 1순위 판례(위험 태그 · 결과 문장 · 사건번호) → 자세히 보기 ›].
///
/// - 판례는 **사기·피해 사례**라 초록 포인트를 쓰지 않는다 — 띠는 숯색, 따옴표만 연한 빨강(2026-10-29 규혁).
/// - "대법원"이라고 부르지 않는다 — 하급심도 섞인다. 사건번호 줄만 그 판례의 실제 법원 이름을 쓴다.
/// - 띠의 N건은 **창고 전체에서 이 집에 맞춰 고른 수**다(순위가 아니다).
/// - 판례 0건(양호한 집)은 초록 체크 + '이 집과 비슷한 피해 판례는 없었어요', 자세히 보기 없음.
/// - 데이터는 리포트가 열릴 때 미리 받아 두는 것([CasePrefetch])을 그대로 쓴다 — 요청이 늘지 않는다.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/content_models.dart';
import '../../repositories/content_repository.dart';
import '../../state/case_prefetch.dart';
import '../cases/case_card.dart'
    show kMaxCardTags, riskTagLabel, stripBoldMarkers;

const Color _kDataChipBg = Color(0xFFECEFED);
const Color _kDataChipFg = Color(0xFF3C4842);

/// 띠 — 숯색 바탕 · 연한 빨강 따옴표
const Color _kBandBg = Color(0xFF2A322E);
const Color _kQuote = Color(0xFFE8A39C);

class CaseChapter extends StatefulWidget {
  const CaseChapter({super.key, required this.reportId});

  final String reportId;

  @override
  State<CaseChapter> createState() => _CaseChapterState();
}

class _CaseChapterState extends State<CaseChapter> {
  late final Future<List<CaseMatch>> _future = () async {
    try {
      return await CasePrefetch.get(
        context.read<ContentRepository>(),
        widget.reportId,
      );
    } catch (_) {
      return const <CaseMatch>[];
    }
  }();

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('report-chapter-cases'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            AppText(
              '3 / 5',
              style: AppTypographyNext.caption.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColorsNext.textMuted,
              ),
            ),
            const _Chip(
              icon: Icons.account_balance_outlined,
              label: '실제 판례',
              bg: _kDataChipBg,
              fg: _kDataChipFg,
            ),
            const _Chip(
              icon: Icons.auto_awesome,
              label: 'AI 매칭',
              bg: AppColors.primarySoft,
              fg: AppColors.primary,
            ),
          ],
        ),
        const SizedBox(height: 6),
        AppText(
          '판례 매칭',
          style: AppTypographyNext.headline.copyWith(
            color: AppColorsNext.textStrong,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(20),
          ),
          clipBehavior: Clip.antiAlias,
          child: FutureBuilder<List<CaseMatch>>(
            future: _future,
            builder: (context, snap) {
              final bool loading = snap.connectionState != ConnectionState.done;
              final cases = snap.data ?? const <CaseMatch>[];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!loading && cases.isNotEmpty) _band(cases.length),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                    child: loading
                        ? const SizedBox(
                            key: ValueKey('case-chapter-loading'),
                            height: 120,
                            child: Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                ),
                              ),
                            ),
                          )
                        : cases.isEmpty
                        ? _empty()
                        : _preview(cases.first),
                  ),
                  // 판례 0건 = 양호한 집 — 판례 화면에도 볼 게 없으니 '자세히 보기'를 두지 않는다
                  if (loading || cases.isNotEmpty) ...[
                    const Divider(
                      height: 1,
                      thickness: 1,
                      indent: 20,
                      endIndent: 20,
                      color: AppColorsNext.divider,
                    ),
                    InkWell(
                      key: const ValueKey('case-chapter-more'),
                      onTap: () => context.push('/cases/${widget.reportId}'),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 16, 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: AppText(
                                '자세히 보기',
                                style: AppTypographyNext.bodyStrong.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                            const Icon(
                              Icons.chevron_right,
                              color: AppColors.primary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// 판례 0건 — 양호한 집에서만 나온다(위험한 집은 판례가 반드시 붙는다, 2026-10-29 규혁). 안심되는 모양으로.
  Widget _empty() => Row(
    key: const ValueKey('case-chapter-empty'),
    children: [
      Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
          color: AppColors.okSoft,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.check_rounded, size: 24, color: AppColors.ok),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: AppText(
          '이 집과 비슷한 피해 판례는 없었어요',
          style: AppTypographyNext.title.copyWith(
            color: AppColorsNext.textStrong,
          ),
        ),
      ),
    ],
  );

  Widget _band(int count) => Container(
    key: const ValueKey('case-chapter-band'),
    color: _kBandBg,
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const AppText(
          '“',
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            fontFamily: 'Georgia',
            fontSize: 30,
            height: 0.9,
            fontWeight: FontWeight.w900,
            color: _kQuote,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: AppText(
            'AI가 실제 판례 중 이 집에 맞춰 고른 $count건',
            style: AppTypographyNext.caption.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _preview(CaseMatch c) {
    final tags = c.displayTags.take(kMaxCardTags).toList();
    return Column(
      key: const ValueKey('case-chapter-preview'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (tags.isNotEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in tags)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.dangerSoft,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: AppText(
                    riskTagLabel(t),
                    style: AppTypographyNext.caption.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppColorsNext.dangerText,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        AppText(
          stripBoldMarkers(c.result).text,
          style: AppTypographyNext.title.copyWith(
            color: AppColorsNext.textStrong,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            const Icon(
              Icons.account_balance_outlined,
              size: 18,
              color: AppColorsNext.textMuted,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: AppText(
                c.caseNo,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypographyNext.caption,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    required this.bg,
    required this.fg,
  });

  final IconData icon;
  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: fg),
        const SizedBox(width: 4),
        AppText(
          label,
          style: AppTypographyNext.caption.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: fg,
          ),
        ),
      ],
    ),
  );
}
