/// 시작 시트 (2026-10-30) — 처음 [로그인 없이 둘러보기]·[카카오로 시작하기]를 누를 때, 그리고 분석을 시작할 때.
///
/// 한 번 동의하면 다시 묻지 않는다([ConsentStore]). 약관을 크게 바꾸면 판(`kConsentVersion`)을 올려 다시 묻는다.
///
/// 구성(같은 날 법 조사 반영):
///   ① 개인정보 안내 — **체크 없이** 세 줄 + [개인정보 처리방침] (굵은 초록, 다른 줄과 구별 · 표준 개인정보 보호지침 제20조)
///      받는 정보가 모두 이용 계약을 지키는 데 필요한 정보라 동의 대신 안내한다(개인정보 보호법 제15조 제1항 제4호).
///      이런 정보에 '필수 동의'를 받는 관행은 개인정보위가 고치라고 한 것이다(제22조 제3항 · 시행령 제17조).
///   ② 체크 두 줄 — [필수] 이용약관 동의(보기) · [필수] 만 14세 이상 + 모두 동의
///   ③ [동의하고 시작하기] — 두 줄을 모두 골라야 열린다
library;

import 'package:flutter/material.dart';

import '../../design_system/components/mascot_safe.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../state/consent_store.dart';
import 'legal_doc.dart';
import 'privacy_content.dart';
import 'terms_content.dart';

/// 동의가 있으면 바로 true. 없으면 시트를 띄워 동의를 받는다(닫으면 false — 하려던 일을 하지 않는다).
Future<bool> ensureConsent(BuildContext context, {ConsentStore? store}) async {
  final consent = store ?? ConsentStore.instance;
  if (consent.hasCurrent) return true;
  final agreed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    barrierColor: AppColors.dim,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    ),
    builder: (_) => const ConsentSheet(),
  );
  if (agreed != true) return false;
  await consent.agree();
  return true;
}

/// 체크하는 항목 하나 (개인정보는 체크가 아니라 안내 — 위 ①)
enum ConsentItem {
  terms('이용약관 동의'),
  age('만 14세 이상이에요');

  const ConsentItem(this.label);
  final String label;
}

class ConsentSheet extends StatefulWidget {
  const ConsentSheet({super.key});

  @override
  State<ConsentSheet> createState() => _ConsentSheetState();
}

class _ConsentSheetState extends State<ConsentSheet> {
  final Set<ConsentItem> _checked = {};

  bool get _all => _checked.length == ConsentItem.values.length;

  void _toggleAll() => setState(() {
    if (_all) {
      _checked.clear();
    } else {
      _checked.addAll(ConsentItem.values);
    }
  });

  void _toggle(ConsentItem item) => setState(() {
    if (!_checked.remove(item)) _checked.add(item);
  });

