/// S-11 계약 여정 체크리스트 (탭) — IA.md §6.
///
/// 첫 진입 "지금 어디쯤이세요?" 단계 선택 → 해당 단계 강조. 단계 아코디언(부제 + 할 일 체크
/// + "왜 해야 하나요?"). 체크 상태는 데모에서 메모리 보관(회원=로컬 저장 자리 — E/D에서 영속화).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_card.dart';
import '../../design_system/components/app_pill.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/content_models.dart';
import '../../repositories/content_repository.dart';

class JourneyScreen extends StatefulWidget {
  const JourneyScreen({super.key, this.showBack = false});

  /// 리포트에서 push로 열릴 때 true — 뒤로가기 버튼을 보인다 (탭 루트일 땐 false).
  final bool showBack;

  @override
  State<JourneyScreen> createState() => _JourneyScreenState();
}

class _JourneyScreenState extends State<JourneyScreen> {
  List<JourneyStage> _stages = const [];
  bool _loading = true;
  bool _failed = false;

  int? _currentStage; // 선택 전 null → "지금 어디쯤이세요?"
  final Set<String> _checked = {}; // "stageIndex:itemIndex"

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final stages = await context.read<ContentRepository>().journeyStages();
      if (!mounted) return;
      setState(() {
        _stages = stages;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('계약 여정'),
        automaticallyImplyLeading: widget.showBack,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
          ? _error()
          : _currentStage == null
          ? _stagePicker()
          : _checklist(),
    );
  }

  Widget _error() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '단계를 불러오지 못했어요\n서버 연결을 확인해 주세요',
            style: AppTypography.body,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.lg),
          AppCompactButton(
            label: '다시 시도',
            icon: Icons.refresh,
            onPressed: _load,
          ),
        ],
      ),
    );
  }

  Widget _stagePicker() {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        Text('지금 어디쯤이세요?', style: AppTypography.headline),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '계약 전부터 보증금 반환까지, 지금 단계에 맞춰 할 일을 안내해 드려요',
          style: AppTypography.caption,
        ),
        const SizedBox(height: AppSpacing.lg),
        for (int i = 0; i < _stages.length; i++) ...[
          AppCard(
            onTap: () => setState(() => _currentStage = i),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_stages[i].title, style: AppTypography.bodyStrong),
                      const SizedBox(height: AppSpacing.xs),
                      Text(_stages[i].subtitle, style: AppTypography.caption),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppColors.textMuted),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }

  Widget _checklist() {
    return Column(
      children: [
        Material(
          color: AppColors.primarySoft,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenPadding,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '현재 단계를 바꾸려면 여기를 눌러요',
                    style: AppTypography.caption,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _currentStage = null),
                  child: const Text('단계 변경'),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            itemCount: _stages.length,
            itemBuilder: (context, i) => _stageTile(i),
          ),
        ),
      ],
    );
  }

  Widget _stageTile(int i) {
    final stage = _stages[i];
    final bool isCurrent = i == _currentStage;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: isCurrent ? AppColors.primary : AppColors.line,
          width: isCurrent ? 1.5 : 1,
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: isCurrent,
          shape: const Border(),
          title: Row(
            children: [
              if (isCurrent) ...[
                const AppPill(
                  label: '현재',
                  color: AppColors.primary,
                  background: AppColors.primarySoft,
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(child: Text(stage.title, style: AppTypography.title)),
            ],
          ),
          subtitle: Text(stage.subtitle, style: AppTypography.caption),
          childrenPadding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          children: [
            for (int j = 0; j < stage.items.length; j++)
              _checkItem(i, j, stage.items[j]),
          ],
        ),
      ),
    );
  }

  Widget _checkItem(int stageIdx, int itemIdx, JourneyItem item) {
    final key = '$stageIdx:$itemIdx';
    final bool checked = _checked.contains(key);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          value: checked,
          onChanged: (v) => setState(() {
            if (v ?? false) {
              _checked.add(key);
            } else {
              _checked.remove(key);
            }
          }),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          activeColor: AppColors.primary,
          title: Text(item.text, style: AppTypography.body),
        ),
        Padding(
          padding: const EdgeInsets.only(
            left: AppSpacing.xxl,
            bottom: AppSpacing.md,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.help_outline,
                size: AppSize.iconXs,
                color: AppColors.textMuted,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(child: Text(item.why, style: AppTypography.caption)),
            ],
          ),
        ),
      ],
    );
  }
}
