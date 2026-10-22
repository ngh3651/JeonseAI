/// 대조 결과 → **지금 할 일** 카드 (2026-10-22, P1-2).
///
/// 대조 결과 화면 맨 위에 하나만 뜬다. 결과를 읽고 "그래서 뭘 하라는 거지?"에서 멈추지 않게.
///
///   - 위험 줄이 있는 `changed` → **잔금 보내기 전에 멈추세요** + 중개사에게 보낼 문자 복사 + 상담처
///   - 달라진 위험이 없는 `changed` → **입금 전 마지막 체크리스트** (여정 데이터의 잔금 단계 항목)
///   - `partial` → **다시 찍기**
///   - 기준 없음·다른 집 → 카드 없음 (그 화면이 이미 할 일 하나만 말한다)
///
/// ⚠ 여기서 **새 판정을 만들지 않는다.** 어느 카드를 띄울지는 서버가 준 결과(`result`)와
///   줄의 색(`tone`)만 보고 정한다. 문자에 넣는 말도 서버가 준 줄 제목과 서버의 질문 템플릿
///   (`GET /api/reports/{id}/questions`, data/questions.json)뿐이다. 새 수치는 없다.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/compare_result.dart';
import '../../models/content_models.dart';
import '../../repositories/content_repository.dart';
import '../pricing/guardian_pass_widgets.dart';

/// 대조 결과 다음에 할 일 — 세 가지.
enum CompareNextStep {
  /// 위험 줄이 있다 — 잔금을 보내기 전에 멈춘다
  stopBeforeBalance,

  /// 다 맞춰봤고 위험 줄이 없다 — 입금 전 마지막 체크리스트
  finalChecklist,

  /// 일부를 못 봤다 — 다시 찍는다
  recapture,
}

/// 결과 → 할 일. **판정이 아니라 서버 결과의 갈래만 옮긴다** (위험 줄 = `tone: danger`).
CompareNextStep? compareNextStepFor(CompareResult result) =>
    switch (result.outcome) {
      CompareOutcome.changed =>
        result.rows.any((r) => r.tone == CompareTone.danger)
            ? CompareNextStep.stopBeforeBalance
            : CompareNextStep.finalChecklist,
      CompareOutcome.partial => CompareNextStep.recapture,
      CompareOutcome.noBaseline || CompareOutcome.differentProperty => null,
    };

/// 상담처 — 앱·서버에 **이미 있는 문구**만 쓴다(서버 fallback_texts.py의 '위험' 다음 할 일과 같은 말).
/// 전화번호·주소(링크)는 공식 확인 전이라 넣지 않는다(decisions.md 2026-07 "상담처 실제 링크/전화").
const String kCounselingLine =
    'HUG(주택도시보증공사) 안심전세포털·대한법률구조공단 등에서 전문가 상담을 받을 수 있어요';

/// 문자에 담는 질문 수 — 판정과 무관한 화면 분량(문자 한 통에 읽히는 길이).
const int kBrokerMessageMaxQuestions = 4;

/// 중개사에게 보낼 문자. 서버가 준 **위험 줄 제목** + 서버의 **질문 템플릿**만 엮는다.
///
/// 이름은 넣지 않는다(위험 줄 제목·빚 줄 첫 줄에는 사람 이름이 없다 — 집주인 줄의 상세는 넣지 않는다).
String brokerMessageFor(CompareResult result, List<QuestionGroup> groups) {
  final b = StringBuffer()
    ..writeln('안녕하세요. 잔금 보내기 전에 등기부를 다시 떼어 보니 처음 서류와 달라진 점이 있어 여쭤봅니다.');
  final String? address = result.baseline.address?.trim();
  if (address != null && address.isNotEmpty) b.writeln('집: $address');
  b.writeln();
  for (final row in result.rows.where((r) => r.tone == CompareTone.danger)) {
    // 새로 생긴 빚은 무엇이 생겼는지(서버 상세의 첫 줄 — "근저당권 1건 · 채권최고액 …")까지 적는다
    final String? first = row.kind == CompareRowKind.added
        ? row.detail?.split('\n').first.trim()
        : null;
    b.writeln(first == null || first.isEmpty ? '- ${row.title}' : '- ${row.title} ($first)');
  }
  // 문자 한 통에 담기게 앞에서부터 [kBrokerMessageMaxQuestions]개만 (전체는 질문 생성기 화면에 있다)
  final questions = [
    for (final g in groups)
      for (final q in g.items) q.question,
  ].take(kBrokerMessageMaxQuestions).toList();
  if (questions.isNotEmpty) {
    b
      ..writeln()
      ..writeln('확인 부탁드려요:');
    for (final q in questions) {
      b.writeln('- $q');
    }
  }
  b
    ..writeln()
    ..write('확인한 뒤에 잔금을 보내려고 해요.');
  return b.toString();
}

