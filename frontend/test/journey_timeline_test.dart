/// S-11 계약 여정 — 2026-10-26 확정 시안(그림 ①~⑬)이 **하기로 한 일**을 못 박는다.
///
///   ① 체크박스 모양이 없다. 이미 고른 단계 칩을 한 번 더 누르면 그 단계 완료가 켜지고 꺼진다(분석 단계는 늘 완료).
///   ② 대조 단계(가계약금·계약서·잔금·입주 다음 날)에는 [최근 분석과 대조하기] — 완료되면 사라진다.
///   ③ 리포트 카드는 등기부 날짜 + 지난 날수("27일 전"), 날짜를 못 읽었으면 지어내지 않는다. 집 이름엔 도로명 주소가 없다.
///   ④ 날짜 원은 사용자가 넣은 날짜로만 찬다 — 날짜 없는 앞 단계는 순서로 추정해 체크만 한다.
///   ⑤ 대조를 마치면: 결과 시트(변동 없음/있음) → 그 단계 자동 완료 → 등기부 변동 기록 맨 위 한 줄.
///   ⑥ 알림을 거절해도 '알림이 꺼져 있어요' 류 문구가 없고, 가족·친구에게 보내기 버튼이 어디에도 없다.
///   ⑦ 같은 집(주소)은 리포트가 여러 개여도 집 하나다.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/design_system/tokens/app_colors.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/models/property_reports.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/journey/journey_compare_flow.dart';
import 'package:jeonse_ai/screens/journey/journey_parts.dart';
import 'package:jeonse_ai/screens/journey/journey_screen.dart';
import 'package:jeonse_ai/state/journey_focus.dart';
import 'package:jeonse_ai/state/app_session.dart';
import 'package:jeonse_ai/state/journey_progress_store.dart';
import 'package:jeonse_ai/state/journey_schedule_store.dart';
import 'package:jeonse_ai/utils/money_format.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneWidth;

/// 테스트용 이력 — 등기부를 뗀 날짜를 **직접 정해서** 경과일을 확정한다. 대조하면 [compareWith]를 돌려준다.
class _FakeRepo extends AnalysisRepository {
  _FakeRepo(this.reports, {this.compareWith});

  final List<AnalysisReport> reports;
  final CompareResult? compareWith;
  final List<List<String>> compared = [];

  @override
  Future<AnalysisReport> analyze(AnalysisRequest request) async =>
      reports.first;

  @override
  Future<List<AnalysisReport>> getHistory() async => reports;

  @override
  Future<AnalysisReport?> getReport(String id) async =>
      reports.where((r) => r.id == id).firstOrNull;

  @override
  Future<void> deleteReport(String id) async {}

  @override
  Future<CompareResult> compareRegistry(String id, List<String> paths) async {
    compared.add(paths);
    return compareWith ??
        CompareResult(
          outcome: CompareOutcome.noBaseline,
          headline: '이 분석은 비교 기준으로 쓸 수 없어요',
          baseline: CompareDoc(reportId: id),
          current: const CompareDoc(),
        );
  }
}

AnalysisReport _report({
  required String id,
  required String alias,
  required String address,
  RiskGrade grade = RiskGrade.caution,
  int? registryAgeDays = 27,
  bool comparable = true,
  int analyzedDaysAgo = 0,
}) {
  final now = DateTime.now();
  return AnalysisReport(
    id: id,
    alias: alias,
    address: address,
    analyzedAt: now.subtract(Duration(days: analyzedDaysAgo, hours: 2)),
    registryViewedAt: registryAgeDays == null
        ? null
        : formatDate(now.subtract(Duration(days: registryAgeDays))),
    grade: grade,
    headline: '확인이 필요해요',
    nextAction: '확인 후 결정하세요',
    topRiskSummary: '예시',
    deposit: 300000000,
    marketPrice: null,
    seniorDebtAmount: 0,
    gaugeProgress: 0.5,
    evidences: const [],
    comparable: comparable,
  );
}

final _jeongja = _report(
  id: 'r-jeongja',
  alias: '정자동 빌라',
  address: '경기 성남시 분당구 정자동 456-7',
);
final _yeoksam = _report(
  id: 'r-yeoksam',
  alias: '역삼동 오피스텔',
  address: '서울 강남구 역삼동 123-45',
  grade: RiskGrade.danger,
  registryAgeDays: 8,
);
final String _jeongjaKey = journeyPropertyKey(_jeongja.address);

