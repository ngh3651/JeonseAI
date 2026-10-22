/// 대조 결과 → **지금 할 일** (P1-2) — 결과를 읽고 "그래서 뭘 하지?"에서 멈추지 않게.
///
///   ① 위험 줄이 있는 `changed` → "잔금 보내기 전에 멈추세요" + 중개사에게 보낼 문자 복사 + 상담처
///   ② 위험 줄이 없는 `changed` → "입금 전 마지막 체크리스트" (여정 데이터의 잔금 단계 항목)
///   ③ `partial` → "빠진 쪽만 더 찍기" (먼저 찍은 장은 그대로)
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
import 'package:jeonse_ai/screens/pricing/guardian_pass_widgets.dart';
import 'package:jeonse_ai/services/text_share.dart';
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
  VoidCallback? onAddMissing,
  VoidCallback? onBackToJourney,
  int? keptPhotoCount,
  DateTime? now,
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
        onAddMissing: onAddMissing ?? () {},
        keptPhotoCount: keptPhotoCount,
        now: now,
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

      expect(message, contains('집: 경기 성남시 분당구 정자동 456-7\n서류: 7월 9일 ↔ 8월 5일 등기부'));
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

    test('가족·배우자용은 인사·질문을 뺀 요약판 (어느 집·어느 서류인지는 남긴다)', () {
      final message = familyMessageFor(_changedWithDanger);
      expect(message, startsWith('[전세AI프] 등기부를 다시 떼어 보니 처음 서류와 달라진 점이 있어요'));
      expect(message, contains('집: 경기 성남시 분당구 정자동 456-7'));
      expect(message, contains('서류: 7월 9일 ↔ 8월 5일 등기부'));
      expect(message, contains('- 새로 생긴 빚이 있어요 (근저당권 1건 · 채권최고액 1억 2,000만원)'));
      expect(message, isNot(contains('안녕하세요')));
      expect(message, isNot(contains('확인 부탁드려요')));
      expect(message, isNot(contains('김○○')));
    });

    test('잔금일이 지났으면 문자에 "잔금 보내기 전"이라고 쓰지 않는다', () {
      final broker = brokerMessageFor(_changedWithDanger, const [], balancePassed: true);
      expect(broker, isNot(contains('잔금 보내기 전')));
      expect(broker, isNot(contains('잔금을 보내려고')));
      final family = familyMessageFor(_changedWithDanger, balancePassed: true);
      expect(family, isNot(contains('잔금을 보내려고')));
    });
  });

  group('화면', () {
    testWidgets('위험 줄 → 결론 바로 아래 "잔금 보내기 전에 멈추세요" + 달라진 점 + 보내기 + 상담처', (tester) async {
      final content = _Content();
      final copied = _captureClipboard(tester);
      final shared = <String>[];
      TextShare.debugOverride((text, {subject}) async => shared.add(text));
      addTearDown(() => TextShare.debugOverride(null));
      await _pump(tester, _changedWithDanger, content: content);

      expect(find.koText('지금 할 일'), findsOneWidget);
      expect(find.koText('잔금 보내기 전에 멈추세요'), findsOneWidget);
      expect(find.koText('입금 전 마지막 체크리스트'), findsNothing);
      // 서버가 준 변경 요약(문자에 쓰는 말과 같다) + 다음 행동
      expect(
        find.koText(
          '달라진 점: 새로 생긴 빚이 있어요 (근저당권 1건 · 채권최고액 1억 2,000만원) · 집주인이 달라요',
        ),
        findsOneWidget,
      );
      expect(find.koText(kDontTrustVerbalLine), findsOneWidget);
      // 빨간 멈춤 카드에는 초록 '지킴이 패스' 표시를 두지 않는다(보호됨으로 읽힌다)
      expect(find.byType(GuardianPassBadge), findsNothing);

      // 순서: 결론 헤더 → 지금 할 일 (리포트의 '등급 → 결정'과 같게, D2)
      final double cardTop = tester.getTopLeft(find.koText('잔금 보내기 전에 멈추세요')).dy;
      final double headlineTop = tester.getTopLeft(find.koText('달라진 점이 2가지 있어요')).dy;
      expect(headlineTop, lessThan(cardTop));

      final counseling = find.koTextContaining(kCounselingLine);
      await tester.scrollUntilVisible(counseling, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.koText('$kCounselingLine $kCounselingSearchHint'), findsOneWidget);

      final send = find.koText('중개사에게 보내기');
      await tester.scrollUntilVisible(send, -200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(send);
      await tester.pumpAndSettle();

      // 이번에 뗀 서류의 리포트로 질문 템플릿을 받는다 → 공유 창 + 복사도 같이
      expect(content.askedFor, ['r-new']);
      expect(shared.single, contains('- 새로 생긴 빚이 있어요'));
      expect(shared.single, contains(_brokerQuestion));
      expect(copied(), shared.single);
      expect(find.koTextContaining('복사도 해 뒀어요'), findsOneWidget);
    });

    testWidgets('질문을 못 받아도 보낸다 (달라진 점만) · 가족에게는 요약판', (tester) async {
      final shared = <String>[];
      TextShare.debugOverride((text, {subject}) async => shared.add(text));
      addTearDown(() => TextShare.debugOverride(null));
      _captureClipboard(tester);
      await _pump(
        tester,
        _changedWithDanger,
        content: _Content(failQuestions: true),
      );

      final send = find.koText('중개사에게 보내기');
      await tester.scrollUntilVisible(send, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(shared.last, contains('- 집주인이 달라요'));
      expect(shared.last, isNot(contains(_brokerQuestion)));

      final family = find.koText('가족·배우자에게 보내기');
      await tester.scrollUntilVisible(family, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(family);
      await tester.pumpAndSettle();
      expect(shared.last, startsWith('[전세AI프]'));
      expect(shared.last, isNot(contains('안녕하세요')));
    });

    testWidgets('폰에 저장된 잔금일이 지났으면 문구만 바꾼다 (판정은 그대로)', (tester) async {
      final key = journeyPropertyKey(_baseline.address!);
      await JourneyScheduleStore.instance.save(
        key,
        const JourneySchedule().copyWith(JourneyDateKey.balance, DateTime(2026, 8, 1)),
      );
      await _pump(tester, _changedWithDanger, now: DateTime(2026, 8, 5, 10));

      expect(find.koText('새로 생긴 빚을 오늘 바로 확인하세요'), findsOneWidget);
      expect(find.koText('잔금 보내기 전에 멈추세요'), findsNothing);
      expect(
        find.koText('이미 잔금을 보냈다면 오늘 중개사·집주인에게 확인하고 아래 상담처에 물어보세요'),
        findsOneWidget,
      );

      // 위험이 없을 때 카드
      await _pump(tester, _unchanged, now: DateTime(2026, 8, 5, 10));
      expect(find.koText('입주 뒤 확인 끝'), findsOneWidget);
      expect(find.koText('입금 전 마지막 체크리스트'), findsNothing);
    });

    testWidgets('잔금 당일은 아직 "보내기 전"이다', (tester) async {
      final key = journeyPropertyKey(_baseline.address!);
      await JourneyScheduleStore.instance.save(
        key,
        const JourneySchedule().copyWith(JourneyDateKey.balance, DateTime(2026, 8, 5)),
      );
      await _pump(tester, _changedWithDanger, now: DateTime(2026, 8, 5, 10));
      expect(find.koText('잔금 보내기 전에 멈추세요'), findsOneWidget);
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
      // 여정으로 돌아가는 버튼은 화면 맨 아래 하나뿐이다 — 카드 안에 같은 버튼을 겹쳐 두지 않는다(D3)
      expect(find.koText('잔금 단계로 돌아가기', skipOffstage: false), findsNothing);

      final bottom = find.koText('잔금 보내기 전에 확인할 것 보기');
      await tester.scrollUntilVisible(bottom, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(bottom);
      await tester.pumpAndSettle();
      expect(back, 1);
    });

    testWidgets('여정 목록을 못 받아도 체크리스트 카드는 할 일을 말한다', (tester) async {
      await _pump(tester, _unchanged, withContent: false);

      expect(find.koText('입금 전 마지막 체크리스트'), findsOneWidget);
      expect(find.koTextContaining('잔금 단계에서 확인할 것을 마저 보세요'), findsOneWidget);
    });

    testWidgets('일부 못 봄 → 빠진 쪽만 더 찍기 (통째로 다시 고르기가 아니다)', (tester) async {
      var added = 0;
      var repicked = 0;
      await _pump(
        tester,
        _partial,
        onAddMissing: () => added++,
        onRecapture: () => repicked++,
        keptPhotoCount: 3,
      );

      expect(find.koText('빠진 쪽만 더 찍어 주세요'), findsOneWidget);
      expect(find.koText('잔금 보내기 전에 멈추세요'), findsNothing);
      expect(find.koText('입금 전 마지막 체크리스트'), findsNothing);

      final button = find.koText('빠진 쪽만 더 찍기 (먼저 찍은 3장은 그대로)');
      await tester.scrollUntilVisible(button, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(added, 1);
      expect(repicked, 0, reason: "'사진 다시 고르기'(통째로 바꾸기)는 다른 집일 때만");
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
