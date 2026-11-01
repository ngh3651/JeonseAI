/// 대조 결과 → **지금 할 일** 카드 (2026-10-22, P1-2 · 2026-10-23 결선 부스 다듬기).
///
/// 대조 결과 화면에 하나만 뜬다(결론 헤더 바로 아래 — 리포트의 '등급 → 결정' 순서와 같게, D2).
/// 결과를 읽고 "그래서 뭘 하라는 거지?"에서 멈추지 않게.
///
///   - 위험 줄이 있는 `changed` → **잔금 보내기 전에 멈추세요** + 달라진 점 한 줄 + 중개사에게 보내기 + 상담처 (가족에게 보내기는 2026-10-26에 뺐다)
///   - 달라진 위험이 없는 `changed` → **입금 전 마지막 체크리스트** (여정 데이터의 잔금 단계 항목)
///   - `partial` → **빠진 쪽만 더 찍기** (먼저 찍은 장은 그대로 두고 새 장을 덧붙여 다시 대조)
///   - 기준 없음·다른 집 → 카드 없음 (그 화면이 이미 할 일 하나만 말한다)
///
/// 폰에 저장된 **잔금일이 이미 지났으면**(서연 리뷰 #3) 문구만 바꾼다 — "잔금 보내기 전"이라고 말하지 않는다.
/// 어느 카드를 띄울지(판정)는 그대로다.
///
/// ⚠ 여기서 **새 판정을 만들지 않는다.** 어느 카드를 띄울지는 서버가 준 결과(`result`)와
///   줄의 색(`tone`)만 보고 정한다. 문자에 넣는 말도 서버가 준 줄 제목·상세 첫 줄과 서버의 질문 템플릿
///   (`GET /api/reports/{id}/questions`, data/questions.json)뿐이다. 새 수치는 없다.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/text/phrase_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/compare_result.dart';
import '../../models/content_models.dart';
import '../../repositories/content_repository.dart';
import '../../services/text_share.dart';
import '../../utils/korean_date.dart';
import '../pricing/guardian_pass_widgets.dart';

/// 대조 결과 다음에 할 일 — 세 가지.
enum CompareNextStep {
  /// 위험 줄이 있다 — 잔금을 보내기 전에 멈춘다
  stopBeforeBalance,

  /// 다 맞춰봤고 위험 줄이 없다 — 입금 전 마지막 체크리스트
  finalChecklist,

