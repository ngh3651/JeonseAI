/// S-11 계약 여정 (탭) — 2026-10-26 확정 시안 (그림 ①~⑥).
///
/// 위에서 아래로: 앱바 → (잔금 배너) → 집 줄 → 리포트 카드 → 내 계약 일정 → 단계별 할 일(칩 줄 + 단계 카드)
/// → 등기부 변동 기록. 하단 탭은 셸이 고정으로 그린다.
///
/// 이 화면의 단 하나의 일: **돈을 보내기 전에 등기부를 다시 떼게 만들고, 그 사이에 무엇이 달라졌는지 보여준다.**
/// - 체크박스 모양은 없다. 이미 고른 단계 칩을 한 번 더 누르면 그 단계 완료가 켜지고 꺼진다.
/// - 판정은 하지 않는다 — 등급은 그 집의 가장 최근 리포트 등급을 보여 주기만 한다.
/// - 날짜·완료·대조 기록은 **이 휴대폰에만** 저장한다 (JourneyScheduleStore · JourneyProgressStore).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/mascot_safe.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/analysis_report.dart';
import '../../models/content_models.dart';
import '../../models/property_reports.dart';
import '../../repositories/analysis_repository.dart';
import '../../repositories/content_repository.dart';
import '../../services/api_client.dart';
import '../../state/journey_progress_store.dart';
import '../../state/journey_schedule_store.dart';
import '../common/analyze_gate.dart';
import '../common/ask_selection.dart';
import '../pricing/guardian_pass_widgets.dart';
import '../search/capture_loop_route.dart';
import 'balance_due_banner.dart';
import 'journey_compare_flow.dart';
import 'journey_logic.dart';
import 'journey_parts.dart';
import 'journey_property_sheet.dart';
import 'journey_reminder_prompt.dart';
import 'journey_schedule_sheet.dart';

/// 예전 이름 — 여정의 집 = 같은 주소 리포트 묶음 ([PropertyReports]).
typedef JourneyProperty = PropertyReports;

class JourneyScreen extends StatefulWidget {
  const JourneyScreen({
    super.key,
    this.showBack = false,
    this.captureOne = defaultCaptureOne,
    this.pickMany = defaultPickMany,
  });

  /// 리포트에서 push로 열릴 때 true — 뒤로가기 버튼을 보인다 (탭 루트일 땐 false).
  final bool showBack;

  /// 카메라·앨범 주입 지점 — 대조할 새 등기부(테스트는 가짜 함수)
  final CaptureOne captureOne;
  final PickMany pickMany;

  @override
  State<JourneyScreen> createState() => _JourneyScreenState();
}

class _JourneyScreenState extends State<JourneyScreen> {
  List<JourneyStage> _stages = const [];
  List<AnalysisReport> _reports = const [];
  bool _loading = true;
  bool _failed = false;
  Object? _loadError;

  /// "집 없이 체크리스트만 볼게요"
  bool _checklistOnly = false;

  /// 고른 단계 (집마다 기억하지 않는다 — 집을 바꾸면 그 집의 현재 단계부터)
  int? _selectedStage;
  String? _selectedFor;

  /// 펼친 [자세히] — 단계를 바꾸면 모두 접힌다
  final Set<int> _openItems = {};

  /// 회색 띠로 바로 간 단계 카드 반짝임
  bool _flash = false;
  Timer? _flashTimer;

  final GlobalKey _stageSectionKey = GlobalKey();
  final ScrollController _chipScroll = ScrollController();

  AnalysisRepository? _analysisRepo;

  @override
  void initState() {
    super.initState();
    // 대조를 하면 같은 집에 **새 리포트**가 생긴다 — 이력 변화를 들어 '최신 리포트'를 바로 바꾼다.
    _analysisRepo = context.read<AnalysisRepository>()
      ..addListener(_reloadHistory);
    _load();
  }

  @override
  void dispose() {
    _analysisRepo?.removeListener(_reloadHistory);
    _flashTimer?.cancel();
    _chipScroll.dispose();
    super.dispose();
  }

