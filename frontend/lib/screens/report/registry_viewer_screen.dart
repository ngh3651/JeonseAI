/// S-07b 내가 올린 사진에서 보기 — 등기부 사진 위에 확인할 곳을 표시한다.
///
/// 목적: 사용자가 **손에 든 등기부 종이와 화면을 대조**할 수 있게 하는 것.
/// 은행원이 색연필로 밑줄 긋듯, 확인해야 할 항목의 위치를 짚어 준다.
///
/// ⚠ 표시 전용이다. 등급·점수를 바꾸지 않는다 (api-contract §9.6).
/// ⚠ 화면에 띄우는 이미지는 반드시 **서버로 보낸 그 JPEG**여야 한다. 갤러리 원본을
///   띄우면 해상도·회전이 달라 좌표가 전부 어긋난다(RegistryPhotoStore 참조).
///
/// ── 2026-07-27 재디자인 (1단계: 문서 스크롤 + 형광펜 + 위치 레일) ──────────────
/// 바뀐 것과 그 이유:
/// - **좌우 넘기기 → 세로 연속 스크롤.** 페이지를 넘겨야만 다음 표시를 볼 수 있으면
///   "표시가 어느 쪽에 있는지" 미리 알 수 없어 사용자가 못 찾고 포기한다.
/// - **빨간 타원 → 형광펜(multiply).** 원본에 인쇄된 빨간 말소선과 색이 겹쳐 의미가
///   정반대로 읽히던 문제가, 색 계열을 주황·초록으로 옮기면서 근본적으로 사라졌다.
///   덕분에 흰 halo와 "이건 앱이 그린 거예요" 주의 문구도 필요 없어졌다.
/// - **위치 레일 추가.** 전체 문서 어디에 표시가 있는지·지금 어디를 보고 있는지를
///   한 줄로 보여 준다. 이게 있어서 **맨 위(1쪽)에서 시작**해도 길을 잃지 않는다
///   (첫 표시로 스크롤 파킹하면 "왜 여기서 시작하지?"가 되고, 스크롤 위치를 사용자가
///   잃는다 — 2026-07-27 사용자 결정).
///
/// 그대로 유지한 것 (실기기에서 값을 치르고 얻은 것들):
/// - **리포트 Future를 initState에서 한 번만 만든다.** build() 안에서 만들면 setState마다
///   새 Future가 생겨 FutureBuilder가 로딩 분기로 되돌아가고, 스크롤이 되감기며 매
///   프레임 서버 요청이 나간다.
/// - **손가락이 2개 닿거나 확대 중이면 스크롤을 잠근다.** 안 잠그면 Scrollable의 드래그
///   인식기가 제스처 아레나에서 이겨 확대가 시작조차 못 한다(`_scrollLocked` 참고).
/// - **뱃지는 줌해도 크기가 그대로다.** 작은 글씨를 보려고 확대했는데 뱃지가 6배로
///   커져 그 글자를 덮으면 확대의 목적이 무너진다.
/// - **탭은 가장 가까운 표시**를 연다(`highlightAt`). 첫 매칭을 쓰면 겹칠 때 항상 앞
///   번호가 이겨 ④를 눌러도 ①이 열린다(공동명의에서 반드시 발생).
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../models/registry_mark_kind.dart';
import '../../repositories/analysis_repository.dart';
import '../../state/registry_photo_store.dart';
import 'registry_document_layout.dart';
import 'registry_mark_carousel.dart';
import 'registry_mark_sheet.dart';
import 'registry_mark_stripe.dart';

// ── 마킹 규격 (오버레이 전용) ───────────────────────────────────────────────
/// 번호 뱃지 지름(논리 픽셀). 색만으로 정보를 전달하지 않기 위해 번호를 붙인다.
const double kBadgeDiameter = 19;

/// 뱃지와 형광펜 오른쪽 끝 사이 여백.
/// 표 **왼쪽**에 두면 등기부의 순위번호 칸을 가려서 원문 대조가 막힌다.
const double kBadgeGap = 4;

/// 최소 터치 영역 — 등기부 글자는 작아서 bbox 그대로면 손가락으로 못 누른다.
const double kMinTouchSize = AppSize.minTouchTarget;

// ── 위치 레일 규격 ─────────────────────────────────────────────────────────
// 캐러셀이 들어오면서 하단이 네 겹(레일·범례·안내 한 줄·캐러셀)이 됐다. 레일은
// 시안 규격(약 46dp)에 맞춰 줄여 문서 영역을 한 dp라도 더 남긴다.
const double kRailTrackHeight = 8;
const double kRailDotDiameter = 12;
const double kRailDotBorder = 2;

/// 레일의 터치 높이 — 트랙은 8dp지만 8dp짜리를 손가락으로 정확히 누를 수는 없다.
const double kRailTouchHeight = 24;

// ── 그어짐 애니메이션 ───────────────────────────────────────────────────────
/// 형광펜이 왼→오로 그어지는 시간 (시안 450ms)
const Duration kDrawDuration = Duration(milliseconds: 450);

/// 표시로 이동할 때 스크롤 시간
const Duration kScrollToMarkDuration = Duration(milliseconds: 380);

/// 사진 디코딩 배율 — 화면에 그리는 폭의 몇 배로 디코딩할지.
///
/// 1200~4000px짜리 사진 5장을 세로로 얹으므로 원본 그대로 디코딩하면 메모리가 터진다.
/// 그렇다고 화면 폭에 딱 맞추면 확대했을 때 글자가 뭉개져 **확대의 목적이 사라진다.**
/// 2배까지 여유를 주고 그 이상은 원본 해상도로 자연히 잘린다.
const double kZoomDecodeFactor = 2;

