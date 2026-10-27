/// 등기부 **변동 내용** 상자 — 대조 결과 시트와 '등기부 변동 기록'이 같은 규칙으로 그린다 (2026-10-27 시안).
///
/// - 새로 생김(빨강) → 없어짐(초록) 상자로 나눈다. 해당 건이 없으면 그 상자는 통째로 숨긴다.
///   **없어진 것은 좋은 소식이라 빨강으로 칠하지 않는다.**
/// - 한 건에 한 줄: 왼쪽 종류 이름, 오른쪽 "2024.1.11 접수". 같은 종류가 여러 건이면 줄을 따로.
///   금액이 붙는 종류는 이름 아래 흐린 한 줄("채권최고액 …" · "금액 확인 필요" — 서버 문구 그대로).
/// - 폭이 좁으면(글자 130% 등) 접수일이 이름 아래로 내려간다 — 겹치지 않게.
library;

import 'package:flutter/material.dart';

import '../../design_system/text/app_text.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_typography_next.dart';
import '../../state/journey_progress_store.dart';

/// "2024.1.11 접수" — 접수일을 못 읽었으면 null
String? receiptLabel(DateTime? d) =>
    d == null ? null : '${d.year}.${d.month}.${d.day} 접수';

class ChangeBoxes extends StatelessWidget {
  const ChangeBoxes({
    super.key,
    required this.items,
    this.padding = 16,
    this.gap = 14,
  });

  final List<CompareLogItem> items;

  /// 상자 안쪽 여백 — 시트 16, 변동 기록 12(공간이 좁아서)
  final double padding;

  /// 상자 사이 — 시트 14, 변동 기록 8
  final double gap;

  @override
  Widget build(BuildContext context) {
    final changed = [
      for (final i in items)
        if (i.kind == CompareLogItemKind.changed) i,
    ];
    final added = [
      for (final i in items)
        if (i.kind == CompareLogItemKind.added) i,
    ];
    final removed = [
      for (final i in items)
        if (i.kind == CompareLogItemKind.removed) i,
    ];
    final boxes = <Widget>[
      if (changed.isNotEmpty)
        _Box(
          key: const ValueKey('change-box-changed'),
          items: changed,
          padding: padding,
          soft: AppColors.dangerSoft,
          strong: AppColorsNext.dangerText,
          sign: '≠',
          title: '바뀌었어요 ${changed.length}건',
        ),
      if (added.isNotEmpty)
        _Box(
          key: const ValueKey('change-box-added'),
          items: added,
          padding: padding,
          soft: AppColors.dangerSoft,
          strong: AppColorsNext.dangerText,
          sign: '+',
          title: '새로 생겼어요 ${added.length}건',
        ),
      if (removed.isNotEmpty)
        _Box(
          key: const ValueKey('change-box-removed'),
          items: removed,
          padding: padding,
          soft: AppColors.okSoft,
          strong: AppColors.ok,
          sign: '−',
          title: '없어졌어요 ${removed.length}건',
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < boxes.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          boxes[i],
        ],
      ],
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({
    super.key,
    required this.items,
    required this.padding,
    required this.soft,
    required this.strong,
    required this.sign,
    required this.title,
  });

  final List<CompareLogItem> items;
  final double padding;
  final Color soft;
  final Color strong;
  final String sign;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(padding, padding, padding, padding - 6),
      decoration: BoxDecoration(
        color: soft,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: strong, shape: BoxShape.circle),
                child: AppText(
                  sign,
                  textScaler: TextScaler.noScaling,
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppText(
                  title,
                  style: AppTypographyNext.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: strong,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (int i = 0; i < items.length; i++)
            Container(
              decoration: i == 0
                  ? null
                  : const BoxDecoration(
                      border: Border(top: BorderSide(color: Colors.white)),
                    ),
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: ChangeItemRow(item: items[i]),
            ),
        ],
      ),
    );
  }
}

/// 한 건 한 줄 — 이름(17/600) · 접수일(15/500, 숫자 폭 고정) · 이름 아래 금액(15/500 흐림).
class ChangeItemRow extends StatelessWidget {
  const ChangeItemRow({super.key, required this.item});

  final CompareLogItem item;

  static final TextStyle _name = AppTypographyNext.bodyStrong.copyWith(
    color: AppColorsNext.textStrong,
  );
  static final TextStyle _date = AppTypographyNext.caption.copyWith(
    color: AppColorsNext.textMuted,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
  static final TextStyle _note = AppTypographyNext.caption.copyWith(
    color: AppColorsNext.textMuted,
  );

  static const double _gap = 12;

  double _width(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return painter.width;
  }

  @override
  Widget build(BuildContext context) {
    final String? date = receiptLabel(item.receiptDate);
    final String? note = (item.note ?? '').trim().isEmpty ? null : item.note;
    return LayoutBuilder(
      builder: (context, box) {
        final bool fits =
            date == null ||
            _width(context, item.label, _name) +
                    _gap +
                    _width(context, date, _date) <=
                box.maxWidth;
        final nameAndNote = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppText(item.label, style: _name),
            if (!fits) AppText(date, style: _date),
            if (note != null) AppText(note, style: _note),
          ],
        );
        if (!fits || date == null) return nameAndNote;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: nameAndNote),
            const SizedBox(width: _gap),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: AppText(date, style: _date),
            ),
          ],
        );
      },
    );
  }
}
