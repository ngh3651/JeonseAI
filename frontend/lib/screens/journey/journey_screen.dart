/// S-11 계약 여정 (탭) — **매물에 붙은 타임라인 + 등기부 대조**.
///
/// 이 화면의 단 하나의 일: **사용자가 잔금을 보내기 전에 등기부를 다시 떼게 만들고,
/// 그 사이에 무엇이 달라졌는지 보여준다.**
///
/// 그래서 예전의 정적 체크리스트에서 두 가지가 바뀌었다:
/// - **체크박스가 없다.** 스스로 체크하는 목록은 "다 봤다"는 기분만 남긴다. 각 단계의
///   핵심 행동은 [다시 떼서 대조하기]이고, 결과는 규칙 엔진이 말해 준다.
/// - **집이 먼저다.** 단계는 집이 정해져야 의미가 생긴다(며칠 지난 등기부인지, 잔금일이
///   언제인지가 전부 그 집의 사실이다).
///
/// 날짜(잔금일 등)는 **이 휴대폰에만** 저장한다 — state/journey_schedule_store.dart.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_pill.dart';
import '../../design_system/components/dashed_border.dart';
import '../../design_system/components/mascot_safe.dart';
import '../../design_system/components/risk_badge.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../models/content_models.dart';
import '../../repositories/analysis_repository.dart';
import '../../repositories/content_repository.dart';
import '../../state/journey_schedule_store.dart';
import '../../utils/korean_date.dart';
import '../common/analyze_gate.dart';
import 'balance_due_banner.dart';
import 'journey_actions.dart';
import 'journey_schedule_sheet.dart';

/// 딥그린 헤더 위에서는 상태바 아이콘도 밝게 (안드로이드 상태바가 초록에 묻히지 않게)
const SystemUiOverlayStyle _kDeepHeaderOverlay = SystemUiOverlayStyle(
  statusBarColor: AppColors.primaryDeep,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
);

/// 아코디언·캐러셀 펼침 시간 (시안 200ms)
const Duration _kExpand = Duration(milliseconds: 200);

/// 매물 하나 = **주소가 같은 분석들의 묶음**.
///
/// 리포트 1건이 아니라 묶음인 이유: 등기부를 다시 떼어 대조하면 같은 집에 분석이
/// 하나 더 생긴다. 그때 카드가 두 장으로 갈라지면 "내 집이 두 채가 됐네?"가 된다.
/// 여정은 **집**에 붙고, 화면이 보여주는 서류는 그 집의 **가장 최근 분석**이다.
class JourneyProperty {
  JourneyProperty({required this.key, required this.reports});

  final String key;

  /// 최신순
  final List<AnalysisReport> reports;

  AnalysisReport get latest => reports.first;
  String get alias => latest.alias;
  String get address => latest.address;

  /// 등기부에 인쇄된 열람일. 못 읽었으면 null — 분석일로 대신 채우지 않는다.
  DateTime? get registryViewedDate =>
      parseRegistryViewedAt(latest.registryViewedAt);

  /// 등기부를 뗀 지 며칠 됐나. 날짜를 못 읽었으면 null.
  int? get registryAgeDays {
    final viewed = registryViewedDate;
    return viewed == null ? null : daysSince(viewed);
  }
}

class JourneyScreen extends StatefulWidget {
  const JourneyScreen({super.key, this.showBack = false});

  /// 리포트에서 push로 열릴 때 true — 뒤로가기 버튼을 보인다 (탭 루트일 땐 false).
  final bool showBack;

  @override
  State<JourneyScreen> createState() => _JourneyScreenState();
}

class _JourneyScreenState extends State<JourneyScreen> {
  List<JourneyStage> _stages = const [];
  List<AnalysisReport> _reports = const [];
  bool _loading = true;
  bool _failed = false;

  /// 기본은 **전부 펼침**(시안). 접은 단계만 기억한다.
  final Set<int> _collapsed = {};

  bool _switcherOpen = false;

  /// "집 없이 체크리스트만 볼게요" — 매물 없이 단계만 훑어보는 모드.
  bool _checklistOnly = false;

  AnalysisRepository? _analysisRepo;

  @override
  void initState() {
    super.initState();
    // 대조를 하면 같은 집에 **새 분석**이 하나 생긴다. 그때 이 화면이 들고 있는 이력이
    // 낡으면 "지금 가진 등기부"가 옛 서류를 계속 가리킨다 — 그래서 이력 변화를 듣는다.
    _analysisRepo = context.read<AnalysisRepository>()..addListener(_reloadHistory);
    _load();
  }

