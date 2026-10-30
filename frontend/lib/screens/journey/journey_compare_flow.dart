/// 등기부 대조 흐름 (그림 ⑦~⑪) — 올리기 시트 → 새 등기부 촬영 → 비교하는 중 → 결과.
///
/// 앱은 등기부를 대신 떼 오지 않는다. 사용자가 새 등기부를 **찍거나 갤러리에서 골라** 올린다(PDF는 받지 않는다).
///
/// - 결과가 '전부 맞춰봤다'(changed — 변동 없음/있음)면 이 시트 안에서 끝낸다(그림 ⑩·⑪).
///   새 등기부로 만든 리포트가 그 집의 최신 리포트가 되고(서버가 이미 저장), 그 단계가 자동 완료되고,
///   '등기부 변동 기록' 맨 위에 한 줄이 생긴다.
/// - 그 밖(일부만 맞춰봄·다른 집·기준 없음·사진 거절·오류)은 지금까지의 대조 화면(`/compare/:id`)으로 넘긴다 —
///   빠진 쪽만 더 찍기·그 장만 다시 찍기 같은 기능을 지우지 않기 위해서다. **서버를 두 번 부르지 않는다**(받은 결과를 넘긴다).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/photo_tray.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../models/analysis_report.dart';
import '../../models/compare_result.dart';
import '../../models/property_reports.dart';
import '../../repositories/analysis_repository.dart';
import '../../services/api_client.dart';
import '../../state/journey_progress_store.dart';
import '../../utils/korean_date.dart';
import '../compare/compare_screen.dart';
import '../search/capture_loop_route.dart';
import 'change_boxes.dart';
import 'journey_actions.dart';
import 'journey_parts.dart';

/// "8월 14일자" — 열람일을 못 읽었으면 "최근 리포트"
String viewedLabel(String? viewedAt, {String fallback = '최근 리포트'}) {
  final d = parseRegistryViewedAt(viewedAt);
  return d == null ? fallback : '${formatMonthDay(d)}자';
}

