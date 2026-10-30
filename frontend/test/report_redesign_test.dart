/// 리포트 1장·사진에서 보기 다시 그리기 (2026-10-31).
///
///   ① 근거 카드 펼침 = 기준 막대 · 이 집 숫자 · ✦ AI 설명 · 이 집에서 할 일 · 근거 한 줄 (줄표 없음)
///   ② 옛 리포트(숫자 줄 없음)는 예전 상세 상자
///   ③ 자세히 보기 = 이 집에서 본 것 · 이 집 맞춤 할 일 · ✦ AI 설명 · 기본 확인 · 근거 (판정 문구 없음)
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/screens/report/registry_findings.dart';
import 'package:jeonse_ai/screens/report/registry_mark_sheet.dart';

import 'support/ko_finders.dart';

const _senior = EvidenceItem(
  id: 'senior_debt',
  title: '나보다 먼저 돈 받아갈 빚이 있나요?',
  termSubtitle: '선순위 채권 · 근저당권',
  grade: RiskGrade.danger,
  easyExplanation: '이 집에는 먼저 갚을 빚이 1억 8,000만원 있어요 — 근저당 2건이에요.\n경매로 넘어가면 이 빚이 먼저예요.',
  detailText: '지금 살아 있는 빚 1억 8,000만원 · 2건 (이미 지워진 빚은 뺐어요) — 긴 줄',
  sourceText: 'HUG 전세보증금반환보증 가입요건',
  points: [
    EvidencePoint(label: '먼저 받아갈 빚', value: '1억 8,000만원 · 2건', tone: 'danger'),
    EvidencePoint(label: '1순위 근저당', value: '2021.6.30 · ○○은행 · 1억 3,000만원'),
  ],
  meter: EvidenceMeter(label: '빚 ÷ 시세', value: 90, marks: [60], tone: 'danger'),
  todo: ['잔금 날 근저당을 **말소**할지 그대로 둘지 중개사에게 묻고, 특약으로 남기세요'],
  termGlossary: {'말소': '등기부에 적혀 있던 권리가 없어졌다는 표시예요.'},
  explanationSource: 'solar-pro4',
);

