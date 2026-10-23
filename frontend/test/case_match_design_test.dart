/// 판례 매칭 화면 디자인 확정안(2026-10-24) — 접기·펴기 · 말풍선 · 빈 상태 · 넘침 검사.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/screens/cases/case_card.dart';
import 'package:jeonse_ai/screens/cases/case_match_screen.dart';

import 'support/ko_finders.dart';

CaseMatch _case({
  String caseNo = '대법원 83다카116',
  String? advice = '계약 전에 가압류를 언제 풀지 물어보세요',
  String? sourceUrl = 'https://www.law.go.kr/precInfoP.do?precSeq=1',
  List<String> tags = const ['압류·가압류', '경매'],
}) => CaseMatch(
  riskPattern: tags.first,
  caseNo: caseNo,
  summary: '가압류가 걸린 집에 나중에 들어간 임차인 이야기예요',
  result: '임차인은 낙찰자에게 대항하지 못해 보증금을 지키기 어려웠어요',
  commonPoint: '이 집에도 가압류가 1건 있어요',
  advice: advice,
  sourceUrl: sourceUrl,
  matchedTags: tags,
);

Future<void> _pump(WidgetTester tester, Widget child, {double scale = 1.0}) async {
  tester.view.physicalSize = const Size(360 * 3, 800 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: const Size(360, 800), textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: child,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('판례 카드 접기·펴기', () {
    testWidgets('접힘: 결과·사건번호만 보이고 요약·말풍선은 없다', (tester) async {
      await _pump(tester, CaseCard(match: _case()));
      expect(find.koTextContaining('대항하지'), findsWidgets);
      expect(find.koText('대법원 83다카116'), findsOneWidget);
      expect(find.koText('펼치기'), findsOneWidget);
      expect(find.koTextContaining('나중에 들어간 임차인'), findsNothing);
      expect(find.koText('우리 매물과 공통점'), findsNothing);
    });

    testWidgets('펼치기를 누르면 요약과 말풍선 이름이 보이고, 접기로 다시 닫힌다', (tester) async {
      await _pump(tester, CaseCard(match: _case()));
      await tester.tap(find.koText('펼치기'));
      await tester.pumpAndSettle();
      expect(find.koTextContaining('나중에 들어간 임차인'), findsOneWidget);
      expect(find.koText('우리 매물과 공통점'), findsOneWidget);
      expect(find.koText('접기'), findsOneWidget);

      await tester.tap(find.koText('접기'));
      await tester.pumpAndSettle();
      expect(find.koTextContaining('나중에 들어간 임차인'), findsNothing);
    });

    testWidgets('처음 펼친 카드: 피하려면은 열림, 공통점은 닫힘 → 이름 줄을 누르면 열린다', (tester) async {
      await _pump(tester, CaseCard(match: _case(), initiallyExpanded: true));
      expect(find.koTextContaining('가압류를 언제 풀지'), findsOneWidget);
      expect(find.koTextContaining('이 집에도 가압류가'), findsNothing);

      await tester.tap(find.koText('우리 매물과 공통점'));
      await tester.pumpAndSettle();
      expect(find.koTextContaining('이 집에도 가압류가'), findsOneWidget);

      await tester.tap(find.koText('이런 피해를 피하려면'));
      await tester.pumpAndSettle();
      expect(find.koTextContaining('가압류를 언제 풀지'), findsNothing);
    });

    testWidgets('피하려면 데이터가 없는 판례는 그 말풍선을 통째로 숨긴다', (tester) async {
      await _pump(tester, CaseCard(match: _case(advice: null), initiallyExpanded: true));
      expect(find.koText('이런 피해를 피하려면'), findsNothing);
      expect(find.koText('우리 매물과 공통점'), findsOneWidget);
    });

    testWidgets('원문 주소가 없으면 ↗ 화살표가 없다', (tester) async {
      await _pump(tester, CaseCard(match: _case(sourceUrl: null)));
      expect(find.byIcon(Icons.north_east), findsNothing);
      await _pump(tester, CaseCard(match: _case()));
      expect(find.byIcon(Icons.north_east), findsOneWidget);
    });

    testWidgets('글자를 키워도(130%·150%) 카드가 넘치지 않는다', (tester) async {
      for (final scale in [1.3, 1.5]) {
        await _pump(
          tester,
          CaseCard(
            match: _case(tags: const ['압류·가압류', '소유권을 맡긴 집', '경매']),
            initiallyExpanded: true,
          ),
          scale: scale,
        );
        await tester.tap(find.koText('우리 매물과 공통점'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '글자 배율 $scale 에서 넘쳤어요');
      }
    });
  });

  group('AI 글의 굵게 표시', () {
    test('**굵게** 표시는 떼어 내고 굵게 칠할 구절로 넘긴다', () {
      final r = stripBoldMarkers('이 집에도 **청구금액 4억 원** 가압류가 있어요');
      expect(r.text, '이 집에도 청구금액 4억 원 가압류가 있어요');
      expect(r.bold, ['청구금액 4억 원']);
    });
  });

  group('위쪽 위험 표 · 제목 · 빈 상태', () {
    testWidgets('위험 개수가 2·3·5개여도 넘치지 않고 개수가 보인다', (tester) async {
      for (final n in [2, 3, 5]) {
        final labels = ['소유권을 맡긴 집', '보증보험', '보증금 비율', '먼저 갚을 빚', '압류·가압류'].take(n).toList();
        await _pump(tester, CaseRiskBox(labels: labels));
        expect(find.koTextContaining('$n'), findsWidgets);
        expect(tester.takeException(), isNull, reason: '위험 $n개에서 넘쳤어요');
      }
    });

    testWidgets('제목은 글자 130%에서도 한 줄로 넘치지 않는다', (tester) async {
      await _pump(tester, const CaseMatchHeader(), scale: 1.3);
      expect(tester.takeException(), isNull);
      expect(find.koText('비슷한 상황의 판례를 모았어요'), findsOneWidget);
    });

    testWidgets('안내 줄 옆에 업데이트 날짜, 모르면 날짜를 뺀다', (tester) async {
      await _pump(tester, const CaseMatchHeader(asOf: '2026.10.24 기준'));
      expect(find.koText('판례 데이터는 계속 추가되고 있어요 · 2026.10.24 기준'), findsOneWidget);
      await _pump(tester, const CaseMatchHeader());
      expect(find.koText('판례 데이터는 계속 추가되고 있어요'), findsOneWidget);
    });

    test('서버 날짜 → "2026.10.24 기준", 이상한 값이면 null', () {
      expect(const PrecedentStatus(updatedAt: '2026-10-24').asOfLabel, '2026.10.24 기준');
      expect(const PrecedentStatus(updatedAt: null).asOfLabel, isNull);
      expect(const PrecedentStatus(updatedAt: '어제').asOfLabel, isNull);
      expect(PrecedentStatus.fromJson({'docCount': 40, 'updatedAt': '2026-10-24'}).docCount, 40);
    });

    testWidgets('판례 0건 상자', (tester) async {
      await _pump(tester, const CaseEmptyBox());
      expect(find.koText('이 매물의 위험과 딱 맞는\n판례가 아직 없어요'), findsOneWidget);
    });

    test('대법원만이면 "대법원 판례 N건", 다른 법원이 섞이면 "판례 N건"', () {
      expect(caseCountTitle([_case(), _case()]), '대법원 판례 2건');
      expect(caseCountTitle([_case(), _case(caseNo: '울산지방법원 2005노338')]), '판례 2건');
    });
  });
}
