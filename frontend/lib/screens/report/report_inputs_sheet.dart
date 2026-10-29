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
/// 저장은 **시트 안에서** 한다 — 다시 판정하는 동안 버튼이 돌고, 실패하면 시트가 그대로 남아 넣은 값이 지켜진다
/// (디자인 리뷰 2026-10-29). [focusPrice]: 근거 카드의 [시세 입력하기]로 열었을 때 — 시세 칸에 바로 커서를 둔다.
Future<AnalysisReport?> editReportInputs(
  BuildContext context,
  AnalysisReport report, {
  bool focusPrice = false,
}) async {
  final repo = context.read<AnalysisRepository>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final router = GoRouter.maybeOf(context);
  final bool numbersEditable = canEditReportNumbers(report);

  final _SheetOutcome? outcome = await showModalBottomSheet<_SheetOutcome>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ReportInputsSheet(
      report: report,
      numbersEditable: numbersEditable,
      focusPrice: focusPrice,
      // 서버에 재료가 없는 옛 리포트는 시트에서 저장하지 않는다 — 닫고 사진으로 다시 분석한다
      save: (inputs, numbersChanged) async {
        if (numbersChanged && !report.rejudgeReady) {
          return _SheetOutcome.reanalyze(inputs);
        }
        try {
          return _SheetOutcome.saved(
            await repo.updateInputs(report.id, inputs),
          );
        } on ApiException catch (e) {
          if (e.statusCode == 409) return _SheetOutcome.reanalyze(inputs);
          throw _SaveError(e.message);
        } catch (_) {
          throw const _SaveError('고치지 못했어요. 잠시 뒤 다시 시도해 주세요.');
        }
      },
    ),
  );
  if (outcome == null || !context.mounted) return null;

  final updated = outcome.report;
  if (updated != null) {
    messenger?.showSnackBar(
      SnackBar(content: AppText(_changeMessage(report, updated))),
    );
    return updated;
  }

  // 옛 리포트 — 폰의 사진으로 다시 분석한다(같은 집이면 옛 리포트를 대신한다)
  final next = outcome.reanalyzeWith!;
  final paths = RegistryPhotoStore.instance.pathsFor(report.id);
  if (paths.isEmpty || router == null) {
    messenger?.showSnackBar(
      const SnackBar(
        content: AppText('이 리포트는 사진이 이 폰에 없어 숫자를 고칠 수 없어요. 새로 분석해 주세요.'),
      ),
    );
    return null;
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
  return null;
}

/// 고친 뒤 한 줄 — **등급이 바뀌었으면 글로** 말한다(색만 바뀌면 놓친다 · 디자인 리뷰 2026-10-29).
String _changeMessage(AnalysisReport before, AnalysisReport after) {
  final numbersChanged =
      before.deposit != after.deposit ||
      before.marketPrice != after.marketPrice;
  if (!numbersChanged) return '이름을 바꿨어요';
  if (before.grade != after.grade) {
    return '새 값으로 다시 판정했어요 — 등급이 바뀌었어요: ${before.grade.label} → ${after.grade.label}';
  }
  return '새 값으로 다시 판정했어요 — 등급은 그대로예요(${after.grade.label})';
}

class _SaveError implements Exception {
  const _SaveError(this.message);
  final String message;
}

/// 시트가 닫히며 돌려주는 것 — 고친 리포트, 또는 사진으로 다시 분석할 입력값
class _SheetOutcome {
  const _SheetOutcome.saved(AnalysisReport this.report) : reanalyzeWith = null;
  const _SheetOutcome.reanalyze(ReportInputs this.reanalyzeWith)
    : report = null;

  final AnalysisReport? report;
  final ReportInputs? reanalyzeWith;
}

/// 고치기 시트 — 보증금 · 매매 시세(선택) · 별칭(선택). 입력 화면과 같은 순서.
class ReportInputsSheet extends StatefulWidget {
  const ReportInputsSheet({
    super.key,
    required this.report,
    required this.numbersEditable,
    required this.save,
    this.focusPrice = false,
  });

  final AnalysisReport report;
  final bool numbersEditable;
  final bool focusPrice;

  /// 저장 — 고친 값과 '숫자가 바뀌었나'를 받아 시트를 닫을 결과를 돌려준다. 실패면 [_SaveError]를 던진다.
  final Future<_SheetOutcome> Function(ReportInputs inputs, bool numbersChanged)
  save;

  @override
  State<ReportInputsSheet> createState() => _ReportInputsSheetState();
}

