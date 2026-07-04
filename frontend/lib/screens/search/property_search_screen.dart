/// S-04 매물 검색 (분석 시작) — IA.md §6.
///
/// [등기부 업로드](기본) | [주소 검색](더미) 세그먼트.
/// 업로드: 촬영/갤러리 여러 장 + 예정 보증금(필수)·시세(선택)·별칭(선택).
/// [분석하기] → S-06 로딩(AnalysisRequest 전달).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/app_callout.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../utils/money_format.dart';

class PropertySearchScreen extends StatefulWidget {
  const PropertySearchScreen({super.key});

  @override
  State<PropertySearchScreen> createState() => _PropertySearchScreenState();
}

class _PropertySearchScreenState extends State<PropertySearchScreen> {
  static const int _maxImages = 10;

  final ImagePicker _picker = ImagePicker();
  final List<XFile> _images = [];
  final TextEditingController _depositCtrl = TextEditingController();
  final TextEditingController _priceCtrl = TextEditingController();
  final TextEditingController _aliasCtrl = TextEditingController();

  bool _addressTab = false; // false = 등기부 업로드, true = 주소 검색(더미)

  @override
  void dispose() {
    _depositCtrl.dispose();
    _priceCtrl.dispose();
    _aliasCtrl.dispose();
    super.dispose();
  }

  /// 만원 단위 입력 → 원. 비었으면 null.
  int? _manwonToWon(String text) {
    final digits = text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    return int.parse(digits) * 10000;
  }

  bool get _canAnalyze =>
      _images.isNotEmpty && _manwonToWon(_depositCtrl.text) != null;

  Future<void> _pickFromGallery() async {
    try {
      final picked = await _picker.pickMultiImage();
      if (picked.isEmpty) return;
      setState(() {
        for (final x in picked) {
          if (_images.length < _maxImages) _images.add(x);
        }
      });
      if (picked.length + _images.length > _maxImages) _showMaxMsg();
    } catch (_) {
      _showPermissionMsg();
    }
  }

  Future<void> _pickFromCamera() async {
    if (_images.length >= _maxImages) {
      _showMaxMsg();
      return;
    }
    try {
      final x = await _picker.pickImage(source: ImageSource.camera);
      if (x == null) return;
      setState(() => _images.add(x));
    } catch (_) {
      _showPermissionMsg();
    }
  }

