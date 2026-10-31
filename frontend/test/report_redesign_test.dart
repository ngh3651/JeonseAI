/// 리포트 1장·사진에서 보기 다시 그리기 (2026-10-31).
///
///   ① 근거 카드 펼침 = 기준 막대 · 이 집 숫자 · ✦ AI 설명 · 이 집에서 할 일 · 근거 한 줄 (줄표 없음)
///   ② 옛 리포트(숫자 줄 없음)는 예전 상세 상자
///   ③ 자세히 보기 = 이 집에서 본 것 · 이 집 맞춤 할 일 · ✦ AI 설명 · 기본 확인 · 근거 (판정 문구 없음)
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/screens/common/ask_selection.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/design_system/components/app_section.dart';
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
  testWidgets('① 펼침(옛 리포트 — 그림 없음) — 막대 · 이 집에서 본 것 · 이 집 핵심 · 이 집 맞춤 할 일 · 근거, 줄표 없음', (tester) async {
    await _pumpCard(tester, _senior);
    expect(find.byKey(const ValueKey('finding-meter')), findsOneWidget);
    expect(find.byKey(const ValueKey('finding-points')), findsOneWidget);
    expect(find.koText('1억 8,000만원 · 2건'), findsOneWidget);
    // 칸 이름은 앱 전체와 같다(2026-11-01) — 'AI 설명' · '이 집에서 할 일'은 없다
    expect(find.koText('이 집에서 본 것'), findsOneWidget);
    expect(find.koText('이 집 핵심'), findsOneWidget);
    expect(find.koText('✦ AI가 썼어요'), findsOneWidget);
    expect(find.koText('이 집 맞춤 할 일'), findsOneWidget);
    expect(find.koText('✦ AI가 읽었어요'), findsOneWidget);
    expect(find.koText('AI 설명'), findsNothing);
    expect(find.koText('이 집에서 할 일'), findsNothing);
    expect(find.koTextContaining('특약으로 남기세요'), findsOneWidget);
    expect(find.byKey(const ValueKey('finding-source-senior_debt')), findsOneWidget);
    // 숫자 줄이 있으면 예전 긴 상세 상자는 그리지 않는다
    expect(find.koTextContaining('긴 줄'), findsNothing);
    // 줄표는 마침표로
    expect(find.koTextContaining('있어요. 근저당 2건이에요'), findsOneWidget);
    expect(find.koTextContaining('—'), findsNothing);
  });

  testWidgets('①-2 준비된 문구면 \'AI가 썼어요\'를 붙이지 않는다', (tester) async {
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
    expect(find.koText('이 집 핵심'), findsOneWidget);
    expect(find.koTextContaining('AI가 썼어요'), findsNothing);
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

  testWidgets('③ 자세히 보기 — 이 집에서 본 것(표) → 기본 확인 → 맞춤 할 일 → 근거, AI 상자 없음', (tester) async {
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
      factRows: [
        ['순위', '1순위'],
        ['접수', '2021.6.30'],
        ['빌려준 곳', '○○은행'],
      ],
      plan: [
        '잔금 날 이 빚(1억 3,000만원)을 갚고 **말소**하는지 중개사에게 묻고, 특약으로 남기세요',
        '지금 남은 빚은 집주인 **대출 잔액 확인서(부채증명원)**로 확인하세요',
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(body: RegistryMarkSheet(mark: mark)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mark-sheet-facts')), findsOneWidget);
    expect(find.koText('2021.6.30'), findsOneWidget);
    expect(find.koText('빌려준 곳'), findsOneWidget);
    expect(find.koText('✦ AI가 읽었어요'), findsOneWidget);
    expect(find.byKey(const ValueKey('mark-sheet-ai')), findsNothing, reason: '초록 AI 설명 상자는 뺐다');
    // 순서: 이 집에서 본 것 → 기본 확인 → 이 집 맞춤 할 일 → 근거
    final ys = [
      for (final t in ['이 집에서 본 것', '기본 확인', '이 집 맞춤 할 일'])
        tester.getTopLeft(find.koText(t)).dy,
      tester.getTopLeft(find.byKey(const ValueKey('mark-sheet-source'))).dy,
    ];
    expect(ys, [...ys]..sort());
    // 기본 확인 = 맞춤 할 일에 없는 줄만. '부채증명원으로 확인하세요'는 할 일 2번과 같은 말이라 빠진다
    expect(find.koTextContaining('먼저 가져가요'), findsOneWidget);
    expect(find.koTextContaining('부채증명원으로 확인하세요'), findsNothing);
    expect(find.koText('근거 · 등기부 을구 · 사진에서 직접 찾은 위치'), findsOneWidget);
    expect(find.koTextContaining('—'), findsNothing);
    expect(find.byType(AskSelectionArea), findsOneWidget, reason: '꾹 눌러 챗봇에 묻기');
  });

  testWidgets('③ 옛 리포트(표 줄 없음)면 이 집에서 본 것을 칩으로', (tester) async {
    const mark = RegistryHighlight(
      id: 'mortgage-0',
      page: 0,
      kind: 'mortgage',
      badge: 1,
      box: HighlightBox(x: 0.1, y: 0.1, w: 0.3, h: 0.02),
      title: '집에 잡힌 빚 (근저당권)',
      body: '집이 경매로 넘어가면 이 돈을 빌려준 곳이 먼저 가져가요.',
      facts: ['1순위', '2021.6.30 접수'],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(body: RegistryMarkSheet(mark: mark)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.koText('2021.6.30 접수'), findsOneWidget);
  });

  test('표 줄을 읽는다 (서버 factRows)', () {
    final h = RegistryHighlight.fromJson({
      'id': 'a',
      'page': 0,
      'kind': 'mortgage',
      'badge': 1,
      'box': {'x': 0, 'y': 0, 'w': 0.1, 'h': 0.1},
      'title': 't',
      'body': 'b',
      'factRows': [
        ['순위', '1순위'],
        ['', '값만'],
      ],
    });
    expect(h.factRows, [
      ['순위', '1순위'],
      ['', '값만'],
    ]);
    expect(h.withPage(2).factRows, h.factRows);
  });

  test('근거 카드 → 사진 위 표시 종류 ([등기부에서 위치 보기])', () {
    expect(markKindsForEvidence('senior_debt'), contains('mortgage'));
    expect(markKindsForEvidence('ownership'), contains('provisional_seizure'));
    expect(markKindsForEvidence('pending'), {'pending_application'});
    expect(markKindsForEvidence('blacklist'), {'owner'});
    expect(markKindsForEvidence('jeonse_ratio'), isEmpty);
  });

  // ── 2026-11-01 리디자인: 한눈에(큰 한 줄 + 그림) · 굵은 머리말 문단 · 밑줄은 처음 한 번 ─────────────
  testWidgets('③ 빚 카드 — 큰 한 줄 · 줄 서기 막대 · 돌려받을 돈 · 색 점 표 · 머리말 문단 · 위치 보기', (tester) async {
    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    const e = EvidenceItem(
      id: 'senior_debt',
      title: '나보다 먼저 돈 받아갈 빚이 있나요?',
      termSubtitle: '선순위 채권',
      grade: RiskGrade.danger,
      easyExplanation: '**집을 산 날 바로 빌렸어요** 같은 날 근저당을 잡았어요.\n**개인에게 더 빌렸어요** 두 번째 근저당은 개인이에요.',
      termGlossary: {'근저당': '집을 담보로 빌린 돈의 표시예요.'},
      explanationSource: 'solar-pro2',
      hero: EvidenceHero(text: '집값의 97%가 이미 빚이에요', accent: '97%'),
      visual: EvidenceVisual(
        type: 'queue',
        items: [
          EvidenceVisualItem(label: '은행', amount: 360000000, kind: 'debt'),
          EvidenceVisualItem(label: '이○○', amount: 52000000, kind: 'debt'),
          EvidenceVisualItem(label: '내 보증금', amount: 250000000, kind: 'mine'),
        ],
        cutLabel: '경매로 팔리는 값',
        cutAmount: 318500000,
        resultValue: '0원',
        resultSub: '내 보증금 2억 5,000만원 중',
        resultTone: 'danger',
      ),
      points: [EvidencePoint(label: '3순위 근저당', value: '3억 6,000만원', sub: '2022.4.15 · 가상은행', dot: 0)],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: FindingsCard(items: const [e], actionFor: (_) => null, locateFor: (_) => () {}, expandedIndex: 0),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('finding-hero')), findsOneWidget);
    expect(find.byKey(const ValueKey('finding-queue')), findsOneWidget);
    expect(find.koText('경매로 팔리는 값 3억 1,850만원'), findsOneWidget);
    expect(find.byKey(const ValueKey('finding-result')), findsOneWidget);
    expect(find.koText('0원'), findsOneWidget);
    expect(find.koText('2022.4.15 · 가상은행'), findsOneWidget);
    // 머리말은 굵은 한 줄로 따로
    expect(find.koText('집을 산 날 바로 빌렸어요'), findsOneWidget);
    // '근저당' 밑줄은 이 카드 글에서 처음 한 번만 — 두 번째 문단의 근저당은 평범한 글자
    expect(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_CaseTerm'), findsOneWidget);
    expect(find.byKey(const ValueKey('finding-locate-senior_debt')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('머리말 문단 나누기', () {
    expect(splitLeadParagraph('**머리말** 본문이에요.'), (lead: '머리말', body: '본문이에요.'));
    expect(splitLeadParagraph('그냥 문단이에요.'), (lead: null, body: '그냥 문단이에요.'));
  });
}
