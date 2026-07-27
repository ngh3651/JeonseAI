/// S-07b 원본에서 보기 — 내가 올린 등기부 사진 위에 확인할 곳을 표시한다.
///
/// 목적: 사용자가 **손에 든 등기부 종이와 화면을 대조**할 수 있게 하는 것.
/// 은행원이 색연필로 동그라미 치듯, 확인해야 할 항목의 위치를 짚어 준다.
///
/// ⚠ 표시 전용이다. 등급·점수를 바꾸지 않는다 (api-contract §9.6).
/// ⚠ 화면에 띄우는 이미지는 반드시 **서버로 보낸 그 JPEG**여야 한다. 갤러리 원본을
///   띄우면 해상도·회전이 달라 좌표가 전부 어긋난다(RegistryPhotoStore 참조).
///
/// 2026-07-27 리뷰 3인(지수·서연·design-reviewer) 반영 요지:
/// - **침묵하지 않는다.** 표시가 0개여도 "무엇을 찾아봤는지"를 항상 보여준다.
///   침묵은 "AI가 안 봤다"로 읽혀 리포트 신뢰까지 깎는다(3인 공통 최다 지적).
/// - **빨간 타원에 흰 halo를 두른다.** 등기부 원본의 빨간 취소선(말소=끝난 권리)과
///   우리 빨강(살아있는 위험)이 대비 1.24:1로 구분 불가라, 의미가 정반대로 읽힐 수 있다.
/// - **탭은 가장 가까운 표시**를 연다. 첫 매칭을 쓰면 겹칠 때 항상 앞 번호가 이겨
///   ④를 눌러도 ①이 열린다(공동명의에서 반드시 발생).
/// - **뱃지는 줌해도 크기가 그대로**다. 작은 글씨를 보려고 확대했는데 뱃지가 6배로
///   커져 그 글자를 덮으면 확대의 목적이 무너진다.
///
/// 2026-07-27 실기기(SM-S931N, 사진 5장) 확인 후 고친 것:
/// - **리포트 Future를 initState에서 한 번만 만든다.** build() 안에서 만들면 setState마다
///   새 Future가 생겨 FutureBuilder가 로딩 분기로 되돌아가고, 그때 PageView가 통째로
///   버려졌다 다시 만들어지며 시작 페이지로 되감긴다. 헤더만 갱신된 인덱스를 들고 있어
///   "1/5인데 두 번째 사진이 보이는" 어긋남이 됐다.
/// - **손가락이 2개 닿으면 PageView의 가로 드래그를 끈다.** 안 끄면 확대가 시작조차
///   못 한다(아래 `_swipeLocked` 주석 참고).
/// - **항상 1번 사진부터 연다.** 표시가 있는 장으로 건너뛰면 사용자가 고장으로 읽는다.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../repositories/analysis_repository.dart';
import '../../state/registry_photo_store.dart';

// ── 마킹 규격 (오버레이 전용) ───────────────────────────────────────────────
/// 뱃지 지름(논리 픽셀). 색만으로 정보를 전달하지 않기 위해 ①②③ 번호를 붙인다.
const double kBadgeDiameter = 22;

/// 최소 터치 영역 — 등기부 글자는 작아서 bbox 그대로면 손가락으로 못 누른다.
const double kMinTouchSize = AppSize.minTouchTarget;

/// 형광펜 테두리 두께 / 위험 타원 두께 / 타원 여백
const double kMarkStrokeThin = 1.5;
const double kMarkStrokeBold = 3.0;
const double kMarkHaloStroke = 5.0;
const double kOvalPad = 4.0;

/// 칩 목록이 사진 영역을 잡아먹지 않도록 하는 상한 (2줄 분량)
const double kChipAreaMaxHeight = 112;

