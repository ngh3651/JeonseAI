/// 리포트 **입력값 고치기** — 별칭 · 예정 전세보증금 · 매매 시세 (2026-10-29 QA).
///
/// 왜: 분석이 끝난 뒤 보증금을 잘못 넣었거나 시세를 알게 되면, 예전엔 등기부를 처음부터 다시 찍어야 했다.
/// 이제 **같은 리포트**를 고친다 — 기록이 두 줄로 남지 않는다.
/// - 별칭만 바꾸면 이름만 바꾼다.
/// - 보증금·시세를 바꾸면 서버가 같은 등기부로 **판정만 다시** 한다(사진을 다시 읽지 않는다 · 판정은 규칙 엔진).
/// - 서버에 재료가 없는 옛 리포트는 폰에 사진이 있을 때만 숫자를 고칠 수 있다 — 그 사진으로 다시 분석한다.
///   사진도 없으면 숫자 칸을 잠그고 이유를 말한다(누를 수 없는 버튼을 두지 않는다).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../models/market_price_source.dart';
import '../../repositories/analysis_repository.dart';
import '../../services/api_client.dart';
import '../../state/registry_photo_store.dart';
import '../../utils/money_format.dart';
import '../search/capture_issue_panel.dart' show CaptureRejection;

/// 이 리포트의 숫자(보증금·시세)를 고칠 수 있나 — 서버가 사진 없이 다시 판정할 수 있거나, 폰에 사진이 남아 있을 때.
bool canEditReportNumbers(AnalysisReport report) =>
    report.rejudgeReady ||
    RegistryPhotoStore.instance.pathsFor(report.id).isNotEmpty;

/// 사용자가 **직접 넣은** 시세(원). 자동으로 찾은 값이면 null — 고치기 시트의 시세 칸은 직접 넣은 값만 담는다.
int? manualMarketPriceOf(AnalysisReport report) =>
    report.marketPriceSource == MarketPriceSource.manual
    ? report.marketPrice
    : null;

/// 고치기 시트를 띄우고, 바꿨으면 저장한다. 같은 자리에서 고쳤으면 **새 리포트**를, 아니면 null을 돌려준다
/// (사진으로 다시 분석한 경우는 로딩 화면이 새 리포트로 데려가므로 null).
///
/// [focusPrice]: 근거 카드의 [시세 입력하기]로 열었을 때 — 시세 칸에 바로 커서를 둔다.
Future<AnalysisReport?> editReportInputs(
  BuildContext context,
  AnalysisReport report, {
  bool focusPrice = false,
}) async {
  final repo = context.read<AnalysisRepository>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final router = GoRouter.maybeOf(context);
  final bool numbersEditable = canEditReportNumbers(report);
  final ReportInputs? next = await showModalBottomSheet<ReportInputs>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ReportInputsSheet(
      report: report,
      numbersEditable: numbersEditable,
      focusPrice: focusPrice,
    ),
  );
  if (next == null || !context.mounted) return null;
  final bool numbersChanged =
      next.deposit != report.deposit ||
      next.marketPrice != manualMarketPriceOf(report);
  if (!numbersChanged && next.alias == report.alias) return null;

  // 서버에 재료가 없는 옛 리포트 — 폰의 사진으로 다시 분석한다(같은 집이면 옛 리포트를 대신한다)
  Future<void> reanalyzeWithPhotos() async {
    final paths = RegistryPhotoStore.instance.pathsFor(report.id);
    if (paths.isEmpty || router == null) {
      messenger?.showSnackBar(
        const SnackBar(
          content: AppText('이 리포트는 사진이 이 폰에 없어 숫자를 고칠 수 없어요. 새로 분석해 주세요.'),
        ),
      );
      return;
    }
    final Object? returned = await router.push<Object?>(
      '/loading',
      extra: AnalysisRequest(
        imagePaths: List.of(paths),
        deposit: next.deposit,
        marketPrice: next.marketPrice,
        alias: next.alias,
        replacesReportId: report.id,
      ),
    );
    if (returned is CaptureRejection) {
      messenger?.showSnackBar(
        SnackBar(
          content: AppText(
            '${returned.message}\n아직 분석하지 않았어요. 사진을 다시 찍어 새로 분석해 주세요.',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  if (numbersChanged && !report.rejudgeReady) {
    await reanalyzeWithPhotos();
    return null;
  }

  // 다시 판정은 설명 문장을 AI로 다시 쓰느라 몇 초 걸린다 — 그동안 막아 둔다
  final navigator = Navigator.of(context, rootNavigator: true);
  if (numbersChanged) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              SizedBox(width: AppSpacing.lg),
              Expanded(child: AppText('같은 등기부로 다시 판정하고 있어요')),
            ],
          ),
        ),
      ),
    );
  }
  try {
    final updated = await repo.updateInputs(report.id, next);
    if (numbersChanged) navigator.pop();
    messenger?.showSnackBar(
      SnackBar(
        content: AppText(numbersChanged ? '새 값으로 다시 판정했어요' : '이름을 바꿨어요'),
      ),
    );
    return updated;
  } on ApiException catch (e) {
    if (numbersChanged) navigator.pop();
    if (e.statusCode == 409) {
      await reanalyzeWithPhotos();
      return null;
    }
    messenger?.showSnackBar(SnackBar(content: AppText(e.message)));
    return null;
  } catch (_) {
    if (numbersChanged) navigator.pop();
    messenger?.showSnackBar(
      const SnackBar(content: AppText('고치지 못했어요. 잠시 뒤 다시 시도해 주세요.')),
    );
    return null;
  }
}