/// 계약 여정의 [최근 분석과 대조하기] — 그 집의 **최신 리포트**와 새 등기부를 맞춰본다.
///
/// [stageIndex]·[stageTitle]: 어느 단계에서 눌렀나 (대조를 마치면 그 단계가 완료, 기록 줄 제목).
Future<void> startJourneyCompare(
  BuildContext context, {
  required PropertyReports property,
  int? stageIndex,
  String? stageTitle,
  CaptureOne captureOne = defaultCaptureOne,
  PickMany pickMany = defaultPickMany,
}) async {
  final AnalysisReport report = property.latest;
  // 기준 없는 리포트(이 기능 이전 이력·예시)는 사진을 받기 **전에** 기준 없음 화면으로 — 찍게 해 놓고 못 한다고 말하지 않게
  if (!report.comparable) {
    context.push(
      '/compare/${report.id}',
      extra: CompareRequest(report: report),
    );
    return;
  }

  final List<String> paths = await pickRegistryPhotos(
    context,
    title: kComparePhotoSheetTitle,
    subtitle: '${viewedLabel(report.registryViewedAt)}와 비교해서 달라진 곳을 찾아 드려요',
    captureOne: captureOne,
    pickMany: pickMany,
    review: (initial, {required bool openCamera}) =>
        Navigator.of(context).push<List<String>>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => CompareCaptureScreen(
              report: report,
              initialPaths: initial,
              openCameraFirst: openCamera,
              captureOne: captureOne,
            ),
          ),
        ),
  );
  if (paths.isEmpty || !context.mounted) return;

  final outcome = await showModalBottomSheet<_SheetOutcome>(
    showDragHandle: false, // 손잡이는 직접 그린다 — 테마 손잡이와 겹쳐 두 개로 보였다 (2026-10-27)
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => CompareProgressSheet(
      report: report,
      imagePaths: paths,
      propertyKey: property.key,
      stageIndex: stageIndex,
      stageTitle: stageTitle,
    ),
  );
  if (!context.mounted || outcome == null) return;
  switch (outcome) {
    case _OpenReport(:final reportId):
      context.push('/report/$reportId');
    case _Handoff(:final result, :final error):
      // 전부 맞춰보지 못한 결과·오류는 지금까지의 대조 화면이 맡는다 (받은 결과를 그대로 넘겨 다시 부르지 않는다)
      context.push(
        '/compare/${report.id}',
        extra: CompareRequest(
          report: report,
          imagePaths: paths,
          initialResult: result,
          initialError: error,
        ),
      );
    case _Done():
      break;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 새 등기부 촬영 (그림 ⑧)
// ═══════════════════════════════════════════════════════════════════════════

/// 대조용 촬영 화면 — 찍는 방식은 분석 촬영과 같고, **보증금·시세·별칭 칸이 없다**(이 집 정보는 그대로 쓴다).
/// [N장으로 비교하기]를 누르면 사진 목록을 돌려준다. 그냥 나가면 null.
class CompareCaptureScreen extends StatefulWidget {
  const CompareCaptureScreen({
    super.key,
    required this.report,
    this.initialPaths = const [],
    this.openCameraFirst = false,
    this.captureOne = defaultCaptureOne,
  });

  static const String title = '새 등기부 촬영';

  final AnalysisReport report;
  final List<String> initialPaths;

  /// [촬영 시작]으로 들어왔으면 화면이 열리자마자 카메라를 띄운다
  final bool openCameraFirst;
  final CaptureOne captureOne;

  @override
  State<CompareCaptureScreen> createState() => _CompareCaptureScreenState();
}

class _CompareCaptureScreenState extends State<CompareCaptureScreen> {
  late final List<String> _photos = List.of(widget.initialPaths);

  @override
  void initState() {
    super.initState();
    if (widget.openCameraFirst && _photos.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _capture();
        // 한 장도 안 찍고 카메라를 닫았으면 이 화면도 닫는다(올리기 시트로 돌아간 것과 같다)
        if (mounted && _photos.isEmpty) Navigator.of(context).pop();
      });
    }
  }

  Future<void> _capture() async {
    if (_photos.length >= kCompareMaxPhotos) return;
    final CaptureLoopResult? result = await Navigator.of(context).push(
      MaterialPageRoute<CaptureLoopResult>(
        fullscreenDialog: true,
        builder: (_) => CaptureLoopRoute(
          alreadyTaken: _photos.length,
          maxPhotos: kCompareMaxPhotos,
          captureOne: widget.captureOne,
        ),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      for (final p in result.newPaths) {
        if (_photos.length < kCompareMaxPhotos) _photos.add(p);
      }
    });
  }

  Future<void> _view(int index) async {
    final PhotoViewerResult? result = await Navigator.of(context).push(
      MaterialPageRoute<PhotoViewerResult>(
        fullscreenDialog: true,
        builder: (_) =>
            PhotoViewerRoute(paths: List.of(_photos), initialIndex: index),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _photos
        ..clear()
        ..addAll(result.paths);
    });
    final int? retake = result.retakeIndex;
    if (retake == null || retake < 0 || retake >= _photos.length) return;
    final CaptureLoopResult? again = await Navigator.of(context).push(
      MaterialPageRoute<CaptureLoopResult>(
        fullscreenDialog: true,
        builder: (_) => CaptureLoopRoute(
          alreadyTaken: _photos.length,
          maxPhotos: _photos.length,
          captureOne: widget.captureOne,
          replacePage: retake,
        ),
      ),
    );
    if (!mounted || again == null || again.newPaths.isEmpty) return;
    setState(() => _photos[retake] = again.newPaths.last);
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      _photos.insert(newIndex, _photos.removeAt(oldIndex));
    });
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final int n = _photos.length;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: AppText(
          CompareCaptureScreen.title,
          style: AppTypographyNext.title,
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          PhotoTray(
            paths: _photos,
            onTapPhoto: _view,
            onAddMore: _capture,
            onReorder: _reorder,
            canAddMore: n < kCompareMaxPhotos,
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.screenPadding),
            child: JourneyCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppText(
                    '이 집 정보는 그대로 써요',
                    style: AppTypographyNext.caption.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _infoRow('집', report.alias),
                  _infoRow(
                    '비교 기준',
                    '${viewedLabel(report.registryViewedAt, fallback: '최근')} 리포트',
                  ),
                  _infoRow('보증금·시세·별칭', '처음 넣은 값 그대로'),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          color: AppColors.surface,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenPadding,
            12,
            AppSpacing.screenPadding,
            12,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppText.rich(
                TextSpan(
                  style: AppTypographyNext.caption,
                  children: [
                    const TextSpan(text: '리포트가 '),
                    TextSpan(
                      text: '새 등기부 기준',
                      style: AppTypographyNext.caption.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColorsNext.textStrong,
                      ),
                    ),
                    const TextSpan(text: '으로 바뀌어요'),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 56,
                child: FilledButton(
                  key: const ValueKey('compare-capture-submit'),
                  onPressed: n == 0
                      ? null
                      : () =>
                            Navigator.of(context).pop(List<String>.of(_photos)),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(kRadiusLg),
                    ),
                  ),
                  child: AppText(
                    n == 0 ? '사진을 찍어 주세요' : '$n장으로 비교하기',
                    style: AppTypographyNext.button.copyWith(
                      color: AppColors.onPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: AppText(label, style: AppTypographyNext.caption),
        ),
        Expanded(
          child: AppText(
            value,
            textAlign: TextAlign.right,
            style: AppTypographyNext.caption.copyWith(
              fontWeight: FontWeight.w600,
              color: AppColorsNext.textStrong,
            ),
          ),
        ),
      ],
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// 비교하는 중 → 결과 (그림 ⑨·⑩·⑪)
// ═══════════════════════════════════════════════════════════════════════════

sealed class _SheetOutcome {
  const _SheetOutcome();
}

class _Done extends _SheetOutcome {
  const _Done();
}

class _OpenReport extends _SheetOutcome {
  const _OpenReport(this.reportId);
  final String reportId;
}

class _Handoff extends _SheetOutcome {
  const _Handoff({this.result, this.error});
  final CompareResult? result;
  final ApiException? error;
}

/// 결과의 두 줄 — 갑구(주인과 압류)·을구(집에 걸린 빚)
class CompareSummaryLine {
  const CompareSummaryLine({
    required this.gu,
    required this.title,
    required this.subtitle,
    required this.rows,
  });

  final String gu;
  final String title;
  final String subtitle;

  /// 이 칸에서 새로 생기거나 바뀐 줄
  final List<CompareRow> rows;

  int get count => rows.fold(0, (sum, r) => sum + rowItemCount(r));
  bool get changed => rows.isNotEmpty;

  /// 새로 생기거나 달라진 건수 (없어진 것 빼고)
  int get addedCount => rows
      .where((r) => r.kind != CompareRowKind.removed)
      .fold(0, (sum, r) => sum + rowItemCount(r));

  /// 없어진 건수
  int get removedCount => rows
      .where((r) => r.kind == CompareRowKind.removed)
      .fold(0, (sum, r) => sum + rowItemCount(r));
}

/// 줄 하나가 몇 건인가 — 서버가 항목을 실었으면 그 수(2026-10-27). 옛 서버면 상세 첫 줄의 "N건"을 **모두** 더한다
/// (예: "압류 1건 · 가압류 2건" = 3). 못 읽으면 1.
int rowItemCount(CompareRow row) {
  if (row.items.isNotEmpty) return row.items.length;
  final first = (row.detail ?? '').split('\n').first;
  final counts = RegExp(r'(\d+)건').allMatches(first).map((m) => int.parse(m.group(1)!));
  return counts.isEmpty ? 1 : counts.fold(0, (a, b) => a + b);
}

/// 처리 중인 등기 신청 줄 (2026-10-31 잔금 당일 빈틈) — 서버가 이번 서류에 '신청사건 처리중'이 있으면 맨 위에 싣는다.
/// 두 서류의 차이가 아니라 이번 서류의 상태라서 갑구·을구 줄과 따로 센다. 없으면 null.
CompareRow? pendingRowOf(CompareResult result) {
  for (final r in result.rows) {
    if (r.group == 'pending' && r.tone == CompareTone.danger) return r;
  }
  return null;
}

/// 결과 → 한 건에 한 줄 항목들 (갑구·을구 순서, 새로 생김 → 없어짐은 상자가 나눈다).
/// 서버가 항목을 안 실은 줄(옛 서버·집주인 줄)은 제목·상세 첫 줄로 한 건을 만든다.
/// 처리 중인 등기 신청이 있으면 맨 앞에 한 건 — 변동 기록에도 남는다(2026-10-31).
List<CompareLogItem> compareLogItems(CompareResult result) => [
  if (pendingRowOf(result) case final CompareRow p)
    CompareLogItem(
      kind: CompareLogItemKind.changed,
      label: '신청사건 처리중',
      note: p.title,
    ),
  for (final line in summarizeCompare(result))
    for (final r in line.rows)
      if (r.items.isNotEmpty)
        for (final i in r.items)
          CompareLogItem(
            kind: r.kind == CompareRowKind.removed
                ? CompareLogItemKind.removed
                : CompareLogItemKind.added,
            label: i.label,
            receiptDate: i.receiptDate,
            note: i.amountText,
          )
      else
        CompareLogItem(
          kind: switch (r.kind) {
            CompareRowKind.removed => CompareLogItemKind.removed,
            CompareRowKind.added => CompareLogItemKind.added,
            _ => CompareLogItemKind.changed,
          },
          label: r.title,
          receiptDate: r.receiptDate,
          note: (r.detail ?? '').split('\n').first.trim(),
        ),
];

/// 결과 rows → 갑구·을구 두 줄. 서버가 칸(group)을 안 실은 옛 응답이면 제목 낱말로 나눈다.
List<CompareSummaryLine> summarizeCompare(CompareResult result) {
  String? groupOf(CompareRow r) {
    if (r.group != null) return r.group;
    if (r.kind == CompareRowKind.grade || r.title.contains('안전도'))
      return 'grade';
    if (r.title.contains('집주인')) return 'owner';
    if (r.title.contains('압류')) return 'seizure';
    if (r.title.contains('빚')) return 'debt';
    return null;
  }

  final gap = [
    for (final r in result.rows)
      if (r.isChange && (groupOf(r) == 'owner' || groupOf(r) == 'seizure')) r,
  ];
  final eul = [
    for (final r in result.rows)
      if (r.isChange && groupOf(r) == 'debt') r,
  ];
  return [
    CompareSummaryLine(
      gu: '갑구',
      title: '갑구 · 주인과 압류',
      subtitle: '소유자, 압류·가압류',
      rows: gap,
    ),
    CompareSummaryLine(
      gu: '을구',
      title: '을구 · 집에 걸린 빚',
      subtitle: '근저당 등',
      rows: eul,
    ),
  ];
}

/// 기록에 남길 바뀐 줄 — "을구 · 새로 생긴 빚이 있어요" / 상세(서버 문구 그대로 " · "로 이음)
/// 여정 '등기부 변동 기록'의 줄들 (최신이 앞, 맨 아래 '첫 분석' 줄은 카드가 따로 그린다) — 2026-10-27.
///
/// - 여정의 [대조하기]로 남긴 기록(이 폰) 그대로
/// - 그 밖에 같은 집을 **다시 분석**한 리포트(홈 등)마다 한 줄 — 서버가 바로 전 리포트와 견준 결과
///   (`changeFromPrevious`)로 '변동 없음/N건'. 견준 기록이 없는 옛 리포트는 꼬리표 없이 "다시 분석"만.
List<CompareLogEntry> journeyChangeLog(
  PropertyReports property,
  List<CompareLogEntry> local,
) {
  final logged = {
    for (final e in local)
      if (e.reportId != null) e.reportId!,
  };
  final first = property.first;
  final byId = {for (final r in property.reports) r.id: r};
  final entries = <CompareLogEntry>[
    for (final e in local) _refreshed(e, byId[e.reportId]),
    for (final r in property.reports)
      if (r.id != first.id && !logged.contains(r.id))
        reanalysisLogEntry(r),
  ]..sort((a, b) => b.at.compareTo(a.at));
  return entries;
}

/// 리포트가 보충본으로 바뀐 기록([CompareLogEntry.fromReport]) → 그 리포트의 '전 리포트와 견준 결과'로 다시 그린다.
/// 날짜·단계는 그대로 둔다. 리포트를 못 찾으면 저장된 그대로.
CompareLogEntry _refreshed(CompareLogEntry e, AnalysisReport? r) {
  if (!e.fromReport || r == null) return e;
  final fresh = reanalysisLogEntry(r);
  return CompareLogEntry(
    at: e.at,
    changedCount: fresh.changedCount,
    stageIndex: e.stageIndex,
    stageTitle: e.stageTitle,
    reportId: r.id,
    viewedAt: r.registryViewedAt,
    lines: fresh.lines,
    items: fresh.items,
    compared: fresh.compared,
    fromReport: true,
  );
}

/// 다시 분석한 리포트 한 건 → 기록 한 줄 (전 리포트와 견준 결과가 없으면 `compared=false`).
CompareLogEntry reanalysisLogEntry(AnalysisReport r) {
  final change = r.changeFromPrevious;
  final usable = change != null && change.outcome == CompareOutcome.changed;
  return CompareLogEntry(
    at: r.analyzedAt,
    changedCount: usable ? compareLogItems(change).length : 0,
    reportId: r.id,
    viewedAt: r.registryViewedAt,
    lines: usable ? compareLogLines(change) : const [],
    items: usable ? compareLogItems(change) : const [],
    reanalysis: true,
    compared: usable,
  );
}

List<CompareLogLine> compareLogLines(CompareResult result) => [
  for (final line in summarizeCompare(result))
    for (final r in line.rows)
      CompareLogLine(
        title: '${line.gu} · ${r.title}',
        detail: (r.detail ?? '')
            .split('\n')
            .where((s) => s.trim().isNotEmpty)
            .join(' · '),
      ),
];

class CompareProgressSheet extends StatefulWidget {
  const CompareProgressSheet({
    super.key,
    required this.report,
    required this.imagePaths,
    required this.propertyKey,
    this.stageIndex,
    this.stageTitle,
  });

  final AnalysisReport report;
  final List<String> imagePaths;
  final String propertyKey;
  final int? stageIndex;
  final String? stageTitle;

  @override
  State<CompareProgressSheet> createState() => _CompareProgressSheetState();
}

class _CompareProgressSheetState extends State<CompareProgressSheet>
    with SingleTickerProviderStateMixin {
  CompareResult? _result;
  int _step = 0;
  Timer? _stepTimer;

  /// 진행 막대 — 실제 진행률을 알 수 없어 25초에 걸쳐 90%까지 차고, 답이 오면 끝까지 찬다
  late final AnimationController _bar = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 25),
  );

  @override
  void initState() {
    super.initState();
    _bar.animateTo(0.9, curve: Curves.easeOutCubic);
    _stepTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _step = 1);
    });
    _run();
  }

  @override
  void dispose() {
    _stepTimer?.cancel();
    _bar.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final repo = context.read<AnalysisRepository>();
    final progress = context.read<JourneyProgressStore>();
    try {
      final result = await repo.compareRegistry(
        widget.report.id,
        widget.imagePaths,
      );
      if (!mounted) return;
      if (result.outcome != CompareOutcome.changed) {
        Navigator.of(context).pop(_Handoff(result: result));
        return;
      }
      await progress.addCompare(
        widget.propertyKey,
        CompareLogEntry(
          at: DateTime.now(),
          changedCount: compareLogItems(result).length,
          stageIndex: widget.stageIndex,
          stageTitle: widget.stageTitle,
          reportId: result.newReportId,
          viewedAt: result.current.viewedAt,
          lines: compareLogLines(result),
          items: compareLogItems(result),
        ),
      );
      if (!mounted) return;
      _stepTimer?.cancel();
      await _bar.animateTo(1, duration: const Duration(milliseconds: 250));
      if (!mounted) return;
      setState(() => _result = result);
    } on ApiException catch (e) {
      if (mounted) Navigator.of(context).pop(_Handoff(error: e));
    } catch (_) {
      if (mounted)
        Navigator.of(context).pop(
          const _Handoff(error: ApiException('대조하지 못했어요. 잠시 후 다시 시도해 주세요')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return PopScope(
      canPop: result != null,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenPadding,
            12,
            AppSpacing.screenPadding,
            20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (result == null) ..._progress() else ..._resultView(result),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _progress() {
    final base = viewedLabel(widget.report.registryViewedAt);
    final messages = ['올린 등기부를 읽고 있어요', '$base와 비교하는 중이에요'];
    return [
      AppText('새 등기부와 비교하는 중', style: AppTypographyNext.title),
      const SizedBox(height: 4),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: AppText(
          messages[_step],
          key: ValueKey(_step),
          style: AppTypographyNext.caption,
        ),
      ),
      const SizedBox(height: 16),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: AnimatedBuilder(
          animation: _bar,
          builder: (_, _) => LinearProgressIndicator(
            value: _bar.value,
            minHeight: 8,
            color: AppColors.primary,
            backgroundColor: AppColors.background,
          ),
        ),
      ),
      const SizedBox(height: 8),
    ];
  }

  List<Widget> _resultView(CompareResult result) {
    final lines = summarizeCompare(result);
    final int count = lines.fold(0, (s, l) => s + l.count);
    // 처리 중인 등기 신청(2026-10-31) — 다른 줄이 모두 그대로여도 '달라진 것 없어요'라고 말하지 않는다
    final CompareRow? pending = pendingRowOf(result);
    final bool changed = count > 0 || pending != null;
    final String from = viewedLabel(result.baseline.viewedAt, fallback: '지난');
    final String to = viewedLabel(result.current.viewedAt, fallback: '새');
    final String? newId = result.newReportId;
    return [
      Center(
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: changed ? AppColors.dangerSoft : AppColors.okSoft,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: changed
              ? AppText(
                  '!',
                  textScaler: TextScaler.noScaling,
                  style: AppTypographyNext.headline.copyWith(
                    color: AppColorsNext.dangerText,
                  ),
                )
              : Icon(Icons.check, size: 32, color: AppColors.ok),
        ),
      ),
      const SizedBox(height: 12),
      AppText(
        count > 0
            ? '달라진 게 $count건 있어요'
            : (pending != null ? pending.title : '달라진 것 없어요'),
        key: const ValueKey('compare-result-title'),
        textAlign: TextAlign.center,
        style: AppTypographyNext.headline,
      ),
      const SizedBox(height: 4),
      AppText(
        '$from → $to 등기부를 비교했어요',
        textAlign: TextAlign.center,
        style: AppTypographyNext.caption,
      ),
      const SizedBox(height: 16),
      if (pending != null) ...[
        PendingApplicationBanner(row: pending),
        const SizedBox(height: 12),
      ],
      for (int i = 0; i < lines.length; i++) ...[
        if (i > 0)
          Divider(height: 1, thickness: 1, color: AppColorsNext.divider),
        _summaryRow(lines[i]),
      ],
      if (changed) ...[
        Divider(height: 1, thickness: 1, color: AppColorsNext.divider),
        const SizedBox(height: 16),
        ChangeBoxes(items: compareLogItems(result)),
      ],
      const SizedBox(height: 20),
      SizedBox(
        height: 56,
        child: OutlinedButton(
          key: const ValueKey('compare-result-open-report'),
          onPressed: () =>
              Navigator.of(context).pop(_OpenReport(newId ?? widget.report.id)),
          style: OutlinedButton.styleFrom(
            backgroundColor: AppColors.surface,
            foregroundColor: AppColors.primary,
            side: BorderSide(color: AppColors.primary, width: 1.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadiusLg),
            ),
          ),
          child: AppText(
            '최근 분석 리포트 보기',
            style: AppTypographyNext.button.copyWith(color: AppColors.primary),
          ),
        ),
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 56,
        child: FilledButton(
          key: const ValueKey('compare-result-ok'),
          onPressed: () => Navigator.of(context).pop(const _Done()),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadiusLg),
            ),
          ),
          child: AppText(
            '확인',
            style: AppTypographyNext.button.copyWith(color: AppColors.onPrimary),
          ),
        ),
      ),
    ];
  }

  Widget _summaryRow(CompareSummaryLine line) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  line.title,
                  style: AppTypographyNext.bodyStrong.copyWith(
                    color: AppColorsNext.textStrong,
                  ),
                ),
                AppText(line.subtitle, style: AppTypographyNext.caption),
              ],
            ),
          ),
          if (line.changed)
            _countTag(line)
          else
            AppText(
              '✓ 같음',
              style: AppTypographyNext.caption.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColors.ok,
              ),
            ),
        ],
      ),
    );
  }

  /// 요약 줄 오른쪽 — "새로 N"(빨강) · "없어짐 N"(초록), 사이에 연한 "·". "바뀜 N건"이라고 쓰지 않는다.
  Widget _countTag(CompareSummaryLine line) {
    final TextStyle base = AppTypographyNext.caption.copyWith(
      fontWeight: FontWeight.w700,
    );
    final int added = line.addedCount;
    final int removed = line.removedCount;
    return AppText.rich(
      TextSpan(
        children: [
          if (added > 0)
            TextSpan(
              text: '새로 $added',
              style: base.copyWith(color: AppColorsNext.dangerText),
            ),
          if (added > 0 && removed > 0)
            TextSpan(
              text: '  ·  ',
              style: base.copyWith(color: AppColorsNext.textMuted),
            ),
          if (removed > 0)
            TextSpan(
              text: '없어짐 $removed',
              style: base.copyWith(color: AppColors.ok),
            ),
        ],
      ),
    );
  }
}

/// 처리 중인 등기 신청 띠 (2026-10-31 잔금 당일 빈틈) — 대조 결과 맨 위. 빨강 바탕 · 멈춤 아이콘 · 서버 문장 그대로.
class PendingApplicationBanner extends StatelessWidget {
  const PendingApplicationBanner({super.key, required this.row});

  final CompareRow row;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('compare-pending-banner'),
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
    decoration: BoxDecoration(
      color: AppColors.dangerSoft,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.pan_tool_rounded, size: 22, color: AppColorsNext.dangerText),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(
                row.title,
                style: AppTypographyNext.bodyStrong.copyWith(
                  color: AppColorsNext.dangerText,
                ),
              ),
              if (row.subtitle != null) ...[
                const SizedBox(height: 4),
                AppText(
                  row.subtitle!,
                  style: AppTypographyNext.body.copyWith(
                    color: AppColorsNext.textStrong,
                  ),
                ),
              ],
              if (row.detail != null) ...[
                const SizedBox(height: 6),
                AppText(row.detail!, style: AppTypographyNext.caption),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}