/// 정규화 좌표(0~1) × 화면에 그린 이미지 크기 → 실제 그릴 사각형.
///
/// 순수 함수로 떼어 둔 이유: 좌표 변환이 이 기능에서 가장 잘 틀리는 곳이라
/// 위젯 없이 바로 테스트할 수 있어야 한다.
Rect highlightRect(HighlightBox box, Size displaySize) => Rect.fromLTWH(
  box.x * displaySize.width,
  box.y * displaySize.height,
  box.w * displaySize.width,
  box.h * displaySize.height,
);

/// 탭 판정용 영역 — 너무 작으면 최소 터치 크기까지 넓힌다(가운데 기준).
Rect touchRect(HighlightBox box, Size displaySize) {
  final r = highlightRect(box, displaySize);
  final dx = math.max(0.0, kMinTouchSize - r.width) / 2;
  final dy = math.max(0.0, kMinTouchSize - r.height) / 2;
  return Rect.fromLTRB(r.left - dx, r.top - dy, r.right + dx, r.bottom + dy);
}

/// 탭 지점에서 **가장 가까운** 표시를 고른다. 없으면 null.
///
/// 첫 매칭을 쓰면 안 된다 — 48dp로 넓힌 터치 영역은 표에서 세로로 인접한 행끼리
/// 반드시 겹치므로, 목록 앞쪽 항목이 항상 이겨 **엉뚱한 사람의 설명이 열린다**.
/// 공동명의 4명이면 ④를 눌러도 ①이 열리고, 시트 본문이 똑같아 사용자는 눈치조차 못 챈다.
RegistryHighlight? highlightAt(
  List<RegistryHighlight> highlights,
  Offset point,
  Size displaySize,
) {
  RegistryHighlight? best;
  double bestDistance = double.infinity;
  double bestArea = double.infinity;
  for (final h in highlights) {
    if (!touchRect(h.box, displaySize).contains(point)) continue;
    final rect = highlightRect(h.box, displaySize);
    final distance = (rect.center - point).distance;
    final area = rect.width * rect.height;
    // 거리가 같으면 더 작은(더 정확히 지목된) 표시를 고른다.
    if (distance < bestDistance ||
        (distance == bestDistance && area < bestArea)) {
      best = h;
      bestDistance = distance;
      bestArea = area;
    }
  }
  return best;
}

// ══════════════════════════════════════════════════════════════════════════
// 화면
// ══════════════════════════════════════════════════════════════════════════

class RegistryViewerScreen extends StatefulWidget {
  const RegistryViewerScreen({super.key, required this.reportId});

  final String reportId;

  @override
  State<RegistryViewerScreen> createState() => _RegistryViewerScreenState();
}

class _RegistryViewerScreenState extends State<RegistryViewerScreen> {
  /// 리포트는 **한 번만** 불러온다.
  ///
  /// build() 안에서 `getReport()`를 부르면 호출할 때마다 새 Future가 만들어져,
  /// setState(페이지 넘김·디버그 토글) 한 번에 FutureBuilder가 로딩 분기로 되돌아간다.
  /// 그 순간 PageView가 통째로 버려졌다가 다시 만들어지며 PageController의 시작 페이지로
  /// 되감기고, 헤더(`_page`)만 갱신된 값을 들고 있어 화면과 어긋난다.
  late final Future<AnalysisReport?> _reportFuture;

  final PageController _pageController = PageController();
  int _page = 0;

  /// PageView의 가로 드래그를 끌지 여부.
  ///
  /// 두 손가락 확대는 InteractiveViewer의 ScaleGestureRecognizer가 처리하는데,
  /// PageView(Scrollable)의 가로 드래그 인식기가 제스처 아레나에서 먼저 이겨 버리면
  /// 확대가 **시작조차 되지 않는다**(둘 다 18dp 슬롭에서 승리를 선언해 경쟁하는데,
  /// 손가락이 좌우로 벌어지는 핀치에서는 드래그가 먼저 임계를 넘는다).
  /// 그래서 ⑴ 손가락이 2개 닿는 순간 드래그 인식기를 아예 빼 확대 쪽이 이기게 하고,
  /// ⑵ 확대 중(배율>1)에도 잠가 한 손가락 이동이 페이지 넘김으로 새지 않게 한다.
  ///
  /// setState 대신 ValueNotifier인 이유: 사진 위젯까지 다시 만들면 확대 상태가 풀린다.
  final ValueNotifier<bool> _swipeLocked = ValueNotifier<bool>(false);