  void _showMaxMsg() => _toast('사진은 최대 $_maxImages장까지 올릴 수 있어요');
  void _showPermissionMsg() => _toast('사진을 불러오려면 카메라·사진 권한이 필요해요');
  void _toast(String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));

  void _analyze() {
    final deposit = _manwonToWon(_depositCtrl.text);
    if (!_canAnalyze || deposit == null) return;
    final request = AnalysisRequest(
      imagePaths: _images.map((x) => x.path).toList(),
      deposit: deposit,
      marketPrice: _manwonToWon(_priceCtrl.text),
      alias: _aliasCtrl.text,
    );
    // 로딩 화면이 analyze를 실행하고 리포트로 교체 진입
    context.push('/loading', extra: request);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('매물 분석')),
      body: Column(
        children: [
          _segment(),
          Expanded(child: _addressTab ? _addressDummy() : _uploadForm()),
        ],
      ),
      // 단일 핵심 행동 [분석하기]는 하단 고정 (스크롤·키보드에 가려지지 않게 — design-reviewer)
      bottomNavigationBar: _addressTab ? null : _analyzeBar(),
    );
  }

  Widget _analyzeBar() {
    return SafeArea(
      minimum: const EdgeInsets.all(AppSpacing.screenPadding),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_canAnalyze)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                '등기부등본 사진과 예정 보증금을 입력하면 분석할 수 있어요',
                style: AppTypography.caption,
                textAlign: TextAlign.center,
              ),
            ),
          AppPrimaryButton(
            label: '분석하기',
            icon: Icons.search,
            onPressed: _canAnalyze ? _analyze : null,
          ),
        ],
      ),
    );
  }

  Widget _segment() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      child: SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('등기부 업로드')),
          ButtonSegment(value: true, label: Text('주소 검색')),
        ],
        selected: {_addressTab},
        onSelectionChanged: (s) => setState(() => _addressTab = s.first),
      ),
    );
  }

  Widget _uploadForm() {
    final int? depositWon = _manwonToWon(_depositCtrl.text);
    final int? priceWon = _manwonToWon(_priceCtrl.text);

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
      children: [
        // 사진 추가
        Row(
          children: [
            Expanded(
              child: AppSecondaryButton(
                label: '촬영',
                icon: Icons.camera_alt_outlined,
                onPressed: _pickFromCamera,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: AppSecondaryButton(
                label: '갤러리',
                icon: Icons.photo_library_outlined,
                onPressed: _pickFromGallery,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        if (_images.isEmpty) _emptyPhotos() else _thumbnails(),
        const SizedBox(height: AppSpacing.xl),

        // 예정 보증금 (필수)
        _fieldLabel('예정 보증금 (필수)'),
        _moneyField(_depositCtrl, '예: 12000'),
        if (depositWon != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              formatWon(depositWon),
              style: AppTypography.caption.copyWith(color: AppColors.primary),
            ),
          ),
        const SizedBox(height: AppSpacing.lg),

        // 매매 시세 (선택)
        _fieldLabel('매매 시세 (선택)'),
        Text(
          '모르면 비워두셔도 돼요. 넣으면 보증금이 집값에 비해 높은지 더 정확히 알려드려요. '
          '(국토부 실거래가·KB시세 등에서 확인)',
          style: AppTypography.caption,
        ),
        const SizedBox(height: AppSpacing.sm),
        _moneyField(_priceCtrl, '예: 20000'),
        if (priceWon != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              formatWon(priceWon),
              style: AppTypography.caption.copyWith(color: AppColors.primary),
            ),
          ),
        const SizedBox(height: AppSpacing.lg),

        // 별칭 (선택)
        _fieldLabel('매물 별칭 (선택)'),
        TextField(
          controller: _aliasCtrl,
          decoration: const InputDecoration(
            hintText: '예: 역삼동 오피스텔 (안 쓰면 주소로 저장돼요)',
          ),
        ),
        const SizedBox(height: AppSpacing.xl),

        Center(
          child: TextButton(
            onPressed: () => context.push('/guide'),
            child: const Text('등기부등본이 없어요 — 발급 가이드'),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }

  Widget _fieldLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: Text(text, style: AppTypography.bodyStrong),
  );

  Widget _moneyField(TextEditingController ctrl, String hint) {
    return TextField(
      controller: ctrl,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(hintText: hint, suffixText: '만원'),
    );
  }

  Widget _emptyPhotos() {
    return Container(
      height: 140,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.add_a_photo_outlined,
            color: AppColors.textMuted,
            size: AppSize.iconMd,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('등기부등본 1페이지부터 순서대로 올려주세요', style: AppTypography.caption),
          Text('순서가 섞여도 분석에는 문제 없어요', style: AppTypography.caption),
        ],
      ),
    );
  }

  Widget _thumbnails() {
    // 셀 위·오른쪽에 여백을 둬 48dp 삭제 버튼이 잘리지 않게 한다.
    return SizedBox(
      height: 96 + AppSpacing.xl,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _images.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.only(
            top: AppSpacing.xl,
            right: AppSpacing.xl,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: Image.file(
                  File(_images[i].path),
                  width: 72,
                  height: 96,
                  fit: BoxFit.cover,
                ),
              ),
              // 삭제 버튼 — 최소 터치 영역(48dp) + 시맨틱 (design-reviewer)
              Positioned(
                top: -AppSpacing.xl,
                right: -AppSpacing.xl,
                child: Semantics(
                  button: true,
                  label: '${i + 1}번째 사진 삭제',
                  child: InkWell(
                    onTap: () => setState(() => _images.removeAt(i)),
                    customBorder: const CircleBorder(),
                    child: SizedBox(
                      width: AppSize.minTouchTarget,
                      height: AppSize.minTouchTarget,
                      child: Center(
                        child: Container(
                          decoration: const BoxDecoration(
                            color: AppColors.dim,
                            shape: BoxShape.circle,
                          ),
                          padding: const EdgeInsets.all(AppSpacing.xs),
                          child: const Icon(
                            Icons.close,
                            color: Colors.white,
                            size: AppSize.iconXs,
                          ),
                        ),
                      ),
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

  /// 주소 검색 탭 — UI만, 로드맵 어필형 안내 (judge-reviewer). 막다른 길 방지로
  /// 업로드 이동 + 발급 가이드 두 갈래 제공 (지수 리뷰).
  Widget _addressDummy() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      child: Column(
        children: [
          const TextField(
            enabled: false,
            decoration: InputDecoration(
              hintText: '도로명·지번 주소',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          const AppCallout(
            tone: CalloutTone.info,
            icon: Icons.rocket_launch_outlined,
            title: '준비 중이에요',
            text:
                '주소만 입력하면 등기부를 자동으로 조회하는 기능을 다음 버전에서 '
                '준비하고 있어요 (공공 데이터 연동). 지금은 등기부등본 사진으로 분석해 주세요.',
          ),
          const SizedBox(height: AppSpacing.lg),
          AppPrimaryButton(
            label: '등기부 사진으로 분석하기',
            onPressed: () => setState(() => _addressTab = false),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppSecondaryButton(
            label: '등기부등본이 없어요 — 발급 가이드',
            onPressed: () => context.push('/guide'),
          ),
        ],
      ),
    );
  }
}
