/// S-08 판례 카드 소제목 — "이 판례는 무엇에 대한 경고인가"를 먼저 보여주는가.
///
/// 배경(2026-08-12 실기기 확인): 카드 본문이 요약·결과·공통점·조언 네 문단이라,
/// 소제목이 없으면 **어느 카드가 어느 위험에 대한 것인지 다 읽어야** 알 수 있었다.
/// 서버는 이미 `matchedTags`를 내려주고 있었는데 화면이 쓰지 않던 상태였다.
///
/// 이 테스트가 고정하는 것 두 가지:
/// 1. 소제목이 **상단 칩과 같은 라벨**을 쓴다 — 다르면 사용자가 머릿속에서
///    번역해야 하고, 소제목을 붙인 이유 자체가 사라진다.
/// 2. `matchedTags`가 비어도 소제목이 사라지지 않는다(riskPattern 폴백).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeonse_ai/design_system/components/app_pill.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/screens/cases/case_match_screen.dart';

CaseMatch _case({
  String riskPattern = '압류·가압류',
  List<String> matchedTags = const [],
}) => CaseMatch(
  riskPattern: riskPattern,
  caseNo: '대법원 83다카116',
  summary: '가압류가 걸린 집에 나중에 들어간 임차인은 낙찰자에게 대항할 수 없다고 본 판결이에요',
  result: '임차인은 낙찰자에게 대항하지 못해 보증금을 지키기 어려웠어요',
  commonPoint: '경매 시 가압류 후 계약한 임차인은 낙찰자에게 대항할 수 없어요',
  matchedTags: matchedTags,
);

void main() {
  group('displayTags — 소제목에 쓸 태그', () {
    test('matchedTags가 있으면 그대로 쓴다', () {
      final c = _case(matchedTags: const ['압류·가압류', '경매']);

      expect(c.displayTags, ['압류·가압류', '경매']);
    });

    test('matchedTags가 비면 riskPattern으로 폴백한다 — 소제목이 사라지면 안 된다', () {
      final c = _case(riskPattern: '신탁등기');

      expect(c.displayTags, ['신탁등기']);
    });
  });

  group('fromJson', () {
    test('서버의 matchedTags를 읽는다', () {
      final c = CaseMatch.fromJson(const {
        'riskPattern': '압류·가압류',
        'caseNo': '대법원 83다카116',
        'summary': '요약',
        'result': '결과',
        'commonPoint': '공통점',
        'matchedTags': ['압류·가압류', '대항력'],
      });

      expect(c.matchedTags, ['압류·가압류', '대항력']);
    });

    test('matchedTags가 없는 옛 응답도 깨지지 않는다', () {
      final c = CaseMatch.fromJson(const {
        'riskPattern': '전세가율',
        'caseNo': '대법원 2022다212594',
        'summary': '요약',
        'result': '결과',
        'commonPoint': '공통점',
      });

      expect(c.matchedTags, isEmpty);
      expect(c.displayTags, ['전세가율']);
    });
  });

  group('riskTagLabel — 칩과 카드가 같은 말을 쓰는가', () {
    test('쉬운 말이 정해진 태그는 그 말로 바꾼다', () {
      expect(riskTagLabel('선순위 채권'), '먼저 갚을 빚');
      expect(riskTagLabel('신탁등기'), '소유권을 맡긴 집');
      expect(riskTagLabel('전세가율'), '보증금 비율');
    });

    test('쉬운 말이 없는 법률 용어는 지어내지 않고 그대로 둔다', () {
      // 검수받지 않은 쉬운 말을 화면에서 만들어내면, "문구는 사람이 확정한다"는
      // 원칙이 이 화면에서만 깨진다. 쉬운 말이 필요하면 용어 사전에 먼저 넣는다.
      expect(riskTagLabel('압류·가압류'), '압류·가압류');
      expect(riskTagLabel('경매'), '경매');
      expect(riskTagLabel('임차권등기'), '임차권등기');
      expect(riskTagLabel('대항력'), '대항력');
    });

    test('모르는 태그가 와도 빈 소제목이 되지 않는다', () {
      expect(riskTagLabel('알 수 없는 태그'), '알 수 없는 태그');
    });
  });

  group('소제목 렌더링', () {
    /// 화면 전체를 띄우면 라우터·리포지토리가 필요해 카드 머리 부분만 재현한다.
    /// (case_match_screen.dart의 `_tagHeader`와 같은 구조)
    Widget header(CaseMatch c) => Wrap(
      children: [
        for (final t in c.displayTags.take(kMaxCardTags))
          AppPill(
            label: riskTagLabel(t),
            color: const Color(0xFFD32F2F),
            background: const Color(0xFFFBEAE8),
          ),
      ],
    );

    Future<void> pump(WidgetTester tester, CaseMatch c, {double scale = 1.0}) =>
        tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(360, 800),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(body: header(c)),
            ),
          ),
        );

    testWidgets('태그가 소제목으로 보인다', (tester) async {
      await pump(tester, _case(matchedTags: const ['압류·가압류']));

      expect(find.text('압류·가압류'), findsOneWidget);
    });

    testWidgets('쉬운 말 라벨로 바뀌어 보인다', (tester) async {
      await pump(tester, _case(matchedTags: const ['선순위 채권']));

      expect(find.text('먼저 갚을 빚'), findsOneWidget);
      expect(find.text('선순위 채권'), findsNothing);
    });

    testWidgets('태그가 많아도 상한까지만 — 소제목 줄이 길어지면 "한눈에"가 깨진다', (tester) async {
      await pump(
        tester,
        _case(matchedTags: const ['압류·가압류', '경매', '대항력', '임차권등기', '보증보험']),
      );

      expect(find.byType(AppPill), findsNWidgets(kMaxCardTags));
    });

    testWidgets('글자를 키워도 소제목 줄이 넘치지 않는다', (tester) async {
      for (final scale in [1.3, 1.5, 2.0]) {
        await pump(
          tester,
          _case(matchedTags: const ['압류·가압류', '소유권을 맡긴 집', '경매']),
          scale: scale,
        );
        expect(tester.takeException(), isNull, reason: '글자 배율 $scale 에서 넘쳤어요');
      }
    });
  });
}
