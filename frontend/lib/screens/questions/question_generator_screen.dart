/// S-10 질문 생성기 — IA.md §6.
///
/// 위험 요소별 질문 + 왜 물어봐야 하는지 + 답변 판별 가이드(안심/보류). 개별·전체 복사.
/// 질문은 예시(E-2에서 분석 결과 기반 Solar Pro 생성으로 교체 — 판정 변경 금지).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/content_models.dart';
import '../../repositories/content_repository.dart';
import '../../design_system/text/app_text.dart';

class QuestionGeneratorScreen extends StatefulWidget {
  const QuestionGeneratorScreen({super.key, required this.reportId});

  final String reportId;

  @override
  State<QuestionGeneratorScreen> createState() =>
      _QuestionGeneratorScreenState();
}

class _QuestionGeneratorScreenState extends State<QuestionGeneratorScreen> {
  late Future<List<QuestionGroup>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    // 서버가 리포트에서 위험 패턴을 파생해 질문을 만든다 (계약 §3.6)
    _future = context.read<ContentRepository>().questionGroups(widget.reportId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const AppText('중개사 질문 생성기')),
      body: FutureBuilder<List<QuestionGroup>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppText(
                    '질문을 불러오지 못했어요\n서버 연결을 확인해 주세요',
                    style: AppTypography.body,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  AppCompactButton(
                    label: '다시 시도',
                    icon: Icons.refresh,
                    onPressed: () => setState(_load),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppCompactButton(
                    label: '홈으로',
                    onPressed: () => context.go('/home'),
                  ),
                ],
              ),
            );
          }

          final groups = snapshot.data!;

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            children: [
              AppText('이 매물, 이럴 땐 꼭 물어보세요', style: AppTypography.title),
              const SizedBox(height: AppSpacing.xs),
              AppText('현장에서 그대로 보여주면 돼요', style: AppTypography.caption),
              const SizedBox(height: AppSpacing.lg),
              for (final g in groups) ...[
                _group(context, g),
                const SizedBox(height: AppSpacing.md),
              ],
              const SizedBox(height: AppSpacing.md),
              AppPrimaryButton(
                label: '질문 전체 복사',
                icon: Icons.copy_all,
                onPressed: () => _copyAll(context, groups),
              ),
              const SizedBox(height: AppSpacing.xxxl),
            ],
          );
        },
      ),
    );
  }

  Widget _group(BuildContext context, QuestionGroup g) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(
            g.riskLabel,
            style: AppTypography.label.copyWith(color: AppColors.primary),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (int i = 0; i < g.items.length; i++) ...[
            if (i > 0) const Divider(height: AppSpacing.xl),
            _questionItem(context, g.items[i]),
          ],
        ],
      ),
    );
  }

  Widget _questionItem(BuildContext context, QuestionItem q) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AppText('“${q.question}”', style: AppTypography.bodyStrong),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: AppSize.iconSm),
              tooltip: '이 질문 복사',
              onPressed: () => _copy(context, q.question),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        AppText(q.why, style: AppTypography.caption),
        const SizedBox(height: AppSpacing.md),
        _answerGuide(
          '이런 답이면 안심',
          q.safeAnswer,
          AppColors.ok,
          AppColors.okSoft,
          Icons.check_circle_outline,
        ),
        const SizedBox(height: AppSpacing.xs),
        _answerGuide(
          '이런 답이면 보류',
          q.riskyAnswer,
          AppColors.caution,
          AppColors.cautionSoft,
          Icons.error_outline,
        ),
      ],
    );
  }

  Widget _answerGuide(
    String label,
    String text,
    Color color,
    Color bg,
    IconData icon,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: AppSize.iconSm, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(label, style: AppTypography.label.copyWith(color: color)),
                const SizedBox(height: 2),
                AppText(text, style: AppTypography.body),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _copy(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    _toast(context, '복사했어요. 중개사무소에서 그대로 보여주세요');
  }

  void _copyAll(BuildContext context, List<QuestionGroup> groups) {
    final buffer = StringBuffer();
    for (final g in groups) {
      buffer.writeln('[${g.riskLabel}]');
      for (final q in g.items) {
        buffer.writeln('- ${q.question}');
      }
      buffer.writeln();
    }
    Clipboard.setData(ClipboardData(text: buffer.toString().trim()));
    _toast(context, '복사했어요. 중개사무소에서 그대로 보여주세요');
  }

  void _toast(BuildContext context, String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: AppText(m)));
}