/// 고치기 시트 — 고친 뒤의 전체 값([ReportInputs])을 돌려준다. 취소하면 null.
class ReportInputsSheet extends StatefulWidget {
  const ReportInputsSheet({
    super.key,
    required this.report,
    required this.numbersEditable,
    this.focusPrice = false,
  });

  final AnalysisReport report;
  final bool numbersEditable;
  final bool focusPrice;

  @override
  State<ReportInputsSheet> createState() => _ReportInputsSheetState();
}

class _ReportInputsSheetState extends State<ReportInputsSheet> {
  late final TextEditingController _alias = TextEditingController(
    text: widget.report.alias,
  );
  late final TextEditingController _deposit = TextEditingController(
    text: _manwonText(widget.report.deposit),
  );
  late final TextEditingController _price = TextEditingController(
    text: _manwonText(manualMarketPriceOf(widget.report)),
  );

  static String _manwonText(int? won) =>
      won == null || won <= 0 ? '' : '${won ~/ 10000}';

  static int? _won(String text) {
    final digits = text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    final manwon = int.parse(digits);
    return manwon > 0 ? manwon * 10000 : null;
  }

  @override
  void dispose() {
    _alias.dispose();
    _deposit.dispose();
    _price.dispose();
    super.dispose();
  }

  ReportInputs? get _result {
    final deposit = _won(_deposit.text);
    if (deposit == null) return null;
    final alias = _alias.text.trim();
    return ReportInputs(
      alias: alias.isEmpty ? widget.report.alias : alias,
      deposit: deposit,
      marketPrice: _won(_price.text),
    );
  }

  bool get _numbersChanged {
    final r = _result;
    return r != null &&
        (r.deposit != widget.report.deposit ||
            r.marketPrice != manualMarketPriceOf(widget.report));
  }

  /// 시세 칸 아래 한 줄 — 비우면 무엇을 쓰는지
  String get _priceHint {
    final report = widget.report;
    if (report.marketPrice != null && report.marketPriceSource.isAuto) {
      return '비우면 자동으로 찾은 값(${formatWon(report.marketPrice!)})을 써요';
    }
    return '비우면 자동으로 찾아요';
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final bool editable = widget.numbersEditable;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        0,
        AppSpacing.screenPadding,
        MediaQuery.viewInsetsOf(context).bottom + AppSpacing.xl,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppText('입력값 고치기', style: AppTypography.title),
            const SizedBox(height: AppSpacing.xs),
            AppText(
              editable
                  ? '보증금이나 시세를 바꾸면 같은 등기부로 판정을 다시 해요. 사진은 다시 찍지 않아도 돼요.'
                  : '이 리포트는 사진이 이 폰에 없어 이름만 바꿀 수 있어요. 숫자를 바꾸려면 새로 분석해 주세요.',
              style: AppTypography.caption.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              key: const ValueKey('inputs-alias-field'),
              controller: _alias,
              maxLength: 40,
              decoration: const InputDecoration(labelText: '매물 별칭'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: const ValueKey('inputs-deposit-field'),
              controller: _deposit,
              enabled: editable,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(8),
              ],
              decoration: InputDecoration(
                labelText: '예정 전세보증금',
                suffixText: '만원',
                helperText: _won(_deposit.text) == null
                    ? '보증금을 넣어 주세요'
                    : formatWon(_won(_deposit.text)!),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const ValueKey('inputs-price-field'),
              controller: _price,
              enabled: editable,
              autofocus: widget.focusPrice && editable,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(8),
              ],
              decoration: InputDecoration(
                labelText: '매매 시세 (선택)',
                suffixText: '만원',
                helperText: _won(_price.text) == null
                    ? _priceHint
                    : formatWon(_won(_price.text)!),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.xl),
            AppPrimaryButton(
              key: const ValueKey('inputs-save-button'),
              label: _numbersChanged ? '저장하고 다시 판정하기' : '저장',
              onPressed: result == null
                  ? null
                  : () => Navigator.of(context).pop(result),
            ),
          ],
        ),
      ),
    );
  }
}
