/// 대조 결과 → **지금 할 일** (P1-2) — 결과를 읽고 "그래서 뭘 하지?"에서 멈추지 않게.
///
///   ① 위험 줄이 있는 `changed` → "잔금 보내기 전에 멈추세요" + 중개사에게 보낼 문자 복사 + 상담처
///   ② 위험 줄이 없는 `changed` → "입금 전 마지막 체크리스트" (여정 데이터의 잔금 단계 항목)
///   ③ `partial` → "다시 찍기"
///   ④ 기준 없음·다른 집 → 카드 없음
///   ⑤ 새 판정을 만들지 않는다 — 문자는 서버 줄 제목 + 서버 질문 템플릿뿐, 이름은 넣지 않는다
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/compare/compare_next_step.dart';
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

const _brokerQuestion = '잔금 드리는 날에 등기부에 잡힌 빚(근저당)을 없애 주실 수 있나요?';

/// 서버 질문 템플릿 대신 — 누구 리포트로 물었는지 남긴다.
class _Content extends DummyContentRepository {
  _Content({this.failQuestions = false});

  final bool failQuestions;
  final List<String> askedFor = [];

  @override
  Future<List<QuestionGroup>> questionGroups(String reportId) async {
    askedFor.add(reportId);
    if (failQuestions) throw Exception('서버에 닿지 못함 흉내');
    return const [
      QuestionGroup(
        riskLabel: '먼저 갚을 빚 (선순위 채권·근저당)',
        items: [
          QuestionItem(
            question: _brokerQuestion,
            why: '먼저 잡힌 빚이 남아 있으면 보증금을 못 돌려받을 위험이 커요',
            safeAnswer: '잔금일에 말소하겠다고 특약으로 넣어 준다',
            riskyAnswer: '말소 계획이 없다고 한다',
          ),
        ],
      ),
    ];
  }
}

const _sameOwner = CompareRow(
  kind: CompareRowKind.same,
  tone: CompareTone.neutral,
  marker: '=',
  title: '집주인 · 그대로예요',
  detail: '김○○ · 변동 없음',
);

/// 6a — 새 근저당 + 집주인 바뀜 (위험 줄 두 개)
final _changedWithDanger = CompareResult(
  outcome: CompareOutcome.changed,
  headline: '달라진 점이 2가지 있어요',
  subline: '6가지를 모두 맞춰봤어요',
  baseline: _baseline,
  current: const CompareDoc(viewedAt: '2026.08.05'),
  newReportId: 'r-new',
  rows: [
    CompareRow(
      kind: CompareRowKind.added,
      tone: CompareTone.danger,
      marker: '+',
      title: '새로 생긴 빚이 있어요',
      detail: '근저당권 1건 · 채권최고액 1억 2,000만원\n2026년 8월 1일 접수',
      receiptDate: DateTime(2026, 8, 1),
    ),
    const CompareRow(
      kind: CompareRowKind.changed,
      tone: CompareTone.danger,
      marker: '≠',
      title: '집주인이 달라요',
      detail: '기준 김○○ → 이번 이○○',
    ),
  ],
);

/// 다 맞춰봤고 달라진 점이 없다 ("그대로")
const _unchanged = CompareResult(
  outcome: CompareOutcome.changed,
  headline: '달라진 점은 없었어요',
  baseline: _baseline,
  current: CompareDoc(viewedAt: '2026.08.05'),
  newReportId: 'r-new',
  rows: [_sameOwner],
);

const _partial = CompareResult(
  outcome: CompareOutcome.partial,
  headline: '일부는 대조하지 못했어요',
  baseline: _baseline,
  current: CompareDoc(viewedAt: '2026.08.05'),
  rows: [
    CompareRow(
      kind: CompareRowKind.unknown,
      tone: CompareTone.caution,
      marker: '?',
      title: '빚 · 대조하지 못했어요',
      action: CompareAction.recapture,
      actionLabel: '빠진 쪽 찍어서 올리기',
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  CompareResult result, {
  ContentRepository? content,
  bool withContent = true,
  VoidCallback? onRecapture,
  VoidCallback? onBackToJourney,
}) async {
  tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final Widget app = MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: CompareResultView(
        result: result,
        baselineReportId: 'r-base',
        onRetry: () {},
        onRecapture: onRecapture ?? () {},
        onQuestions: () {},
        onAnalyze: () {},
        onGuide: () {},
        onBackToJourney: onBackToJourney ?? () {},
      ),
    ),
  );

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<JourneyScheduleStore>.value(
          value: JourneyScheduleStore.instance,
        ),
        if (withContent)
          Provider<ContentRepository>.value(value: content ?? _Content()),
      ],
      child: app,
    ),
  );
  await tester.pumpAndSettle();
}

