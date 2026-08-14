/// 촬영 루프 — **찍고 → 확인하고 → 다음 장 찍기**를 앱 안에서 돈다.
///
/// 왜 이 루트가 따로 있나 (2026-08-03 디자인 핸드오프 "촬영 스튜디오"):
/// `image_picker`는 1회에 한 장이라, 그대로 쓰면 3장을 찍을 때 **카메라를 세 번 여는
/// 느낌**이 난다(앱 → 카메라 → 앱 → 카메라 …). 등기부는 보통 3~5장이라 이 왕복이
/// 그대로 이탈로 이어진다. 그래서 확인 화면의 **주 버튼을 [다음 장 찍기]로 두고**,
/// 한 번 시작하면 앱 안에서 계속 찍게 만든다.
///
/// 이 루트가 돌려주는 것: 이번 세션에서 새로 찍은 사진 경로 목록(순서 유지).
/// 취소하면 빈 목록. **호출한 화면이 기존 목록에 이어 붙인다** — 이 루트는 전체
/// 사진 목록을 모른다(상태를 한 곳에만 두기 위해).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../design_system/text/app_text.dart';

/// 어두운 전면 화면들의 공통 시스템 UI 스타일 (상태바까지 어두워진다).
const SystemUiOverlayStyle kDarkStudioOverlay = SystemUiOverlayStyle(
  statusBarColor: AppColors.cameraBackdrop,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
);

/// 사진 한 장을 가져오는 방법 — 카메라 1회 호출. 취소하면 null.
///
/// 위젯이 `ImagePicker` **타입**에 직접 매달리지 않게 함수로 뺐다.
/// 테스트는 여기에 가짜 함수를 넣어 카메라 없이 루프를 돌린다.
typedef CaptureOne = Future<String?> Function();

/// 여러 장을 가져오는 방법 — 갤러리.
typedef PickMany = Future<List<String>> Function();

/// 기본 구현 — 실제 카메라.
Future<String?> defaultCaptureOne() async {
  final XFile? x = await ImagePicker().pickImage(source: ImageSource.camera);
  return x?.path;
}

/// 기본 구현 — 실제 갤러리.
Future<List<String>> defaultPickMany() async {
  final List<XFile> picked = await ImagePicker().pickMultiImage();
  return picked.map((x) => x.path).toList();
}

/// 촬영 루프 결과 — 새로 찍은 사진들 + 왜 끝났는지.
class CaptureLoopResult {
  const CaptureLoopResult({required this.newPaths, this.hitLimit = false});

  final List<String> newPaths;

  /// 최대 장수에 걸려서 멈췄나 (호출한 화면이 토스트를 띄운다)
  final bool hitLimit;
}

class CaptureLoopRoute extends StatefulWidget {
  const CaptureLoopRoute({
    super.key,
    required this.alreadyTaken,
    required this.maxPhotos,
    this.captureOne = defaultCaptureOne,
  });

  /// 들어올 때 이미 갖고 있던 장수 — 뱃지의 "n장째" 계산과 상한 판정에 쓴다.
  final int alreadyTaken;
  final int maxPhotos;

  /// 사진 한 장을 가져오는 방법 (테스트에서 교체)
  final CaptureOne captureOne;

  @override
  State<CaptureLoopRoute> createState() => _CaptureLoopRouteState();
}

enum _Mode { camera, confirm }

class _CaptureLoopRouteState extends State<CaptureLoopRoute> {
  final List<String> _taken = [];
  _Mode _mode = _Mode.camera;
  String? _justTaken;
  bool _busy = false;
  bool _hitLimit = false;
  bool _permissionDenied = false;

  int get _total => widget.alreadyTaken + _taken.length;

  @override
  void initState() {
    super.initState();
    // 화면이 뜨자마자 카메라를 연다 — [촬영 시작]을 이미 눌렀으므로 한 번 더 누르게
    // 하면 탭이 하나 늘 뿐이다.
    WidgetsBinding.instance.addPostFrameCallback((_) => _shoot());
  }

