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
import '../../design_system/text/app_text.dart';

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
    // 2026-07-09 A3: 항상 문장 흐름에 붙는 인라인 렌더.
    // (이전엔 48dp 최소 터치박스+Center로 감싸 용어 앞뒤에 큰 공백이 생겼다.
    //  termSpan이 inline 플래그를 전달하지 않아 문단 속 용어까지 박스로 렌더된 버그.)
    final Widget label = AppText(
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
        child: label,
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

/// 문장 + `termGlossary` → **어려운 말에 점선 밑줄이 박힌 리치 텍스트**.
///
/// 리포트 근거 카드·판례 카드·용어 챗봇이 **같은 함수**를 쓴다. 화면마다 따로 만들면
/// 한 곳만 고쳐졌을 때 어떤 화면에서는 밑줄이 안 붙는데, 그 차이를 아무도 눈치채지 못한다.
///
/// 규칙: 키가 **본문에 그대로 있어야** 붙는다(`indexOf`). 서버는 문장에 실제로 등장한
/// 표기만 키로 보내므로(terms.attach) 이 전제가 지켜진다. 못 찾으면 그냥 평범한 글자다.
InlineSpan buildTermSpan(
  BuildContext context, {
  required String text,
  required Map<String, String> glossary,
  TextStyle? style,
  VoidCallback? onAskChatbot,
}) {
  final TextStyle base = style ?? AppTypography.body;
  if (glossary.isEmpty) {
    return TextSpan(text: text, style: base);
  }

  final List<InlineSpan> children = [];
  String rest = text;
  while (rest.isNotEmpty) {
    int bestIndex = -1;
    String? bestTerm;
    for (final term in glossary.keys) {
      final int idx = rest.indexOf(term);
      if (idx >= 0 && (bestIndex == -1 || idx < bestIndex)) {
        bestIndex = idx;
        bestTerm = term;
      }
    }
    if (bestTerm == null) {
      children.add(TextSpan(text: rest));
      break;
    }
    if (bestIndex > 0) {
      children.add(TextSpan(text: rest.substring(0, bestIndex)));
    }
    children.add(
      termSpan(
        context,
        term: bestTerm,
        description: glossary[bestTerm]!,
        onAskChatbot: onAskChatbot,
        style: base,
      ),
    );
    rest = rest.substring(bestIndex + bestTerm.length);
  }
  return TextSpan(style: base, children: children);
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
          AppText(term, style: AppTypography.headline),
          const SizedBox(height: AppSpacing.md),
          AppText(description, style: AppTypography.body),
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