/// 대조 결과 맨 위 카드. [step]이 할 일을 정한다.
class CompareNextStepCard extends StatelessWidget {
  const CompareNextStepCard({
    super.key,
    required this.step,
    required this.result,
    required this.reportId,
    required this.onRecapture,
    required this.onBackToJourney,
  });

  final CompareNextStep step;
  final CompareResult result;

  /// 질문 템플릿을 받을 리포트 — 이번에 뗀 서류의 리포트(없으면 기준 리포트)
  final String reportId;
  final VoidCallback onRecapture;
  final VoidCallback onBackToJourney;

  @override
  Widget build(BuildContext context) {
    return switch (step) {
      CompareNextStep.stopBeforeBalance => _StopCard(
        result: result,
        reportId: reportId,
      ),
      CompareNextStep.finalChecklist => _ChecklistCard(
        onBackToJourney: onBackToJourney,
      ),
      CompareNextStep.recapture => _RecaptureCard(onRecapture: onRecapture),
    };
  }
}

/// 카드 공통 틀 — 왼쪽 굵은 띠 + 연한 바탕. "지금 할 일" 머리말이 늘 붙는다.
class _StepFrame extends StatelessWidget {
  const _StepFrame({
    required this.color,
    required this.soft,
    required this.icon,
    required this.title,
    required this.children,
  });

  final Color color;
  final Color soft;
  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: soft,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border(left: BorderSide(color: color, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: AppText(
                  '지금 할 일',
                  style: AppTypography.label.copyWith(color: color),
                ),
              ),
              // 계약 지킴이 패스가 있으면 다시 대조에도 표시만 (2026-10-22, P2-1)
              const GuardianPassBadge(),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: AppSize.iconMd, color: color),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppText(
                  title,
                  style: AppTypography.headline.copyWith(color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          ...children,
        ],
      ),
    );
  }
}

// ── ① 잔금 보내기 전에 멈추세요 ─────────────────────────────────────────────

class _StopCard extends StatefulWidget {
  const _StopCard({required this.result, required this.reportId});

  final CompareResult result;
  final String reportId;

  @override
  State<_StopCard> createState() => _StopCardState();
}

class _StopCardState extends State<_StopCard> {
  bool _copying = false;

  static const Duration _questionsTimeout = Duration(seconds: 8);

  Future<void> _copyMessage() async {
    setState(() => _copying = true);
    List<QuestionGroup> groups = const [];
    try {
      // 질문은 서버 템플릿 그대로 — 못 받아도 달라진 점만으로 문자를 만든다
      final repo = context.read<ContentRepository?>();
      if (repo != null) {
        groups = await repo
            .questionGroups(widget.reportId)
            .timeout(_questionsTimeout);
      }
    } catch (e) {
      debugPrint('[지금 할 일] 질문을 받지 못해 달라진 점만 복사합니다 (${e.runtimeType})');
    }
    final String message = brokerMessageFor(widget.result, groups);
    try {
      await Clipboard.setData(ClipboardData(text: message));
    } catch (e) {
      debugPrint('[지금 할 일] 복사하지 못했어요 (${e.runtimeType})');
    }
    if (!mounted) return;
    setState(() => _copying = false);
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: AppText('복사했어요. 문자나 카톡 창에 붙여 넣어 중개사에게 보내세요'),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    // 달라진 줄은 바로 아래 카드들이 하나씩 보여 준다 — 여기서는 되풀이하지 않고 할 일만 말한다.
    return _StepFrame(
      color: AppColors.danger,
      soft: AppColors.dangerSoft,
      icon: Icons.pan_tool_outlined,
      title: '잔금 보내기 전에 멈추세요',
      children: [
        AppText(
          '아래 달라진 점을 중개사·집주인에게 확인하기 전에는 돈을 보내지 마세요',
          style: AppTypography.body,
        ),
        const SizedBox(height: AppSpacing.md),
        AppPrimaryButton(
          label: '중개사에게 보낼 문자 복사',
          icon: Icons.content_copy,
          loading: _copying,
          onPressed: _copying ? null : _copyMessage,
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.support_agent,
              size: AppSize.iconSm,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: AppSpacing.sm),
            const Expanded(
              child: AppText(kCounselingLine, style: AppTypography.caption),
            ),
          ],
        ),
      ],
    );
  }
}

