/// 등기부 대조 결과 4갈래 (S-11 6a~6d) — **말해야 할 것과 말하면 안 되는 것**.
///
/// 이 화면의 실패 방식은 둘 다 사람의 돈을 잃게 만든다:
///   ⑴ 못 본 것을 '이상 없음'으로 보이게 하는 것 → 6b는 반드시 "달라진 게 없다는 뜻이
///      아니에요"를 띄우고 행동 버튼을 붙인다.
///   ⑵ 다른 집 숫자를 보여주는 것 → 6d는 등급·금액을 **한 글자도 그리지 않는다.**
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/components/risk_badge.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/screens/compare/compare_result_view.dart';
import 'package:jeonse_ai/state/journey_schedule_store.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneHeight, kPhoneWidth;

const _baseline = CompareDoc(
  reportId: 'r-base',
  alias: '정자동 빌라',
  address: '경기 성남시 분당구 정자동 456-7',
  viewedAt: '2026.07.09',
  grade: RiskGrade.caution,
);

Future<void> _pump(WidgetTester tester, CompareResult result) async {
  tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ChangeNotifierProvider<JourneyScheduleStore>.value(
      value: JourneyScheduleStore.instance,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: CompareResultView(
            result: result,
            baselineReportId: 'r-base',
            onRetry: () {},
            onRecapture: () {},
            onQuestions: () {},
            onAnalyze: () {},
            onGuide: () {},
            onBackToJourney: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    JourneyScheduleStore.instance.resetForTest();
  });

  testWidgets('6a 변동 발견 — 변한 것과 안 변한 것을 모두 보여준다', (tester) async {
    await _pump(
      tester,
      CompareResult(
        outcome: CompareOutcome.changed,
        headline: '달라진 점이 2가지 있어요',
        subline: '4가지를 모두 맞춰봤어요',
        baseline: _baseline,
        current: const CompareDoc(viewedAt: '2026.08.05', grade: RiskGrade.danger),
        daysBetween: 27,
        rows: [
          CompareRow(
            kind: CompareRowKind.added,
            tone: CompareTone.danger,
            marker: '+',
            title: '새로 생긴 빚이 있어요',
            subtitle: '나보다 먼저 돈 받아갈 빚 (근저당권·전세권·임차권등기)',
            detail: '근저당권 1건 · 채권최고액 1억 2,000만원\n2026년 8월 1일 접수',
            receiptDate: DateTime(2026, 8, 1),
          ),
          const CompareRow(
            kind: CompareRowKind.grade,
            tone: CompareTone.danger,
            marker: '!',
            title: '안전도가 내려갔어요',
            gradeBefore: RiskGrade.caution,
            gradeAfter: RiskGrade.danger,
          ),
          const CompareRow(
            kind: CompareRowKind.same,
            tone: CompareTone.neutral,
            marker: '=',
            title: '집주인 · 그대로예요',
            detail: '김○○ · 변동 없음',
          ),
        ],
      ),
    );

    expect(find.koText('달라진 점이 2가지 있어요'), findsOneWidget);
    expect(find.koText('7월 9일자 서류 ↔ 8월 5일자 서류'), findsOneWidget);
    expect(find.koText('근저당권 1건 · 채권최고액 1억 2,000만원'), findsOneWidget);
    // 안 변한 것도 반드시 보인다 (변한 것만 나열하면 "나머지는 안 봤나?"가 된다)
    expect(find.koText('집주인 · 그대로예요'), findsOneWidget);
    // 등급 변화는 뱃지 두 개로
    expect(find.byType(RiskBadge), findsNWidgets(2));
    // 규칙 기반 고지가 늘 따라붙는다
    expect(find.koTextContaining('AI가 판단하지 않았어요'), findsOneWidget);
  });

  testWidgets('6b 일부 대조 불가 — 못 본 것을 이상 없음으로 두지 않는다', (tester) async {
    await _pump(
      tester,
      const CompareResult(
        outcome: CompareOutcome.partial,
        headline: '일부는 대조하지 못했어요',
        subline: '4가지 중 2가지만 맞춰봤어요',
        baseline: _baseline,
        current: CompareDoc(viewedAt: '2026.08.05'),
        rows: [
          CompareRow(
            kind: CompareRowKind.unknown,
            tone: CompareTone.caution,
            marker: '?',
            title: '빚 · 대조하지 못했어요',
            subtitle: '이번에 올린 사진 3장에서 그 쪽을 찾지 못했어요',
            action: CompareAction.recapture,
            actionLabel: '빠진 쪽 찍어서 올리기',
          ),
        ],
      ),
    );

    expect(find.koText("대조하지 못한 항목은 '달라진 게 없다'는 뜻이 아니에요"), findsOneWidget);
    // 경고 문구 뒤에는 반드시 행동 버튼
    expect(find.koText('빠진 쪽 찍어서 올리기'), findsWidgets);
  });

  testWidgets('6c 기준 없음 — 비난이 아니라 초대 톤 (경고색 금지)', (tester) async {
    await _pump(
      tester,
      const CompareResult(
        outcome: CompareOutcome.noBaseline,
        headline: '이 분석은 비교 기준으로 쓸 수 없어요',
        subline: '지금 한 번 떼어 기준을 만들어 두면, 다음에 뗄 때부터 달라진 점을 알려드릴 수 있어요.',
        baseline: _baseline,
        current: CompareDoc(),
      ),
    );

    expect(find.koText('이 분석은 비교 기준으로 쓸 수 없어요'), findsOneWidget);
    expect(find.koText('오늘 뗀 등기부가 기준이 돼요'), findsOneWidget);
    expect(find.koText('지금 떼어 기준 만들기'), findsOneWidget);
    expect(find.koText('기준을 만들어도 전에 받은 리포트는 그대로 볼 수 있어요'), findsOneWidget);
    // 등급 뱃지(색 강조)를 쓰지 않는다 — 여기는 판정 화면이 아니다
    expect(find.byType(RiskBadge), findsNothing);
  });

  testWidgets('6d 다른 집 — 숫자도 등급도 그리지 않는다', (tester) async {
    await _pump(
      tester,
      const CompareResult(
        outcome: CompareOutcome.differentProperty,
        headline: '같은 집이 아닌 것 같아요',
        subline: '이번에 올린 등기부는 먼저 분석한 집과 다른 집이에요. 대조는 같은 집끼리만 할 수 있어요.',
        baseline: _baseline,
        current: CompareDoc(viewedAt: '2026.08.05'),
        identityBasis: '고유번호',
        notices: ['다른 집끼리 숫자를 비교하면 틀린 결론이 나와서, 대조 결과는 보여드리지 않아요'],
      ),
    );

    expect(find.koText('같은 집이 아닌 것 같아요'), findsOneWidget);
    expect(find.koText('확인되지 않은 다른 집'), findsOneWidget);
    expect(find.koTextContaining('대조 결과는 보여드리지 않아요'), findsOneWidget);
    expect(find.koText('사진 다시 고르기'), findsOneWidget);
    // **수치·등급을 아예 렌더하지 않는다**
    expect(find.byType(RiskBadge), findsNothing);
    expect(find.koTextContaining('원'), findsNothing);
  });
}
