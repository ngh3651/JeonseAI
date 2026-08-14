/// 카드 2종: 기본 카드(AppCard) + 근거 카드(EvidenceCard, 접힘/펼침).
///
/// EvidenceCard는 "결론 크게 → 근거 펼침" 원칙의 핵심 컴포넌트다 (IA.md §6 S-07):
/// - 접힘: 상태 뱃지 + 쉬운 질문형 제목 + 전문용어 부제
/// - 펼침: 쉬운 설명 → 상세 수치 → 출처 + 판정/설명 구분 라벨
library;

import 'package:flutter/material.dart';

import '../../models/risk_grade.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'risk_badge.dart';
import 'source_label.dart';
import '../../design_system/text/app_text.dart';

/// 표면 카드 — 테마의 CardThemeData(테두리·라운드)를 그대로 쓰는 패딩 컨테이너.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.cardPadH, // F5: 18
      vertical: AppSpacing.cardPadV, // F5: 16
    ),
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
    if (onTap == null) return card;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// 근거 카드 (접힘/펼침).
class EvidenceCard extends StatefulWidget {
  const EvidenceCard({
    super.key,
    required this.title,
    required this.termSubtitle,
    required this.grade,
    this.statusLabel,
    required this.easyExplanation,
    this.explanationSpan,
    this.detailText,
    this.sourceText,
    this.explanationSource,
    this.action,
    this.initiallyExpanded = false,
  });

  /// 쉬운 질문형 제목 (예: "나보다 먼저 돈 받아갈 빚이 있나요?")
  final String title;

  /// 전문용어 부제 (예: "선순위 채권 · 근저당")
  final String termSubtitle;

  /// 상태 색·뱃지에 쓰일 등급
  final RiskGrade grade;

  /// 등급 라벨 대신 표시할 상태 (예: "페이지 누락"). null이면 등급 라벨.
  final String? statusLabel;

  /// 펼침 1단: 쉬운 설명 (AI 생성 문장 슬롯)
  final String easyExplanation;

  /// 쉬운 설명을 용어 툴팁(termSpan) 포함 리치 텍스트로 그릴 때 —
  /// 지정하면 [easyExplanation] 대신 이 스팬을 렌더링한다.
  final InlineSpan? explanationSpan;

  /// 펼침 2단: 상세 수치
  final String? detailText;

  /// 펼침 3단: 판정 출처 (예: "HUG 전세보증 기준")
  final String? sourceText;

  /// 이 카드의 **설명 문장**을 누가 썼는가 (2026-08-14 D26).
  /// null이면 [VerdictSourceLabel]이 종전 라벨('자동 생성')을 쓴다.
  final String? explanationSource;

  /// 다음 행동 버튼.
  ///
  /// **사용 규칙 (IA.md §0)**: "확인 필요" 등 보수적 상태로 쓸 때는 반드시 action을
  /// 함께 전달할 것 — "위험이 없다는 뜻은 아니에요"류 문구 단독 노출 금지.
  final Widget? action;

  final bool initiallyExpanded;

  @override
  State<EvidenceCard> createState() => _EvidenceCardState();
}

class _EvidenceCardState extends State<EvidenceCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        button: true,
        expanded: _expanded,
        label: '근거: ${widget.title}',
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.cardPadH, // F5: 18
              vertical: AppSpacing.cardPadV, // F5: 16
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // F7: 뱃지를 제목 위로 — 질문형 긴 제목이 뱃지 때문에 줄바꿈되던 문제 방지.
                // 뱃지는 좌상단, 펼침 아이콘은 우상단, 제목은 아래 전폭.
                Row(
                  children: [
                    RiskBadge(
                      grade: widget.grade,
                      labelOverride: widget.statusLabel,
                    ),
                    const Spacer(),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      color: AppColors.textMuted,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                AppText(widget.title, style: AppTypography.title),
                const SizedBox(height: AppSpacing.xs),
                AppText(widget.termSubtitle, style: AppTypography.caption),
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 180),
                  crossFadeState: _expanded
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  firstChild: const SizedBox(width: double.infinity),
                  secondChild: Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ── [D24 · 2026-08-14] 회색 요약 박스를 설명문 **위로** ──────
                        //
                        // 예전에는 설명문(4줄) → 회색 박스 순서였다. 카드를 펼치면
                        // 문장부터 읽어야 이 집의 숫자가 나와서, "그래서 얼마인데?"에
                        // 닿기까지 네 줄이 걸렸다. 숫자가 결론이고 설명문은 그 결론을
                        // 풀어 주는 말이므로 순서를 뒤집는다 —
                        // "결론 먼저 크게 → 근거는 펼쳐 보기"(IA.md §0)와 같은 방향이다.
                        //
                        // ⚠ 박스 스타일·패딩·타이포는 **그대로**다. 순서만 바꿨다.
                        // ⚠ `explanationSpan`(용어 툴팁이 심긴 리치 텍스트)은 그대로
                        //   `easyExplanation` 자리에 그려진다 — report_screen이 붙이는
                        //   indexOf 배선은 이 위젯의 순서와 무관하다(스팬은 이미 조립된
                        //   상태로 넘어온다). 툴팁은 그대로 산다.
                        if (widget.detailText != null) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(AppSpacing.md),
                            decoration: BoxDecoration(
                              color: AppColors.background,
                              borderRadius: BorderRadius.circular(AppRadius.md),
                            ),
                            child: AppText(
                              widget.detailText!,
                              style: AppTypography.bodyStrong,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                        ],
                        if (widget.explanationSpan != null)
                          AppText.rich(widget.explanationSpan!)
                        else
                          AppText(
                            widget.easyExplanation,
                            style: AppTypography.body,
                          ),
                        const SizedBox(height: AppSpacing.md),
                        VerdictSourceLabel(
                          verdictSource: widget.sourceText,
                          explanationSource: widget.explanationSource,
                        ),
                        if (widget.action != null) ...[
                          const SizedBox(height: AppSpacing.md),
                          widget.action!,
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