class _ReportInputsSheetState extends State<ReportInputsSheet> {
  late final TextEditingController _deposit = TextEditingController(
    text: _manwonText(widget.report.deposit),
  );
  // 시세 칸은 **지금 리포트의 시세**로 채운다(자동으로 찾은 값이든 직접 넣은 값이든 — 2026-10-30 규혁: 수정이면 칸이 채워져 있어야).
  // 안 건드리면 출처도 그대로(자동은 자동), 바꾸면 직접 넣은 값, 비우면 다시 자동으로 찾는다.
  late final TextEditingController _price = TextEditingController(
    text: _manwonText(widget.report.marketPrice),
  );
  late final TextEditingController _alias = TextEditingController(
    text: widget.report.alias,
  );
  bool _saving = false;
  String? _error;

  static String _manwonText(int? won) =>
      won == null || won <= 0 ? '' : _withCommas('${won ~/ 10000}');

  static String _withCommas(String digits) {
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return buf.toString();
  }

  static int? _won(String text) {
    final digits = text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    final manwon = int.parse(digits);
    return manwon > 0 ? manwon * 10000 : null;
  }

  @override
  void dispose() {
    _deposit.dispose();
    _price.dispose();
    _alias.dispose();
    super.dispose();
  }

  /// 시세 칸을 건드렸나 — 채워 둔 값과 다르면(비운 것 포함) 바꾼 것이다
  bool get _priceChanged => _won(_price.text) != widget.report.marketPrice;

  ReportInputs? get _result {
    final deposit = _won(_deposit.text);
    if (deposit == null) return null;
    final alias = _alias.text.trim();
    return ReportInputs(
      alias: alias.isEmpty ? widget.report.alias : alias,
      deposit: deposit,
      // 안 건드렸으면 원래 출처 그대로(자동 → null), 바꿨으면 넣은 값(비우면 null = 다시 자동으로 찾기)
      marketPrice: _priceChanged
          ? _won(_price.text)
          : manualMarketPriceOf(widget.report),
    );
  }

  bool get _numbersChanged {
    final r = _result;
    return r != null && (r.deposit != widget.report.deposit || _priceChanged);
  }

  Future<void> _submit() async {
    final result = _result;
    if (result == null || _saving) return;
    if (!_numbersChanged && result.alias == widget.report.alias) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final outcome = await widget.save(result, _numbersChanged);
      if (mounted) Navigator.of(context).pop(outcome);
    } on _SaveError catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    }
  }

  /// 금액 칸 — 칸 아래엔 넣은 값을 '1억 2,000만원'처럼 읽어 주기만 한다(0을 하나 더 넣어도 바로 보이게).
  /// 설명 문장은 두지 않는다(2026-10-30 규혁: 말이 많다).
  InputDecoration _moneyDecoration(String label, TextEditingController c) {
    final won = _won(c.text);
    return InputDecoration(
      labelText: label,
      suffixText: '만원',
      helperText: !widget.numbersEditable
          ? '사진이 없어 못 고쳐요'
          : (won == null ? null : formatWon(won)),
      suffixIcon: widget.numbersEditable
          ? null
          : const Icon(Icons.lock_outline),
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final bool editable = widget.numbersEditable && !_saving;
    final money = [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(8),
      _CommaFormatter(),
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.screenPadding,
          0,
          AppSpacing.screenPadding,
          MediaQuery.viewInsetsOf(context).bottom + AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const AppText('정보 수정', style: AppTypography.title),
                    const SizedBox(height: AppSpacing.lg),
                    TextField(
                      key: const ValueKey('inputs-deposit-field'),
                      controller: _deposit,
                      enabled: editable,
                      keyboardType: TextInputType.number,
                      inputFormatters: money,
                      decoration: _moneyDecoration('전세보증금', _deposit),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextField(
                      key: const ValueKey('inputs-price-field'),
                      controller: _price,
                      enabled: editable,
                      autofocus: widget.focusPrice && widget.numbersEditable,
                      keyboardType: TextInputType.number,
                      inputFormatters: money,
                      decoration: _moneyDecoration('매매 시세', _price),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextField(
                      key: const ValueKey('inputs-alias-field'),
                      controller: _alias,
                      enabled: !_saving,
                      maxLength: 40,
                      decoration: const InputDecoration(
                        labelText: '별칭',
                        counterText: '',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      AppText(
                        _error!,
                        key: const ValueKey('inputs-error'),
                        style: AppTypography.caption.copyWith(
                          color: AppColors.danger,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.lg),
                  ],
                ),
              ),
            ),
            // 저장 버튼은 스크롤 밖 — 키보드가 올라와도 바로 위에 보인다
            AppPrimaryButton(
              key: const ValueKey('inputs-save-button'),
              label: _numbersChanged ? '저장하고 다시 판정' : '저장',
              loading: _saving,
              onPressed: result == null || _saving ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// 만원 칸 — 세 자리마다 쉼표(입력 화면과 같은 모양, 0을 하나 더 넣으면 바로 보이게)
class _CommaFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return const TextEditingValue();
    final text = _ReportInputsSheetState._withCommas(digits);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