  void _openDoc(LegalDoc doc) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => LegalDocScreen(doc: doc)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 내용은 스크롤 — 작은 폰·큰 글씨에서 넘치면 여기만 줄어든다
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenPadding,
                12,
                AppSpacing.screenPadding,
                0,
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
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppColors.primarySoft,
                          shape: BoxShape.circle,
                        ),
                        child: const MascotSafe(size: 42, state: MascotState.home),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: AppText(
                          '시작하기 전에\n확인해 주세요',
                          key: const ValueKey('consent-title'),
                          style: AppTypographyNext.headline,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _PrivacyNotice(onOpen: () => _openDoc(privacyPolicyDoc())),
                  const SizedBox(height: 16),
                  _AllRow(checked: _all, onTap: _toggleAll),
                  const SizedBox(height: 4),
                  for (final item in ConsentItem.values)
                    _ItemRow(
                      item: item,
                      checked: _checked.contains(item),
                      onTap: () => _toggle(item),
                      onOpen: item == ConsentItem.terms ? () => _openDoc(termsDoc()) : null,
                    ),
                ],
              ),
            ),
          ),
          // 버튼은 늘 화면 아래 — 시작 화면의 메인 버튼과 같은 모양(높이 52 · 반경 12)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenPadding,
              12,
              AppSpacing.screenPadding,
              16,
            ),
            child: SizedBox(
              height: 52,
              child: FilledButton(
                key: const ValueKey('consent-agree'),
                onPressed: _all ? () => Navigator.of(context).pop(true) : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  disabledBackgroundColor: AppColors.buttonDisabledBg,
                  disabledForegroundColor: AppColors.buttonDisabledFg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                child: AppText(
                  '동의하고 시작하기',
                  style: AppTypographyNext.button.copyWith(
                    color: _all ? AppColors.onPrimary : AppColors.buttonDisabledFg,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ① 개인정보 안내 — 체크 없이 읽기만. 처리방침 '한눈에 보기'와 같은 세 줄([kPrivacyAtAGlance]).
class _PrivacyNotice extends StatelessWidget {
  const _PrivacyNotice({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(18);
    return Container(
      key: const ValueKey('consent-privacy-notice'),
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: AppColorsNext.divider, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: AppText(
              '개인정보는 이렇게 지켜요',
              style: AppTypographyNext.caption.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColors.primaryStrong,
              ),
            ),
          ),
          for (final h in kPrivacyAtAGlance)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: AppColors.primarySoft,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(h.icon, size: 16, color: AppColors.primary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: AppText(
                        noOrphan(h.text),
                        style: AppTypographyNext.caption.copyWith(
                          fontWeight: FontWeight.w600,
                          color: AppColorsNext.textBody,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          Divider(height: 1, thickness: 1, color: AppColorsNext.divider),
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: const ValueKey('consent-open-privacy'),
              onTap: onOpen,
              borderRadius: BorderRadius.vertical(bottom: radius.bottomLeft),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 10, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: AppText(
                          '개인정보 처리방침',
                          style: AppTypographyNext.body.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                      Icon(Icons.chevron_right, color: AppColors.primary),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckCircle extends StatelessWidget {
  const _CheckCircle({required this.checked, this.size = 26});

  final bool checked;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: checked ? AppColors.primary : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(
          color: checked ? AppColors.primary : AppColorsNext.textMuted,
          width: 2,
        ),
      ),
      child: Icon(
        Icons.check_rounded,
        size: size * 0.66,
        color: checked ? AppColors.onPrimary : AppColorsNext.textMuted,
      ),
    );
  }
}

class _AllRow extends StatelessWidget {
  const _AllRow({required this.checked, required this.onTap});

  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      checked: checked,
      button: true,
      child: Material(
        color: checked ? AppColors.primarySoft : AppColors.chipBg,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: const ValueKey('consent-all'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Row(
              children: [
                _CheckCircle(checked: checked, size: 28),
                const SizedBox(width: 14),
                Expanded(
                  child: AppText(
                    '모두 동의할게요',
                    style: AppTypographyNext.title.copyWith(fontSize: 18),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.checked,
    required this.onTap,
    this.onOpen,
  });

  final ConsentItem item;
  final bool checked;
  final VoidCallback onTap;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Semantics(
            checked: checked,
            button: true,
            child: InkWell(
              key: ValueKey('consent-${item.name}'),
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_rounded,
                        size: 22,
                        color: checked ? AppColors.primary : AppColorsNext.textMuted,
                      ),
                      const SizedBox(width: 12),
                      AppText(
                        '필수',
                        style: AppTypographyNext.caption.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: AppText(
                          item.label,
                          style: AppTypographyNext.body.copyWith(
                            fontSize: 16,
                            color: AppColorsNext.textBody,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (onOpen != null)
          IconButton(
            key: ValueKey('consent-open-${item.name}'),
            tooltip: '${item.label} 보기',
            onPressed: onOpen,
            icon: Icon(Icons.chevron_right, color: AppColorsNext.textMuted),
          )
        else
          const SizedBox(width: 48),
      ],
    );
  }
}