  Future<void> _reloadHistory() async {
    try {
      final reports = await _analysisRepo!.getHistory();
      if (!mounted) return;
      setState(() => _reports = reports);
    } catch (_) {
      // 목록 갱신 실패로 보고 있는 화면을 깨뜨리지 않는다(다음 진입에서 다시 시도).
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
      _loadError = null;
    });
    try {
      final content = context.read<ContentRepository>();
      final analysis = context.read<AnalysisRepository>();
      final results = await Future.wait([
        content.journeyStages(),
        analysis.getHistory(),
      ]);
      if (!mounted) return;
      setState(() {
        _stages = results[0] as List<JourneyStage>;
        _reports = results[1] as List<AnalysisReport>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _loadError = e;
      });
    }
  }

  List<PropertyReports> get _properties => groupByProperty(_reports);

  /// 고른 집 — 저장된 선택이 없거나 사라졌으면 첫 집(가장 최근에 분석한 집).
  PropertyReports? _selected(
    List<PropertyReports> properties,
    JourneyScheduleStore store,
  ) {
    if (properties.isEmpty) return null;
    for (final p in properties) {
      if (p.key == store.selectedPropertyKey) return p;
    }
    return properties.first;
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<JourneyScheduleStore>();
    final progressStore = context.watch<JourneyProgressStore>();
    final properties = _properties;
    final PropertyReports? property = _checklistOnly
        ? null
        : _selected(properties, store);

    final Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_failed) {
      body = _error();
    } else if (!_checklistOnly && properties.isEmpty) {
      body = _emptyProperties();
    } else {
      body = _content(property, properties, store, progressStore);
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Column(
          children: [
            JourneyAppBar(showBack: widget.showBack),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 본문
  // ══════════════════════════════════════════════════════════════════════════

  Widget _content(
    PropertyReports? property,
    List<PropertyReports> properties,
    JourneyScheduleStore store,
    JourneyProgressStore progressStore,
  ) {
    final JourneySchedule schedule = property == null
        ? const JourneySchedule()
        : store.scheduleFor(property.key);
    final progress = JourneyProgress(
      stages: _stages,
      schedule: schedule,
      hasProperty: property != null,
      manualDone: property == null
          ? null
          : (i) => progressStore.manualDone(property.key, i),
    );
    if (_stages.isEmpty) return const SizedBox.shrink();

    // 집이 바뀌면 그 집의 현재 단계부터
    final String forKey = property?.key ?? '';
    if (_selectedFor != forKey ||
        _selectedStage == null ||
        _selectedStage! >= _stages.length) {
      _selectedFor = forKey;
      _selectedStage = progress.initialSelection.clamp(0, _stages.length - 1);
      _openItems.clear();
    }
    final int selected = _selectedStage!;
    final banner = property == null ? null : journeyBannerFor(schedule);
    final logs = property == null
        ? const <CompareLogEntry>[]
        : progressStore.logFor(property.key);

    // 글자를 꾹 눌러 [챗봇에 묻기] (2026-10-26)
    return AskSelectionArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenPadding,
          8,
          AppSpacing.screenPadding,
          32,
        ),
        children: [
          if (property != null && banner != null) ...[
            BalanceDueBanner(
              title: banner.title,
              message: banner.message,
              legalNote: banner.legalNote,
              onCompare: () =>
                  _compareFromBanner(property, progress, banner.isMoveInNext),
              onGuide: () => context.push('/guide'),
              onEditSchedule: () => _openScheduleSheet(property, store),
            ),
            const SizedBox(height: 12),
          ],
          if (property != null) ...[
            HouseRow(
              property: property,
              onSwitch: () => _switchHouse(properties, property, store),
            ),
            const SizedBox(height: 12),
            ReportCard(
              property: property,
              latestLog: _latestLog(property, logs),
              recheck: _recheckSpan(progress),
              onOpen: () => context.push('/report/${property.latest.id}'),
              onRecheck: _recheckTarget(progress) == null
                  ? null
                  : () => _jumpToStage(_recheckTarget(progress)!),
            ),
            // 계약 지킴이 패스가 있으면 작은 표시만 (없으면 자리도 없다)
            const GuardianPassBadge(padding: EdgeInsets.only(top: 8)),
            const SizedBox(height: 12),
            ScheduleCard(
              progress: progress,
              onEdit: () => _openScheduleSheet(property, store),
              showNotifyLine: progressStore.notificationsOn == true,
            ),
          ] else
            _noPropertyHeader(),
          const SizedBox(height: 24),
          // ── 단계별 할 일 ──
          Row(
            key: _stageSectionKey,
            children: [
              Expanded(
                child: AppText('단계별 할 일', style: AppTypographyNext.title),
              ),
              AppText(
                '${_stages.length}단계 중 ${progress.stepNumber}단계',
                style: AppTypographyNext.caption.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          StageChipsRow(
            progress: progress,
            selected: selected,
            controller: _chipScroll,
            onTap: (i) =>
                _onChip(i, selected, property, progress, progressStore),
          ),
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: AnimatedBuilder(
                animation: anim,
                child: child,
                builder: (_, c) => Transform.translate(
                  offset: Offset(0, 8 * (1 - anim.value)),
                  child: c,
                ),
              ),
            ),
            child: KeyedSubtree(
              key: ValueKey('stage-card-$selected-$forKey'),
              child: StageCard(
                index: selected,
                progress: progress,
                openItems: _openItems,
                flash: _flash,
                onToggleItem: (i) => setState(
                  () => _openItems.contains(i)
                      ? _openItems.remove(i)
                      : _openItems.add(i),
                ),
                compareSubtitle: property == null
                    ? '먼저 등기부를 분석해 주세요'
                    : '${viewedLabel(property.latest.registryViewedAt)} 리포트와 비교',
                onCompare: () => property == null
                    ? startAnalysis(context)
                    : startJourneyCompare(
                        context,
                        property: property,
                        stageIndex: selected,
                        stageTitle: _stages[selected].title,
                        captureOne: widget.captureOne,
                        pickMany: widget.pickMany,
                      ),
              ),
            ),
          ),
          if (property != null) ...[
            const SizedBox(height: 24),
            ChangeLogCard(
              entries: logs,
              firstAnalysis: property.first.analyzedAt,
              onOpenLatest: () => context.push('/report/${property.latest.id}'),
            ),
          ],
          // 요금제로 가는 입구 (2026-10-22, P2-1) — 패스가 없어도 위 단계·알림·대조는 그대로 쓴다
          const SizedBox(height: 16),
          const GuardianPassEntry(),
        ],
      ),
    );
  }

  /// 최신 리포트를 만든 대조 기록 (리포트 카드 날짜 줄 꼬리말)
  CompareLogEntry? _latestLog(
    PropertyReports property,
    List<CompareLogEntry> logs,
  ) {
    for (final e in logs) {
      if (e.reportId == property.latest.id) return e;
    }
    return null;
  }

  int? _recheckTarget(JourneyProgress progress) {
    if (progress.schedule.isEmpty) return progress.firstOpenCompareIndex;
    return progress.nextRecheckIndex;
  }

  /// 회색 띠 문구 — 일정이 있으면 "10/26 **계약서 날**에 다시 떼기", 없으면 "돈 보내기 전 **다시 떼서 대조**"
  InlineSpan _recheckSpan(JourneyProgress progress) {
    final base = AppTypographyNext.caption.copyWith(
      color: AppColorsNext.textBody,
    );
    final bold = base.copyWith(
      fontWeight: FontWeight.w700,
      color: AppColorsNext.textStrong,
    );
    if (progress.schedule.isEmpty) {
      return TextSpan(
        style: base,
        children: [
          const TextSpan(text: '돈 보내기 전 '),
          TextSpan(text: '다시 떼서 대조', style: bold),
        ],
      );
    }
    final i = progress.nextRecheckIndex;
    if (i == null) return TextSpan(text: '다시 뗄 일정이 없어요', style: base);
    final date = progress.dateOf(i)!;
    return TextSpan(
      style: base,
      children: [
        TextSpan(
          text: '${slashDate(date)} ${recheckDayLabel(_stages[i].dateKey!)}',
          style: bold,
        ),
        const TextSpan(text: '에 다시 떼기'),
      ],
    );
  }

  /// 회색 띠 — 그 단계 카드로 스크롤하고 선택, 테두리가 1.2초 반짝인다.
  void _jumpToStage(int i) {
    setState(() {
      _selectedStage = i;
      _openItems.clear();
      _flash = true;
    });
    final ctx = _stageSectionKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
    _scrollChipIntoView(i);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _flash = false);
    });
  }

  void _scrollChipIntoView(int i) {
    if (!_chipScroll.hasClients) return;
    final target = (i * StageChipsRow.cellWidth - 2 * StageChipsRow.cellWidth)
        .clamp(0.0, _chipScroll.position.maxScrollExtent);
    _chipScroll.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// 칩 누르기 — 다른 칸이면 그 단계로, 이미 고른 칸이면 완료를 켜고 끈다(분석 단계는 늘 완료).
  void _onChip(
    int i,
    int selected,
    PropertyReports? property,
    JourneyProgress progress,
    JourneyProgressStore progressStore,
  ) {
    if (i != selected) {
      setState(() {
        _selectedStage = i;
        _openItems.clear();
      });
      return;
    }
    if (property == null || !progress.canToggle(i)) return;
    HapticFeedback.selectionClick();
    progressStore.setDone(property.key, i, !progress.isDone(i));
  }

  /// 잔금 배너의 [최근 분석과 대조하기] — 잔금(또는 입주 다음 날) 단계로 기록한다.
  void _compareFromBanner(
    PropertyReports property,
    JourneyProgress progress,
    bool moveInNext,
  ) {
    final key = moveInNext ? JourneyDateKey.moveInNext : JourneyDateKey.balance;
    final int index = _stages.indexWhere((s) => s.dateKey == key);
    startJourneyCompare(
      context,
      property: property,
      stageIndex: index < 0 ? null : index,
      stageTitle: index < 0 ? null : _stages[index].title,
      captureOne: widget.captureOne,
      pickMany: widget.pickMany,
    );
  }

  Future<void> _switchHouse(
    List<PropertyReports> properties,
    PropertyReports current,
    JourneyScheduleStore store,
  ) async {
    final pick = await showHouseSwitchSheet(
      context,
      properties: properties,
      selectedKey: current.key,
      store: store,
    );
    if (!mounted || pick == null) return;
    switch (pick) {
      case HousePicked(:final key):
        await store.select(key);
      case HouseNewAnalysis():
        if (mounted) startAnalysis(context);
    }
  }

  Future<void> _openScheduleSheet(
    PropertyReports property,
    JourneyScheduleStore store,
  ) async {
    final saved = await showJourneyScheduleSheet(
      context,
      initial: store.scheduleFor(property.key),
    );
    if (saved == null) return;
    await store.save(property.key, saved);
    if (!mounted) return;
    // 저장한 **그 순간** 알림을 맞춘다 — 꺼져 있으면 이유를 말한 뒤 권한을 묻는다(거절하면 아무 안내도 없다).
    await applyJourneyReminders(
      context,
      propertyKey: property.key,
      alias: property.alias,
      schedule: saved,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 집이 없을 때 · 오류
  // ══════════════════════════════════════════════════════════════════════════

  Widget _error() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MascotSafe(size: 72, state: MascotState.error),
            const SizedBox(height: AppSpacing.lg),
            AppText(
              '여정을 불러오지 못했어요\n${apiErrorHint(_loadError, fallback: '서버 연결을 확인해 주세요')}',
              style: AppTypographyNext.body,
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
      ),
    );
  }

  /// 분석 이력이 0건 — 마스코트(primarySoft 받침 원) + "아직 분석한 집이 없어요" + [먼저 분석하기] + 체크리스트만 보기.
  Widget _emptyProperties() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 112,
              height: 112,
              decoration: const BoxDecoration(
                color: AppColors.primarySoft,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const MascotSafe(size: 84, state: MascotState.tip),
            ),
            const SizedBox(height: 16),
            AppText('아직 분석한 집이 없어요', style: AppTypographyNext.headline),
            const SizedBox(height: 4),
            AppText(
              '등기부를 한 번 분석하면 그 집의 계약 여정이 열려요',
              textAlign: TextAlign.center,
              style: AppTypographyNext.caption,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                onPressed: () => startAnalysis(context),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(kRadiusLg),
                  ),
                ),
                child: AppText(
                  '먼저 분석하기',
                  style: AppTypographyNext.button.copyWith(color: Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() => _checklistOnly = true),
              style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
              child: AppText(
                '집 없이 체크리스트만 볼게요',
                style: AppTypographyNext.caption.copyWith(
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 체크리스트만 보는 모드 — 단계 카드만 보이고, 집을 붙일 입구는 남긴다.
  Widget _noPropertyHeader() {
    final bool hasHouses = _reports.isNotEmpty;
    return JourneyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText('집 없이 보는 중이에요', style: AppTypographyNext.title),
          const SizedBox(height: 4),
          AppText(
            '집을 고르면 그 집의 등기부로 달라진 점까지 맞춰볼 수 있어요',
            style: AppTypographyNext.caption,
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => hasHouses
                ? setState(() => _checklistOnly = false)
                : startAnalysis(context),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              foregroundColor: AppColors.primary,
              side: const BorderSide(color: AppColors.primary, width: 1.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kRadiusMd),
              ),
            ),
            child: AppText(hasHouses ? '집 고르기' : '먼저 분석하기'),
          ),
        ],
      ),
    );
  }
}
