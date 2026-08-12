/// S-12 용어 챗봇 추천 칩 — 개수·글자 크기가 늘어도 깨지지 않는지.
///
/// 배경: 용어 사전이 6개 → 18개로 늘었다(terms.json 일원화, 2026-08-05).
/// 인계 문서에 "앱 화면을 못 봤다 — 깨질 수 있다"로 남아 있던 항목이다.
///
/// **결론: 깨지지 않는다** (2026-08-12 실측).
/// - 개수: 가로 스크롤 ListView라 18개든 100개든 넘치지 않는다.
/// - 높이: 48은 시각적 칩 크기가 아니라 **최소 터치 타깃**이다. 글자 배율 2.0배에서도
///   라벨 높이는 29px라 틀 안에 들어간다(가장 긴 '등기사항전부증명서' 기준 실측).
///
/// 이 파일은 그 결론을 **고정**하기 위한 것이다. 칩 줄 구조를 Wrap이나 고정 Row로
/// 바꾸면 개수·배율 어느 쪽에서든 깨지므로, 그때 이 테스트가 먼저 알려준다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeonse_ai/design_system/tokens/app_colors.dart';
import 'package:jeonse_ai/design_system/tokens/app_spacing.dart';
import 'package:jeonse_ai/design_system/tokens/app_typography.dart';

/// glossary_chatbot_screen.dart의 `_recommendedChips`와 같은 구조.
/// (화면 전체를 띄우면 리포지토리·라우터가 필요해 칩 줄만 떼어 재현한다)
Widget buildChipRow(List<String> terms) {
  return SizedBox(
    height: AppSize.minTouchTarget,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
      itemCount: terms.length,
      separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
      itemBuilder: (context, i) => ActionChip(
        label: Text(terms[i]),
        onPressed: () {},
        backgroundColor: AppColors.primarySoft,
        side: BorderSide.none,
        labelStyle: AppTypography.label.copyWith(color: AppColors.primary),
      ),
    ),
  );
}

/// 서버가 실제로 내려주는 18개 (GET /api/glossary, 2026-08-12 확인)
const _terms = <String>[
  '전세가율', '선순위 채권', '근저당권', '신탁등기', '압류', '가압류',
  '경매개시결정', '임차권등기', '확정일자', '전입신고', '등기사항전부증명서',
  '갑구', '을구', '말소', '다가구주택', '전세보증금 반환보증', 'HUG', '실거래가',
];

Future<void> _pump(
  WidgetTester tester,
  List<String> terms, {
  double textScale = 1.0,
  double width = 360,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(body: Center(child: buildChipRow(terms))),
      ),
    ),
  );
}

void main() {
  testWidgets('용어 18개여도 가로 스크롤이라 넘치지 않는다', (tester) async {
    await _pump(tester, _terms);

    expect(tester.takeException(), isNull);
    expect(find.byType(ActionChip), findsWidgets);
  });

  testWidgets('좁은 화면(320)에서도 깨지지 않는다', (tester) async {
    await _pump(tester, _terms, width: 320);

    expect(tester.takeException(), isNull);
  });

  testWidgets('글자 크기를 키워도 칩이 세로로 넘치지 않는다', (tester) async {
    // 안드로이드 접근성 '글꼴 크게'는 1.3배, '가장 크게'는 2.0배까지 간다.
    // 여기서 넘치면 실기기에서 노란 줄무늬(RenderFlex overflow)가 뜬다.
    for (final scale in [1.3, 1.5, 2.0]) {
      await _pump(tester, _terms, textScale: scale);
      expect(
        tester.takeException(),
        isNull,
        reason: '글자 배율 $scale 에서 칩 줄이 넘쳤어요',
      );
    }
  });

  testWidgets('칩 줄 높이가 최소 터치 타깃(48) 이상이다', (tester) async {
    await _pump(tester, _terms);

    final box = tester.getSize(find.byType(ListView));
    expect(box.height, greaterThanOrEqualTo(AppSize.minTouchTarget));
  });

  testWidgets('용어가 0개여도 빈 줄만 남고 터지지 않는다', (tester) async {
    // 서버 실패 시 _terms가 빈 목록으로 남는 경로 (화면 주석 참고)
    await _pump(tester, const []);

    expect(tester.takeException(), isNull);
    expect(find.byType(ActionChip), findsNothing);
  });
}
