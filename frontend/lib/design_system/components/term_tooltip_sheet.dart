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
    this.inline = false,
  });

  final String term;
  final String description;

  /// null이면 "챗봇에 더 물어보기" 버튼을 숨긴다.
  final VoidCallback? onAskChatbot;

  final TextStyle? style;

  /// 문단 속(termSpan)에서 쓰일 때 true — 줄 흐름 유지를 위해 터치 영역 확장을 하지 않는다.
  /// (인라인 터치 영역은 C-3에서 재검토)
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final TextStyle base = style ?? AppTypography.body;
    final Widget label = Text(
      term,
      style: base.copyWith(
        color: AppColors.primary,
        fontWeight: FontWeight.w600,
        decoration: TextDecoration.underline,
        decorationStyle: TextDecorationStyle.dashed,
        decorationColor: AppColors.primaryBright,
      ),
    );

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
        child: inline
            ? label
            // 단독 사용 시 최소 터치 영역(48dp) 확보 (design-reviewer 반영)
            : ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSize.minTouchTarget,
                  minWidth: AppSize.minTouchTarget,
                ),
                child: Center(child: label),
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
