/// [시세 입력하기] — 시세를 넣고 **같은 사진·같은 보증금으로** 새로 분석한다 (2026-10-23).
///
/// 예전에는 리포트 근거 카드·손실 시뮬레이터의 이 버튼이 "곧 제공되는 기능이에요"만 띄웠다
/// (심사위원이 누르면 끝 — 서연 리뷰 #4). 이제 실제로 돈다:
///   시세(만원) 입력 → 이 폰에 남은 그 리포트의 사진 + 같은 보증금 + 입력한 시세 → 로딩 → 새 리포트.
///
/// - 판정은 서버 규칙 엔진이 새로 낸다(시세는 사용자가 넣은 값이고, 앱은 숫자를 만들지 않는다).
/// - 사진이 이 폰에 없으면(최근 5건 밖·앱 재설치) 버튼을 **그리지 않는다** — 누를 수 없는 버튼을 두지 않는다.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../models/analysis_report.dart';
import '../../state/registry_photo_store.dart';
import '../search/capture_issue_panel.dart' show CaptureRejection;

/// 이 리포트를 시세만 바꿔 다시 분석할 수 있나 — 사진이 이 폰에 남아 있어야 한다.
bool canReanalyzeWithMarketPrice(AnalysisReport report) =>
    RegistryPhotoStore.instance.pathsFor(report.id).isNotEmpty;

/// 시세를 묻고 새로 분석한다. 취소하거나 사진이 없으면 아무것도 하지 않는다.
Future<void> reanalyzeWithMarketPrice(BuildContext context, AnalysisReport report) async {
  final paths = RegistryPhotoStore.instance.pathsFor(report.id);
  if (paths.isEmpty) return;
  final router = GoRouter.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final int? won = await showDialog<int>(
    context: context,
    builder: (_) => const _MarketPriceDialog(),
  );
  if (won == null) return;
  final Object? returned = await router.push<Object?>(
    '/loading',
    extra: AnalysisRequest(
      imagePaths: List.of(paths),
      deposit: report.deposit,
      marketPrice: won,
      alias: report.alias,
    ),
  );
  // 사진이 이번엔 품질 검사에 걸렸다(분석 전 거절 — 크레딧 0원) — 조용히 돌아오지 않고 이유를 말한다.
  if (returned is CaptureRejection) {
    messenger?.showSnackBar(
      SnackBar(
        content: AppText('${returned.message}\n분석은 하지 않았어요. 사진을 다시 찍어 새로 분석해 주세요.'),
        duration: const Duration(seconds: 5),
      ),
    );
  }
}

class _MarketPriceDialog extends StatefulWidget {
  const _MarketPriceDialog();

  @override
  State<_MarketPriceDialog> createState() => _MarketPriceDialogState();
}

class _MarketPriceDialogState extends State<_MarketPriceDialog> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 만원 단위 입력 → 원. 비었거나 0이면 null.
  int? get _won {
    final digits = _ctrl.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    final int manwon = int.parse(digits);
    return manwon > 0 ? manwon * 10000 : null;
  }

  @override
  Widget build(BuildContext context) {
    final int? won = _won;
    return AlertDialog(
      title: const AppText('매매 시세를 넣어 다시 분석할까요?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(
            '이 집을 사고팔 때의 값(매매 시세)이에요. 같은 사진·같은 보증금으로 새로 분석해요.',
            style: AppTypography.caption,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('market-price-field'),
            controller: _ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(8),
            ],
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(suffixText: '만원'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const AppText('취소'),
        ),
        TextButton(
          onPressed: won == null ? null : () => Navigator.of(context).pop(won),
          child: const AppText('다시 분석하기'),
        ),
      ],
    );
  }
}