  @override
  void dispose() {
    _analysisRepo?.removeListener(_reloadHistory);
    super.dispose();
  }

  Future<void> _reloadHistory() async {
    try {
      final reports = await _analysisRepo!.getHistory();
      if (!mounted) return;
      setState(() => _reports = reports);
    } catch (_) {
      // 목록 갱신 실패로 지금 보고 있는 화면을 깨뜨리지 않는다(다음 진입에서 다시 시도).
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
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
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  /// 이력(최신순) → 매물 묶음(주소 기준).
  List<JourneyProperty> get _properties {
    final grouped = <String, List<AnalysisReport>>{};
    for (final report in _reports) {
      grouped.putIfAbsent(journeyPropertyKey(report.address), () => []).add(report);
    }
    return [
      for (final entry in grouped.entries)
        JourneyProperty(key: entry.key, reports: entry.value),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<JourneyScheduleStore>();
    final properties = _properties;
    final JourneyProperty? selected = _selected(properties, store);

    final Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_failed) {
      body = _error();
    } else if (_checklistOnly) {
      // 집 없이 단계만 보는 모드 — 이력이 0건이어도 들어올 수 있다.
      body = _timeline(selected, store);
    } else if (properties.isEmpty) {
      body = _emptyProperties();
    } else if (selected == null) {
      body = _picker(properties, store);
    } else {
      body = _timeline(selected, store);
    }

    // 로딩·에러 화면만 밝은 배경이라 상태바 아이콘을 되돌린다.
    final bool darkTop = !_loading && !_failed;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: darkTop ? _kDeepHeaderOverlay : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: selected == null && !_checklistOnly
            ? AppColors.primaryDeep
            : AppColors.background,
        body: body,
      ),
    );
  }