  /// 화면에 닿아 있는 손가락 수 (제스처 아레나 밖에서 Listener로만 센다).
  int _pointers = 0;
  bool _zoomed = false;

  /// 개발용 — 켜면 터치 영역까지 그리고 원본/표시 크기를 로그로 찍는다.
  /// 릴리스에는 노출하지 않는다(시연 영상에 벌레 아이콘이 찍히면 미완성으로 보인다).
  bool _debug = false;

  @override
  void initState() {
    super.initState();
    _reportFuture = context.read<AnalysisRepository>().getReport(
      widget.reportId,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    _swipeLocked.dispose();
    super.dispose();
  }

  void _syncSwipeLock() => _swipeLocked.value = _pointers >= 2 || _zoomed;

  void _changePointers(int delta) {
    _pointers = math.max(0, _pointers + delta);
    _syncSwipeLock();
  }

  void _onZoomChanged(bool zoomed) {
    _zoomed = zoomed;
    _syncSwipeLock();
  }

  void _onPageChanged(int i) {
    // 페이지가 넘어가면 이전 장의 위젯이 폐기되며 확대도 사라진다 — 잠금도 함께 푼다.
    _zoomed = false;
    _syncSwipeLock();
    setState(() => _page = i);
  }

  @override
  Widget build(BuildContext context) {
    final paths = RegistryPhotoStore.instance.pathsFor(widget.reportId);

    return FutureBuilder<AnalysisReport?>(
      future: _reportFuture,
      builder: (context, snapshot) {
        final report = snapshot.data;
        if (snapshot.connectionState == ConnectionState.waiting) {
          // 로딩에도 AppBar를 유지한다 — 없으면 시스템 백 말고는 빠져나갈 길이 없다.
          return Scaffold(
            appBar: AppBar(title: const Text('내가 올린 사진에서 보기')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        if (report == null || paths.isEmpty) {
          return _emptyScaffold(context);
        }

        // 사진 장수보다 큰 page 인덱스는 버린다 — 엉뚱한 사진에 그리지 않기 위함.
        final usable = [
          for (final h in report.highlights)
            if (h.page >= 0 && h.page < paths.length) h,
        ];
        final onThisPage = [
          for (final h in usable)
            if (h.page == _page) h,
        ];

        return Scaffold(
          appBar: AppBar(
            // 제목을 매물 별칭으로 — 캡처해서 배우자에게 보낼 때 맥락이 없으면 못 보낸다.
            title: Text(report.alias, overflow: TextOverflow.ellipsis),
            actions: [
              if (kDebugMode)
                IconButton(
                  icon: Icon(
                    _debug ? Icons.bug_report : Icons.bug_report_outlined,
                  ),
                  tooltip: _debug ? '좌표 진단 끄기' : '좌표 진단 켜기',
                  onPressed: () => setState(() => _debug = !_debug),
                ),
            ],
          ),
          body: Column(
            children: [
              _pageHeader(paths.length, onThisPage.length, usable.length),
              if (report.highlightNotice != null)
                _noticeBar(report.highlightNotice!),
              if (kDebugMode && _debug) _debugBar(),
              Expanded(
                // Listener는 제스처 아레나에 끼어들지 않고 손가락 수만 센다.
                // 두 번째 손가락이 닿는 시점은 드래그·확대 중 누가 이길지 정해지기
                // **전**이라, 여기서 드래그 인식기를 빼면 확대가 이긴다.
                child: Listener(
                  onPointerDown: (_) => _changePointers(1),
                  onPointerUp: (_) => _changePointers(-1),
                  onPointerCancel: (_) => _changePointers(-1),
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _swipeLocked,
                    builder: (context, locked, _) => PageView.builder(
                      controller: _pageController,
                      physics: locked
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      itemCount: paths.length,
                      onPageChanged: _onPageChanged,
                      itemBuilder: (_, i) => _RegistryPage(
                        path: paths[i],
                        pageIndex: i,
                        highlights: [
                          for (final h in usable)
                            if (h.page == i) h,
                        ],
                        debug: _debug,
                        onTapHighlight: (h) => _showSheet(context, h),
                        onZoomChanged: _onZoomChanged,
                      ),
                    ),
                  ),
                ),
              ),
              _bottomPanel(context, report, onThisPage),
            ],
          ),
        );
      },
    );
  }

  Scaffold _emptyScaffold(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('내가 올린 사진에서 보기')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '이 분석에 쓴 사진이 남아 있지 않아요.\n등기부 사진은 안전을 위해 저장하지 않아요.',
              textAlign: TextAlign.center,
              style: AppTypography.body,
            ),
            const SizedBox(height: AppSpacing.lg),
            AppCompactButton(
              label: '새로 분석하기',
              onPressed: () => context.go('/analyze'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _pageHeader(int total, int onThisPage, int all) {
    return Container(
      width: double.infinity,
      color: AppColors.primarySoft,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Text('${_page + 1} / $total', style: AppTypography.bodyStrong),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              total > 1 ? '좌우로 넘기고, 두 손가락으로 확대할 수 있어요' : '두 손가락으로 확대할 수 있어요',
              style: AppTypography.caption,
            ),
          ),
          // 이 사진 개수와 전체 개수를 나눠 적는다 — 합쳐 적으면 아래 칩 개수와
          // 맞지 않아 "나머지는 어디 갔지?"가 된다.
          Text('이 사진 $onThisPage곳 · 전체 $all곳', style: AppTypography.caption),
        ],
      ),
    );
  }

  Widget _noticeBar(String notice) => Container(
    width: double.infinity,
    color: AppColors.cautionSoft,
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.lg,
      vertical: AppSpacing.sm,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.info_outline,
          size: AppSize.iconSm,
          color: AppColors.caution,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(notice, style: AppTypography.caption)),
      ],
    ),
  );

  /// 개발용 한 줄 — 진단을 켜면 사진 위에 나타나는 파란 네모가 무엇인지 말해 준다.
  ///
  /// 설명이 없으면 개발자 본인도 "이 네모가 서버가 준 좌표인가?"를 헷갈린다.
  /// 파란 네모는 서버 좌표가 아니라 **손가락으로 누를 수 있게 48dp까지 넓힌 판정 영역**이다.
  /// 호출부가 `kDebugMode` 안에 있어 릴리스 빌드에는 남지 않는다.
  Widget _debugBar() => Container(
    width: double.infinity,
    color: AppColors.textMuted.withValues(alpha: 0.12),
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.lg,
      vertical: AppSpacing.xs,
    ),
    child: Row(
      children: [
        const Icon(
          Icons.bug_report,
          size: AppSize.iconSm,
          color: AppColors.textMuted,
        ),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            '디버그: 파란 네모는 터치 판정 영역이에요 (표시 자체가 아니라 누를 수 있는 범위)',
            style: AppTypography.caption,
          ),
        ),
      ],
    ),
  );

  /// 화면 아래 패널 — 줌하지 않아도 무엇이 표시됐는지 **글로** 읽을 수 있게 한다.
  /// 등기부 본문 글자는 화면 맞춤 배율에서 3~4px이라, 형광펜만으로는 아무것도 못 읽는다.
  Widget _bottomPanel(
    BuildContext context,
    AnalysisReport report,
    List<RegistryHighlight> onThisPage,
  ) {
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.md,
        ),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.line)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _colorKey(),
            const SizedBox(height: AppSpacing.sm),
            if (onThisPage.isEmpty)
              Text(
                '이 사진에는 표시할 곳이 없었어요. 표시가 없다고 위험이 없다는 뜻은 아니에요 — '
                '판정 결과는 리포트에서 확인하세요.',
                style: AppTypography.caption,
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: kChipAreaMaxHeight,
                ),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (final h in onThisPage)
                        _HighlightChip(
                          highlight: h,
                          onTap: () => _showSheet(context, h),
                        ),
                    ],
                  ),
                ),
              ),
            if (report.checkedNotes.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              _CheckedNotes(notes: report.checkedNotes),
            ],
          ],
        ),
      ),
    );
  }

  /// 색-의미 키 — 색각 이상 사용자에게 색 매핑을 학습할 곳을 준다.
  /// 원본 빨간 취소선과 우리 빨강이 구분 불가라는 점도 여기서 말해 준다.
  Widget _colorKey() => Wrap(
    spacing: AppSpacing.md,
    runSpacing: AppSpacing.xs,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      _KeySwatch(
        color: AppColors.markerStroke,
        fill: AppColors.markerFill,
        oval: false,
        label: '이름처럼 대조할 곳',
      ),
      _KeySwatch(
        color: AppColors.markerAttention,
        fill: null,
        oval: true,
        label: '빚처럼 따져볼 곳',
      ),
      Text('※ 동그라미는 앱이 그린 표시예요(서류에 인쇄된 빨간 줄과 다릅니다)',
          style: AppTypography.caption),
    ],
  );

  void _showSheet(BuildContext context, RegistryHighlight highlight) {
    final color = highlight.isOwner
        ? AppColors.markerStroke
        : AppColors.markerAttention;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl,
              0,
              AppSpacing.xl,
              AppSpacing.xxl,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _BadgeCircle(number: highlight.badge, color: color),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(highlight.title, style: AppTypography.title),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Text(highlight.body, style: AppTypography.body),
                if (highlight.caution != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: AppColors.cautionSoft,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Text(highlight.caution!, style: AppTypography.body),
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                Text(
                  '${highlight.source ?? '등기부 원본'} · 위치 안내이며 위험도 판정이 아닙니다',
                  style: AppTypography.caption,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// 사진 1장 (이미지 + 오버레이)
// ══════════════════════════════════════════════════════════════════════════

class _RegistryPage extends StatefulWidget {
  const _RegistryPage({
    required this.path,
    required this.pageIndex,
    required this.highlights,
    required this.debug,
    required this.onTapHighlight,
    required this.onZoomChanged,
  });

  final String path;
  final int pageIndex;
  final List<RegistryHighlight> highlights;
  final bool debug;
  final void Function(RegistryHighlight) onTapHighlight;

  /// 확대 상태가 바뀔 때 부모에게 알린다 — 부모는 이 값으로 페이지 넘김을 잠근다.
  final void Function(bool zoomed) onZoomChanged;

  @override
  State<_RegistryPage> createState() => _RegistryPageState();
}

class _RegistryPageState extends State<_RegistryPage> {
  final TransformationController _transform = TransformationController();
  late Future<Size> _sizeFuture;

  /// 마지막으로 부모에게 알린 확대 여부 — 같은 값을 반복해 올리지 않기 위함.
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _sizeFuture = _intrinsicSize(widget.path);
    _transform.addListener(_reportZoom);
  }

  @override
  void dispose() {
    _transform.removeListener(_reportZoom);
    _transform.dispose();
    super.dispose();
  }

  /// 확대되면(배율>1) 부모가 PageView의 가로 드래그를 잠근다.
  /// 잠그지 않으면 확대된 사진을 한 손가락으로 밀 때 사진이 움직이는 대신 페이지가 넘어간다.
  /// 임계를 1.01로 둔 이유: 확대를 풀 때 배율이 1.0000001 같은 값으로 남는다.
  void _reportZoom() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    _zoomed = zoomed;
    widget.onZoomChanged(zoomed);
  }

  /// 파일 헤더만 읽어 원본 픽셀 크기를 구한다(전체 디코딩 없이).
  /// 좌표가 어긋나는 원인 1순위가 "서버로 보낸 이미지와 화면에 띄운 이미지가 다름"이라
  /// 이 값을 디버그 로그에 반드시 남긴다.
  static Future<Size> _intrinsicSize(String path) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size = Size(
      descriptor.width.toDouble(),
      descriptor.height.toDouble(),
    );
    descriptor.dispose();
    return size;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Size>(
      future: _sizeFuture,
      builder: (context, snapshot) {
        // 에러 분기가 없으면 스피너가 영원히 돈다 (임시 파일이 정리된 경우 등)
        if (snapshot.hasError) return _brokenPhoto();
        final intrinsic = snapshot.data;
        if (intrinsic == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            // 이미지를 '가운데 맞춤(contain)'했을 때의 실제 표시 크기를 직접 계산한다.
            // Image 위젯에 맡기면 그려진 사각형을 알 수 없어 오버레이가 레터박스만큼 어긋난다.
            final display = _fitted(intrinsic, constraints.biggest);
            _logIfDebug(intrinsic, display);
            // ⚠ 확대는 이 위젯만으로는 동작하지 않는다. 부모 PageView의 가로 드래그
            //   인식기가 제스처 아레나에서 먼저 이기기 때문에, 부모가 손가락 2개를
            //   감지해 드래그를 꺼 줘야 한다(`_swipeLocked` 참고). 그 잠금을 지우면
            //   여기 설정과 무관하게 두 손가락 확대가 다시 안 된다.
            return InteractiveViewer(
              transformationController: _transform,
              minScale: 1,
              maxScale: 6,
              // 뱃지가 이미지 가장자리 바깥에 그려질 수 있어 여백을 준다
              boundaryMargin: const EdgeInsets.all(24),
              child: Center(
                child: SizedBox(
                  width: display.width,
                  height: display.height,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) {
                      final hit = highlightAt(
                        widget.highlights,
                        details.localPosition,
                        display,
                      );
                      if (hit != null) widget.onTapHighlight(hit);
                    },
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(
                          File(widget.path),
                          fit: BoxFit.fill,
                          errorBuilder: (_, _, _) => _brokenPhoto(),
                        ),
                        ValueListenableBuilder<Matrix4>(
                          valueListenable: _transform,
                          builder: (_, matrix, _) => RegistryHighlightOverlay(
                            highlights: widget.highlights,
                            debug: widget.debug,
                            scale: matrix.getMaxScaleOnAxis(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _brokenPhoto() => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Text(
        '이 사진을 불러오지 못했어요.\n분석 결과와 판정은 리포트에서 그대로 확인할 수 있어요.',
        textAlign: TextAlign.center,
        style: AppTypography.body,
      ),
    ),
  );

  void _logIfDebug(Size intrinsic, Size display) {
    if (!widget.debug) return;
    debugPrint(
      '[하이라이트] 사진 ${widget.pageIndex + 1} — 원본 ${intrinsic.width.toInt()}x'
      '${intrinsic.height.toInt()}px / 표시 ${display.width.toStringAsFixed(1)}x'
      '${display.height.toStringAsFixed(1)} / 좌표 ${widget.highlights.length}건',
    );
    for (final h in widget.highlights.take(3)) {
      final r = highlightRect(h.box, display);
      debugPrint(
        '[하이라이트]   ${h.badge}. ${h.kind} 정규화(${h.box.x.toStringAsFixed(4)}, '
        '${h.box.y.toStringAsFixed(4)}) → 표시(${r.left.toStringAsFixed(1)}, '
        '${r.top.toStringAsFixed(1)}) 크기 ${r.width.toStringAsFixed(1)}x'
        '${r.height.toStringAsFixed(1)}',
      );
    }
  }

  /// BoxFit.contain과 동일한 결과 크기.
  static Size _fitted(Size source, Size box) {
    if (source.width <= 0 || source.height <= 0) return Size.zero;
    final scale = (box.width / source.width) < (box.height / source.height)
        ? box.width / source.width
        : box.height / source.height;
    return Size(source.width * scale, source.height * scale);
  }
}

/// 사진 위에 그리는 표시 레이어 — 위젯 테스트에서 단독으로 띄울 수 있게 분리했다.
class RegistryHighlightOverlay extends StatelessWidget {
  const RegistryHighlightOverlay({
    super.key,
    required this.highlights,
    this.debug = false,
    this.scale = 1.0,
  });

  final List<RegistryHighlight> highlights;
  final bool debug;

  /// 현재 확대 배율 — 뱃지를 이 값으로 나눠 그려 **화면상 크기를 일정하게** 유지한다.
  final double scale;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: HighlightPainter(
        highlights: highlights,
        debug: debug,
        scale: scale,
      ),
      // 좌표가 없으면 아무것도 그리지 않는다 — 에러 문구 없이 사진만 보인다.
      child: const SizedBox.expand(),
    );
  }
}

class HighlightPainter extends CustomPainter {
  HighlightPainter({
    required this.highlights,
    this.debug = false,
    this.scale = 1.0,
  });

  final List<RegistryHighlight> highlights;
  final bool debug;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final s = scale <= 0 ? 1.0 : scale;
    // 2패스로 그린다 — 항목마다 [도형→뱃지]를 순차 실행하면 뒤 항목의 도형이
    // 앞 항목의 뱃지를 덮는다.
    for (final h in highlights) {
      final rect = highlightRect(h.box, size);
      if (h.isOwner) {
        _paintHighlighter(canvas, rect, s);
      } else {
        _paintCircle(canvas, rect, s);
      }
      if (debug) {
        canvas.drawRect(
          touchRect(h.box, size),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1 / s
            ..color = const Color(0xFF0066FF),
        );
      }
    }
    for (final h in highlights) {
      _paintBadge(canvas, highlightRect(h.box, size), h, size, s);
    }
  }

  /// 노란 형광펜 — 글자가 비쳐 보이도록 반투명으로 칠하고 테두리를 얇게 준다.
  /// (채움만으로는 흰 종이와 대비 1.17:1이라 테두리가 유일한 경계다)
  void _paintHighlighter(Canvas canvas, Rect rect, double s) {
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(3));
    canvas.drawRRect(rrect, Paint()..color = AppColors.markerFill);
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = kMarkStrokeThin
        ..color = AppColors.markerStroke,
    );
  }

  /// 빨간 타원 — 은행원이 동그라미 치듯.
  ///
  /// **흰 halo를 먼저 깐다.** 등기부 원본의 빨간 취소선·직인과 우리 빨강은 대비
  /// 1.24:1로 사실상 같은 색인데 의미는 정반대다(원본 빨강=말소, 우리 빨강=살아있는 위험).
  /// 인쇄 잉크는 halo를 가질 수 없으므로, halo가 "앱이 얹은 표시"라는 형태 단서가 된다.
  void _paintCircle(Canvas canvas, Rect rect, double s) {
    final oval = rect.inflate(kOvalPad / s);
    canvas.drawOval(
      oval,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = kMarkHaloStroke / s
        ..color = AppColors.markerHalo,
    );
    canvas.drawOval(
      oval,
      Paint()..color = AppColors.markerAttention.withValues(alpha: 0.08),
    );
    canvas.drawOval(
      oval,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (kMarkStrokeBold / s).clamp(1.2, kMarkStrokeBold)
        ..color = AppColors.markerAttention,
    );
  }

  /// ①②③ 번호 뱃지 — 색만으로 정보를 전달하지 않기 위함(접근성).
  ///
  /// 크기를 `/ s` 로 나눠 **확대해도 화면상 22dp를 유지**한다. 작은 글씨를 보려고
  /// 확대했는데 뱃지가 6배(132dp)로 커져 그 글자를 덮으면 확대의 목적이 무너진다.
  /// 위치는 bbox 왼쪽 바깥 세로 중앙 — 등기부는 가로로 긴 표라 이 자리가 행 간
  /// 충돌이 가장 적다. 이미지 밖으로 나가지 않게 클램프한다.
  void _paintBadge(
    Canvas canvas,
    Rect rect,
    RegistryHighlight h,
    Size size,
    double s,
  ) {
    final color = h.isOwner
        ? AppColors.markerStroke
        : AppColors.markerAttention;
    final r = kBadgeDiameter / 2 / s;
    final desired = Offset(rect.left - r - 2 / s, rect.center.dy);
    final center = Offset(
      desired.dx.clamp(r + 1, math.max(r + 1, size.width - r - 1)),
      desired.dy.clamp(r + 1, math.max(r + 1, size.height - r - 1)),
    );
    canvas.drawCircle(center, r, Paint()..color = color);
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = kMarkStrokeThin / s
        ..color = Colors.white,
    );
    final painter = TextPainter(
      text: TextSpan(
        text: '${h.badge}',
        style: AppTypography.label.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: (AppTypography.label.fontSize ?? 12) / s,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(HighlightPainter old) =>
      old.highlights != highlights ||
      old.debug != debug ||
      old.scale != scale;
}

// ══════════════════════════════════════════════════════════════════════════
// 작은 부품
// ══════════════════════════════════════════════════════════════════════════

class _BadgeCircle extends StatelessWidget {
  const _BadgeCircle({required this.number, required this.color});

  final int number;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(
        minWidth: kBadgeDiameter,
        minHeight: kBadgeDiameter,
      ),
      padding: const EdgeInsets.all(3),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        '$number',
        // 사진 위 뱃지와 동작을 맞춘다(그쪽은 캔버스라 시스템 글꼴 확대가 안 걸린다)
        textScaler: TextScaler.noScaling,
        style: AppTypography.label.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 색-의미 키 한 칸.
class _KeySwatch extends StatelessWidget {
  const _KeySwatch({
    required this.color,
    required this.fill,
    required this.oval,
    required this.label,
  });

  final Color color;
  final Color? fill;
  final bool oval;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 22,
          height: 14,
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: color, width: 2),
            borderRadius: oval
                ? BorderRadius.circular(999)
                : BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(label, style: AppTypography.caption),
      ],
    );
  }
}

class _HighlightChip extends StatelessWidget {
  const _HighlightChip({required this.highlight, required this.onTap});

  final RegistryHighlight highlight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final owner = highlight.isOwner;
    final color = owner ? AppColors.markerStroke : AppColors.markerAttention;
    final soft = owner ? AppColors.cautionSoft : AppColors.dangerSoft;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: Container(
        constraints: const BoxConstraints(minHeight: kMinTouchSize),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: soft,
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _BadgeCircle(number: highlight.badge, color: color),
            const SizedBox(width: AppSpacing.sm),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.6,
              ),
              child: Text(
                highlight.title,
                style: AppTypography.bodyStrong,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "무엇을 찾아봤고 무엇을 왜 표시하지 않았는지" — 접었다 펼 수 있는 요약.
///
/// 이 위젯이 이 화면에서 가장 중요한 신뢰 장치다. 이게 없으면 이름에만 형광펜이
/// 칠해진 화면이 "AI가 이름만 봤다"는 증거로 읽혀 리포트 신뢰까지 깎인다.
class _CheckedNotes extends StatefulWidget {
  const _CheckedNotes({required this.notes});

  final List<String> notes;

  @override
  State<_CheckedNotes> createState() => _CheckedNotesState();
}

class _CheckedNotesState extends State<_CheckedNotes> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Container(
            constraints: const BoxConstraints(minHeight: kMinTouchSize),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                const Icon(
                  Icons.checklist_rtl,
                  size: AppSize.iconSm,
                  color: AppColors.primary,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    // 접힌 상태에서도 첫 줄은 보여준다 — 펼치지 않는 사람이 대부분이다
                    _open ? '이 등기부에서 찾아본 것' : widget.notes.first,
                    style: AppTypography.bodyStrong,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  _open ? Icons.expand_less : Icons.expand_more,
                  size: AppSize.iconSm,
                  color: AppColors.textMuted,
                ),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.xl,
              bottom: AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final note in widget.notes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: Text(
                      '· ${note.replaceAll('**', '')}',
                      style: AppTypography.caption,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