/// 정규화 좌표(0~1) × 화면에 그린 이미지 크기 → 실제 그릴 사각형.
///
/// 순수 함수로 떼어 둔 이유: 좌표 변환이 이 기능에서 가장 잘 틀리는 곳이라
/// 위젯 없이 바로 테스트할 수 있어야 한다.
///
/// ⚠ 여기서 **좌표를 새로 보정하지 않는다.** 백엔드가 준 값은 이미
///   "앱이 서버로 보낸 그 JPEG 픽셀 기준"의 정규화 좌표이고, 화면에 띄우는 것도
///   같은 파일이다. 시안이 말하는 '원근 보정 후 좌표계' 같은 중간 단계는 이 앱에 없다.
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

/// 서버가 보낸 "찾아본 것" 중 **사진에 표시하지 못한 것**만 골라내는 표식.
///
/// 문장 자체는 서버가 만든다. 앱은 고르기만 한다 — 새 사유가 생겨도 이 목록만 늘린다.
const List<String> kUnmarkedNoteMarkers = ['표시하지 않았', '찾지 못했', '생략했'];

/// 목록 맨 끝 회색 한 줄 — "리포트엔 있는데 사진에는 표시하지 못한 것". 없으면 null.
///
/// 왜 필요한가: 리포트에는 근저당이 4건인데 사진에는 3개만 표시되는 일이 흔하다
/// (1건이 말소면 표시 대상에서 빠진다). 이 줄이 없으면 **개수가 안 맞는 이유를
/// 화면 어디에서도 찾을 수 없다** — 실제로 팀원이 못 찾고 물었다.
///
/// **말소 전용 문구가 아니다.** 위치를 못 찾았을 때·표시를 통째로 보류했을 때도
/// 같은 자리에 사유만 갈아끼워 나간다. 표시하지 못한 것이 없으면 줄 자체가 사라진다.
String? unmarkedNotice(List<String> checkedNotes) {
  final picked = [
    for (final note in checkedNotes)
      if (kUnmarkedNoteMarkers.any(note.contains)) note.replaceAll('**', ''),
  ];
  return picked.isEmpty ? null : picked.join(' · ');
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

class _RegistryViewerScreenState extends State<RegistryViewerScreen>
    with TickerProviderStateMixin {
  /// 사진 경로 — build()마다 다시 묻지 않는다. 도중에 바뀌면 좌표가 밀린다.
  late final List<String> _paths;

  /// 리포트 + 사진 원본 크기는 **한 번만** 불러온다.
  ///
  /// build() 안에서 만들면 호출할 때마다 새 Future가 생겨, setState 한 번에
  /// FutureBuilder가 로딩 분기로 되돌아가고 스크롤이 되감기며 매 프레임 요청이 나간다.
  late final Future<_ViewerData> _dataFuture;

  final ScrollController _scroll = ScrollController();

  /// 레일이 볼 스크롤 지표. setState 대신 Notifier인 이유: 스크롤 한 프레임마다
  /// 화면 전체를 다시 만들면 사진이 재디코딩되고 확대 상태가 풀린다.
  final ValueNotifier<_ScrollSnapshot> _metrics = ValueNotifier(
    const _ScrollSnapshot.empty(),
  );

  /// 세로 스크롤을 끌지 여부.
  ///
  /// 두 손가락 확대는 InteractiveViewer의 ScaleGestureRecognizer가 처리하는데,
  /// Scrollable의 세로 드래그 인식기가 제스처 아레나에서 먼저 이겨 버리면 확대가
  /// **시작조차 되지 않는다**. 그래서 ⑴ 손가락이 2개 닿는 순간 드래그 인식기를 아예
  /// 빼 확대 쪽이 이기게 하고, ⑵ 확대 중(배율>1)에도 잠가 한 손가락 이동이 스크롤로
  /// 새지 않게 한다 — 확대 상태에서 한 손가락 이동은 그 사진 안에서만 일어나야 한다.
  final ValueNotifier<bool> _scrollLocked = ValueNotifier<bool>(false);

  /// 화면에 닿아 있는 손가락 수 (제스처 아레나 밖에서 Listener로만 센다).
  int _pointers = 0;

  /// 지금 확대돼 있는 쪽들. 쪽이 화면 밖으로 밀려 폐기되면 스스로 빠진다.
  final Set<int> _zoomedPages = <int>{};

  /// 카드 캐러셀 — 선택이 바뀌면 그 카드를 화면 안으로 끌어온다.
  final ScrollController _carousel = ScrollController();

  /// 선택된 표시 — 형광펜이 진해지고 번호 뱃지가 그 자리에 붙고 카드가 선택 상태가 된다.
  /// 진입 시 첫 표시로 두되 **스크롤은 맨 위에 그대로 둔다**(사용자 결정).
  ///
  /// setState가 아니라 Notifier인 이유: 문서를 스크롤할 때마다 선택이 따라 바뀌는데,
  /// 그때마다 화면 전체를 다시 만들면 사진이 재디코딩되고 확대 상태가 풀린다.
  final ValueNotifier<String?> _selected = ValueNotifier<String?>(null);

  /// 형광펜 그어짐 진행도 (0=아직, 1=다 그음).
  ///
  /// ⚠ **initState에서 만든다.** `late final … = AnimationController(…)`로 두면 처음
  ///   읽을 때 만들어지는데, 로딩 중에 사용자가 뒤로 나가면 그 '처음 읽기'가 dispose()가
  ///   되어 이미 떨어져 나간 위젯에서 Ticker를 만들려다 터진다.
  late final AnimationController _draw;

  /// 우리가 코드로 스크롤하는 중인가 — 그 동안은 "보이는 표시로 선택 따라가기"를 멈춘다.
  /// 안 멈추면 목적지로 가는 길에 스쳐 지나가는 표시들이 차례로 선택돼 카드가 요동친다.
  bool _programmaticScroll = false;

  @override
  void initState() {
    super.initState();
    _paths = RegistryPhotoStore.instance.pathsFor(widget.reportId);
    _dataFuture = _load(context.read<AnalysisRepository>());
    _draw = AnimationController(
      vsync: this,
      duration: kDrawDuration,
      value: 1,
    );
    _scroll.addListener(_publishMetrics);
  }

  @override
  void dispose() {
    _scroll.removeListener(_publishMetrics);
    _scroll.dispose();
    _carousel.dispose();
    _draw.dispose();
    _selected.dispose();
    _metrics.dispose();
    _scrollLocked.dispose();
    super.dispose();
  }

  Future<_ViewerData> _load(AnalysisRepository repo) async {
    final report = await repo.getReport(widget.reportId);
    final sizes = await Future.wait([for (final p in _paths) _intrinsicSize(p)]);
    final data = _ViewerData(report: report, sizes: sizes);
    _selected.value ??= data.marks.isEmpty ? null : data.marks.first.id;
    return data;
  }

  /// 파일 헤더만 읽어 원본 픽셀 크기를 구한다(전체 디코딩 없이).
  /// 실패하면 [Size.zero] — 레일이 A4 비율로 자리만 잡고, 그 쪽은 실패 안내를 띄운다.
  static Future<Size> _intrinsicSize(String path) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(path);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = Size(
        descriptor.width.toDouble(),
        descriptor.height.toDouble(),
      );
      descriptor.dispose();
      return size;
    } catch (e) {
      debugPrint('[뷰어] 사진 크기를 읽지 못했어요 (${e.runtimeType})');
      return Size.zero;
    }
  }

  /// 스크롤 연동(레일 필·카드 선택)이 보는 값 — build()에서 채운다.
  /// 스크롤 콜백은 build 바깥에서 불리므로 어딘가에 담아 둬야 한다.
  RegistryDocumentLayout? _layout;
  List<RegistryHighlight> _marks = const [];

  void _publishMetrics() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    _metrics.value = _ScrollSnapshot(
      offset: p.pixels,
      viewport: p.viewportDimension,
      maxExtent: p.maxScrollExtent,
    );
    final layout = _layout;
    if (layout != null) _syncSelectionToScroll(layout, _marks);
  }

  void _syncScrollLock() =>
      _scrollLocked.value = _pointers >= 2 || _zoomedPages.isNotEmpty;

  void _changePointers(int delta) {
    _pointers = math.max(0, _pointers + delta);
    _syncScrollLock();
  }

  void _onZoomChanged(int page, bool zoomed) {
    // 화면을 빠져나가는 중에 마지막 쪽이 폐기되며 들어올 수 있다.
    if (!mounted) return;
    if (zoomed) {
      _zoomedPages.add(page);
    } else {
      _zoomedPages.remove(page);
    }
    _syncScrollLock();
  }

  /// 모션 감소가 켜져 있으면 애니메이션 없이 즉시 상태를 바꾼다(접근성).
  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  /// 표시를 고른다 — 형광펜을 다시 긋고, 그 자리로 스크롤하고, 카드를 끌어온다.
  ///
  /// **같은 표시를 다시 눌러도 애니메이션이 다시 재생돼야 한다**(시안). 그래서 선택이
  /// 바뀌었는지와 무관하게 [_draw]를 0에서 다시 돌린다.
  Future<void> _select(
    RegistryHighlight mark,
    RegistryDocumentLayout layout,
    List<RegistryHighlight> marks,
  ) async {
    _selected.value = mark.id;
    _scrollCarouselTo(marks.indexOf(mark));
    if (_reduceMotion) {
      _draw.value = 1;
    } else {
      _draw.forward(from: 0);
    }
    await _scrollToMark(mark, layout);
  }

  /// 표시가 화면 위쪽 1/3에 오도록 문서를 옮긴다.
  Future<void> _scrollToMark(
    RegistryHighlight mark,
    RegistryDocumentLayout layout,
  ) async {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final target = scrollTargetFor(
      markY: layout.markTop(mark.page, mark.box.y),
      viewportHeight: p.viewportDimension,
      maxScrollExtent: p.maxScrollExtent,
    );
    if ((target - p.pixels).abs() < 1) return;
    _programmaticScroll = true;
    try {
      if (_reduceMotion) {
        _scroll.jumpTo(target);
      } else {
        await _scroll.animateTo(
          target,
          duration: kScrollToMarkDuration,
          curve: Curves.easeOutCubic,
        );
      }
    } finally {
      _programmaticScroll = false;
    }
  }

  void _scrollCarouselTo(int index) {
    if (index < 0 || !_carousel.hasClients) return;
    final width = cardWidthFor(MediaQuery.sizeOf(context).width);
    final p = _carousel.position;
    // 카드를 화면 가운데로 — 양 끝 카드는 클램프되어 자연스럽게 가장자리에 붙는다.
    final target =
        (index * (width + kCardGap) +
                kCarouselPadH +
                width / 2 -
                p.viewportDimension / 2)
            .clamp(0.0, p.maxScrollExtent);
    if (_reduceMotion) {
      _carousel.jumpTo(target);
    } else {
      _carousel.animateTo(
        target,
        duration: kScrollToMarkDuration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 문서를 손으로 스크롤하면 **지금 보이는 표시**가 선택된다 — 레일 필이 움직이는 것과
  /// 같은 방향의 연동이다. 화면에 표시가 하나도 없으면 이전 선택을 그대로 둔다
  /// (선택을 비우면 카드 캐러셀이 깜빡이며 아무것도 안 고른 상태가 된다).
  void _syncSelectionToScroll(
    RegistryDocumentLayout layout,
    List<RegistryHighlight> marks,
  ) {
    if (_programmaticScroll || marks.isEmpty || !_scroll.hasClients) return;
    final p = _scroll.position;
    if (p.viewportDimension <= 0) return;
    // 스크롤 목표와 같은 기준선(위쪽 1/3)을 쓴다 — 카드를 눌러 이동했을 때 그 표시가
    // 그대로 선택으로 남는다.
    final anchor = p.pixels + p.viewportDimension / 3;
    RegistryHighlight? best;
    double bestGap = double.infinity;
    for (final m in marks) {
      final y = layout.markCenterY(m.page, m.box.y, m.box.h);
      if (y < p.pixels || y > p.pixels + p.viewportDimension) continue;
      final gap = (y - anchor).abs();
      if (gap < bestGap) {
        best = m;
        bestGap = gap;
      }
    }
    if (best == null || best.id == _selected.value) return;
    _selected.value = best.id;
    _draw.value = 1; // 스크롤로 바뀐 선택은 그어짐을 재생하지 않는다(따라다니면 산만하다)
    _scrollCarouselTo(marks.indexOf(best));
  }

  /// 레일 위 비율 → 그 위치로 점프. 필(현재 위치 표시)의 **가운데**가 손가락에 온다.
  void _seek(double fraction, RegistryDocumentLayout layout) {
    if (!_scroll.hasClients || layout.totalHeight <= 0) return;
    final p = _scroll.position;
    final pillWidth = p.viewportDimension / layout.totalHeight;
    final target = ((fraction - pillWidth / 2) * layout.totalHeight).clamp(
      0.0,
      p.maxScrollExtent,
    );
    _scroll.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_ViewerData>(
      future: _dataFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          // 로딩에도 앱바를 유지한다 — 없으면 시스템 백 말고는 빠져나갈 길이 없다.
          return const Scaffold(
            backgroundColor: AppColors.surface,
            appBar: _ViewerAppBar(),
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final data = snapshot.data;
        if (data?.report == null || _paths.isEmpty) return _emptyScaffold();

        final report = data!.report!;
        final marks = data.marks;
        // 문서와 레일이 **같은 기하**를 봐야 한다. 각자 LayoutBuilder로 재면 레일 쪽만
        // SafeArea 좌우 인셋을 빼고 재게 되어, 쪽 높이·전체 높이가 미세하게 달라지고
        // 레일을 눌렀을 때 엉뚱한 자리로 간다. 문서 영역은 화면 폭 전체다.
        final layout = data.layoutFor(MediaQuery.sizeOf(context).width);
        _layout = layout;
        _marks = marks;

        return Scaffold(
          backgroundColor: AppColors.surface,
          appBar: _ViewerAppBar(
            // 제목은 **매물 별칭**이다. 이 화면은 캡처해서 배우자·부모에게 보내는
            // 용도가 있는데, 주소가 없으면 무슨 집인지 알 수 없다. 화면 이름을 적는 것은
            // 방금 그 문구를 눌러 들어온 사용자에게 아는 것을 반복하는 셈이기도 하다
            // (2026-07-27 서연 리뷰 — 시안보다 이 결정을 우선한다).
            title: report.alias,
          ),
          body: Column(
            children: [
              if (report.highlightNotice != null)
                _noticeBar(report.highlightNotice!),
              Expanded(child: _document(layout, data, marks)),
              // 레일·범례·캐러셀은 시스템 제스처 바 위로 올린다.
              SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _rail(layout, marks),
                    _bottomInfo(report, marks),
                    _carouselBar(layout, marks),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── 문서 (세로 연속 스크롤) ───────────────────────────────────────────────

  Widget _document(
    RegistryDocumentLayout layout,
    _ViewerData data,
    List<RegistryHighlight> marks,
  ) {
    return ColoredBox(
      color: AppColors.viewerBackdrop,
      // Listener는 제스처 아레나에 끼어들지 않고 손가락 수만 센다. 두 번째 손가락이
      // 닿는 시점은 드래그·확대 중 누가 이길지 정해지기 **전**이라, 여기서 드래그
      // 인식기를 빼면 확대가 이긴다.
      child: Listener(
        onPointerDown: (_) => _changePointers(1),
        onPointerUp: (_) => _changePointers(-1),
        onPointerCancel: (_) => _changePointers(-1),
        child: NotificationListener<ScrollMetricsNotification>(
          // 스크롤 없이 지표만 바뀌는 순간(첫 레이아웃·회전)에도 레일을 맞춘다.
          onNotification: (n) {
            _metrics.value = _ScrollSnapshot(
              offset: n.metrics.pixels,
              viewport: n.metrics.viewportDimension,
              maxExtent: n.metrics.maxScrollExtent,
            );
            return false;
          },
          child: ValueListenableBuilder<bool>(
            valueListenable: _scrollLocked,
            builder: (context, locked, _) => ListView.builder(
              controller: _scroll,
              physics: locked
                  ? const NeverScrollableScrollPhysics()
                  : const ClampingScrollPhysics(),
              padding: const EdgeInsets.symmetric(
                horizontal: kDocPadH,
                vertical: kDocPadV,
              ),
              itemCount: layout.pageCount,
              // 화면 밖으로 나간 쪽은 놓아준다 — 1200~4000px 사진 5장을 전부
              // 살려 두면 메모리가 버티지 못한다.
              addAutomaticKeepAlives: false,
              itemBuilder: (context, i) => Padding(
                padding: EdgeInsets.only(
                  bottom: i == layout.pageCount - 1 ? 0 : kPageGap,
                ),
                child: SizedBox(
                  height: layout.pageHeight(i),
                  child: _RegistryPage(
                    path: _paths[i],
                    pageIndex: i,
                    intrinsic: data.sizes[i],
                    highlights: [
                      for (final m in marks)
                        if (m.page == i) m,
                    ],
                    selected: _selected,
                    draw: _draw,
                    // 사진 위 표시를 직접 누르면 카드와 같은 대접을 한다 —
                    // 고르고, 다시 긋고, 설명까지 연다.
                    onTapHighlight: (h) {
                      _select(h, layout, marks);
                      showRegistryMarkSheet(context, h);
                    },
                    onZoomChanged: (z) => _onZoomChanged(i, z),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 위치 레일 ────────────────────────────────────────────────────────────

  Widget _rail(RegistryDocumentLayout layout, List<RegistryHighlight> marks) {
    return ValueListenableBuilder<_ScrollSnapshot>(
      valueListenable: _metrics,
      builder: (context, metrics, _) => RegistryPositionRail(
        layout: layout,
        marks: marks,
        offset: metrics.offset,
        viewport: metrics.viewport,
        onSeek: (fraction) => _seek(fraction, layout),
      ),
    );
  }

  // ── 하단 (범례 + 표시하지 못한 것 한 줄 + 카드 캐러셀) ─────────────────────
  // 캐러셀이 들어오면서 하단이 네 겹이 됐다. 어느 것도 뺄 수 없어서 대신 **줄였다** —
  // 범례는 색-의미를 담당하고(두 표시가 형태가 같아 색이 유일한 단서다), 회색 한 줄은
  // 카드 개수와 리포트가 안 맞는 이유를 댄다. 자세한 높이는
  // test/registry_viewer_layout_test.dart가 360dp 기준으로 재고 상한을 지킨다.

  Widget _bottomInfo(AnalysisReport report, List<RegistryHighlight> marks) {
    final unmarked = unmarkedNotice(report.checkedNotes);
    final legend = MarkLegend.fromKinds(marks.map((m) => m.markKind));
    if (legend.isEmpty && unmarked == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (legend.isNotEmpty) _LegendRow(entries: legend),
          if (unmarked != null) ...[
            if (legend.isNotEmpty) const SizedBox(height: 2),
            // 개수가 안 맞는 이유를 대는 줄 — 회색 한 줄로 조용히, 그러나 반드시.
            // 두 줄을 넘기면 하단이 잠식되므로 자르되, 같은 내용이 리포트에도 있다.
            Text(
              unmarked,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.caption.copyWith(height: 1.35),
            ),
          ],
        ],
      ),
    );
  }

  Widget _carouselBar(
    RegistryDocumentLayout layout,
    List<RegistryHighlight> marks,
  ) {
    return ValueListenableBuilder<String?>(
      valueListenable: _selected,
      builder: (context, selectedId, _) => RegistryMarkCarousel(
        marks: marks,
        selectedId: selectedId,
        controller: _carousel,
        // 본문 탭 — 위치만 보여 준다. 시트는 열지 않는다(시안).
        onTapCard: (m) => _select(m, layout, marks),
        // '자세히 보기' 탭 — 같은 이동 + **첫 탭에 바로** 시트.
        onTapDetail: (m) {
          _select(m, layout, marks);
          showRegistryMarkSheet(context, m);
        },
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

  Scaffold _emptyScaffold() => Scaffold(
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

}

/// 뷰어 앱바 — 흰 바탕에 아래 실선 1dp.
///
/// **우측 카운트 뱃지를 두지 않는다** — 진입 카드에서 이미 세어 보여줬고, 같은 숫자를
/// 두 곳에 두면 종류가 늘 때마다 둘이 어긋난다.
///
/// 제목은 **매물 별칭**이다. 시안은 화면 이름('내가 올린 사진에서 보기')을 적지만,
/// ⑴ 이 화면은 캡처해 배우자·부모에게 보내는 용도가 있어 주소가 없으면 무슨 집인지
/// 알 수 없고, ⑵ 방금 그 문구가 적힌 카드를 눌러 들어왔고 화면에 자기 사진이 깔려 있어
/// 앱바가 이미 아는 것을 반복하게 된다(2026-07-27 서연 리뷰).
class _ViewerAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _ViewerAppBar({this.title = '내가 올린 사진에서 보기'});

  final String title;

  static const double _barHeight = 46;

  @override
  Size get preferredSize => const Size.fromHeight(_barHeight + 1);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      toolbarHeight: _barHeight,
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleSpacing: 0,
      title: Text(
        title,
        style: AppTypography.bodyStrong,
        overflow: TextOverflow.ellipsis,
      ),
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, thickness: 1, color: AppColors.line),
      ),
    );
  }
}

/// 화면이 쓰는 데이터 한 묶음 — 리포트 + 사진 원본 크기.
class _ViewerData {
  _ViewerData({required this.report, required this.sizes})
    : marks = [
        if (report != null)
          for (final h in report.highlights)
            // 사진 장수보다 큰 page 인덱스는 버린다 — 엉뚱한 사진에 그리지 않기 위함.
            if (h.page >= 0 && h.page < sizes.length) h,
      ];

  final AnalysisReport? report;
  final List<Size> sizes;

  /// 실제로 그릴 수 있는 표시들. 번호(badge)는 **서버가 매긴 것을 그대로 쓴다** —
  /// 앱이 다시 매기면 리포트·시트에 적힌 번호와 어긋난다.
  final List<RegistryHighlight> marks;

  RegistryDocumentLayout? _cached;
  double _cachedWidth = -1;

  /// 폭이 같으면 재계산하지 않는다 — 스크롤 프레임마다 다시 만들 이유가 없다.
  RegistryDocumentLayout layoutFor(double availableWidth) {
    if (_cached != null && _cachedWidth == availableWidth) return _cached!;
    _cachedWidth = availableWidth;
    return _cached = RegistryDocumentLayout.fromSizes(
      sizes: sizes,
      pageWidth: math.max(0.0, availableWidth - kDocPadH * 2),
    );
  }
}

/// 레일이 보는 스크롤 지표. 값 클래스가 아니라 **매번 새 인스턴스**라, 같은 값이라도
/// ValueNotifier가 알려 준다(첫 레이아웃에서 0 → 0으로 보이지만 뷰포트가 채워진다).
class _ScrollSnapshot {
  const _ScrollSnapshot({
    required this.offset,
    required this.viewport,
    required this.maxExtent,
  });

  const _ScrollSnapshot.empty() : offset = 0, viewport = 0, maxExtent = 0;

  final double offset;
  final double viewport;
  final double maxExtent;
}

// ══════════════════════════════════════════════════════════════════════════
// 사진 1장 (이미지 + 오버레이)
// ══════════════════════════════════════════════════════════════════════════

class _RegistryPage extends StatefulWidget {
  const _RegistryPage({
    required this.path,
    required this.pageIndex,
    required this.intrinsic,
    required this.highlights,
    required this.selected,
    required this.draw,
    required this.onTapHighlight,
    required this.onZoomChanged,
  });

  final String path;
  final int pageIndex;

  /// 서버로 보낸 그 JPEG의 원본 픽셀 크기. [Size.zero]면 읽지 못한 것이다.
  final Size intrinsic;

  final List<RegistryHighlight> highlights;

  /// 선택된 표시 id. Listenable로 받는 이유: 스크롤 연동으로 매 프레임 바뀔 수 있는데
  /// 그때마다 이 위젯을 다시 만들면 사진이 재디코딩되고 확대가 풀린다.
  final ValueListenable<String?> selected;

  /// 형광펜 그어짐 진행도 0~1.
  final Animation<double> draw;
  final void Function(RegistryHighlight) onTapHighlight;

  /// 확대 상태가 바뀔 때 부모에게 알린다 — 부모는 이 값으로 세로 스크롤을 잠근다.
  final void Function(bool zoomed) onZoomChanged;

  @override
  State<_RegistryPage> createState() => _RegistryPageState();
}

class _RegistryPageState extends State<_RegistryPage> {
  final TransformationController _transform = TransformationController();

  /// 마지막으로 부모에게 알린 확대 여부 — 같은 값을 반복해 올리지 않기 위함.
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_reportZoom);
  }

  @override
  void dispose() {
    _transform.removeListener(_reportZoom);
    _transform.dispose();
    // 확대된 채로 화면 밖으로 밀려 폐기될 수 있다. 알리지 않으면 스크롤이 영영 잠긴다.
    // 지금 바로 알리면 해체·레이아웃 도중 부모가 setState를 하게 되어 터지므로
    // **다음 프레임에** 알린다(부모는 이미 사라졌을 수 있어 mounted를 본다).
    if (_zoomed) {
      final notify = widget.onZoomChanged;
      WidgetsBinding.instance.addPostFrameCallback((_) => notify(false));
    }
    super.dispose();
  }

  /// 확대되면(배율>1) 부모가 세로 스크롤을 잠근다.
  /// 임계를 1.01로 둔 이유: 확대를 풀 때 배율이 1.0000001 같은 값으로 남는다.
  void _reportZoom() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    _zoomed = zoomed;
    widget.onZoomChanged(zoomed);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 쪽 높이를 종횡비로 미리 잡아 두었으므로 표시 크기 = 이 상자 크기다.
        final display = constraints.biggest;
        return DecoratedBox(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            boxShadow: [
              BoxShadow(
                color: AppColors.viewerShadowInk,
                blurRadius: 6,
                offset: Offset(0, 1),
              ),
            ],
          ),
          // ⚠ 확대는 이 위젯만으로는 동작하지 않는다. 부모 Scrollable의 세로 드래그
          //   인식기가 제스처 아레나에서 먼저 이기기 때문에, 부모가 손가락 2개를
          //   감지해 스크롤을 꺼 줘야 한다(`_scrollLocked` 참고).
          child: InteractiveViewer(
            transformationController: _transform,
            minScale: 1,
            maxScale: 6,
            // 뱃지를 사진 안쪽으로 클램프하므로 여백이 필요 없다. 여백을 주면 배율 1에서도
            // 사진이 움직여 세로 스크롤과 다툰다.
            boundaryMargin: EdgeInsets.zero,
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
                  _image(context, display),
                  // 확대 배율·선택·그어짐 세 가지 중 하나라도 바뀌면 다시 그린다.
                  // 사진(Image)은 이 builder 밖에 있어 다시 디코딩되지 않는다.
                  AnimatedBuilder(
                    animation: Listenable.merge([
                      _transform,
                      widget.selected,
                      widget.draw,
                    ]),
                    builder: (_, _) => RegistryHighlightOverlay(
                      highlights: widget.highlights,
                      selectedId: widget.selected.value,
                      drawProgress: widget.draw.value,
                      scale: _transform.value.getMaxScaleOnAxis(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _image(BuildContext context, Size display) {
    // 확대해도 글자가 읽히도록 화면 폭의 몇 배까지만 디코딩한다. 원본이 더 작으면
    // cacheWidth가 원본보다 커져 오히려 확대 디코딩이 되므로 원본 폭에서 자른다.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final wanted = (display.width * dpr * kZoomDecodeFactor).round();
    final cacheWidth = widget.intrinsic.width > 0
        ? math.min(wanted, widget.intrinsic.width.round())
        : wanted;
    return Image.file(
      File(widget.path),
      fit: BoxFit.fill,
      filterQuality: FilterQuality.medium,
      cacheWidth: cacheWidth > 0 ? cacheWidth : null,
      errorBuilder: (_, _, _) => _brokenPhoto(),
    );
  }

  Widget _brokenPhoto() => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Text(
        '${widget.pageIndex + 1}쪽 사진을 불러오지 못했어요.\n'
        '분석 결과와 판정은 리포트에서 그대로 확인할 수 있어요.',
        textAlign: TextAlign.center,
        style: AppTypography.caption,
      ),
    ),
  );

}

/// 사진 위에 그리는 표시 레이어 — 위젯 테스트에서 단독으로 띄울 수 있게 분리했다.
class RegistryHighlightOverlay extends StatelessWidget {
  const RegistryHighlightOverlay({
    super.key,
    required this.highlights,
    this.selectedId,
    this.drawProgress = 1.0,
    this.scale = 1.0,
  });

  final List<RegistryHighlight> highlights;

  /// 선택된 표시 — 형광펜이 진해지고 번호 뱃지가 여기에만 붙는다.
  final String? selectedId;

  /// 선택된 표시의 그어짐 진행도 0~1. 나머지 표시는 항상 다 그려진 상태다.
  final double drawProgress;

  /// 현재 확대 배율 — 뱃지를 이 값으로 나눠 그려 **화면상 크기를 일정하게** 유지한다.
  final double scale;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: HighlightPainter(
        highlights: highlights,
        selectedId: selectedId,
        drawProgress: drawProgress,
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
    this.selectedId,
    this.drawProgress = 1.0,
    this.scale = 1.0,
  });

  final List<RegistryHighlight> highlights;
  final String? selectedId;
  final double drawProgress;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final s = scale <= 0 ? 1.0 : scale;
    final progress = drawProgress.clamp(0.0, 1.0);
    RegistryHighlight? selected;
    for (final h in highlights) {
      final isSelected = h.id == selectedId;
      if (isSelected) selected = h;
      _paintHighlighter(
        canvas,
        highlightRect(h.box, size),
        h,
        selected: isSelected,
        // 선택된 것만 그어지는 중일 수 있다. 나머지는 언제나 다 그어진 상태다.
        progress: isSelected ? progress : 1.0,
      );
    }
    // 뱃지는 형광펜을 전부 그린 뒤에 — 아니면 뒤 항목의 형광펜이 뱃지를 덮는다.
    if (selected != null) {
      _paintBadge(
        canvas,
        highlightRect(selected.box, size),
        selected,
        size,
        s,
        progress,
      );
    }
  }

  /// 형광펜 — **곱하기(multiply)로 겹친다.**
  /// 불투명하게 칠하면 정작 그 글자를 못 읽는 최악이 된다. 글자가 비쳐 보여야
  /// 사용자가 종이와 화면을 대조할 수 있다.
  ///
  /// [progress]가 1보다 작으면 **왼쪽부터 그 비율만큼만** 칠한다 — 형광펜을 왼→오로
  /// 긋는 동작이다. 모서리 둥글기는 원래 사각형 기준으로 두고 클립만 좁혀,
  /// 그어지는 도중에 오른쪽 끝이 둥글어졌다 각졌다 하지 않게 한다.
  void _paintHighlighter(
    Canvas canvas,
    Rect rect,
    RegistryHighlight h, {
    required bool selected,
    required double progress,
  }) {
    final paint = Paint()
      ..color = AppColors.markHighlight(h.markKind.tone, selected: selected)
      ..blendMode = BlendMode.multiply;
    if (progress >= 1) {
      canvas.drawRRect(kMarkRadius.toRRect(rect), paint);
      return;
    }
    if (progress <= 0) return;
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(rect.left, rect.top, rect.width * progress, rect.height),
    );
    canvas.drawRRect(kMarkRadius.toRRect(rect), paint);
    canvas.restore();
  }

  /// 번호 뱃지 — 선택된 표시 하나에만.
  ///
  /// 크기를 `/ s` 로 나눠 **확대해도 화면상 19dp를 유지**한다. 작은 글씨를 보려고
  /// 확대했는데 뱃지가 6배로 커져 그 글자를 덮으면 확대의 목적이 무너진다.
  /// 위치는 형광펜 **오른쪽** 바깥 — 왼쪽에 두면 등기부의 순위번호 칸을 가린다.
  /// 그어지는 동안에는 펜 끝을 따라온다(다 그으면 원래 자리에 선다).
  void _paintBadge(
    Canvas canvas,
    Rect rect,
    RegistryHighlight h,
    Size size,
    double s,
    double progress,
  ) {
    final color = AppColors.markSolid(h.markKind.tone);
    final r = kBadgeDiameter / 2 / s;
    final tip = rect.left + rect.width * progress;
    final desired = Offset(tip + kBadgeGap / s + r, rect.center.dy);
    final center = Offset(
      desired.dx.clamp(r + 1, math.max(r + 1, size.width - r - 1)),
      desired.dy.clamp(r + 1, math.max(r + 1, size.height - r - 1)),
    );
    canvas.drawCircle(
      center.translate(0, 1 / s),
      r,
      Paint()
        ..color = const Color(0x47101814) // rgba(16,24,20,.28)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 / s),
    );
    canvas.drawCircle(center, r, Paint()..color = color);
    final painter = TextPainter(
      text: TextSpan(
        text: '${h.badge}',
        style: AppTypography.label.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 11 / s,
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
      old.selectedId != selectedId ||
      old.drawProgress != drawProgress ||
      old.scale != scale;
}

// ══════════════════════════════════════════════════════════════════════════
// 위치 레일
// ══════════════════════════════════════════════════════════════════════════

/// 문서 전체에서 **지금 어디를 보고 있는지 + 표시가 어디에 있는지**를 한 줄로.
///
/// 이것이 있어서 맨 위(1쪽)에서 시작해도 "표시를 못 찾겠다"가 되지 않는다.
/// 쪽 눈금은 균등 5칸이 아니라 **실제 쪽 높이 비율**이다(쪽마다 해상도가 다르다).
class RegistryPositionRail extends StatelessWidget {
  const RegistryPositionRail({
    super.key,
    required this.layout,
    required this.marks,
    required this.offset,
    required this.viewport,
    this.onSeek,
  });

  final RegistryDocumentLayout layout;
  final List<RegistryHighlight> marks;
  final double offset;
  final double viewport;

  /// 레일 위 비율(0~1)로 점프.
  final ValueChanged<double>? onSeek;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      // 시안 규격(약 46dp)에 맞춘 여백. 하단이 네 겹이라 여기서 아낀 1dp가 그대로
      // 문서 영역이 된다.
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 5, AppSpacing.lg, 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return Semantics(
            label: '문서 위치 — 전체 ${layout.pageCount}쪽 중 표시 ${marks.length}곳',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _seek(d.localPosition.dx, width),
                  onHorizontalDragStart: (d) => _seek(d.localPosition.dx, width),
                  onHorizontalDragUpdate: (d) =>
                      _seek(d.localPosition.dx, width),
                  child: SizedBox(
                    height: kRailTouchHeight,
                    child: CustomPaint(
                      painter: _RailPainter(
                        layout: layout,
                        marks: marks,
                        offset: offset,
                        viewport: viewport,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                const SizedBox(height: 1),
                SizedBox(
                  height: 13,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (var i = 0; i < layout.pageCount; i++)
                        Positioned(
                          left: layout.pageCenterFraction(i) * width - 8,
                          top: 0,
                          width: 16,
                          child: Text(
                            '${i + 1}',
                            textAlign: TextAlign.center,
                            // 10sp라 시스템 확대를 그대로 받으면 쪽번호끼리 겹친다.
                            // 레일은 보조 안내이고, 쪽 번호의 원본은 종이 자체다.
                            textScaler: MediaQuery.textScalerOf(
                              context,
                            ).clamp(maxScaleFactor: 1.2),
                            style: AppTypography.label.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _seek(double dx, double width) {
    if (onSeek == null || width <= 0) return;
    onSeek!((dx / width).clamp(0.0, 1.0));
  }
}

class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.layout,
    required this.marks,
    required this.offset,
    required this.viewport,
  });

  final RegistryDocumentLayout layout;
  final List<RegistryHighlight> marks;
  final double offset;
  final double viewport;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final track = Rect.fromCenter(
      center: Offset(size.width / 2, cy),
      width: size.width,
      height: kRailTrackHeight,
    );
    final trackRRect = RRect.fromRectAndRadius(
      track,
      const Radius.circular(kRailTrackHeight / 2),
    );
    canvas.drawRRect(trackRRect, Paint()..color = AppColors.viewerRailTrack);

    // 쪽 경계 눈금 — 균등 분할이 아니라 실제 높이 비율.
    final tick = Paint()..color = AppColors.surface;
    for (var i = 0; i < layout.pageCount - 1; i++) {
      final x = layout.boundaryFraction(i) * size.width;
      canvas.drawRect(Rect.fromLTWH(x - 0.5, track.top, 1, track.height), tick);
    }

    // 현재 위치 필 — 트랙 위아래로 살짝 넘치게 그려 트랙과 구분한다.
    if (viewport > 0 && layout.totalHeight > 0) {
      final left = (offset / layout.totalHeight).clamp(0.0, 1.0) * size.width;
      final w = (viewport / layout.totalHeight).clamp(0.0, 1.0) * size.width;
      final pill = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          math.min(left, math.max(0.0, size.width - w)),
          track.top - 3,
          w,
          track.height + 6,
        ),
        const Radius.circular(kRailTrackHeight),
      );
      canvas.drawRRect(
        pill,
        Paint()..color = AppColors.primary.withValues(alpha: 0.22),
      );
      canvas.drawRRect(
        pill,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = AppColors.primary,
      );
    }

    // 표시 점 — 필보다 위에 그려 현재 위치에 가려지지 않게 한다.
    final r = kRailDotDiameter / 2;
    for (final m in marks) {
      final y = layout.markCenterY(m.page, m.box.y, m.box.h);
      // 점이 트랙 끝을 넘어가지 않게 반지름만큼 안으로 붙인다.
      final double maxX = math.max(r, size.width - r);
      final double x = (layout.fractionOf(y) * size.width)
          .clamp(r, maxX)
          .toDouble();
      canvas.drawCircle(
        Offset(x, cy),
        r,
        Paint()..color = AppColors.surface,
      );
      canvas.drawCircle(
        Offset(x, cy),
        r - kRailDotBorder,
        Paint()..color = AppColors.markDot(m.markKind.tone),
      );
    }
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.offset != offset ||
      old.viewport != viewport ||
      old.marks != marks ||
      old.layout != layout;
}

// ══════════════════════════════════════════════════════════════════════════
// 작은 부품
// ══════════════════════════════════════════════════════════════════════════

/// 번호가 든 원 — 시트·카드에서 사진 위 뱃지와 같은 것임을 알리는 표식.
class BadgeCircle extends StatelessWidget {
  const BadgeCircle({
    super.key,
    required this.number,
    required this.color,
    this.diameter = 23,
  });

  final int number;
  final Color color;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        '$number',
        // 사진 위 뱃지와 동작을 맞춘다(그쪽은 캔버스라 시스템 글꼴 확대가 안 걸린다)
        textScaler: TextScaler.noScaling,
        style: AppTypography.label.copyWith(
          color: Colors.white,
          fontSize: diameter * 0.54,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 범례 — **표시에 실제로 있는 종류로만** 만든다(MarkLegend 참조).
class _LegendRow extends StatelessWidget {
  const _LegendRow({required this.entries});

  final List<MarkLegendEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final e in entries)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 20,
                height: 11,
                decoration: BoxDecoration(
                  color: AppColors.markHighlight(e.tone, selected: false),
                  borderRadius: kMarkRadius,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(e.label, style: AppTypography.caption),
            ],
          ),
      ],
    );
  }
}