  JourneyProperty? _selected(
    List<JourneyProperty> properties,
    JourneyScheduleStore store,
  ) {
    if (properties.isEmpty) return null;
    for (final p in properties) {
      if (p.key == store.selectedPropertyKey) return p;
    }
    return null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 공통 조각
  // ══════════════════════════════════════════════════════════════════════════

  /// 딥그린 상단 바 — 상태바 영역까지 같은 색으로 덮는다.
  ///
  /// 매물 선택 화면은 시안에서 **제목 줄이 없다**(상태바 아래 바로 오버라인이 온다).
  /// 그때는 색만 덮고 바 자체를 그리지 않는다 — 빈 바를 0px로 눌러 두면 그 안의
  /// 아이콘·글자가 눌린 채로 남는다.
  Widget _deepTopBar({String? title}) {
    final double top = MediaQuery.paddingOf(context).top;
    final bool hasBar = title != null || widget.showBack;
    if (!hasBar) {
      return Container(
        color: AppColors.primaryDeep,
        padding: EdgeInsets.only(top: top),
        child: const SizedBox(width: double.infinity),
      );
    }
    return Container(
      color: AppColors.primaryDeep,
      padding: EdgeInsets.only(top: top),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            if (widget.showBack)
              Semantics(
                button: true,
                label: '뒤로',
                child: InkWell(
                  onTap: () => Navigator.of(context).maybePop(),
                  customBorder: const CircleBorder(),
                  child: const SizedBox(
                    width: AppSize.minTouchTarget,
                    height: AppSize.minTouchTarget,
                    child: Icon(Icons.arrow_back, color: Colors.white),
                  ),
                ),
              )
            else
              const SizedBox(width: AppSize.minTouchTarget),
            Expanded(
              child: AppText(
                title ?? '',
                textAlign: TextAlign.center,
                style: AppTypography.title.copyWith(color: Colors.white),
              ),
            ),
            const SizedBox(width: AppSize.minTouchTarget),
          ],
        ),
      ),
    );
  }

  Widget _error() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MascotSafe(size: 72, state: MascotState.error),
            const SizedBox(height: AppSpacing.lg),
            const AppText(
              '여정을 불러오지 못했어요\n서버 연결을 확인해 주세요',
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
      ),
    );
  }

  /// 분석 이력이 0건 — 여정을 시작할 집 자체가 없다.
  Widget _emptyProperties() {
    final double top = MediaQuery.paddingOf(context).top;
    return Container(
      color: AppColors.primaryDeep,
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        top + AppSpacing.xxl,
        AppSpacing.screenPadding,
        AppSpacing.xxl,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const MascotSafe(size: 72, state: MascotState.tip),
          const SizedBox(height: AppSpacing.lg),
          AppText(
            '아직 분석한 집이 없어요',
            style: AppTypography.headline.copyWith(color: Colors.white),
          ),
          const SizedBox(height: AppSpacing.xs),
          AppText(
            '등기부를 한 번 분석하면 그 집의 계약 여정이 열려요',
            textAlign: TextAlign.center,
            style: AppTypography.caption.copyWith(
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => startAnalysis(context),
              child: const AppText('먼저 분석하기'),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            onPressed: () => setState(() => _checklistOnly = true),
            child: AppText(
              '집 없이 체크리스트만 볼게요',
              style: AppTypography.caption.copyWith(
                color: Colors.white.withValues(alpha: 0.6),
                decoration: TextDecoration.underline,
                decorationColor: Colors.white.withValues(alpha: 0.3),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 화면 1 — 매물 선택
  // ══════════════════════════════════════════════════════════════════════════

  Widget _picker(List<JourneyProperty> properties, JourneyScheduleStore store) {
    return Column(
      children: [
        // 상태바 영역은 이 바가 이미 딥그린으로 덮는다 — 아래 목록에서 또 띄우지 않는다.
        _deepTopBar(title: widget.showBack ? '계약 여정' : null),
        Expanded(
          child: Container(
            color: AppColors.primaryDeep,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenPadding,
                AppSpacing.xxl,
                AppSpacing.screenPadding,
                AppSpacing.xxl + AppSpacing.xs,
              ),
              children: [
                AppText(
                  '계약 여정',
                  style: AppTypography.label.copyWith(
                    color: AppColors.primaryBright,
                    letterSpacing: 1.68, // 12px × .14em
                  ),
                ),
                const SizedBox(height: 6),
                AppText(
                  '어느 집의\n돈을 지킬까요?',
                  style: AppTypography.conclusion.copyWith(
                    fontSize: 28,
                    height: 1.25,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: AppSpacing.xxl),
                // 시안의 섹션 간격 24 — 카드끼리도 같은 간격이다.
                for (final property in properties) ...[
                  _propertyCard(property, store),
                  const SizedBox(height: AppSpacing.xxl),
                ],
                DashedBorder(
                  color: Colors.white.withValues(alpha: 0.24),
                  child: InkWell(
                    onTap: () => startAnalysis(context),
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.add,
                            size: AppSize.iconSm,
                            color: Colors.white.withValues(alpha: 0.7),
                          ),
                          const SizedBox(width: 6),
                          AppText(
                            '다른 집 새로 분석하기',
                            style: AppTypography.buttonSmall.copyWith(
                              color: Colors.white.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xxl),
                Center(
                  child: GestureDetector(
                    onTap: () => setState(() => _checklistOnly = true),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.sm,
                      ),
                      child: AppText(
                        '집 없이 체크리스트만 볼게요',
                        style: AppTypography.caption.copyWith(
                          color: Colors.white.withValues(alpha: 0.5),
                          decoration: TextDecoration.underline,
                          decorationColor: Colors.white.withValues(alpha: 0.2),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _propertyCard(JourneyProperty property, JourneyScheduleStore store) {
    final schedule = store.scheduleFor(property.key);
    final bool started = !schedule.isEmpty;
    final int? age = property.registryAgeDays;

    return Material(
      color: Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        onTap: () => store.select(property.key),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppText(
                          property.alias,
                          style: AppTypography.headline.copyWith(
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        AppText(
                          property.address,
                          style: AppTypography.caption.copyWith(
                            color: Colors.white.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  RiskBadge(grade: property.latest.grade),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              // 등기부 경과일 — **이 화면이 가장 크게 말하는 숫자**
              if (age != null)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    AppText(
                      '$age',
                      style: AppTypography.conclusion.copyWith(
                        fontSize: 34,
                        height: 1,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: AppText(
                        '일 지난 등기부',
                        style: AppTypography.body.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                          color: Colors.white.withValues(alpha: 0.72),
                        ),
                      ),
                    ),
                  ],
                )
              else
                AppText(
                  '등기부를 뗀 날짜를 읽지 못했어요',
                  style: AppTypography.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.72),
                  ),
                ),
              const SizedBox(height: AppSpacing.lg),
              if (started) ...[
                _progressBar(schedule),
                const SizedBox(height: AppSpacing.sm),
              ],
              Row(
                children: [
                  Expanded(
                    child: AppText(
                      _propertyStatusLine(schedule, started),
                      style: AppTypography.label.copyWith(
                        fontWeight: FontWeight.w400,
                        height: 1.45,
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  AppText(
                    '여정 열기',
                    style: AppTypography.buttonSmall.copyWith(
                      color: AppColors.primaryBright,
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: AppColors.primaryBright,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _propertyStatusLine(JourneySchedule schedule, bool started) {
    if (!started) return '아직 시작 안 한 여정';
    final balance = schedule.balance;
    if (balance == null) return '등기부 분석 완료 · 잔금일 미정';
    return '등기부 분석 완료 · 잔금일 ${formatMonthDay(balance)}';
  }

  /// 진행 막대 — **사용자가 넣은 날짜에서만** 칸이 찬다(임의로 채우지 않는다).
  Widget _progressBar(JourneySchedule schedule) {
    final stages = _progressStages;
    return Row(
      children: [
        for (int i = 0; i < stages.length; i++) ...[
          if (i > 0) const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color: _isDone(stages[i], schedule)
                    ? AppColors.primaryBright
                    : Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 진행 막대에 세는 단계 — 1~2년 뒤 일(later)은 뺀다.
  List<JourneyStage> get _progressStages =>
      [for (final s in _stages) if (s.kind != JourneyStageKind.later) s];

  /// 끝난 단계인가 — 분석 단계는 기록이 있으므로 자동, 나머지는 **날짜가 지났는가**로만.
  bool _isDone(JourneyStage stage, JourneySchedule schedule) {
    if (stage.kind == JourneyStageKind.analysis) return true;
    final key = stage.dateKey;
    if (key == null) return false;
    final date = schedule[key];
    if (date == null) return false;
    return daysUntil(date) < 0;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 화면 2 — 타임라인
  // ══════════════════════════════════════════════════════════════════════════

  Widget _timeline(JourneyProperty? property, JourneyScheduleStore store) {
    final JourneySchedule schedule = property == null
        ? const JourneySchedule()
        : store.scheduleFor(property.key);

    return Column(
      children: [
        _deepTopBar(title: '계약 여정'),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              if (property != null)
                _propertyHeader(property, schedule, store)
              else
                _noPropertyHeader(),
              Container(
                color: AppColors.background,
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.screenPadding,
                  AppSpacing.lg,
                  AppSpacing.screenPadding,
                  AppSpacing.xxl + AppSpacing.xs,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (property != null && schedule.balance == null) ...[
                      _askScheduleCard(property, store),
                      const SizedBox(height: AppSpacing.lg),
                    ],
                    if (property != null && schedule.isBalanceTomorrow) ...[
                      BalanceDueBanner(
                        title:
                            '잔금일이 내일이에요 · '
                            '${formatMonthDay(schedule.balance!)}',
                        note: _checkPointNote,
                        onCompare: () =>
                            startRegistryCompare(context, property.latest),
                        onGuide: () => context.push('/guide'),
                        onEditSchedule: () => _openScheduleSheet(property, store),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                    ],
                    for (int i = 0; i < _stages.length; i++)
                      _stageRow(i, property, schedule, store),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 배너 아래 한 줄 — **우리 단계 정의에서 세어 만든 수**다(출처 없는 수치를 쓰지 않는다).
  String get _checkPointNote {
    final int checks =
        1 + _stages.where((s) => s.compare).length; // 처음 분석 + 다시 떼는 단계들
    return '이 앱은 계약 전후로 등기부를 $checks번 확인하도록 안내해요';
  }

  Widget _propertyHeader(
    JourneyProperty property,
    JourneySchedule schedule,
    JourneyScheduleStore store,
  ) {
    return Container(
      color: AppColors.primaryDeep,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        0,
        AppSpacing.screenPadding,
        AppSpacing.screenPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: AppText(
                            property.alias,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.headline.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        RiskBadge(grade: property.latest.grade),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    AppText(
                      property.address,
                      style: AppTypography.caption.copyWith(
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              _switchPropertyButton(),
            ],
          ),
          // 접으면 캐러셀이 트리에서 사라진다 — 안 보이는 카드가 손가락을 먹지 않게.
          AnimatedSize(
            duration: _kExpand,
            alignment: Alignment.topCenter,
            curve: Curves.easeOut,
            child: _switcherOpen
                ? _switcher(property, store)
                : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: AppSpacing.md),
          _registryDateCard(property, schedule),
        ],
      ),
    );
  }

  Widget _switchPropertyButton() {
    return Material(
      color: Colors.white.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(AppRadius.buttonMini),
      child: InkWell(
        onTap: () => setState(() => _switcherOpen = !_switcherOpen),
        borderRadius: BorderRadius.circular(AppRadius.buttonMini),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(11, 7, 9, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppText(
                '집 바꾸기',
                style: AppTypography.label.copyWith(
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
              Icon(
                _switcherOpen ? Icons.expand_less : Icons.expand_more,
                size: AppSize.iconXs + 2,
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 집 바꾸기 캐러셀 — 좌우로 밀어 고른다. 끝에 [새로 분석] 타일.
  Widget _switcher(JourneyProperty current, JourneyScheduleStore store) {
    final properties = _properties;
    // 카드 높이 = 별칭 1줄 + 메타 2줄 + 패딩. 가로 스크롤이라 높이가 고정이어야 하므로
    // **시스템 글꼴 확대 배율을 곱해** 큰 글씨 설정에서도 넘치지 않게 한다.
    final double scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.4);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 100 * scale,
            child: ListView(
              scrollDirection: Axis.horizontal,
              physics: const PageScrollPhysics(),
              children: [
                for (final property in properties) ...[
                  _switcherCard(property, current, store),
                  const SizedBox(width: AppSpacing.md - 2),
                ],
                DashedBorder(
                  color: Colors.white.withValues(alpha: 0.24),
                  radius: AppRadius.md,
                  child: InkWell(
                    onTap: () => startAnalysis(context),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    child: SizedBox(
                      width: 132,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.add,
                            size: AppSize.iconSm,
                            color: Colors.white.withValues(alpha: 0.7),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          AppText(
                            '새로 분석',
                            style: AppTypography.label.copyWith(
                              color: Colors.white.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppText(
            '좌우로 밀어서 고르세요',
            style: AppTypography.label.copyWith(
              fontWeight: FontWeight.w400,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _switcherCard(
    JourneyProperty property,
    JourneyProperty current,
    JourneyScheduleStore store,
  ) {
    final bool on = property.key == current.key;
    final schedule = store.scheduleFor(property.key);
    final balance = schedule.balance;
    final int? age = property.registryAgeDays;
    final String meta = balance != null
        ? '잔금일 ${formatMonthDay(balance)}'
        : (age != null
              ? '${_viewedLabel(property)} · $age일 지남'
              : '등기부 날짜 못 읽음');

    return Material(
      color: Colors.white.withValues(alpha: on ? 0.18 : 0.07),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: () {
          store.select(property.key);
          setState(() {
            _switcherOpen = false;
            _collapsed.clear();
          });
        },
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          width: 186,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: on
                  ? Colors.white.withValues(alpha: 0.45)
                  : Colors.transparent,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: AppText(
                      property.alias,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.body.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  if (on)
                    const Icon(
                      Icons.check_circle,
                      size: 18,
                      color: AppColors.primaryBright,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              AppText(
                meta,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.label.copyWith(
                  fontWeight: FontWeight.w400,
                  height: 1.4,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// "7월 9일자" — 등기부에 인쇄된 열람일. 못 읽었으면 빈 문자열.
  String _viewedLabel(JourneyProperty property) {
    final viewed = property.registryViewedDate;
    return viewed == null ? '' : '${formatMonthDay(viewed)}자';
  }

  /// 지금 가진 등기부 — **항상 발급 날짜 기준으로 말한다**("마지막 확인일" 표기 금지).
  Widget _registryDateCard(
    JourneyProperty property,
    JourneySchedule schedule,
  ) {
    final viewed = property.registryViewedDate;
    final int? age = property.registryAgeDays;
    final balance = schedule.balance;

    final String title = viewed == null
        ? '지금 가진 등기부의 날짜를 읽지 못했어요'
        : '지금 가진 등기부는 ${_viewedLabel(property)}';
    final String note;
    if (balance != null) {
      note = '잔금일 ${formatMonthDay(balance)} · ${relativeDayLabel(balance)}';
    } else if (age != null) {
      note = '오늘까지 $age일 지났어요';
    } else {
      note = '계약 직전에는 새로 떼어 확인하세요';
    }

    return Material(
      color: Colors.white.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: () => context.push('/report/${property.latest.id}'),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      title,
                      style: AppTypography.caption.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    AppText(
                      note,
                      style: AppTypography.label.copyWith(
                        fontWeight: FontWeight.w400,
                        height: 1.45,
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 22,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 매물 없이 단계만 보는 모드의 헤더 — 언제든 집을 붙일 수 있게 입구를 남긴다.
  Widget _noPropertyHeader() {
    return Container(
      color: AppColors.primaryDeep,
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        0,
        AppSpacing.screenPadding,
        AppSpacing.screenPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(
            '집 없이 보는 중이에요',
            style: AppTypography.headline.copyWith(color: Colors.white),
          ),
          const SizedBox(height: AppSpacing.xs),
          AppText(
            '집을 고르면 그 집의 등기부로 달라진 점까지 맞춰볼 수 있어요',
            style: AppTypography.caption.copyWith(
              color: Colors.white.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Material(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.buttonMini),
            child: InkWell(
              onTap: () => setState(() => _checklistOnly = false),
              borderRadius: BorderRadius.circular(AppRadius.buttonMini),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 7,
                ),
                child: AppText(
                  '집 고르기',
                  style: AppTypography.label.copyWith(
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 잔금일이 아직 없을 때만 — "잔금 보내는 날이 언제예요?"
  Widget _askScheduleCard(
    JourneyProperty property,
    JourneyScheduleStore store,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: 18,
        vertical: AppSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppText('잔금 보내는 날이 언제예요?', style: AppTypography.title),
          const SizedBox(height: AppSpacing.md),
          AppTonalButton(
            label: '날짜 넣기',
            icon: Icons.event_outlined,
            onPressed: () => _openScheduleSheet(property, store),
          ),
        ],
      ),
    );
  }

  Future<void> _openScheduleSheet(
    JourneyProperty property,
    JourneyScheduleStore store,
  ) async {
    final saved = await showJourneyScheduleSheet(
      context,
      initial: store.scheduleFor(property.key),
    );
    if (saved == null) return;
    await store.save(property.key, saved);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 단계 카드
  // ══════════════════════════════════════════════════════════════════════════

  /// '현재' 단계 = 아직 지나지 않은 날짜 중 가장 이른 단계. 날짜가 하나도 없으면 없다.
  int? _currentStageIndex(JourneySchedule schedule) {
    int? best;
    int bestDays = 1 << 30;
    for (int i = 0; i < _stages.length; i++) {
      final key = _stages[i].dateKey;
      if (key == null) continue;
      final date = schedule[key];
      if (date == null) continue;
      final days = daysUntil(date);
      if (days >= 0 && days < bestDays) {
        best = i;
        bestDays = days;
      }
    }
    return best;
  }

  Widget _stageRow(
    int index,
    JourneyProperty? property,
    JourneySchedule schedule,
    JourneyScheduleStore store,
  ) {
    final stage = _stages[index];
    final bool open = !_collapsed.contains(index);
    // 1단계 완료는 상태가 아니라 **"분석 기록이 있다"는 사실**이다 — 집이 없으면 미완료.
    final bool done = stage.kind == JourneyStageKind.analysis
        ? property != null
        : _isDone(stage, schedule);
    final bool isCurrent = _currentStageIndex(schedule) == index;
    final bool later = stage.kind == JourneyStageKind.later;
    final bool isBalanceTomorrow = stage.isBalance && schedule.isBalanceTomorrow;

    // ⚠ 세로줄을 [Stack]으로 깐다 — 예전에 `IntrinsicHeight + Row(stretch)`로 그렸더니
    //   카드가 펼쳐지는 **200ms 동안** 카드 높이와 강제된 높이가 어긋나 넘쳤다
    //   (실측: 258px 오버플로). Stack은 카드 높이를 그대로 따라가고, 줄은 Positioned로
    //   그 높이만큼 늘어난다 — 애니메이션 중에도 어긋날 곳이 없다.
    return Stack(
      children: [
        Positioned(
          top: 12, // 도트 한가운데서 시작
          bottom: 0,
          left: 11,
          width: 2,
          child: Container(color: AppColors.line),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _dot(
              number: index + 1,
              done: done,
              current: isCurrent,
              later: later,
              auto: stage.kind == JourneyStageKind.analysis,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Opacity(
                opacity: later ? 0.72 : 1,
                child: Container(
                  margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(
                      color: isCurrent ? AppColors.primary : AppColors.line,
                      width: isCurrent ? 1.5 : 1,
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: 14,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _stageHeader(
                        index: index,
                        stage: stage,
                        schedule: schedule,
                        open: open,
                        isCurrent: isCurrent,
                        isBalanceTomorrow: isBalanceTomorrow,
                      ),
                      // 접으면 **내용이 트리에서 사라진다** — 스크린 리더가 접힌 단계의
                      // 할 일을 읽지 않게(그리고 접힘이 진짜 접힘이 되게).
                      AnimatedSize(
                        duration: _kExpand,
                        alignment: Alignment.topCenter,
                        curve: Curves.easeOut,
                        child: open
                            ? _stageBody(stage, property, schedule, store)
                            : const SizedBox(width: double.infinity),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _stageHeader({
    required int index,
    required JourneyStage stage,
    required JourneySchedule schedule,
    required bool open,
    required bool isCurrent,
    required bool isBalanceTomorrow,
  }) {
    final DateTime? date = stage.dateKey == null ? null : schedule[stage.dateKey!];
    final String subtitle;
    if (isCurrent && date != null) {
      subtitle = '${formatMonthDay(date)} · ${relativeDayLabel(date)}';
    } else if (date != null) {
      subtitle = '${stage.subtitle} · ${formatMonthDay(date)}';
    } else {
      subtitle = stage.subtitle;
    }

    return Semantics(
      button: true,
      expanded: open,
      label: '${index + 1}단계 ${stage.title}',
      child: InkWell(
        onTap: () => setState(() {
          if (open) {
            _collapsed.add(index);
          } else {
            _collapsed.remove(index);
          }
        }),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isCurrent) ...[
                    Row(
                      children: [
                        const AppPill(
                          label: '현재',
                          color: AppColors.primary,
                          background: AppColors.primarySoft,
                        ),
                        if (isBalanceTomorrow) ...[
                          const SizedBox(width: 6),
                          const AppPill(
                            label: 'D-1',
                            color: AppColors.caution,
                            background: AppColors.cautionSoft,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                  ] else if (stage.isBalance) ...[
                    const AppPill(
                      label: '가장 중요',
                      color: AppColors.caution,
                      background: AppColors.cautionSoft,
                    ),
                    const SizedBox(height: 6),
                  ],
                  AppText(stage.title, style: AppTypography.title),
                  const SizedBox(height: 2),
                  AppText(subtitle, style: AppTypography.caption),
                ],
              ),
            ),
            Icon(
              open ? Icons.expand_less : Icons.expand_more,
              size: AppSize.iconMd,
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _stageBody(
    JourneyStage stage,
    JourneyProperty? property,
    JourneySchedule schedule,
    JourneyScheduleStore store,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (stage.kind == JourneyStageKind.analysis) ...[
            _analysisSummary(property),
            if (stage.items.isNotEmpty) const SizedBox(height: AppSpacing.md),
          ],
          if (stage.agency != null) ...[
            AppPill(
              label: stage.agency!,
              color: AppColors.primary,
              background: AppColors.primarySoft,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          for (int i = 0; i < stage.items.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _item(stage.items[i]),
          ],
          if (stage.compare) ...[
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: AppCompactButton(
                label: '다시 떼서 대조하기',
                icon: Icons.compare_arrows,
                tonal: true,
                onPressed: () => property == null
                    ? startAnalysis(context)
                    : startRegistryCompare(context, property.latest),
              ),
            ),
          ],
          if (stage.askDates && property != null && schedule.balance == null) ...[
            const SizedBox(height: AppSpacing.md),
            _askDatesBox(property, store),
          ],
        ],
      ),
    );
  }

  /// 1단계 — **자동 완료.** 사용자가 체크하는 것이 아니라 "분석 기록이 있다"는 사실이다.
  Widget _analysisSummary(JourneyProperty? property) {
    if (property == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText('아직 분석한 집이 없어요', style: AppTypography.body),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: AppCompactButton(
              label: '지금 분석하기',
              icon: Icons.photo_camera_outlined,
              tonal: true,
              onPressed: () => startAnalysis(context),
            ),
          ),
        ],
      );
    }

    final report = property.latest;
    final int? age = property.registryAgeDays;
    final String ageLine = age == null
        ? '그때 뗀 등기부의 날짜를 읽지 못했어요. 계약 직전엔 다시 확인하세요'
        : '그때 뗀 등기부는 ${_viewedLabel(property)} — $age일 지났어요. '
              '계약 직전엔 다시 확인하세요';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          '등기부를 떼어 안전도 리포트로 분석했어요',
          style: AppTypography.body.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(
                '${report.alias} · ${formatMonthDay(report.analyzedAt)} 분석 · '
                '${report.grade.label}',
                style: AppTypography.caption.copyWith(
                  color: AppColors.textStrong,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              AppText(
                ageLine,
                style: AppTypography.caption.copyWith(color: AppColors.caution),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () => context.push('/report/${report.id}'),
          behavior: HitTestBehavior.opaque,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppText(
                '리포트 다시 보기',
                style: AppTypography.buttonSmall.copyWith(
                  color: AppColors.primary,
                ),
              ),
              const Icon(
                Icons.chevron_right,
                size: 18,
                color: AppColors.primary,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 할 일 한 줄 + "왜?" — **체크박스가 없다**(탭 동작도 없다).
  Widget _item(JourneyItem item) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(top: 8),
              decoration: const BoxDecoration(
                color: AppColors.primaryBright,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: AppText(item.text, style: AppTypography.body)),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Padding(
          padding: const EdgeInsets.only(left: AppSpacing.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.help_outline,
                  size: AppSize.iconXs,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(child: AppText(item.why, style: AppTypography.caption)),
            ],
          ),
        ),
      ],
    );
  }

  /// 계약서 단계의 날짜 안내 — 계약서에 적히는 날짜를 그 자리에서 받는다.
  Widget _askDatesBox(JourneyProperty property, JourneyScheduleStore store) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cautionSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(
            '계약서에 잔금일과 이사 날짜가 적혀 있어요. 지금 넣어둘까요?',
            style: AppTypography.body.copyWith(color: AppColors.caution),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: AppSize.compactButtonHeight,
            child: FilledButton.icon(
              onPressed: () => _openScheduleSheet(property, store),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, AppSize.compactButtonHeight),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.buttonMini),
                ),
                textStyle: AppTypography.buttonSmall,
              ),
              icon: const Icon(Icons.event_outlined, size: AppSize.iconSm),
              label: const AppText('날짜 넣기'),
            ),
          ),
        ],
      ),
    );
  }

  /// 타임라인 도트 24dp.
  Widget _dot({
    required int number,
    required bool done,
    required bool current,
    required bool later,
    required bool auto,
  }) {
    if (auto && done) {
      return _dotBox(
        color: AppColors.line,
        child: const Icon(Icons.check, size: 14, color: AppColors.textMuted),
      );
    }
    if (done) {
      return _dotBox(
        color: AppColors.primarySoft,
        child: const Icon(Icons.check, size: 14, color: AppColors.primary),
      );
    }
    if (current) {
      return _dotBox(
        color: AppColors.primary,
        child: _dotNumber(number, Colors.white),
      );
    }
    if (later) {
      // 아직 오지 않은 일 — 점선 원으로 '비어 있음'을 형태로 말한다.
      return SizedBox(
        width: 24,
        height: 24,
        child: DashedBorder(
          circle: true,
          strokeWidth: 1.5,
          dash: 3,
          gap: 3,
          color: AppColors.textMuted.withValues(alpha: 0.4),
          child: Center(child: _dotNumber(number, AppColors.textMuted)),
        ),
      );
    }
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surface,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.line, width: 1.5),
      ),
      child: _dotNumber(number, AppColors.textMuted),
    );
  }

  Widget _dotBox({required Color color, required Widget child}) => Container(
    width: 24,
    height: 24,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: child,
  );

  Widget _dotNumber(int number, Color color) => AppText(
    '$number',
    textScaler: TextScaler.noScaling, // 24dp 원 안이라 시스템 글꼴 확대에 밀리지 않게
    style: AppTypography.label.copyWith(
      color: color,
      fontWeight: FontWeight.w700,
      height: 1,
    ),
  );
}