  void _finish() => Navigator.of(context).pop(
    CaptureLoopResult(newPaths: List.of(_taken), hitLimit: _hitLimit),
  );

  Future<void> _shoot() async {
    if (_busy) return;
    if (_total >= widget.maxPhotos) {
      setState(() => _hitLimit = true);
      _finish();
      return;
    }
    setState(() => _busy = true);
    try {
      final String? path = await widget.captureOne();
      if (!mounted) return;
      if (path == null) {
        // 사용자가 카메라를 그냥 닫았다 — 찍은 게 있으면 확인 화면, 없으면 종료.
        setState(() => _busy = false);
        if (_taken.isEmpty) {
          _finish();
        } else {
          setState(() => _mode = _Mode.confirm);
        }
        return;
      }
      setState(() {
        _taken.add(path);
        _justTaken = path;
        _mode = _Mode.confirm;
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _permissionDenied = true;
      });
    }
  }

  void _retake() {
    // 방금 장을 버리고 다시 찍는다. 파일은 임시 저장소에 남지만 우리가 참조하지 않는다.
    setState(() {
      if (_justTaken != null) _taken.remove(_justTaken);
      _justTaken = null;
    });
    _shoot();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: kDarkStudioOverlay,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _finish(); // 뒤로가기 = 지금까지 찍은 것을 들고 form 복귀
        },
        child: Scaffold(
          backgroundColor: AppColors.cameraBackdrop,
          body: SafeArea(
            child: _permissionDenied
                ? _permissionPanel()
                : (_mode == _Mode.camera ? _cameraView() : _confirmView()),
          ),
        ),
      ),
    );
  }

  // ── camera ────────────────────────────────────────────────────────────────

  Widget _cameraView() {
    return Column(
      children: [
        _darkAppBar(
          leading: Icons.close,
          onLeading: _finish,
          title: '${_total + 1}장째',
          trailing: Icons.flash_off,
        ),
        const Expanded(
          child: Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
              child: AppText(
                '카메라를 여는 중이에요…',
                style: TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── confirm — 루프의 핵심 ─────────────────────────────────────────────────

  Widget _confirmView() {
    return Column(
      children: [
        const SizedBox(height: AppSpacing.md),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 5,
          ),
          decoration: BoxDecoration(
            color: AppColors.primaryBright.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: AppText(
            '$_total장째 찍었어요',
            style: AppTypography.caption.copyWith(
              color: AppColors.primaryBright,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              child: _justTaken == null
                  ? const SizedBox.shrink()
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 440),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.thumb),
                        child: Image.file(
                          File(_justTaken!),
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const AppText(
                            '사진을 불러오지 못했어요',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenPadding,
            AppSpacing.lg,
            AppSpacing.screenPadding,
            AppSpacing.xxl,
          ),
          child: Column(
            children: [
              AppText(
                '글자가 흐리거나 잘렸으면 다시 찍어 주세요',
                textAlign: TextAlign.center,
                style: AppTypography.body.copyWith(
                  color: Colors.white.withValues(alpha: 0.78),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              // 주 버튼이 [다음 장 찍기]인 것이 이 안의 핵심이다.
              SizedBox(
                height: AppSize.buttonHeight,
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _shoot,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.button),
                    ),
                    textStyle: AppTypography.button.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  icon: const Icon(Icons.photo_camera, size: 22),
                  label: const AppText('다음 장 찍기'),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: _darkButton(
                      label: '다시 찍기',
                      onPressed: _busy ? null : _retake,
                      outlined: true,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: _darkButton(
                      label: '완료 · $_total장',
                      onPressed: _finish,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _permissionPanel() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.no_photography_outlined, color: Colors.white70, size: 40),
          const SizedBox(height: AppSpacing.lg),
          AppText(
            '카메라 권한이 필요해요',
            style: AppTypography.title.copyWith(color: Colors.white),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppText(
            '등기부등본을 찍으려면 카메라 권한이 필요해요. 사진은 분석에만 쓰고, '
            '최근 분석 5건만 기기에 남아요.',
            textAlign: TextAlign.center,
            style: AppTypography.body.copyWith(
              color: Colors.white.withValues(alpha: 0.78),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          SizedBox(
            width: double.infinity,
            child: _darkButton(label: '돌아가기', onPressed: _finish),
          ),
        ],
      ),
    );
  }

  // ── 공통 조각 ─────────────────────────────────────────────────────────────

  Widget _darkAppBar({
    required IconData leading,
    required VoidCallback onLeading,
    required String title,
    IconData? trailing,
    VoidCallback? onTrailing,
  }) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          _iconButton(leading, onLeading, semantic: '닫기'),
          Expanded(
            child: AppText(
              title,
              textAlign: TextAlign.center,
              style: AppTypography.bodyStrong.copyWith(color: Colors.white),
            ),
          ),
          if (trailing != null)
            _iconButton(
              trailing,
              onTrailing,
              semantic: '플래시',
              color: Colors.white.withValues(alpha: 0.7),
            )
          else
            const SizedBox(width: AppSize.minTouchTarget),
        ],
      ),
    );
  }

  Widget _iconButton(
    IconData icon,
    VoidCallback? onTap, {
    required String semantic,
    Color color = Colors.white,
  }) {
    return Semantics(
      button: true,
      label: semantic,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: AppSize.minTouchTarget,
          height: AppSize.minTouchTarget,
          child: Icon(icon, color: color, size: AppSize.iconMd),
        ),
      ),
    );
  }

  Widget _darkButton({
    required String label,
    required VoidCallback? onPressed,
    bool outlined = false,
  }) {
    final ButtonStyle style = FilledButton.styleFrom(
      backgroundColor: outlined
          ? Colors.transparent
          : Colors.white.withValues(alpha: 0.14),
      foregroundColor: Colors.white,
      minimumSize: const Size.fromHeight(AppSize.minTouchTarget),
      side: outlined
          ? BorderSide(color: Colors.white.withValues(alpha: 0.45), width: 1.2)
          : BorderSide.none,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      textStyle: AppTypography.button,
    );
    return FilledButton(onPressed: onPressed, style: style, child: AppText(label));
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 크게 보기 (viewer)
// ════════════════════════════════════════════════════════════════════════════

/// 뷰어에서 사용자가 한 일 — 호출한 화면이 목록을 고친다(상태는 한 곳에만).
class PhotoViewerResult {
  const PhotoViewerResult({required this.paths, this.wantsRetake = false});

  /// 삭제·순서 변경이 반영된 최종 목록
  final List<String> paths;

  /// [다시 찍기]를 눌렀나 — 호출한 화면이 촬영 루프를 연다
  final bool wantsRetake;
}

class PhotoViewerRoute extends StatefulWidget {
  const PhotoViewerRoute({
    super.key,
    required this.paths,
    required this.initialIndex,
  });

  final List<String> paths;
  final int initialIndex;

  @override
  State<PhotoViewerRoute> createState() => _PhotoViewerRouteState();
}

class _PhotoViewerRouteState extends State<PhotoViewerRoute> {
  late final List<String> _paths = List.of(widget.paths);
  late int _index = widget.initialIndex.clamp(0, widget.paths.length - 1);

  void _close({bool retake = false}) => Navigator.of(context).pop(
    PhotoViewerResult(paths: List.of(_paths), wantsRetake: retake),
  );

  void _delete() {
    setState(() {
      _paths.removeAt(_index);
      // 인덱스 보정 — 마지막 장을 지웠으면 한 칸 앞으로.
      if (_index >= _paths.length) _index = _paths.length - 1;
    });
    if (_paths.isEmpty) _close(); // 전부 지웠으면 form 복귀
  }

  void _move(int delta) {
    final int to = _index + delta;
    if (to < 0 || to >= _paths.length) return;
    setState(() => _index = to);
  }

  /// 현재 장을 앞/뒤로 한 칸 옮긴다.
  void _reorder(int delta) {
    final int to = _index + delta;
    if (to < 0 || to >= _paths.length) return;
    setState(() {
      final String p = _paths.removeAt(_index);
      _paths.insert(to, p);
      _index = to;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_paths.isEmpty) return const SizedBox.shrink();
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: kDarkStudioOverlay,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: Scaffold(
          backgroundColor: AppColors.cameraBackdrop,
          body: SafeArea(
            child: Column(
              children: [
                SizedBox(
                  height: 56,
                  child: Row(
                    children: [
                      _icon(Icons.arrow_back, () => _close(), '뒤로'),
                      Expanded(
                        child: AppText(
                          '${_index + 1} / ${_paths.length}장',
                          textAlign: TextAlign.center,
                          style: AppTypography.button.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ),
                      _icon(Icons.delete, _delete, '이 사진 삭제'),
                    ],
                  ),
                ),
                Expanded(child: _stage()),
                _rail(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.screenPadding,
                    AppSpacing.md,
                    AppSpacing.screenPadding,
                    AppSpacing.xl,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _flat('앞으로', _index > 0 ? () => _reorder(-1) : null),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: _flat('다시 찍기', () => _close(retake: true)),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: _flat(
                          '뒤로',
                          _index < _paths.length - 1 ? () => _reorder(1) : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stage() {
    return Stack(
      alignment: Alignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 56),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 520),
            child: InteractiveViewer(
              maxScale: 5,
              child: Image.file(
                File(_paths[_index]),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const AppText(
                  '사진을 불러오지 못했어요',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: AppSpacing.xs,
          child: _round(Icons.chevron_left, _index > 0 ? () => _move(-1) : null, '이전 장'),
        ),
        Positioned(
          right: AppSpacing.xs,
          child: _round(
            Icons.chevron_right,
            _index < _paths.length - 1 ? () => _move(1) : null,
            '다음 장',
          ),
        ),
      ],
    );
  }

  Widget _rail() {
    return SizedBox(
      height: 54,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
        itemCount: _paths.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, i) => GestureDetector(
          onTap: () => setState(() => _index = i),
          child: Container(
            width: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: i == _index
                    ? AppColors.primaryBright
                    : Colors.white.withValues(alpha: 0.25),
                width: i == _index ? 2 : 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.file(
                File(_paths[i]),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _icon(IconData icon, VoidCallback onTap, String semantic) => Semantics(
    button: true,
    label: semantic,
    child: InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: SizedBox(
        width: AppSize.minTouchTarget,
        height: AppSize.minTouchTarget,
        child: Icon(icon, color: Colors.white, size: AppSize.iconMd),
      ),
    ),
  );

  Widget _round(IconData icon, VoidCallback? onTap, String semantic) => Semantics(
    button: true,
    label: semantic,
    child: Material(
      color: Colors.white.withValues(alpha: onTap == null ? 0.04 : 0.14),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: AppSize.minTouchTarget,
          height: AppSize.minTouchTarget,
          child: Icon(
            icon,
            color: Colors.white.withValues(alpha: onTap == null ? 0.3 : 1),
          ),
        ),
      ),
    ),
  );

  Widget _flat(String label, VoidCallback? onPressed) => FilledButton(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      backgroundColor: Colors.white.withValues(alpha: 0.12),
      foregroundColor: Colors.white,
      disabledBackgroundColor: Colors.white.withValues(alpha: 0.05),
      disabledForegroundColor: Colors.white.withValues(alpha: 0.35),
      minimumSize: const Size.fromHeight(AppSize.minTouchTarget),
      padding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      textStyle: AppTypography.buttonSmall,
    ),
    child: AppText(label),
  );
}