/// 클립보드에 들어간 글자를 붙잡는다 (실제 휴대폰 클립보드 대신).
String? Function() _captureClipboard(WidgetTester tester) {
  String? copied;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return () => copied;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    JourneyScheduleStore.instance.resetForTest();
  });

  group('어느 카드인가 (서버 결과의 갈래만 옮긴다)', () {
    test('위험 줄이 있는 changed → 멈추세요', () {
      expect(
        compareNextStepFor(_changedWithDanger),
        CompareNextStep.stopBeforeBalance,
      );
    });

    test('위험 줄이 없는 changed → 입금 전 마지막 체크리스트', () {
      expect(compareNextStepFor(_unchanged), CompareNextStep.finalChecklist);
      // 없어진 항목(회색 줄)만 있어도 위험 줄은 아니다 — 서버가 정한 색을 그대로 따른다
      const removedOnly = CompareResult(
        outcome: CompareOutcome.changed,
        headline: '달라진 점이 1가지 있어요',
        baseline: _baseline,
        current: CompareDoc(),
        rows: [
          CompareRow(
            kind: CompareRowKind.removed,
            tone: CompareTone.neutral,
            marker: '−',
            title: '없어진 빚이 있어요',
          ),
        ],
      );
      expect(compareNextStepFor(removedOnly), CompareNextStep.finalChecklist);
    });

    test('partial → 다시 찍기 · 기준 없음·다른 집 → 카드 없음', () {
      expect(compareNextStepFor(_partial), CompareNextStep.recapture);
      expect(
        compareNextStepFor(
          const CompareResult(
            outcome: CompareOutcome.noBaseline,
            headline: '이 분석은 비교 기준으로 쓸 수 없어요',
            baseline: _baseline,
            current: CompareDoc(),
          ),
        ),
        isNull,
      );
      expect(
        compareNextStepFor(
          const CompareResult(
            outcome: CompareOutcome.differentProperty,
            headline: '같은 집이 아닌 것 같아요',
            baseline: _baseline,
            current: CompareDoc(),
          ),
        ),
        isNull,
      );
    });
  });

  group('중개사에게 보낼 문자', () {
    test('서버 줄 제목 + 서버 질문 템플릿만 — 이름은 넣지 않는다', () {
      final message = brokerMessageFor(_changedWithDanger, const [
        QuestionGroup(
          riskLabel: '먼저 갚을 빚',
          items: [
            QuestionItem(
              question: _brokerQuestion,
              why: '',
              safeAnswer: '',
              riskyAnswer: '',
            ),
          ],
        ),
      ]);

      expect(message, contains('집: 경기 성남시 분당구 정자동 456-7'));
      expect(
        message,
        contains('- 새로 생긴 빚이 있어요 (근저당권 1건 · 채권최고액 1억 2,000만원)'),
      );
      expect(message, contains('- 집주인이 달라요'));
      expect(message, contains('- $_brokerQuestion'));
      // 집주인 줄의 상세(가린 이름)도, 접수일 줄도 문자에 옮기지 않는다
      expect(message, isNot(contains('김○○')));
      expect(message, isNot(contains('이○○')));
      expect(message, isNot(contains('8월 1일 접수')));
    });

    test('질문은 문자 한 통 분량만 (앞에서부터)', () {
      final message = brokerMessageFor(_changedWithDanger, [
        QuestionGroup(
          riskLabel: '많은 질문',
          items: [
            for (int i = 1; i <= kBrokerMessageMaxQuestions + 2; i++)
              QuestionItem(
                question: '질문$i번',
                why: '',
                safeAnswer: '',
                riskyAnswer: '',
              ),
          ],
        ),
      ]);
      expect(message, contains('- 질문1번'));
      expect(message, contains('- 질문$kBrokerMessageMaxQuestions번'));
      expect(message, isNot(contains('- 질문${kBrokerMessageMaxQuestions + 1}번')));
    });

    test('질문을 못 받으면 달라진 점만 담는다', () {
      final message = brokerMessageFor(_changedWithDanger, const []);
      expect(message, contains('- 새로 생긴 빚이 있어요'));
      expect(message, isNot(contains('확인 부탁드려요')));
    });
  });

  group('화면', () {
    testWidgets('위험 줄 → 맨 위 "잔금 보내기 전에 멈추세요" + 문자 복사 + 상담처', (tester) async {
      final content = _Content();
      final copied = _captureClipboard(tester);
      await _pump(tester, _changedWithDanger, content: content);

      expect(find.koText('지금 할 일'), findsOneWidget);
      expect(find.koText('잔금 보내기 전에 멈추세요'), findsOneWidget);
      expect(find.koText(kCounselingLine), findsOneWidget);
      expect(find.koText('입금 전 마지막 체크리스트'), findsNothing);

      // 카드가 결과(제목 카드)보다 위에 있다
      final double cardTop = tester.getTopLeft(find.koText('잔금 보내기 전에 멈추세요')).dy;
      final double headlineTop = tester.getTopLeft(find.koText('달라진 점이 2가지 있어요')).dy;
      expect(cardTop, lessThan(headlineTop));

      await tester.tap(find.koText('중개사에게 보낼 문자 복사'));
      await tester.pumpAndSettle();

      // 이번에 뗀 서류의 리포트로 질문 템플릿을 받는다
      expect(content.askedFor, ['r-new']);
      expect(copied(), contains('- 새로 생긴 빚이 있어요'));
      expect(copied(), contains(_brokerQuestion));
      expect(find.koTextContaining('복사했어요'), findsOneWidget);
    });

    testWidgets('질문을 못 받아도 복사는 된다 (달라진 점만)', (tester) async {
      final copied = _captureClipboard(tester);
      await _pump(
        tester,
        _changedWithDanger,
        content: _Content(failQuestions: true),
      );

      await tester.tap(find.koText('중개사에게 보낼 문자 복사'));
      await tester.pumpAndSettle();

      expect(copied(), contains('- 집주인이 달라요'));
      expect(copied(), isNot(contains(_brokerQuestion)));
      expect(find.koTextContaining('복사했어요'), findsOneWidget);
    });

    testWidgets('그대로 → 입금 전 마지막 체크리스트 (여정의 잔금 단계 항목, 등기부 대조는 방금 함)', (
      tester,
    ) async {
      var back = 0;
      await _pump(tester, _unchanged, onBackToJourney: () => back++);

      expect(find.koText('입금 전 마지막 체크리스트'), findsOneWidget);
      expect(find.koText('돈 받는 계좌 주인이 집주인과 같은지 확인하기'), findsOneWidget);
      expect(
        find.koText('등기부를 다시 떼서 달라진 게 없는지 보기 — 방금 했어요'),
        findsOneWidget,
      );
      expect(find.koText('잔금 보내기 전에 멈추세요'), findsNothing);

      await tester.tap(find.koText('잔금 단계로 돌아가기'));
      await tester.pumpAndSettle();
      expect(back, 1);
    });

    testWidgets('여정 목록을 못 받아도 체크리스트 카드는 할 일을 말한다', (tester) async {
      await _pump(tester, _unchanged, withContent: false);

      expect(find.koText('입금 전 마지막 체크리스트'), findsOneWidget);
      expect(find.koTextContaining('잔금 단계에서 확인할 것을 마저 보세요'), findsOneWidget);
      expect(find.koText('잔금 단계로 돌아가기'), findsOneWidget);
    });

    testWidgets('일부 못 봄 → 다시 찍기', (tester) async {
      var recaptured = 0;
      await _pump(tester, _partial, onRecapture: () => recaptured++);

      expect(find.koText('빠진 쪽을 다시 찍어 주세요'), findsOneWidget);
      expect(find.koText('잔금 보내기 전에 멈추세요'), findsNothing);
      expect(find.koText('입금 전 마지막 체크리스트'), findsNothing);

      await tester.tap(find.koText('다시 찍기'));
      await tester.pumpAndSettle();
      expect(recaptured, 1);
    });

    testWidgets('기준 없음 → 지금 할 일 카드를 따로 띄우지 않는다', (tester) async {
      await _pump(
        tester,
        const CompareResult(
          outcome: CompareOutcome.noBaseline,
          headline: '이 분석은 비교 기준으로 쓸 수 없어요',
          baseline: _baseline,
          current: CompareDoc(),
        ),
      );
      expect(find.koText('지금 할 일'), findsNothing);
    });
  });
}
