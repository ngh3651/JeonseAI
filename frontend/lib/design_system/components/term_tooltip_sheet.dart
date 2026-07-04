/// 용어 툴팁 — 밑줄 용어(TermText) + 설명 바텀시트.
///
/// IA.md §0 전문용어 원칙: 부득이 노출되는 용어에는 탭 → 짧은 설명 바텀시트를 단다.
/// 시트에는 "챗봇에 더 물어보기" 연결 슬롯이 있다 (S-12 push, 뒤로가기 = 원래 화면).
library;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'app_button.dart';

/// 본문 속 밑줄 용어. 탭하면 설명 바텀시트가 열린다.
class TermText extends StatelessWidget {
  const TermText({
    super.key,
    required this.term,
    required this.description,
    this.onAskChatbot,
    this.style,
  });

  final String term;
  final String description;

  /// null이면 "챗봇에 더 물어보기" 버튼을 숨긴다.
  final VoidCallback? onAskChatbot;

  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final TextStyle base = style ?? AppTypography.body;
    return Semantics(
      button: true,
      label: '$term 용어 설명 보기',
      child: InkWell(
        onTap: () => showTermTooltipSheet(
          context,
          term: term,
          description: description,
          onAskChatbot: onAskChatbot,
        ),
        child: Text(
          term,
          style: base.copyWith(
            color: AppColors.primary,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.dashed,
            decorationColor: AppColors.primaryBright,
          ),
        ),
      ),
    );
  }
}

/// 문단(Text.rich) **안에서** 용어를 인라인으로 쓸 때 사용한다.
///
/// 예: `Text.rich(TextSpan(children: [TextSpan(text: '이 집에는 '),
///      termSpan(context, term: '근저당권', description: '...'), TextSpan(text: '이 있어요.')]))`
/// 베이스라인 정렬로 본문과 줄이 맞고, 문장 줄바꿈 흐름을 깨지 않는다.
InlineSpan termSpan(
  BuildContext context, {
  required String term,
  required String description,
  VoidCallback? onAskChatbot,
  TextStyle? style,
}) {
  return WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    child: TermText(
      term: term,
      description: description,
      onAskChatbot: onAskChatbot,
      style: style,
    ),
  );
}

/// 용어 설명 바텀시트를 연다.
Future<void> showTermTooltipSheet(
  BuildContext context, {
  required String term,
  required String description,
  VoidCallback? onAskChatbot,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.screenPadding,
        right: AppSpacing.screenPadding,
        bottom: MediaQuery.paddingOf(sheetContext).bottom + AppSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(term, style: AppTypography.headline),
          const SizedBox(height: AppSpacing.md),
          Text(description, style: AppTypography.body),
          if (onAskChatbot != null) ...[
            const SizedBox(height: AppSpacing.xl),
            AppSecondaryButton(
              label: '챗봇에 더 물어보기',
              icon: Icons.chat_bubble_outline,
              onPressed: () {
                Navigator.of(sheetContext).pop();
                onAskChatbot();
              },
            ),
          ],
        ],
      ),
    ),
  );
}