DateTime _day(int offset) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day + offset);
}

Future<_FakeRepo> _pumpJourney(
  WidgetTester tester, {
  List<AnalysisReport>? reports,
  CompareResult? compareWith,
  List<String> gallery = const [],
}) async {
  // 키가 큰 화면 — 아래 단계 카드·기록까지 한 번에 그린다(스크롤 밖은 만들지 않으므로)
  tester.view.physicalSize = const Size(kPhoneWidth * 3, 2200 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final repo = _FakeRepo(
    reports ?? [_jeongja, _yeoksam],
    compareWith: compareWith,
  );
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => JourneyScreen(
          pickMany: () async => gallery,
          captureOne: () async => null,
        ),
      ),
      GoRoute(
        path: '/report/:id',
        builder: (_, s) =>
            Scaffold(body: Text('리포트 ${s.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/compare/:id',
        builder: (_, s) =>
            Scaffold(body: Text('대조 화면 ${s.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/analyze',
        builder: (_, _) => const Scaffold(body: Text('분석 화면')),
      ),
      GoRoute(
        path: '/guide',
        builder: (_, _) => const Scaffold(body: Text('가이드')),
      ),
    ],
  );
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSession()),
        ChangeNotifierProvider<AnalysisRepository>.value(value: repo),
        Provider<ContentRepository>(create: (_) => DummyContentRepository()),
        ChangeNotifierProvider<JourneyScheduleStore>.value(
          value: JourneyScheduleStore.instance,
        ),
        ChangeNotifierProvider<JourneyProgressStore>.value(
          value: JourneyProgressStore.instance,
        ),
      ],
      child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

Future<void> _tapChip(WidgetTester tester, int index) async {
  final chip = find.byKey(ValueKey('journey-chip-$index'));
  // 칩 줄은 옆으로 스크롤된다 — 안 보이는 칸은 만들어지지 않으므로 보일 때까지 민다
  final row = find.descendant(
    of: find.byType(StageChipsRow),
    matching: find.byType(Scrollable),
  );
  await tester.drag(row, const Offset(2000, 0)); // 맨 앞으로
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(chip, 64, scrollable: row);
  await tester.pumpAndSettle();
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

CompareResult _compareResult({required bool newDebt}) => CompareResult(
  outcome: CompareOutcome.changed,
  headline: newDebt ? '달라진 점이 1가지 있어요' : '달라진 점은 없었어요',
  baseline: const CompareDoc(reportId: 'r-jeongja', viewedAt: '2026.08.14'),
  current: const CompareDoc(reportId: 'r-new', viewedAt: '2026.10.24'),
  totalCount: 4,
  comparedCount: 4,
  newReportId: 'r-new',
  rows: [
    if (newDebt)
      CompareRow(
        kind: CompareRowKind.added,
        tone: CompareTone.danger,
        marker: '+',
        title: '새로 생긴 빚이 있어요',
        detail: '근저당권 1건 · 채권최고액 1억 2,000만원\n2026년 10월 20일 접수',
        group: 'debt',
        items: [
          CompareItem(
            label: '근저당권',
            receiptDate: DateTime(2026, 10, 20),
            amountText: '채권최고액 1억 2,000만원',
          ),
        ],
      )
    else
      const CompareRow(
        kind: CompareRowKind.same,
        tone: CompareTone.neutral,
        marker: '=',
        title: '빚 · 그대로예요',
        group: 'debt',
      ),
    const CompareRow(
      kind: CompareRowKind.same,
      tone: CompareTone.neutral,
      marker: '=',
      title: '집주인 · 그대로예요',
      group: 'owner',
    ),
    const CompareRow(
      kind: CompareRowKind.same,
      tone: CompareTone.neutral,
      marker: '=',
      title: '압류·가압류 · 그대로예요',
      group: 'seizure',
    ),
  ],
);

/// 실기기 화면 그대로 — 새로 생김 2건(경매개시결정 · 0원 근저당), 없어짐 4건(압류 · 가압류 2 · 경매개시결정)
CompareResult _mixedResult() => CompareResult(
  outcome: CompareOutcome.changed,
  headline: '달라진 점이 3가지 있어요',
  baseline: const CompareDoc(reportId: 'r-jeongja', viewedAt: '2026.08.14'),
  current: const CompareDoc(reportId: 'r-new', viewedAt: '2026.10.27'),
  totalCount: 4,
  comparedCount: 4,
  newReportId: 'r-new',
  rows: [
    CompareRow(
      kind: CompareRowKind.added,
      tone: CompareTone.danger,
      marker: '+',
      title: '새로 생긴 압류·가압류가 있어요',
      group: 'seizure',
      items: [CompareItem(label: '경매개시결정', receiptDate: DateTime(2022, 7, 27))],
    ),
    CompareRow(
      kind: CompareRowKind.removed,
      tone: CompareTone.neutral,
      marker: '−',
      title: '없어진 압류·가압류가 있어요',
      group: 'seizure',
      items: [
        CompareItem(label: '압류', receiptDate: DateTime(2024, 3, 4)),
        CompareItem(label: '가압류', receiptDate: DateTime(2024, 1, 11)),
        CompareItem(label: '가압류', receiptDate: DateTime(2024, 2, 2)),
        CompareItem(label: '경매개시결정', receiptDate: DateTime(2024, 3, 22)),
      ],
    ),
    CompareRow(
      kind: CompareRowKind.added,
      tone: CompareTone.danger,
      marker: '+',
      title: '새로 생긴 빚이 있어요',
      group: 'debt',
      items: [
        CompareItem(
          label: '근저당권',
          receiptDate: DateTime(2021, 4, 22),
          amountText: '금액 확인 필요',
        ),
      ],
    ),
    const CompareRow(
      kind: CompareRowKind.same,
      tone: CompareTone.neutral,
      marker: '=',
      title: '집주인 · 그대로예요',
      group: 'owner',
    ),
  ],
);

/// 대조 결과 시트 안에서만 찾는다 — 시트 뒤 '등기부 변동 기록'에도 같은 상자가 그려진다
Finder _inSheet(Finder f) =>
    find.descendant(of: find.byType(CompareProgressSheet), matching: f);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    JourneyScheduleStore.instance.resetForTest();
    JourneyProgressStore.instance.resetForTest();
  });

  group('화면 구조', () {
    testWidgets('집 줄(등급 + 별칭, 도로명 주소 없음) · 리포트 카드 · 내 계약 일정 · 9단계 칩 · 변동 기록', (
      tester,
    ) async {
      await _pumpJourney(tester);

      expect(find.koText('계약 여정'), findsOneWidget);
      expect(find.koText('정자동 빌라'), findsOneWidget);
      expect(
        find.koText('경기 성남시 분당구 정자동 456-7'),
        findsNothing,
        reason: '집 이름에 주소를 넣지 않는다',
      );
      expect(find.byType(GradePill), findsWidgets);
      expect(find.koText('최근 분석 리포트'), findsOneWidget);
      expect(find.koTextContaining('27일 전'), findsOneWidget);
      expect(find.koText('내 계약 일정'), findsOneWidget);
      expect(find.koText('날짜를 넣으면 이 화면이 내 일정표가 돼요'), findsOneWidget);
      expect(find.koText('일정 넣기'), findsOneWidget);
      for (final name in ['분석', '가계약금', '계약서', '잔금', '이사']) {
        expect(find.koText(name), findsWidgets, reason: name);
      }
      expect(find.koText('9단계 중 2단계'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.koText('등기부 변동 기록'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.koText('첫 분석'), findsOneWidget);
      // 체크박스 모양 · "꼭" 표시 · 판정 문장 없음
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.textContaining('안전해요'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('등기부 날짜를 못 읽었으면 지난 날수를 지어내지 않는다', (tester) async {
      await _pumpJourney(
        tester,
        reports: [
          _report(
            id: 'r-x',
            alias: '날짜 없는 집',
            address: '서울 마포구 성산동 1',
            registryAgeDays: null,
          ),
        ],
      );
      expect(find.koText('등기부 날짜를 읽지 못했어요'), findsOneWidget);
      expect(find.koTextContaining('일 전'), findsNothing);
    });

    testWidgets('같은 주소 리포트가 여러 개여도 집은 하나 — 최신 리포트 등급', (tester) async {
      await _pumpJourney(
        tester,
        reports: [
          _report(
            id: 'new',
            alias: '정자동 새 별칭',
            address: '경기 성남시 분당구  정자동 456-7',
            grade: RiskGrade.danger,
          ),
          _report(
            id: 'old',
            alias: '정자동 빌라',
            address: '경기 성남시 분당구 정자동 456-7',
            analyzedDaysAgo: 30,
          ),
        ],
      );
      expect(find.koText('정자동 새 별칭'), findsOneWidget, reason: '별칭은 최신 분석의 값');
      expect(find.koText('정자동 빌라'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('journey-switch-house')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('house-card-new')), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey &&
              '${(w.key as ValueKey).value}'.startsWith('house-card-') &&
              (w.key as ValueKey).value != 'house-card-new',
        ),
        findsOneWidget,
      );
    });

    testWidgets('집 바꾸기 시트 — 카드를 누르면 그 집으로', (tester) async {
      await _pumpJourney(tester);
      await tester.tap(find.byKey(const ValueKey('journey-switch-house')));
      await tester.pumpAndSettle();
      expect(find.koText('어느 집의 여정을 볼까요?'), findsOneWidget);
      expect(find.koText('잔금일 없음'), findsNWidgets(2));
      final card = find.byKey(
        ValueKey('house-card-${journeyPropertyKey(_yeoksam.address)}'),
      );
      await tester.ensureVisible(card); // 옆으로 넘겨서 고른다
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pump(const Duration(milliseconds: 300)); // 고른 모습 0.2초 → 닫힘
      await tester.pumpAndSettle();
      expect(find.koText('어느 집의 여정을 볼까요?'), findsNothing);
      expect(find.koText('역삼동 오피스텔'), findsOneWidget);
      expect(find.koTextContaining('8일 전'), findsOneWidget);
    });

    testWidgets('집이 없으면 먼저 분석하기 · 체크리스트만 보기', (tester) async {
      await _pumpJourney(tester, reports: const []);
      expect(find.koText('아직 분석한 집이 없어요'), findsOneWidget);
      expect(find.koText('먼저 분석하기'), findsOneWidget);
      await tester.tap(find.koText('집 없이 체크리스트만 볼게요'));
      await tester.pumpAndSettle();
      expect(find.koText('단계별 할 일'), findsOneWidget);
      expect(find.koText('집 없이 보는 중이에요'), findsOneWidget);
    });
  });

  group('내 계약 일정 · 단계', () {
    testWidgets('일정 4개 — 다음 일정 줄, 현재 단계 D-2, 회색 띠가 그 날을 가리킨다', (tester) async {
      await JourneyScheduleStore.instance.save(
        _jeongjaKey,
        const JourneySchedule()
            .copyWith(JourneyDateKey.downPayment, _day(-6))
            .copyWith(JourneyDateKey.contract, _day(2))
            .copyWith(JourneyDateKey.balance, _day(6))
            .copyWith(JourneyDateKey.moveIn, _day(8)),
      );
      await _pumpJourney(tester);

      expect(find.koText('다음은 계약서 쓰는 날 · 2일 뒤'), findsOneWidget);
      expect(find.koText('일정 수정'), findsOneWidget);
      expect(find.koText('9단계 중 3단계'), findsOneWidget);
      expect(
        find.koText('계약서 쓰는 날'),
        findsOneWidget,
        reason: '현재 단계 카드가 처음에 열린다',
      );
      expect(find.koText('D-2'), findsWidgets);
      final d = _day(2);
      expect(
        find.koTextContaining('${d.month}/${d.day} 계약서 날'),
        findsOneWidget,
      );
      // 알림이 켜졌는지 모르면 안내 줄을 숨긴다
      expect(find.koTextContaining('오전 8시'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('알림이 켜져 있으면 "일정마다 오전 8시에 알려 드려요"', (tester) async {
      await JourneyProgressStore.instance.setNotificationsOn(true);
      await JourneyScheduleStore.instance.save(
        _jeongjaKey,
        const JourneySchedule().copyWith(JourneyDateKey.balance, _day(6)),
      );
      await _pumpJourney(tester);
      expect(find.koTextContaining('오전 8시'), findsOneWidget);
    });

    testWidgets('날짜 없는 앞 단계는 순서로 추정해 완료 — 잔금이 현재면 가계약금·계약서는 체크', (
      tester,
    ) async {
      await JourneyScheduleStore.instance.save(
        _jeongjaKey,
        const JourneySchedule().copyWith(JourneyDateKey.balance, _day(6)),
      );
      await _pumpJourney(tester);
      expect(find.koText('9단계 중 4단계'), findsOneWidget);
      expect(find.koText('잔금 보내는 날'), findsOneWidget);
      // 가계약금 칸을 누르면 그 단계 — '완료' 칩, 대조 버튼 없음
      await _tapChip(tester, 1);
      expect(find.koText('가계약금 보내기 전'), findsOneWidget);
      expect(find.koText('완료'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('journey-compare-button')),
        findsNothing,
      );
    });

    testWidgets('같은 칩을 한 번 더 누르면 완료가 켜지고 꺼진다 — 분석 단계는 늘 완료', (tester) async {
      await _pumpJourney(tester);
      // 처음 = 2단계(가계약금) 선택, 대조 버튼 있음
      expect(find.koText('가계약금 보내기 전'), findsOneWidget);
      expect(find.koText('날짜 없음'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('journey-compare-button')),
        findsOneWidget,
      );

      await _tapChip(tester, 1); // 한 번 더 → 완료
      expect(JourneyProgressStore.instance.manualDone(_jeongjaKey, 1), isTrue);
      expect(find.koText('완료'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('journey-compare-button')),
        findsNothing,
      );

      await _tapChip(tester, 1); // 또 한 번 → 꺼짐
      expect(JourneyProgressStore.instance.manualDone(_jeongjaKey, 1), isFalse);
      expect(
        find.byKey(const ValueKey('journey-compare-button')),
        findsOneWidget,
      );

      await _tapChip(tester, 0); // 분석 단계로
      await _tapChip(tester, 0); // 한 번 더 눌러도 그대로 완료
      expect(JourneyProgressStore.instance.manualDone(_jeongjaKey, 0), isNull);
      expect(find.koText('완료'), findsOneWidget);
    });

    testWidgets('[자세히]를 누르면 왜·어디서가 같이 펼쳐지고, 단계를 바꾸면 접힌다', (tester) async {
      await _pumpJourney(tester);
      expect(find.koTextContaining('뗀 날짜 기준으로만'), findsNothing);
      await tester.tap(find.koText('자세히').first);
      await tester.pumpAndSettle();
      expect(find.koTextContaining('뗀 날짜 기준으로만'), findsOneWidget);
      expect(find.koTextContaining('인터넷등기소 · 열람 700원'), findsOneWidget);
      await _tapChip(tester, 2);
      await _tapChip(tester, 1);
      expect(find.koTextContaining('뗀 날짜 기준으로만'), findsNothing);
    });

    testWidgets('6~9단계는 날짜가 없으면 상태 칩을 숨기고, 꼬리표(HUG · HF · SGI)를 붙인다', (
      tester,
    ) async {
      await _pumpJourney(tester);
      await _tapChip(tester, 6);
      expect(find.koText('보증보험 가입'), findsOneWidget);
      expect(find.koText('HUG · HF · SGI'), findsOneWidget);
      expect(find.byKey(const ValueKey('stage-status-6')), findsNothing);
      await _tapChip(tester, 4);
      expect(find.koText('주민센터·정부24'), findsOneWidget);
      expect(find.koText('날짜 없음'), findsOneWidget);
    });

    // 2026-10-27 홈_종버튼_시안: 여정 화면 안에도 큰 배너를 띄우지 않는다
    testWidgets('잔금 하루 전에도 큰 배너가 없다', (tester) async {
      await JourneyScheduleStore.instance.save(
        _jeongjaKey,
        const JourneySchedule().copyWith(JourneyDateKey.balance, _day(1)),
      );
      await _pumpJourney(tester);
      expect(find.koTextContaining('잔금일이 내일이에요'), findsNothing);
      expect(find.koText('떼는 법'), findsNothing);
    });

    testWidgets('내 계약 일정의 [+] 원을 눌러도 일정 넣기 시트가 열린다', (tester) async {
      await _pumpJourney(tester);
      final plus = find.byKey(const ValueKey('journey-circle-tap-0'));
      await tester.ensureVisible(plus);
      await tester.pumpAndSettle();
      await tester.tap(plus);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('schedule-sheet-title')), findsOneWidget);
      expect(find.koText('계약 일정'), findsWidgets);
    });

    testWidgets('홈 종 시트에서 왔으면 그날 단계가 골라진 채 열린다', (tester) async {
      JourneyFocus.request(JourneyDateKey.contract);
      await _pumpJourney(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stage-status-2')), findsOneWidget, reason: '3번째 칩 = 계약서');
      expect(JourneyFocus.pending.value, isNull, reason: '쓰고 나면 비운다');
    });
  });

  group('대조 흐름', () {
    testWidgets('갤러리 → 새 등기부 촬영(입력칸 없음) → 결과 "달라진 것 없어요" → 단계 완료 + 기록 한 줄', (
      tester,
    ) async {
      final repo = await _pumpJourney(
        tester,
        compareWith: _compareResult(newDebt: false),
        gallery: ['/tmp/a.jpg', '/tmp/b.jpg'],
      );
      await tester.tap(find.byKey(const ValueKey('journey-compare-button')));
      await tester.pumpAndSettle();
      // 올리기 시트 (그림 ⑦)
      expect(find.koText('새 등기부를 올려 주세요'), findsOneWidget);
      expect(find.koTextContaining('와 비교해서 달라진 곳을 찾아 드려요'), findsOneWidget);
      expect(find.textContaining('700원'), findsNothing);
      await tester.tap(find.koText('갤러리에서 고르기'));
      await tester.pumpAndSettle();
      // 새 등기부 촬영 (그림 ⑧)
      expect(find.koText(CompareCaptureScreen.title), findsOneWidget);
      expect(find.koText('이 집 정보는 그대로 써요'), findsOneWidget);
      expect(find.koText('처음 넣은 값 그대로'), findsOneWidget);
      expect(
        find.byType(TextField),
        findsNothing,
        reason: '보증금·시세·별칭 입력 칸이 없다',
      );
      await tester.tap(find.koText('2장으로 비교하기'));
      await tester.pump();
      await tester.pumpAndSettle();
      // 결과 (그림 ⑩)
      expect(repo.compared.single, ['/tmp/a.jpg', '/tmp/b.jpg']);
      expect(find.koText('달라진 것 없어요'), findsOneWidget);
      expect(find.koText('8월 14일자 → 10월 24일자 등기부를 비교했어요'), findsOneWidget);
      expect(find.koText('✓ 같음'), findsNWidgets(2));
      expect(find.koText('새 등기부로 다시 분석하기'), findsNothing);
      expect(find.koText('나중에 볼게요'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('compare-result-ok')));
      await tester.pumpAndSettle();
      // 그 단계 자동 완료 + 기록
      expect(JourneyProgressStore.instance.manualDone(_jeongjaKey, 1), isTrue);
      final log = JourneyProgressStore.instance.logFor(_jeongjaKey).single;
      expect(log.changed, isFalse);
      expect(log.stageTitle, '가계약금 보내기 전');
      expect(log.reportId, 'r-new');
    });

    testWidgets('새 빚이 생기면 "달라진 게 1건 있어요" + 새로 생김 상자(한 건 한 줄) + [최근 분석 리포트 보기]는 새 리포트로', (
      tester,
    ) async {
      await _pumpJourney(
        tester,
        compareWith: _compareResult(newDebt: true),
        gallery: ['/tmp/a.jpg'],
      );
      await tester.tap(find.byKey(const ValueKey('journey-compare-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('갤러리에서 고르기'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('1장으로 비교하기'));
      await tester.pumpAndSettle();
      expect(find.koText('달라진 게 1건 있어요'), findsOneWidget);
      expect(find.koText('새로 1'), findsOneWidget);
      expect(_inSheet(find.koText('새로 생겼어요 1건')), findsOneWidget);
      expect(_inSheet(find.koText('근저당권')), findsOneWidget);
      expect(_inSheet(find.koText('2026.10.20 접수')), findsOneWidget);
      expect(_inSheet(find.koText('채권최고액 1억 2,000만원')), findsOneWidget);
      // 설명 문장·"— 변동"·"바뀜 N건"은 없다 (2026-10-27 시안)
      expect(find.koText('새 빚은 내 보증금보다 먼저 갚게 될 수 있어요'), findsNothing);
      expect(find.koTextContaining('— 변동'), findsNothing);
      expect(find.koTextContaining('바뀜'), findsNothing);
      final log = JourneyProgressStore.instance.logFor(_jeongjaKey).single;
      expect(log.changedCount, 1);
      expect(log.items.single.label, '근저당권');
      await tester.tap(
        find.byKey(const ValueKey('compare-result-open-report')),
      );
      await tester.pumpAndSettle();
      expect(find.text('리포트 r-new'), findsOneWidget);
    });

    testWidgets('새로 생김·없어짐을 나눠 센다 — 가압류 2건은 두 줄, 0원은 "금액 확인 필요", 없어진 건 빨강이 아니다', (
      tester,
    ) async {
      await _pumpJourney(
        tester,
        compareWith: _mixedResult(),
        gallery: ['/tmp/a.jpg'],
      );
      await tester.tap(find.byKey(const ValueKey('journey-compare-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('갤러리에서 고르기'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('1장으로 비교하기'));
      await tester.pumpAndSettle();
      expect(find.koText('달라진 게 6건 있어요'), findsOneWidget);
      expect(_inSheet(find.koText('새로 생겼어요 2건')), findsOneWidget);
      expect(_inSheet(find.koText('없어졌어요 4건')), findsOneWidget);
      expect(_inSheet(find.koText('가압류')), findsNWidgets(2));
      expect(_inSheet(find.koText('금액 확인 필요')), findsOneWidget);
      expect(find.koTextContaining('0원'), findsNothing);
      // 없어짐 상자는 초록 바탕
      final removedBox = tester.widget<Container>(
        find.descendant(
          of: _inSheet(find.byKey(const ValueKey('change-box-removed'))),
          matching: find.byType(Container),
        ).first,
      );
      expect((removedBox.decoration as BoxDecoration).color, AppColors.okSoft);
      expect(JourneyProgressStore.instance.logFor(_jeongjaKey).single.changedCount, 6);
    });

    testWidgets('글자 130%에서도 상자 안 이름과 접수일이 겹치지 않는다', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pumpJourney(
        tester,
        compareWith: _mixedResult(),
        gallery: ['/tmp/a.jpg'],
      );
      await tester.tap(find.byKey(const ValueKey('journey-compare-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('갤러리에서 고르기'));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('1장으로 비교하기'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final name = tester.getRect(_inSheet(find.koText('경매개시결정')).first);
      final date = tester.getRect(_inSheet(find.koText('2022.7.27 접수')));
      expect(name.overlaps(date), isFalse);
    });

    testWidgets('기준 없는 리포트는 사진을 받기 전에 대조 화면(기준 없음)으로', (tester) async {
      await _pumpJourney(
        tester,
        reports: [
          _report(
            id: 'r-old',
            alias: '옛 분석',
            address: '서울 마포구 성산동 1',
            comparable: false,
          ),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('journey-compare-button')));
      await tester.pumpAndSettle();
      expect(find.koText('새 등기부를 올려 주세요'), findsNothing);
      expect(find.text('대조 화면 r-old'), findsOneWidget);
    });

    testWidgets('[나중에 할게요]는 시트만 닫는다', (tester) async {
      final repo = await _pumpJourney(
        tester,
        compareWith: _compareResult(newDebt: false),
      );
      await tester.tap(find.byKey(const ValueKey('journey-compare-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.koText('나중에 할게요'));
      await tester.pumpAndSettle();
      expect(find.koText('새 등기부를 올려 주세요'), findsNothing);
      expect(repo.compared, isEmpty);
    });
  });

  group('등기부 변동 기록', () {
    testWidgets('변동 있는 최신 줄은 펼쳐져 있고, "이 리포트 보기 ›"는 상자 밖에', (tester) async {
      await JourneyProgressStore.instance.addCompare(
        _jeongjaKey,
        CompareLogEntry(
          at: _day(-1),
          changedCount: 2,
          stageIndex: 2,
          stageTitle: '계약서 쓰는 날',
          reportId: 'r-jeongja',
          items: [
            CompareLogItem(
              kind: CompareLogItemKind.added,
              label: '근저당권',
              receiptDate: DateTime(2021, 4, 22),
              note: '금액 확인 필요',
            ),
            CompareLogItem(
              kind: CompareLogItemKind.removed,
              label: '압류',
              receiptDate: DateTime(2024, 3, 4),
            ),
          ],
        ),
      );
      await _pumpJourney(tester);
      // 리포트 카드 꼬리말이 '변동 2건'으로
      expect(find.koTextContaining('변동 2건'), findsWidgets);
      await tester.scrollUntilVisible(
        find.koText('계약서 쓰는 날 대조'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.koText('새로 생겼어요 1건'), findsOneWidget);
      expect(find.koText('없어졌어요 1건'), findsOneWidget);
      expect(find.koText('2021.4.22 접수'), findsOneWidget);
      expect(find.koTextContaining('— 변동'), findsNothing);
      expect(
        find.byKey(const ValueKey('journey-log-open-report')),
        findsOneWidget,
      );
      expect(find.koText('2건'), findsOneWidget);
    });

    testWidgets('없어진 것만 있는 대조는 초록 ✓ · "없어짐 N건"(초록) · 펼칠 수 있다', (tester) async {
      await JourneyProgressStore.instance.addCompare(
        _jeongjaKey,
        CompareLogEntry(
          at: _day(-1),
          changedCount: 1,
          stageTitle: '잔금 보내는 날',
          reportId: 'r-jeongja',
          items: [
            CompareLogItem(
              kind: CompareLogItemKind.removed,
              label: '가압류',
              receiptDate: DateTime(2024, 1, 11),
            ),
          ],
        ),
      );
      await _pumpJourney(tester);
      await tester.scrollUntilVisible(
        find.koText('잔금 보내는 날 대조'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.koText('없어짐 1건'), findsOneWidget);
      expect(find.koText('변동 1건'), findsNothing);
      expect(find.koText('없어졌어요 1건'), findsOneWidget);
      expect(find.byKey(const ValueKey('change-box-added')), findsNothing);
    });

    test('보충본이 대신한 리포트의 기록은 새 리포트의 견준 결과로 다시 그린다 — 한 줄로', () async {
      final store = JourneyProgressStore.instance;
      await store.addCompare(
        _jeongjaKey,
        CompareLogEntry(
          at: _day(-1),
          changedCount: 3,
          stageTitle: '잔금 보내는 날',
          reportId: 'r-part',
          items: const [
            CompareLogItem(kind: CompareLogItemKind.added, label: '경매개시결정'),
          ],
        ),
      );
      await store.replaceReportId('r-part', 'r-full');
      final base = _report(id: 'r-base', alias: '정자동 빌라', address: _jeongja.address, analyzedDaysAgo: 2);
      final full = AnalysisReport(
        id: 'r-full',
        alias: base.alias,
        address: base.address,
        analyzedAt: DateTime.now(),
        grade: base.grade,
        headline: base.headline,
        nextAction: base.nextAction,
        topRiskSummary: base.topRiskSummary,
        deposit: base.deposit,
        marketPrice: null,
        seniorDebtAmount: 0,
        gaugeProgress: 0.5,
        evidences: const [],
        changeFromPrevious: _compareResult(newDebt: false),
      );
      final log = journeyChangeLog(
        PropertyReports(key: _jeongjaKey, reports: [full, base]),
        store.logFor(_jeongjaKey),
      );
      expect(log, hasLength(1), reason: '보충본이 따로 "다시 분석" 줄을 만들지 않는다');
      expect(log.single.reportId, 'r-full');
      expect(log.single.stageTitle, '잔금 보내는 날');
      expect(log.single.changedCount, 0, reason: '덜 찍은 서류의 틀린 3건이 아니라 보충본의 결과');
    });
  });

  test('가족·친구에게 보내기 · 알림 꺼짐 안내 문구가 여정 코드 어디에도 없다', () {
    // 화면에 그리는 글자를 소스에서 직접 찾는다 (주석 제외)
    for (final f in [
      'lib/screens/journey/journey_screen.dart',
      'lib/screens/journey/journey_parts.dart',
      'lib/screens/journey/journey_compare_flow.dart',
      'lib/screens/journey/journey_reminder_prompt.dart',
      'lib/screens/compare/compare_next_step.dart',
    ]) {
      final code = [
        for (final line in File(f).readAsLinesSync())
          if (!line.trimLeft().startsWith('//')) line,
      ].join('\n');
      expect(code.contains('가족·배우자에게 보내기'), isFalse, reason: f);
      expect(code.contains('알림이 꺼져 있어요'), isFalse, reason: f);
    }
  });
}
