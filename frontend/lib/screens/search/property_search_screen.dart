/// S-04 매물 분석 — **촬영 스튜디오** (2026-08-03 디자인 핸드오프 안 B로 전면 재구현).
///
/// 핵심 컨셉: **이 화면은 서류를 찍는 도구다. 금액은 다 찍은 다음에 묻는다.**
/// - 사진 0장: 화면 전체가 딥그린이 되고 지시가 하나뿐이다 — [촬영 시작].
///   **[분석하기] 버튼을 아예 그리지 않는다.** 비활성 버튼은 "왜 안 눌리지"만 남긴다.
/// - 사진 1장 이상: 작업 모드로 바뀐다 — 사진 트레이 + 금액 카드 + 하단 고정 바.
///
/// 이 앱만의 추가 (Phase 1·2 연결):
/// 시세 칸은 이제 **비워 두면 공공데이터로 찾아본다.** 다만 그 조회는 주소를 알아야
/// 하고 주소는 OCR 이후에 나오므로, **첫 분석에서는 이 화면에서 조회할 수 없다.**
/// 그래서 여기서는 "앞으로 일어날 일"을 미리 알려 주고([AmberHint]),
/// 재분석처럼 주소를 아는 경로에서 들어오면 [prefill]로 값과 출처 라벨을 받아 표시한다.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../common/analyze_gate.dart' show AnalyzeStart;
import '../../design_system/components/amber_hint.dart';
import '../../design_system/components/mascot_safe.dart';
import '../../design_system/components/photo_tray.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../models/market_price_source.dart';
import '../../state/registry_photo_store.dart';
import '../../utils/money_format.dart';
import 'capture_issue_panel.dart';
import 'capture_loop_route.dart';
import '../../design_system/text/app_text.dart';

/// 재진입(재분석 등)에서 넘겨받는 미리 채울 값.
///
/// ⚠ **2026-08-03 현재 이걸 채워서 넘기는 경로는 아직 없다.** 리포트 화면의 [재분석]은
///   스텁이고 주소를 들고 오지 않는다. 억지로 만들지 않고, **UI가 라벨을 받을 수 있는
///   구조만 열어 둔다** — 재분석 흐름이 생기면 이 클래스만 채워 넘기면 된다.
class PropertySearchPrefill {
  const PropertySearchPrefill({
    this.marketPriceWon,
    this.marketPriceSource = MarketPriceSource.unknown,
    this.marketPriceAsOf,
    this.marketPriceSampleCount,
    this.alias,
  });

  final int? marketPriceWon;
  final MarketPriceSource marketPriceSource;
  final String? marketPriceAsOf;
  final int? marketPriceSampleCount;
  final String? alias;
}

class PropertySearchScreen extends StatefulWidget {
  const PropertySearchScreen({
    super.key,
    this.prefill,
    this.startWith,
    this.captureOne = defaultCaptureOne,
    this.pickMany = defaultPickMany,
  });

  final PropertySearchPrefill? prefill;

  /// 들어오자마자 열 것 — 카메라(촬영 루프) 또는 갤러리 (2026-10-30 홈 리뉴얼).
  /// 고른 쪽에서 한 장도 안 가져오고 돌아오면 이 화면도 닫고 출발한 곳으로 돌아간다(첫 안내 화면을 거치지 않는다).
  final AnalyzeStart? startWith;

  /// 카메라·갤러리 주입 지점 — 위젯이 `image_picker` 타입에 직접 매달리지 않게
  /// 함수로 뺐다(테스트에서 카메라 없이 촬영 루프를 돌리기 위해).
  final CaptureOne captureOne;
  final PickMany pickMany;

  @override
  State<PropertySearchScreen> createState() => _PropertySearchScreenState();
}

class _PropertySearchScreenState extends State<PropertySearchScreen> {
  static const int _maxImages = 10;

  final List<String> _photos = [];

  /// 서버가 사진 품질로 거절한 결과 (없으면 null). 문제인 장을 다시 찍어 바꾸면 그 장은 목록에서 빠진다.
  CaptureRejection? _rejection;

  /// 거절 뒤에 **이미 바꾼** 장 번호(0부터) — 다시 보내기 전에 "바꿨어요" 표시를 단다.
  final Set<int> _replaced = {};
  final TextEditingController _depositCtrl = TextEditingController();
  final TextEditingController _priceCtrl = TextEditingController();
  final TextEditingController _aliasCtrl = TextEditingController();

  // 처음부터 펼쳐 둔다 — 접혀 있으면 대부분 건너뛴다(2026-10-30 규혁). 접기는 그대로 된다.
  bool _priceOpen = true;
  bool _aliasOpen = true;
  bool _hintsOn = false;

