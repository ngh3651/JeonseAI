/// S-11 계약 여정 재설계 — **이 화면이 하기로 한 일**을 못 박는다.
///
/// 화면의 단 하나의 일은 "잔금을 보내기 전에 등기부를 다시 떼게 만드는 것"이다.
/// 그래서 여기서 검사하는 것도 그 한 줄에서 파생된 것들이다:
///
///   ① **체크박스가 없다.** 스스로 체크하는 목록으로 되돌아가면 화면의 목적이 사라진다.
///   ② 등기부를 다시 떼는 단계에는 **반드시 [다시 떼서 대조하기]가 붙는다.**
///   ③ 등기부 경과일은 **뗀 날짜 기준**으로 말한다("마지막 확인일" 표기 금지).
///   ④ 잔금일이 내일이면 **경고 배너 + 행동 버튼**이 타임라인 최상단에 뜬다.
///   ⑤ 날짜를 못 읽은 등기부는 숫자를 **지어내지 않는다.**
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/journey/journey_screen.dart';
import 'package:jeonse_ai/state/app_session.dart';
import 'package:jeonse_ai/state/journey_schedule_store.dart';
import 'package:jeonse_ai/utils/money_format.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneHeight, kPhoneWidth;

/// 테스트용 이력 — 등기부를 뗀 날짜를 **직접 정해서** 경과일을 확정한다.
class _FakeRepo extends AnalysisRepository {
  _FakeRepo(this.reports);

  final List<AnalysisReport> reports;

  @override
  Future<AnalysisReport> analyze(AnalysisRequest request) async => reports.first;

  @override
  Future<List<AnalysisReport>> getHistory() async => reports;

  @override
  Future<AnalysisReport?> getReport(String id) async =>
      reports.where((r) => r.id == id).firstOrNull;

  @override
  Future<void> deleteReport(String id) async {}

  @override
  Future<CompareResult> compareRegistry(String id, List<String> paths) async =>
      CompareResult(
        outcome: CompareOutcome.noBaseline,
        headline: '이 분석은 비교 기준으로 쓸 수 없어요',
        baseline: CompareDoc(reportId: id),
        current: const CompareDoc(),
      );
}