Future<void> _pumpCard(WidgetTester tester, EvidenceItem e) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: FindingsCard(items: [e], actionFor: (_) => null, expandedIndex: 0),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('① 펼침 — 막대 · 이 집 숫자 · AI 설명 · 할 일 · 근거, 줄표 없음', (tester) async {
    await _pumpCard(tester, _senior);
    expect(find.byKey(const ValueKey('finding-meter')), findsOneWidget);
    expect(find.byKey(const ValueKey('finding-points')), findsOneWidget);
    expect(find.koText('1억 8,000만원 · 2건'), findsOneWidget);
    expect(find.koText('AI 설명'), findsOneWidget);
    expect(find.koText('이 집에서 할 일'), findsOneWidget);
    expect(find.koTextContaining('특약으로 남기세요'), findsOneWidget);
    expect(find.byKey(const ValueKey('finding-source-senior_debt')), findsOneWidget);
    // 숫자 줄이 있으면 예전 긴 상세 상자는 그리지 않는다
    expect(find.koTextContaining('긴 줄'), findsNothing);
    // 줄표는 마침표로
    expect(find.koTextContaining('있어요. 근저당 2건이에요'), findsOneWidget);
    expect(find.koTextContaining('—'), findsNothing);
  });

  testWidgets('①-2 준비된 문구면 \'AI 설명\'이라고 하지 않는다', (tester) async {
    const fallback = EvidenceItem(
      id: 'senior_debt',
      title: '나보다 먼저 돈 받아갈 빚이 있나요?',
      termSubtitle: '선순위 채권 · 근저당권',
      grade: RiskGrade.danger,
      easyExplanation: '준비된 설명',
      points: [EvidencePoint(label: '먼저 받아갈 빚', value: '1억원 · 1건', tone: 'danger')],
      explanationSource: '준비된 문구',
    );
    await _pumpCard(tester, fallback);
    expect(find.koText('AI 설명'), findsNothing);
    expect(find.koText('설명'), findsOneWidget);
    expect(explanationByAi('solar-pro4'), isTrue);
    expect(explanationByAi('준비된 문구'), isFalse);
    expect(explanationByAi(null), isFalse);
    expect(explanationByAi('자동 생성'), isFalse);
  });

  testWidgets('② 옛 리포트는 예전 상세 상자 (줄표는 걷는다)', (tester) async {
    const old = EvidenceItem(
      id: 'senior_debt',
      title: '나보다 먼저 돈 받아갈 빚이 있나요?',
      termSubtitle: '선순위 채권 · 근저당권',
      grade: RiskGrade.danger,
      easyExplanation: '설명',
      detailText: '지금 살아 있는 빚 1억원 · 1건 — 위험 기준을 넘어요',
    );
    await _pumpCard(tester, old);
    expect(find.byKey(const ValueKey('finding-points')), findsNothing);
    expect(find.koTextContaining('1건, 위험 기준을 넘어요'), findsOneWidget);
  });

  test('줄표 걷기', () {
    expect(softenDashes('아니에요 — 아래를 보세요'), '아니에요. 아래를 보세요');
    expect(softenDashes('보증금 1억 — 시세 2억'), '보증금 1억, 시세 2억');
    expect(softenDashes('줄표 없음'), '줄표 없음');
  });

  testWidgets('③ 자세히 보기 — 이 집에서 본 것 · 맞춤 할 일 · AI 설명 · 기본 확인 · 근거', (tester) async {
    const mark = RegistryHighlight(
      id: 'mortgage-0',
      page: 0,
      kind: 'mortgage',
      badge: 3,
      box: HighlightBox(x: 0.1, y: 0.1, w: 0.3, h: 0.02),
      title: '집에 잡힌 빚 (근저당권) · 1억 3,000만원',
      body: '집이 경매로 넘어가면 이 돈을 빌려준 곳이 먼저 가져가요.\n지금 남은 빚은 부채증명원으로 확인하세요.',
      source: '등기부 을구 — 이 앱이 사진에서 직접 찾은 위치',
      facts: ['1순위', '2021.6.30 접수', '○○은행', '채권최고액 1억 3,000만원'],
      plan: [
        '잔금 날 이 빚(1억 3,000만원)을 갚고 **말소**하는지 중개사에게 묻고, 특약으로 남기세요',
        '지금 남은 빚은 집주인 **대출 잔액 확인서(부채증명원)**로 확인하세요',
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(
          body: RegistryMarkSheet(
            mark: mark,
            aiText: '이 집 빚은 시세의 90%예요 — 높아요.\n둘째 문단.\n셋째 문단.',
            aiWritten: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mark-sheet-facts')), findsOneWidget);
    expect(find.koText('2021.6.30 접수'), findsOneWidget);
    expect(find.koText('이 집 맞춤 할 일'), findsOneWidget);
    expect(find.byKey(const ValueKey('mark-sheet-ai')), findsOneWidget);
    expect(find.koTextContaining('셋째 문단'), findsNothing, reason: 'AI 설명은 두 문단까지');
    expect(find.koText('AI가 이 집에 맞춰 쓴 설명'), findsOneWidget);
    expect(find.koText('기본 확인'), findsOneWidget);
    // 기본 확인 = 맞춤 할 일에 없는 줄만. '부채증명원으로 확인하세요'는 할 일 2번과 같은 말이라 빠진다
    expect(find.koTextContaining('먼저 가져가요'), findsOneWidget);
    expect(find.koTextContaining('부채증명원으로 확인하세요'), findsNothing);
    expect(find.koTextContaining('위험도 판정이 아닙니다'), findsNothing);
    expect(find.koText('근거 · 등기부 을구 · 사진에서 직접 찾은 위치'), findsOneWidget);
    expect(find.koTextContaining('—'), findsNothing);
  });

  test('표시 → 같은 이야기를 하는 근거 카드', () {
    expect(evidenceIdForMark('mortgage'), 'senior_debt');
    expect(evidenceIdForMark('provisional_seizure'), 'ownership');
    expect(evidenceIdForMark('pending_application'), 'pending');
    expect(evidenceIdForMark('owner'), 'blacklist');
    expect(evidenceIdForMark('address'), isNull);
  });
}