  /// 시세 칸에 지금 들어 있는 값의 출처. 사용자가 손대면 곧바로 manual이 된다 —
  /// 자동 조회값을 사용자가 고쳤는데 "자동 조회"라고 계속 말하면 거짓말이 된다.
  MarketPriceSource _priceSource = MarketPriceSource.unknown;
  String? _priceAsOf;
  int? _priceSampleCount;

  @override
  void initState() {
    super.initState();
    final PropertySearchPrefill? p = widget.prefill;
    if (p != null) {
      if (p.marketPriceWon != null) {
        _priceCtrl.text = '${p.marketPriceWon! ~/ 10000}';
        _priceSource = p.marketPriceSource;
        _priceAsOf = p.marketPriceAsOf;
        _priceSampleCount = p.marketPriceSampleCount;
        _priceOpen = true; // 미리 채운 값은 접어 두면 못 본다
      }
      if (p.alias != null && p.alias!.isNotEmpty) {
        _aliasCtrl.text = p.alias!;
      }
    }
    final AnalyzeStart? start = widget.startWith;
    if (start != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _startRightAway(start),
      );
    }
  }

  /// 고른 쪽을 바로 연다. 한 장도 안 가져왔으면 이 화면을 닫는다(갤러리 권한 안내가 떴으면 그대로 둔다).
  Future<void> _startRightAway(AnalyzeStart start) async {
    if (!mounted) return;
    final bool gotPermissionSheet = switch (start) {
      AnalyzeStart.camera => await _openCaptureLoop().then((_) => false),
      AnalyzeStart.gallery => await _pickFromGallery(),
    };
    if (!mounted || gotPermissionSheet || _photos.isNotEmpty) return;
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _depositCtrl.dispose();
    _priceCtrl.dispose();
    _aliasCtrl.dispose();
    super.dispose();
  }

  // ── 값 ────────────────────────────────────────────────────────────────────

  /// 만원 단위 입력 → 원. 비었으면 null.
  int? _manwonToWon(String text) {
    final String digits = text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    return int.parse(digits) * 10000;
  }

  /// 다시 찍어야 할 장이 남아 있으면 보내지 않는다(D6) — 같은 사진을 또 보내면 서버가 또 거절한다.
  bool get _canAnalyze =>
      _photos.isNotEmpty &&
      (_manwonToWon(_depositCtrl.text) ?? 0) > 0 &&
      _pagesStillToRetake.isEmpty;

  // ── 촬영 루프 ─────────────────────────────────────────────────────────────

  Future<void> _openCaptureLoop() async {
    if (_photos.length >= _maxImages) {
      _toast('사진은 최대 $_maxImages장까지 올릴 수 있어요');
      return;
    }
    final CaptureLoopResult? result = await Navigator.of(context).push(
      MaterialPageRoute<CaptureLoopResult>(
        fullscreenDialog: true,
        builder: (_) => CaptureLoopRoute(
          alreadyTaken: _photos.length,
          maxPhotos: _maxImages,
          captureOne: widget.captureOne,
        ),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      for (final String p in result.newPaths) {
        if (_photos.length < _maxImages) _photos.add(p);
      }
    });
    if (result.hitLimit) _toast('사진은 최대 $_maxImages장까지 올릴 수 있어요');
  }

  /// 갤러리에서 고르기. 권한 안내 시트를 띄웠으면 true.
  Future<bool> _pickFromGallery() async {
    if (_photos.length >= _maxImages) {
      _toast('사진은 최대 $_maxImages장까지 올릴 수 있어요');
      return false;
    }
    try {
      final List<String> picked = await widget.pickMany();
      if (!mounted || picked.isEmpty) return false;
      final int room = _maxImages - _photos.length;
      setState(() => _photos.addAll(picked.take(room)));
      if (picked.length > room) {
        _toast('사진은 최대 $_maxImages장까지 올릴 수 있어요');
      }
      return false;
    } catch (_) {
      if (mounted) _showPermissionSheet();
      return true;
    }
  }

  Future<void> _openViewer(int index) async {
    final PhotoViewerResult? result = await Navigator.of(context).push(
      MaterialPageRoute<PhotoViewerResult>(
        fullscreenDialog: true,
        builder: (_) =>
            PhotoViewerRoute(paths: List.of(_photos), initialIndex: index),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      // 크게 보기에서 지우거나 순서를 바꿨으면 "몇 쪽이 문제" 안내가 어긋난다 → 접는다.
      if (!_samePaths(result.paths)) _clearRejection();
      _photos
        ..clear()
        ..addAll(result.paths);
    });
    // [이 장 다시 찍기] — 그 장을 **그 자리에서** 바꾼다(예전에는 맨 뒤에 새 장이 붙었다, 지수 리뷰 #1).
    final int? retake = result.retakeIndex;
    if (retake != null) await _replacePhotoAt(retake);
  }

  bool _samePaths(List<String> other) {
    if (other.length != _photos.length) return false;
    for (var i = 0; i < other.length; i++) {
      if (other[i] != _photos[i]) return false;
    }
    return true;
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final String p = _photos.removeAt(oldIndex);
      _photos.insert(newIndex, p);
      // 장 순서가 바뀌면 "몇 쪽이 문제"라는 안내가 엉뚱한 장을 가리킨다 → 안내를 접는다.
      _clearRejection();
    });
  }

  // ── 그 장만 다시 찍기 (P1-1) ───────────────────────────────────────────────

  void _clearRejection() {
    _rejection = null;
    _replaced.clear();
  }

  /// 문제인 장 하나를 다시 찍어 **그 자리에** 바꿔 끼운다. 나머지 장·입력값은 그대로다.
  Future<void> _retakePage(CapturePageIssue page) =>
      _replacePhotoAt(page.index, tip: page.tip);

  /// [index]번째 장을 다시 찍어 그 자리에 바꿔 끼운다 — 거절 안내의 [그 장만 다시 찍기]와
  /// 크게 보기의 [이 장 다시 찍기]가 같은 흐름을 쓴다. 서버가 그 장에 이유를 줬으면 함께 보여 준다.
  Future<void> _replacePhotoAt(int index, {String? tip}) async {
    if (index < 0 || index >= _photos.length) return;
    final String? reason = tip ?? _rejection?.check.issueFor(index)?.tip;
    final CaptureLoopResult? result = await Navigator.of(context).push(
      MaterialPageRoute<CaptureLoopResult>(
        fullscreenDialog: true,
        builder: (_) => CaptureLoopRoute(
          alreadyTaken: _photos.length,
          maxPhotos: _maxImages,
          captureOne: widget.captureOne,
          replacePage: index,
          replaceTip: reason,
        ),
      ),
    );
    if (!mounted || result == null || result.newPaths.isEmpty) return;
    // ⚠ 토스트를 띄우지 않는다 — 떠 있는 2.6초 동안 바로 아래 [분석하기]를 덮어 누를 수 없다.
    //   무엇을 바꿨고 무엇이 남았는지는 안내 패널이 그 자리에서 바뀌어 말한다.
    setState(() {
      _photos[index] = result.newPaths.last;
      _replaced.add(index);
    });
  }

  /// 거절됐는데 아직 안 바꾼 **심한** 장들 — 이게 남아 있으면 같은 사진을 또 보내는 셈이다.
  List<CapturePageIssue> get _pagesStillToRetake => [
    for (final p in _rejection?.check.pages ?? const <CapturePageIssue>[])
      if (p.severe && !_replaced.contains(p.index)) p,
  ];

  /// 분석 화면에서 돌아온 결과를 받는다 — 사진 품질 거절이면 장별 안내를 띄운다.
  void _onAnalysisReturned(Object? result) {
    if (!mounted || result is! CaptureRejection) return;
    setState(() {
      _rejection = result;
      _replaced.clear();
    });
  }

  // ── 안내 ──────────────────────────────────────────────────────────────────

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: AppText(
            message,
            style: AppTypography.body.copyWith(color: Colors.white),
          ),
          backgroundColor: AppColors.primaryDeep,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 2600),
          margin: const EdgeInsets.fromLTRB(
            AppSpacing.screenPadding,
            0,
            AppSpacing.screenPadding,
            AppSpacing.screenPadding,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
        ),
      );
  }

  void _showSheet({
    required String title,
    required String body,
    required String cta,
    required VoidCallback onCta,
  }) {
    showModalBottomSheet<void>(
      showDragHandle: false, // 손잡이는 직접 그린다 — 테마 손잡이와 겹쳐 두 개로 보였다 (2026-10-27)
      context: context,
      backgroundColor: AppColors.surface,
      barrierColor: AppColors.viewerSheetScrim,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenPadding,
            AppSpacing.sm,
            AppSpacing.screenPadding,
            AppSpacing.xxl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.line,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppText(title, style: AppTypography.title),
              const SizedBox(height: AppSpacing.sm),
              AppText(body, style: AppTypography.body),
              const SizedBox(height: AppSpacing.xl),
              SizedBox(
                width: double.infinity,
                height: AppSize.buttonHeight,
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    onCta();
                  },
                  child: AppText(cta),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showGuideSheet() => _showSheet(
    title: '등기부등본 발급 방법',
    body:
        '인터넷등기소에서 열람용으로 700원에 뗄 수 있어요. '
        '화면을 캡처하거나 출력해서 찍으면 돼요.',
    cta: '발급 방법 보기',
    onCta: () => context.push('/guide'),
  );

  // [주소로 찾기]는 뺐다(2026-10-23) — 누르면 "준비 중이에요"만 나오는 입구였다. 부스에서 심사위원이 누르면
  // 미완성으로 보인다(서연 리뷰 #4 "곧 제공" 버튼과 같은 기준: 만들 수 없으면 숨긴다). 주소→등기부 자동 조회(CODEF)는
  // NOW.md 8절 '하지 않는 것'이다 — 발표에서는 로드맵으로 말한다.

  void _showPermissionSheet() => _showSheet(
    title: '카메라·사진 권한이 필요해요',
    body:
        '등기부등본을 찍거나 가져오려면 카메라·사진 권한이 필요해요. '
        '${RegistryPhotoStore.retentionNotice}',
    cta: '확인',
    onCta: () {},
  );

  /// 물음표 — 사진 0장이면 발급 안내, 1장 이상이면 인라인 힌트 토글.
  /// (등기부가 없는 사람은 정확히 빈 상태에서 막힌다.)
  void _onHelp() {
    if (_photos.isEmpty) {
      _showGuideSheet();
    } else {
      setState(() => _hintsOn = !_hintsOn);
    }
  }

  Future<void> _analyze() async {
    final int? deposit = _manwonToWon(_depositCtrl.text);
    if (!_canAnalyze || deposit == null) return;
    setState(_clearRejection); // 다시 보내면 지난 안내는 접는다(새 결과가 오면 다시 띄운다)
    final Object? returned = await context.push<Object?>(
      '/loading',
      extra: AnalysisRequest(
        imagePaths: List.of(_photos),
        deposit: deposit,
        marketPrice: _manwonToWon(_priceCtrl.text),
        alias: _aliasCtrl.text,
      ),
    );
    _onAnalysisReturned(returned);
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bool empty = _photos.isEmpty;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: empty
          ? SystemUiOverlayStyle(
              statusBarColor: AppColors.primaryDeep,
              statusBarIconBrightness: Brightness.light,
              statusBarBrightness: Brightness.dark,
            )
          : SystemUiOverlayStyle(
              statusBarColor: AppColors.viewerBackdrop,
              statusBarIconBrightness: Brightness.dark,
              statusBarBrightness: Brightness.light,
            ),
      child: Scaffold(
        // 하단 고정 바가 body 안에 있으므로 이 값이 **주 버튼이 키보드에 안 가리는 근거**다.
        resizeToAvoidBottomInset: true,
        backgroundColor: empty ? AppColors.primaryDeep : AppColors.background,
        appBar: AppBar(
          backgroundColor: empty
              ? AppColors.primaryDeep
              : AppColors.viewerBackdrop,
          foregroundColor: empty ? Colors.white : AppColors.textStrong,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: AppText(
            '등기부등본 촬영',
            style: AppTypography.bodyStrong.copyWith(
              color: empty ? Colors.white : AppColors.textStrong,
            ),
          ),
          centerTitle: true,
          actions: [
            Semantics(
              button: true,
              label: empty ? '등기부등본 발급 안내' : '화면 도움말 켜고 끄기',
              child: IconButton(
                onPressed: _onHelp,
                icon: Icon(
                  _hintsOn && !empty ? Icons.help : Icons.help_outline,
                  color: _hintsOn && !empty
                      ? AppColors.caution
                      : (empty ? Colors.white : AppColors.textStrong),
                ),
              ),
            ),
          ],
        ),
        body: empty ? _emptyState() : _workMode(),
      ),
    );
  }

  // ── ① 빈 상태 (사진 0장) ─────────────────────────────────────────────────

  Widget _emptyState() {
    return Stack(
      children: [
        // 장식 원 — 딥그린 위 옅은 밝은 초록
        Positioned(
          top: -40,
          right: -60,
          child: Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              color: AppColors.primaryBright.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenPadding,
              0,
              AppSpacing.screenPadding,
              AppSpacing.screenPadding,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: Center(child: _paperStack())),
                AppText(
                  '등기부등본을\n한 장씩 찍어 주세요',
                  style: AppTypography.headline.copyWith(color: Colors.white),
                ),
                const SizedBox(height: AppSpacing.sm),
                AppText.rich(
                  TextSpan(
                    style: AppTypography.body.copyWith(
                      color: Colors.white.withValues(alpha: 0.72),
                    ),
                    children: [
                      // ⚠ 굵은 글씨는 **촬영 루프의 실제 버튼 라벨과 글자까지 같아야 한다.**
                      //   예전에는 여기가 '찍고 계속'이었는데 그런 버튼은 화면에 없다
                      //   (capture_loop_route.dart의 주 버튼은 '다음 장 찍기'다).
                      //   안내가 가리키는 버튼을 찾지 못하면 안내가 아니라 방해가 된다.
                      // '보통 3~5장이에요'는 뺐다(2026-08-14) — 장수는 등기부마다 다른데
                      // 숫자를 먼저 던지면 "3장이면 되는구나"로 읽혀 뒷장을 안 찍는다.
                      // 이 자리에서 알려야 할 것은 **어떻게 이어 찍는가** 하나뿐이다.
                      TextSpan(
                        text: '다음 장 찍기',
                        style: AppTypography.bodyStrong.copyWith(
                          color: Colors.white,
                        ),
                      ),
                      const TextSpan(text: '를 눌러 이어서 찍을 수 있어요.'),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                SizedBox(
                  height: AppSize.buttonHeight,
                  child: FilledButton.icon(
                    onPressed: _openCaptureLoop,
                    style: FilledButton.styleFrom(
                      // 이 화면은 밝게·어둡게 모두 진초록 바탕 — 흰 버튼 그대로
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF0B3D2A),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.button),
                      ),
                      textStyle: AppTypography.button,
                    ),
                    icon: const Icon(Icons.photo_camera, size: AppSize.iconMd),
                    label: const AppText('촬영 시작'),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                SizedBox(
                  height: AppSize.buttonHeight,
                  child: OutlinedButton.icon(
                    onPressed: _pickFromGallery,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.55),
                        width: 1.2,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.button),
                      ),
                      textStyle: AppTypography.button,
                    ),
                    icon: const Icon(Icons.photo_library, size: 22),
                    label: const AppText('갤러리에서 고르기'),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _footLink('등기부등본이 없어요', _showGuideSheet, strong: true),
                  ],
                ),
                // ⑤ 사진 0장일 때 [분석하기] 버튼은 **아예 그리지 않는다.**
                //    비활성 버튼을 보여 주면 "왜 안 눌리지"만 남고, 지금 해야 할 일
                //    ([촬영 시작])에서 눈을 뺏는다.
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _paperStack() {
    return SizedBox(
      width: 190,
      height: 200,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _paper(left: 6, top: 26, angle: -9),
          _paper(left: 34, top: 16, angle: -2),
          _paper(left: 62, top: 30, angle: 7, strongShadow: true),
          const Positioned(
            right: -16,
            bottom: -14,
            child: MascotSafe(size: 78, state: MascotState.info),
          ),
        ],
      ),
    );
  }

  Widget _paper({
    required double left,
    required double top,
    required double angle,
    bool strongShadow = false,
  }) {
    return Positioned(
      left: left,
      top: top,
      child: Transform.rotate(
        angle: angle * 3.1415926535 / 180,
        child: Container(
          width: 112,
          height: 150,
          decoration: BoxDecoration(
            color: const Color(0xFFD8DCDA),
            borderRadius: BorderRadius.circular(AppRadius.thumb),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: strongShadow ? 0.30 : 0.28,
                ),
                blurRadius: strongShadow ? 22 : 18,
                offset: Offset(0, strongShadow ? 8 : 6),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _footLink(String label, VoidCallback onTap, {bool strong = false}) {
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: AppText(
            label,
            style: AppTypography.caption.copyWith(
              color: Colors.white.withValues(alpha: strong ? 0.82 : 0.6),
              fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
              decoration: strong ? TextDecoration.underline : null,
              decorationColor: Colors.white.withValues(alpha: 0.35),
            ),
          ),
        ),
      ),
    );
  }

  // ── ② 작업 모드 (사진 1장 이상) ──────────────────────────────────────────

  Widget _workMode() {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              PhotoTray(
                paths: _photos,
                onTapPhoto: _openViewer,
                onAddMore: _openCaptureLoop,
                onReorder: _reorder,
                // 서버가 문제라고 한 장(아직 안 바꾼 장)에 한 단어 표시 — "어느 장"이 눈에 바로 보이게
                issueLabels: {
                  for (final p
                      in _rejection?.check.pages ?? const <CapturePageIssue>[])
                    if (!_replaced.contains(p.index)) p.index: p.shortLabel,
                },
              ),
              if (_rejection != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.screenPadding,
                    AppSpacing.md,
                    AppSpacing.screenPadding,
                    0,
                  ),
                  child: _rejectionPanel(_rejection!),
                ),
              if (_hintsOn)
                const Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.screenPadding,
                  ),
                  child: AmberHint(text: '탭하면 크게 · 끌면 순서 바꾸기'),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.screenPadding,
                  AppSpacing.lg,
                  AppSpacing.screenPadding,
                  0,
                ),
                child: _depositCard(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.screenPadding,
                  AppSpacing.sm,
                  AppSpacing.screenPadding,
                  AppSpacing.screenPadding,
                ),
                child: _optionalCard(),
              ),
            ],
          ),
        ),
        _bottomBar(),
      ],
    );
  }

  /// 거절 안내 — 아직 바꿀 장이 남았으면 장마다 [다시 찍기], 다 바꿨으면 "다시 분석할 수 있어요".
  Widget _rejectionPanel(CaptureRejection rejection) {
    final remaining = _pagesStillToRetake;
    final List<CapturePageIssue> pages = [
      for (final p in rejection.check.pages)
        if (!_replaced.contains(p.index)) p,
    ];
    if (remaining.isEmpty) {
      return CaptureIssuePanel(
        check: CaptureCheck(ok: false, pages: pages),
        title: '바꿔 찍었어요 — 아래 [분석하기]로 다시 보내 주세요',
        message:
            '바꾼 장: ${(_replaced.toList()..sort()).map((i) => '${i + 1}쪽').join(', ')}'
            '${pages.isEmpty ? '' : ' · 아래 장은 그대로 보내도 돼요 $kSoftIssueNote'}',
        onRetake: _retakePage,
        retakeParticle: '도',
      );
    }
    final String done = _replaced.isEmpty
        ? ''
        : '\n바꾼 장: ${(_replaced.toList()..sort()).map((i) => '${i + 1}쪽').join(', ')}'
              ' · 다시 찍을 장 ${remaining.length}장 남았어요';
    return CaptureIssuePanel(
      check: CaptureCheck(ok: false, pages: pages),
      title: '사진을 다시 찍어야 분석할 수 있어요',
      // '크레딧' 같은 내부 말은 빼고 지금 상태와 할 일만(지수 리뷰 #4)
      message:
          '${rejection.message}\n아직 분석하지 않았어요. '
          '문제인 장만 다시 찍으면 나머지 사진은 그대로 써요.$done',
      onRetake: _retakePage,
      retakeParticle: '만',
    );
  }

  Widget _card({required Widget child, EdgeInsets? padding}) => Container(
    padding:
        padding ??
        const EdgeInsets.symmetric(
          horizontal: AppSpacing.cardPadH,
          vertical: AppSpacing.cardPadV,
        ),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      boxShadow: const [
        BoxShadow(
          color: Color(0x1F101814),
          blurRadius: 4,
          offset: Offset(0, 1),
        ),
      ],
    ),
    child: child,
  );

  Widget _depositCard() {
    final int? won = _manwonToWon(_depositCtrl.text);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppText('예정 전세보증금', style: AppTypography.bodyStrong),
              const SizedBox(width: 6),
              AppText(
                '필수',
                style: AppTypography.label.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // ② 28px 한글 표기 — 이 화면에서 **가장 큰 숫자**여야 한다.
          //    (예전 구현은 이걸 13px 캡션으로 내려놨던 것이 가장 큰 문제였다.)
          AppText(
            won != null ? formatWon(won) : '얼마를 맡기시나요?',
            style: AppTypography.numberLarge.copyWith(
              color: won != null ? AppColors.textStrong : AppColors.textMuted,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          // ⚠ 힌트를 비워 둔다. 예시 숫자('12,000')를 넣었더니 실기기에서 **이미 입력된
          //   값**으로 읽혔다 — 흐린 글씨는 "빈 칸"이 아니라 "적혀 있는 값"으로 보인다.
          //   보증금은 판정의 핵심 입력이라, 안 넣은 것을 넣은 줄 알게 하면 안 된다.
          //   칸이 무엇인지는 위의 '예정 전세보증금'과 '얼마를 맡기시나요?'가 말한다.
          _moneyField(
            controller: _depositCtrl,
            hint: '',
            active: won != null,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    );
  }

  Widget _optionalCard() {
    return _card(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          _expandRow(
            icon: Icons.payments,
            label: '매매 시세',
            summary: _priceSummary(),
            open: _priceOpen,
            onTap: () => setState(() => _priceOpen = !_priceOpen),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _moneyField(
                  controller: _priceCtrl,
                  hint: '', // 예시값 금지 — 위 보증금 칸과 같은 이유
                  active: _manwonToWon(_priceCtrl.text) != null,
                  onChanged: (_) => setState(() {
                    // 사용자가 손대는 순간 '직접 입력'이 된다 — 자동 조회값을 고쳤는데
                    // "자동 조회"라고 계속 말하면 거짓말이 된다.
                    _priceSource = MarketPriceSource.manual;
                    _priceAsOf = null;
                    _priceSampleCount = null;
                  }),
                ),
                _priceSourceHint(),
              ],
            ),
          ),
          Divider(
            height: 1,
            thickness: 1,
            color: AppColors.line,
            indent: AppSpacing.cardPadH,
            endIndent: AppSpacing.cardPadH,
          ),
          _expandRow(
            icon: Icons.label,
            label: '매물 별칭',
            summary: _aliasCtrl.text.trim().isEmpty
                ? '주소로 자동'
                : _aliasCtrl.text.trim(),
            open: _aliasOpen,
            onTap: () => setState(() => _aliasOpen = !_aliasOpen),
            body: SizedBox(
              height: AppSize.inputHeight,
              child: TextField(
                controller: _aliasCtrl,
                onChanged: (_) => setState(() {}),
                style: AppTypography.title,
                // 예시값 금지 — '역삼동 오피스텔'이 입력된 별칭으로 읽혔다.
                // 안 적으면 어떻게 되는지는 접힘 줄의 '주소로 자동'이 이미 말한다.
                decoration: _fieldDecoration(hint: '', active: false),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _priceSummary() {
    final int? won = _manwonToWon(_priceCtrl.text);
    return won != null ? formatWon(won) : '모르면 건너뛰기';
  }

  /// 시세 칸의 **출처 라벨**. 이 앱의 근거 전면 공개 원칙을 시세에도 적용한 것.
  ///
  /// ⚠ **타이밍**: 첫 분석에서는 아직 주소를 모른다(주소는 OCR 이후에 나온다).
  ///   그래서 여기서 자동 조회를 시도하지 않고, **앞으로 일어날 일**만 알린다.
  ///
  /// 2026-08-14: 예전에는 이 줄에 "모든 집에서 되지는 않아요 — 안 되면 알려드릴게요"를
  ///   붙여 뒀다. 못 하는 것을 못 한다고 말하는 원칙은 그대로지만, **그 말을 할 자리가
  ///   여기가 아니다** — 조회는 아직 시도조차 하지 않았고, 실패는 리포트에서
  ///   '시세를 못 구했어요'로 이미 분명하게 말한다. 여기서는 두 줄로 넘쳐 접힘 줄을
  ///   밀어내는 대가만 치르고 있었다.
  Widget _priceSourceHint() {
    final bool hasValue = _manwonToWon(_priceCtrl.text) != null;

    if (!hasValue) {
      // **한 줄에 들어가야 한다.** 두 줄짜리 안내는 접힘 줄을 밀어내 입력 칸보다
      // 커 보이고, 실기기에서 실제로 그렇게 보였다. 폰트를 줄이는 대신(12px는 이미
      // 최소다) 문장을 줄였다.
      //
      // 폭 계산 (360dp 기준): 360 − 화면패딩 40 − 카드패딩 36 − 힌트패딩 16
      //   − 아이콘·간격 17 = **글자에 쓸 수 있는 폭 251dp**.
      //   Pretendard 12px 한글은 글자당 약 12dp라 한글 19자(≈241dp)가 상한이다.
      // "안 되면 알려드릴게요"는 지웠다 — 못 구하면 리포트가 '시세를 못 구했어요'로
      //   이미 말한다(report_screen.dart의 결론 헤더). 같은 말을 두 번 하지 않는다.
      return const AmberHint(
        text: '비우면 실거래가·공시가격으로 찾아요',
        // 이 칸을 비우면 **무엇으로** 찾아오는지가 핵심이다 — 출처를 굵게 세운다.
        // (굵기는 줄 수를 바꾸지 않는다 — AmberHint.emphasis 주석 참고)
        emphasis: '실거래가·공시가격',
        icon: Icons.auto_awesome,
      );
    }
    if (_priceSource.isAuto) {
      return AmberHint(
        tone: AmberHintTone.positive,
        icon: Icons.verified_outlined,
        text: marketPriceSourceLabel(
          source: _priceSource,
          asOf: _priceAsOf,
          sampleCount: _priceSampleCount,
        ),
      );
    }
    return const AmberHint(
      tone: AmberHintTone.neutral,
      icon: Icons.edit_outlined,
      text: '직접 입력하신 값',
    );
  }

  Widget _expandRow({
    required IconData icon,
    required String label,
    required String summary,
    required bool open,
    required VoidCallback onTap,
    required Widget body,
  }) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.cardPadH,
            ),
            child: Row(
              children: [
                Icon(icon, size: AppSize.iconSm, color: AppColors.textMuted),
                const SizedBox(width: AppSpacing.md),
                AppText(label, style: AppTypography.bodyStrong),
                AppText(' · 선택', style: AppTypography.caption),
                const Spacer(),
                Flexible(
                  child: AppText(
                    summary,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: AppTypography.caption.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: const Icon(Icons.expand_more, size: 22),
                ),
              ],
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.cardPadH,
              0,
              AppSpacing.cardPadH,
              AppSpacing.lg,
            ),
            child: body,
          ),
      ],
    );
  }

  // ── 입력 필드 ─────────────────────────────────────────────────────────────

  InputDecoration _fieldDecoration({
    required String hint,
    required bool active,
  }) {
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.input),
      borderSide: BorderSide(color: color, width: width),
    );
    return InputDecoration(
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.md,
      ),
      enabledBorder: border(active ? AppColors.primary : AppColors.line, 1.5),
      focusedBorder: border(AppColors.primary, 1.5),
      border: border(AppColors.line, 1.5),
    );
  }

  Widget _moneyField({
    required TextEditingController controller,
    required String hint,
    required bool active,
    required ValueChanged<String> onChanged,
  }) {
    return SizedBox(
      height: AppSize.inputHeight,
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: false),
        // 숫자만, 최대 8자리 + 세 자리 쉼표 (표시는 쉼표, 값은 숫자)
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(11), // 쉼표 포함 길이 (8자리 + 쉼표 3개)
          _ThousandsFormatter(maxDigits: 8),
        ],
        onChanged: onChanged,
        style: AppTypography.title,
        decoration: _fieldDecoration(hint: hint, active: active).copyWith(
          // ② 접미사는 입력값보다 **작고 흐리게**. (예전 구현은 반대였다.)
          suffixText: '만원',
          suffixStyle: AppTypography.body.copyWith(color: AppColors.textMuted),
        ),
      ),
    );
  }

  // ── 하단 고정 바 ──────────────────────────────────────────────────────────

  Widget _bottomBar() {
    // ③ 키보드가 올라와도 주 버튼이 가리지 않게.
    //
    // 예전 구현은 이 바를 `bottomNavigationBar`에 뒀다 — 그 슬롯은
    // `resizeToAvoidBottomInset`의 대상이 **아니라서** 키보드가 그대로 덮었다.
    // 그래서 본문(body) 안 마지막 고정 영역으로 옮겼다. Scaffold가 body 높이를
    // viewInsets.bottom만큼 줄여 주므로 바는 자동으로 키보드 위에 앉는다.
    //
    // ⚠ 여기서 viewInsets.bottom을 **다시 더하면 안 된다.** 처음엔 그렇게 썼는데
    //   Scaffold가 이미 뺀 값을 또 더하는 셈이라 화면 밖으로 밀려나며 오버플로가 났다
    //   (위젯 테스트가 키보드 300dp에서 164px 넘침으로 잡았다).
    return Container(
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        AppSpacing.md,
        AppSpacing.screenPadding,
        AppSpacing.lg,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // [분석하기]가 비활성인 **이유**를 체크 2개로 보여 준다.
            // 문장 안내("…을 입력하면 분석할 수 있어요")를 쓰지 않는다 —
            // 무엇이 모자란지가 한눈에 보여야 한다.
            // D6(2026-10-23): 다시 찍을 장이 남았는데 초록 '사진 n장 ✓'이면 상태가 모순이다 → 앰버로 남은 장수를 말한다.
            Row(
              children: [
                if (_pagesStillToRetake.isNotEmpty)
                  _retakeLeft(_pagesStillToRetake.length)
                else
                  _check('사진 ${_photos.length}장', _photos.isNotEmpty),
                const SizedBox(width: 14),
                _check('보증금', (_manwonToWon(_depositCtrl.text) ?? 0) > 0),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              height: AppSize.buttonHeight,
              child: FilledButton.icon(
                onPressed: _canAnalyze ? _analyze : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.onPrimary,
                  disabledBackgroundColor: AppColors.buttonDisabledBg,
                  disabledForegroundColor: AppColors.buttonDisabledFg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.button),
                  ),
                  textStyle: AppTypography.button,
                ),
                icon: const Icon(Icons.search, size: AppSize.iconMd),
                label: const AppText('분석하기'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "다시 찍을 장 n장" — 앰버는 아이콘에만, 글자는 진한 색(D8 — 작은 앰버 글자는 대비가 모자라다).
  Widget _retakeLeft(int count) {
    return Row(
      key: const ValueKey('retake-left-check'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.photo_camera_outlined, size: 17, color: AppColors.caution),
        const SizedBox(width: 5),
        AppText(
          '다시 찍을 장 $count장',
          style: AppTypography.caption.copyWith(
            color: AppColors.textStrong,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _check(String label, bool done) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          done ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 17,
          color: done ? AppColors.ok : AppColors.textMuted,
        ),
        const SizedBox(width: 5),
        AppText(
          label,
          style: AppTypography.caption.copyWith(
            color: done ? AppColors.ok : AppColors.textMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// 세 자리 쉼표 + 자릿수 제한 포매터. 값은 숫자만 남기고 표시만 쉼표를 넣는다.
class _ThousandsFormatter extends TextInputFormatter {
  const _ThousandsFormatter({required this.maxDigits});

  final int maxDigits;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    String digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length > maxDigits) digits = digits.substring(0, maxDigits);
    if (digits.isEmpty) return const TextEditingValue();
    final StringBuffer buf = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    final String text = buf.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