// ── ② 입금 전 마지막 체크리스트 ────────────────────────────────────────────

class _ChecklistCard extends StatefulWidget {
  const _ChecklistCard({required this.onBackToJourney});

  final VoidCallback onBackToJourney;

  @override
  State<_ChecklistCard> createState() => _ChecklistCardState();
}

class _ChecklistCardState extends State<_ChecklistCard> {
  /// 여정 데이터(서버 journey_stages.json)의 '잔금 보내는 날' 항목. 못 받으면 null.
  Future<List<JourneyItem>>? _items;

  @override
  void initState() {
    super.initState();
    final repo = context.read<ContentRepository?>();
    if (repo != null) {
      _items = repo.journeyStages().then(
        (stages) => [
          for (final s in stages)
            if (s.isBalance) ...s.items,
        ],
      );
    }
  }

  /// 등기부 대조는 **방금 했다** — 여정의 그 항목은 체크된 모양으로 그린다.
  static bool _isRegistryCheck(JourneyItem item) => item.text.contains('등기부');

  @override
  Widget build(BuildContext context) {
    return _StepFrame(
      color: AppColors.primary,
      soft: AppColors.primarySoft,
      icon: Icons.checklist,
      title: '입금 전 마지막 체크리스트',
      children: [
        FutureBuilder<List<JourneyItem>>(
          future: _items,
          builder: (context, snapshot) {
            final items = snapshot.data ?? const <JourneyItem>[];
            if (items.isEmpty) {
              // 목록을 못 받아도 할 일은 말한다 — 여정 화면의 잔금 단계가 같은 목록이다
              return AppText(
                '등기부는 방금 대조했어요. 잔금 단계에서 확인할 것을 마저 보세요',
                style: AppTypography.body,
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in items) ...[
                  _checkRow(item),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        AppTonalButton(
          label: '잔금 단계로 돌아가기',
          icon: Icons.arrow_back,
          onPressed: widget.onBackToJourney,
        ),
      ],
    );
  }

  Widget _checkRow(JourneyItem item) {
    final bool done = _isRegistryCheck(item);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          done ? Icons.check_circle : Icons.radio_button_unchecked,
          size: AppSize.iconSm,
          color: done ? AppColors.primary : AppColors.textMuted,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(
                done ? '${item.text} — 방금 했어요' : item.text,
                style: AppTypography.bodyStrong,
              ),
              const SizedBox(height: 2),
              AppText(item.why, style: AppTypography.caption),
            ],
          ),
        ),
      ],
    );
  }
}

// ── ③ 다시 찍기 ──────────────────────────────────────────────────────────

class _RecaptureCard extends StatelessWidget {
  const _RecaptureCard({required this.onRecapture});

  final VoidCallback onRecapture;

  @override
  Widget build(BuildContext context) {
    return _StepFrame(
      color: AppColors.caution,
      soft: AppColors.cautionSoft,
      icon: Icons.photo_camera_outlined,
      title: '빠진 쪽을 다시 찍어 주세요',
      children: [
        AppText(
          '다 맞춰보기 전에는 "그대로"라고 말할 수 없어요. 빠진 쪽을 찍어 올리면 다시 대조해요',
          style: AppTypography.body,
        ),
        const SizedBox(height: AppSpacing.md),
        AppPrimaryButton(
          label: '다시 찍기',
          icon: Icons.photo_camera,
          onPressed: onRecapture,
        ),
      ],
    );
  }
}