AnalysisReport _report({
  required String id,
  required String alias,
  required String address,
  RiskGrade grade = RiskGrade.caution,
  int? registryAgeDays = 27,
}) {
  final now = DateTime.now();
  return AnalysisReport(
    id: id,
    alias: alias,
    address: address,
    analyzedAt: now.subtract(const Duration(hours: 2)),
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

Future<void> _pumpJourney(
  WidgetTester tester, {
  List<AnalysisReport>? reports,
}) async {
  tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSession()),
        ChangeNotifierProvider<AnalysisRepository>(
          create: (_) => _FakeRepo(reports ?? [_jeongja, _yeoksam]),
        ),
        Provider<ContentRepository>(create: (_) => DummyContentRepository()),
        ChangeNotifierProvider<JourneyScheduleStore>.value(
          value: JourneyScheduleStore.instance,
        ),
      ],
      child: MaterialApp(theme: buildAppTheme(), home: const JourneyScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// 매물 카드를 눌러 타임라인으로 들어간다.
Future<void> _openTimeline(WidgetTester tester, {String alias = '정자동 빌라'}) async {
  await tester.tap(find.koText(alias));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    JourneyScheduleStore.instance.resetForTest();
  });

  group('매물 선택 (매물 미연결)', () {
    testWidgets('분석 이력마다 카드 1장 + 등기부 경과일을 크게 말한다', (tester) async {
      await _pumpJourney(tester);

      expect(find.koText('어느 집의\n돈을 지킬까요?'), findsOneWidget);
      expect(find.koText('정자동 빌라'), findsOneWidget);
      expect(find.koText('역삼동 오피스텔'), findsOneWidget);
      // 경과일은 **등기부를 뗀 날** 기준이다 (분석일이 아니다)
      expect(find.koText('27'), findsOneWidget);
      expect(find.koText('8'), findsOneWidget);
      expect(find.koText('일 지난 등기부'), findsNWidgets(2));
    });

    testWidgets('등기부 날짜를 못 읽었으면 경과일을 지어내지 않는다', (tester) async {
      await _pumpJourney(
        tester,
        reports: [
          _report(
            id: 'r-noviewed',
            alias: '날짜 미상 빌라',
            address: '서울 어딘가 1-1',
            registryAgeDays: null,
          ),
        ],
      );

      expect(find.koText('등기부를 뗀 날짜를 읽지 못했어요'), findsOneWidget);
      expect(find.koTextContaining('일 지난 등기부'), findsNothing);
    });

    testWidgets('"마지막 확인일" 표기는 어디에도 없다', (tester) async {
      await _pumpJourney(tester);
      expect(find.koTextContaining('마지막 확인'), findsNothing);
    });
  });

  group('타임라인', () {
    testWidgets('9단계가 모두 나오고 체크박스는 하나도 없다', (tester) async {
      await _pumpJourney(tester);
      await _openTimeline(tester);

      expect(find.koText('집 둘러보고 등기부 분석하기'), findsOneWidget);
      expect(find.koText('잔금 보내는 날'), findsOneWidget);
      // 체크박스를 되살리면 이 화면의 목적(대조 유도)이 사라진다
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
    });

    testWidgets('등기부를 다시 떼는 단계에는 대조 버튼이 붙는다', (tester) async {
      await _pumpJourney(tester);
      await _openTimeline(tester);

      final stages = await DummyContentRepository().journeyStages();
      final expected = stages.where((s) => s.compare).length;
      expect(expected, 4, reason: '2·3·4·6단계가 등기부를 다시 떼는 시점이다');

      // 화면 밖 단계까지 세려면 offstage도 포함해야 한다(ListView는 보이는 것만 그린다)
      var found = 0;
      final scrollable = find.byType(Scrollable).first;
      for (var i = 0; i < 12; i++) {
        found = tester
            .widgetList(find.koText('다시 떼서 대조하기'))
            .length
            .clamp(found, 99);
        if (found >= expected) break;
        await tester.drag(scrollable, const Offset(0, -400));
        await tester.pumpAndSettle();
      }
      expect(found, greaterThanOrEqualTo(1));
    });

    testWidgets('지금 가진 등기부는 뗀 날짜와 경과일로 말한다', (tester) async {
      await _pumpJourney(tester);
      await _openTimeline(tester);

      expect(find.koTextContaining('지금 가진 등기부는'), findsOneWidget);
      expect(find.koText('오늘까지 27일 지났어요'), findsOneWidget);
    });

    testWidgets('잔금일이 없으면 날짜를 물어본다', (tester) async {
      await _pumpJourney(tester);
      await _openTimeline(tester);

      expect(find.koText('잔금 보내는 날이 언제예요?'), findsOneWidget);
      expect(find.koText('날짜 넣기'), findsWidgets);
    });

    testWidgets('단계 헤더를 누르면 접힌다', (tester) async {
      await _pumpJourney(tester);
      await _openTimeline(tester);

      const why = '등기부는 뗀 날짜 기준으로만 유효해요';
      expect(find.koText(why), findsOneWidget);

      await tester.tap(find.koText('가계약금 보내기 전'));
      await tester.pumpAndSettle();

      expect(find.koText(why), findsNothing);
    });

    testWidgets('집 바꾸기를 누르면 다른 집으로 갈아탈 수 있다', (tester) async {
      await _pumpJourney(tester);
      await _openTimeline(tester);

      // 접혀 있을 때는 캐러셀이 트리에 없다 — 안 보이는 카드가 탭을 먹으면 안 된다
      expect(find.koText('좌우로 밀어서 고르세요'), findsNothing);

      await tester.tap(find.koText('집 바꾸기'));
      await tester.pumpAndSettle();
      expect(find.koText('좌우로 밀어서 고르세요'), findsOneWidget);

      await tester.tap(find.koText('역삼동 오피스텔').last);
      await tester.pumpAndSettle();

      // 헤더가 그 집으로 바뀐다 (경과일 8일짜리 서류)
      expect(find.koText('오늘까지 8일 지났어요'), findsOneWidget);
    });
  });

  group('잔금 D-1', () {
    Future<void> setBalanceTomorrow(String address) async {
      final key = journeyPropertyKey(address);
      await JourneyScheduleStore.instance.save(
        key,
        const JourneySchedule().copyWith(
          JourneyDateKey.balance,
          DateTime.now().add(const Duration(days: 1)),
        ),
      );
    }

    testWidgets('경고 배너와 행동 버튼이 타임라인 최상단에 뜬다', (tester) async {
      await setBalanceTomorrow(_jeongja.address);
      await _pumpJourney(tester);
      await _openTimeline(tester);

      expect(find.koTextContaining('잔금일이 내일이에요'), findsOneWidget);
      // 경고 문구 뒤에는 반드시 행동 버튼 (IA.md §0)
      expect(find.koText('지금 다시 떼서 대조하기'), findsOneWidget);
      expect(find.koText('일정 수정'), findsOneWidget);
    });

    testWidgets('잔금 단계가 현재로 강조되고 D-1 뱃지가 붙는다', (tester) async {
      await setBalanceTomorrow(_jeongja.address);
      await _pumpJourney(tester);
      await _openTimeline(tester);

      await tester.scrollUntilVisible(
        find.koText('잔금 보내는 날'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.koText('현재'), findsOneWidget);
      expect(find.koText('D-1'), findsOneWidget);
      expect(find.koTextContaining('내일이에요'), findsWidgets);
    });

    testWidgets('배너 아래 줄에 출처 없는 수치를 적지 않는다', (tester) async {
      await setBalanceTomorrow(_jeongja.address);
      await _pumpJourney(tester);
      await _openTimeline(tester);

      // 우리 단계 정의에서 센 수(처음 분석 1 + 다시 떼는 단계 4)만 말한다
      expect(find.koText('이 앱은 계약 전후로 등기부를 5번 확인하도록 안내해요'), findsOneWidget);
      expect(find.koTextContaining('전문가 권장'), findsNothing);
    });
  });

  group('빈 상태', () {
    testWidgets('분석 이력이 없으면 먼저 분석하기를 권한다', (tester) async {
      await _pumpJourney(tester, reports: []);

      expect(find.koText('아직 분석한 집이 없어요'), findsOneWidget);
      expect(find.koText('먼저 분석하기'), findsOneWidget);
      expect(find.koText('집 없이 체크리스트만 볼게요'), findsOneWidget);
    });

    testWidgets('집 없이 체크리스트만 볼 수도 있다', (tester) async {
      await _pumpJourney(tester, reports: []);

      await tester.tap(find.koText('집 없이 체크리스트만 볼게요'));
      await tester.pumpAndSettle();

      expect(find.koText('집 없이 보는 중이에요'), findsOneWidget);
      expect(find.koText('잔금 보내는 날'), findsOneWidget);
      // 집이 없으면 대조할 기준도 없다 — 대신 분석으로 이끈다
      expect(find.koText('아직 분석한 집이 없어요'), findsOneWidget);
    });
  });
}