  /// 일부를 못 봤다 — 빠진 쪽만 더 찍는다
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

/// 상담처 줄 끝 — 링크가 없으니 찾는 법을 말한다(지수 리뷰 #8: "어디로 가라는 건지 모르겠어요").
const String kCounselingSearchHint = "(검색창에 '안심전세포털'을 쳐 보세요)";

/// 멈춤 카드의 다음 행동 — 여정 데이터의 "구두 약속은 지켜지지 않을 수 있어요"(journey_stages.json)를
/// 그날 할 일로 옮긴 말이다(지수 #8 · 서연 #2).
const String kDontTrustVerbalLine =
    "'괜찮아요'라는 말만 듣고 보내지 마세요. 답을 문자로 받아 두고, 아래 상담처에 먼저 물어보세요.";

/// 잔금을 이미 보낸 뒤 — 같은 뜻에서 "보내지 마세요"만 뺀다.
const String kDontTrustVerbalLineAfterBalance =
    "'괜찮아요'라는 말만 믿지 마세요. 답을 문자로 받아 두고, 아래 상담처에 먼저 물어보세요.";

/// 문자에 담는 질문 수 — 판정과 무관한 화면 분량(문자 한 통에 읽히는 길이).
const int kBrokerMessageMaxQuestions = 4;

/// 서버가 준 **위험 줄**을 한 줄씩 — "새로 생긴 빚이 있어요 (근저당권 1건 · 채권최고액 …)" · "집주인이 달라요".
///
/// 새로 생긴 빚은 무엇이 생겼는지(서버 상세의 첫 줄)까지 붙인다. 집주인 줄의 상세(가린 이름)는 넣지 않는다.
List<String> dangerSummaryFor(CompareResult result) => [
  for (final row in result.rows.where((r) => r.tone == CompareTone.danger))
    () {
      final String? first = row.kind == CompareRowKind.added
          ? row.detail?.split('\n').first.trim()
          : null;
      return first == null || first.isEmpty
          ? row.title
          : '${row.title} ($first)';
    }(),
];

/// 두 서류를 뗀 날 — "7월 9일 ↔ 8월 5일". 서버 응답의 열람일만 쓴다. 둘 다 못 읽었으면 null.
String? compareDocumentDates(CompareResult result) {
  final base = parseRegistryViewedAt(result.baseline.viewedAt);
  final now = parseRegistryViewedAt(result.current.viewedAt);
  if (base == null && now == null) return null;
  final left = base == null ? '기준 서류' : formatMonthDay(base);
  final right = now == null ? '이번 서류' : formatMonthDay(now);
  return '$left ↔ $right';
}

/// 중개사에게 보낼 문자. 서버가 준 **위험 줄 제목** + 서버의 **질문 템플릿**만 엮는다.
///
/// 이름은 넣지 않는다(위험 줄 제목·빚 줄 첫 줄에는 사람 이름이 없다 — 집주인 줄의 상세는 넣지 않는다).
/// [balancePassed]면(폰에 저장된 잔금일이 지났다) "잔금 보내기 전"이라고 쓰지 않는다.
String brokerMessageFor(
  CompareResult result,
  List<QuestionGroup> groups, {
  bool balancePassed = false,
}) {
  final b = StringBuffer()
    ..writeln(
      balancePassed
          ? '안녕하세요. 등기부를 다시 떼어 보니 처음 서류와 달라진 점이 있어 여쭤봅니다.'
          : '안녕하세요. 잔금 보내기 전에 등기부를 다시 떼어 보니 처음 서류와 달라진 점이 있어 여쭤봅니다.',
    );
  _writePlace(b, result);
  b.writeln();
  for (final line in dangerSummaryFor(result)) {
    b.writeln('- $line');
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
    ..write(balancePassed ? '답은 문자로 남겨 주시면 고맙겠어요.' : '확인한 뒤에 잔금을 보내려고 해요.');
  return b.toString();
}

/// "집: …" 다음 줄에 "서류: 7월 9일 ↔ 8월 5일 등기부" (서연 리뷰 #2·#6 — 어느 서류끼리 견줬는지).
void _writePlace(StringBuffer b, CompareResult result) {
  final String? address = result.baseline.address?.trim();
  if (address != null && address.isNotEmpty) b.writeln('집: $address');
  final String? dates = compareDocumentDates(result);
  if (dates != null) b.writeln('서류: $dates 등기부');
}

/// 대조 결과의 '지금 할 일' 카드. [step]이 할 일을 정한다.
class CompareNextStepCard extends StatelessWidget {
  const CompareNextStepCard({
    super.key,
    required this.step,
    required this.result,
    required this.reportId,
    required this.onAddMissing,
    this.keptPhotoCount,
    this.balancePassed = false,
  });

  final CompareNextStep step;
  final CompareResult result;

  /// 질문 템플릿을 받을 리포트 — 이번에 뗀 서류의 리포트(없으면 기준 리포트)
  final String reportId;

  /// 빠진 쪽만 더 찍기 — 먼저 찍은 장 뒤에 덧붙여 다시 대조한다(통째로 바꾸지 않는다)
  final VoidCallback onAddMissing;

  /// 먼저 찍은 장수 — 버튼의 "(먼저 찍은 N장은 그대로)". 모르면 괄호를 뺀다.
  final int? keptPhotoCount;

  /// 폰에 저장된 잔금일이 지났나 — 문구만 바꾼다(판정·카드 갈래는 그대로).
  final bool balancePassed;

  @override
  Widget build(BuildContext context) {
    return switch (step) {
      CompareNextStep.stopBeforeBalance => _StopCard(
        result: result,
        reportId: reportId,
        balancePassed: balancePassed,
      ),
      // 여정으로 돌아가는 버튼은 화면 맨 아래에 이미 있다 — 카드에 같은 버튼을 겹쳐 두지 않는다(D3)
      CompareNextStep.finalChecklist => _ChecklistCard(
        balancePassed: balancePassed,
      ),
      CompareNextStep.recapture => _RecaptureCard(
        onAddMissing: onAddMissing,
        keptPhotoCount: keptPhotoCount,
      ),
    };
  }
}

/// 카드 공통 틀 — 왼쪽 굵은 띠 + 연한 바탕. "지금 할 일" 머리말이 늘 붙는다.
///
/// 글자는 진한 글자색(textStrong/textBody), 카드 색(빨강·앰버·초록)은 띠·아이콘에만 —
/// 연한 바탕 위 같은 계열 글자는 대비가 모자라다(D8). 제목은 title 크기(D2).
class _StepFrame extends StatelessWidget {
  const _StepFrame({
    required this.color,
    required this.soft,
    required this.icon,
    required this.title,
    required this.children,
    this.showPassBadge = true,
  });

  final Color color;
  final Color soft;
  final IconData icon;
  final String title;
  final List<Widget> children;

  /// 계약 지킴이 패스 표시 — 빨간 멈춤 카드에서는 숨긴다(초록 '패스'가 '보호됨'으로 읽힌다, D2).
  final bool showPassBadge;

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
                  style: AppTypography.label.copyWith(
                    color: AppColors.textStrong,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              // 계약 지킴이 패스가 있으면 다시 대조에도 표시만 (2026-10-22, P2-1)
              if (showPassBadge) const GuardianPassBadge(),
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
                  style: AppTypography.title.copyWith(
                    color: AppColors.textStrong,
                    fontWeight: FontWeight.w700,
                  ),
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
  const _StopCard({
    required this.result,
    required this.reportId,
    required this.balancePassed,
  });

  final CompareResult result;
  final String reportId;
  final bool balancePassed;

  @override
  State<_StopCard> createState() => _StopCardState();
}

class _StopCardState extends State<_StopCard> {
  bool _sending = false;

  static const Duration _questionsTimeout = Duration(seconds: 8);

  /// [중개사에게 보내기] — 문자를 만들어 **복사해 두고** 공유 창을 연다(서연 리뷰 #6: 복사만으로는 한 단계가 더 있었다).
  Future<void> _sendToBroker() async {
    setState(() => _sending = true);
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
      debugPrint('[지금 할 일] 질문을 받지 못해 달라진 점만 담습니다 (${e.runtimeType})');
    }
    final String message = brokerMessageFor(
      widget.result,
      groups,
      balancePassed: widget.balancePassed,
    );
    await _copyAndShare(message);
    if (mounted) setState(() => _sending = false);
  }

  Future<void> _copyAndShare(String message) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    var copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: message));
      copied = true;
    } catch (e) {
      debugPrint('[지금 할 일] 복사하지 못했어요 (${e.runtimeType})');
    }
    final outcome = await TextShare.share(message);
    final String text = switch (outcome) {
      TextShareOutcome.opened when copied => '복사도 해 뒀어요 — 문자나 카톡 창에 붙여 넣어도 돼요',
      TextShareOutcome.opened => '공유 창을 열었어요',
      TextShareOutcome.copied => '공유 창을 열지 못해 복사해 뒀어요. 문자나 카톡 창에 붙여 넣어 주세요',
      TextShareOutcome.failed when copied =>
        '공유 창을 열지 못했어요. 복사해 둔 글을 문자나 카톡 창에 붙여 넣어 주세요',
      TextShareOutcome.failed => '보내지 못했어요. 잠시 후 다시 눌러 주세요',
    };
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: AppText(text)));
  }

  @override
  Widget build(BuildContext context) {
    final bool passed = widget.balancePassed;
    final List<String> changes = dangerSummaryFor(widget.result);
    // 달라진 줄 하나하나는 아래 카드들이 보여 준다 — 여기서는 한 줄 요약 + 할 일만 말한다.
    return _StepFrame(
      color: AppColors.danger,
      soft: AppColors.dangerSoft,
      icon: Icons.pan_tool_outlined,
      title: passed ? '새로 생긴 빚을 오늘 바로 확인하세요' : '잔금 보내기 전에 멈추세요',
      showPassBadge: false,
      children: [
        AppText(
          passed
              ? '이미 잔금을 보냈다면 오늘 중개사·집주인에게 확인하고 아래 상담처에 물어보세요'
              : '아래 달라진 점을 중개사·집주인에게 확인하기 전에는 돈을 보내지 마세요',
          style: AppTypography.body,
        ),
        if (changes.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          // ' · '로 이은 목록이다 — 덩어리 사이에서만 줄을 바꾼다(2026-11-01)
          PhraseText(
            '달라진 점: ${changes.join(' · ')}',
            key: const ValueKey('stop-card-changes'),
            style: AppTypography.bodyStrong,
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        AppText(
          passed ? kDontTrustVerbalLineAfterBalance : kDontTrustVerbalLine,
          style: AppTypography.body,
        ),
        const SizedBox(height: AppSpacing.md),
        AppPrimaryButton(
          label: '중개사에게 보내기',
          icon: Icons.send_outlined,
          loading: _sending,
          onPressed: _sending ? null : _sendToBroker,
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.support_agent,
              size: AppSize.iconSm,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: AppText(
                '$kCounselingLine $kCounselingSearchHint',
                style: AppTypography.caption.copyWith(
                  color: AppColors.textBody,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── ② 입금 전 마지막 체크리스트 ────────────────────────────────────────────

class _ChecklistCard extends StatefulWidget {
  const _ChecklistCard({required this.balancePassed});

  final bool balancePassed;

  @override
  State<_ChecklistCard> createState() => _ChecklistCardState();
}

class _ChecklistCardState extends State<_ChecklistCard> {
  /// 여정 데이터(서버 journey_stages.json)의 항목 — 잔금 전이면 '잔금 보내는 날', 지났으면 '입주 다음 날'. 못 받으면 null.
  Future<List<JourneyItem>>? _items;

  @override
  void initState() {
    super.initState();
    final repo = context.read<ContentRepository?>();
    if (repo != null) {
      final bool passed = widget.balancePassed;
      _items = repo.journeyStages().then(
        (stages) => [
          for (final s in stages)
            if (passed ? s.dateKey == JourneyDateKey.moveInNext : s.isBalance)
              ...s.items,
        ],
      );
    }
  }

  /// 등기부 대조는 **방금 했다** — 여정의 그 항목은 체크된 모양으로 그린다.
  static bool _isRegistryCheck(JourneyItem item) => item.text.contains('등기부');

  @override
  Widget build(BuildContext context) {
    final bool passed = widget.balancePassed;
    return _StepFrame(
      color: AppColors.primary,
      soft: AppColors.primarySoft,
      icon: Icons.checklist,
      title: passed ? '입주 뒤 확인 끝' : '입금 전 마지막 체크리스트',
      children: [
        FutureBuilder<List<JourneyItem>>(
          future: _items,
          builder: (context, snapshot) {
            final items = snapshot.data ?? const <JourneyItem>[];
            if (items.isEmpty) {
              // 목록을 못 받아도 할 일은 말한다 — 여정 화면의 잔금 단계가 같은 목록이다
              return AppText(
                passed
                    ? '등기부는 방금 대조했어요. 계약 여정에서 남은 단계를 마저 보세요'
                    : '등기부는 방금 대조했어요. 잔금 단계에서 확인할 것을 마저 보세요',
                style: AppTypography.body,
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppSpacing.sm),
                  _checkRow(items[i]),
                ],
              ],
            );
          },
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
              AppText(
                item.why,
                style: AppTypography.caption.copyWith(
                  color: AppColors.textBody,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── ③ 빠진 쪽만 더 찍기 ──────────────────────────────────────────────────

class _RecaptureCard extends StatelessWidget {
  const _RecaptureCard({required this.onAddMissing, this.keptPhotoCount});

  final VoidCallback onAddMissing;
  final int? keptPhotoCount;

  @override
  Widget build(BuildContext context) {
    final int? kept = keptPhotoCount;
    return _StepFrame(
      color: AppColors.caution,
      soft: AppColors.cautionSoft,
      icon: Icons.photo_camera_outlined,
      title: '빠진 쪽만 더 찍어 주세요',
      children: [
        AppText(
          '다 맞춰보기 전에는 "그대로"라고 말할 수 없어요. '
          '빠진 쪽만 더 찍으면 먼저 찍은 장과 합쳐 다시 대조해요',
          style: AppTypography.body,
        ),
        const SizedBox(height: AppSpacing.md),
        AppPrimaryButton(
          label: kept == null || kept <= 0
              ? '빠진 쪽만 더 찍기'
              : '빠진 쪽만 더 찍기 (먼저 찍은 $kept장은 그대로)',
          icon: Icons.photo_camera,
          onPressed: onAddMissing,
        ),
      ],
    );
  }
}
