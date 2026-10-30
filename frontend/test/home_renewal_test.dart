/// 홈 리뉴얼 (2026-10-30) — 집 카드 하나 · 분석 시작 시트 · 꿀팁 손으로 넘기기 · 홈 → 챗봇.
///
/// ① 집 카드 연초록 줄: 날짜가 없으면 "2단계 · 가계약금 보내기 전", 앞으로의 날짜가 있으면 "잔금 D-6 · 11/5 (목)"
/// ② 새 집 분석의 문(＋ · 새로 분석 · 빈 화면) = 같은 '매물 분석 시작하기' 시트 [촬영하기][갤러리] + 인터넷등기소
/// ③ 꿀팁: 6초마다 저절로 · 손으로 밀면 그 팁에서 다시 6초
/// ④ 홈 질문 칩 → 챗봇이 바로 보낸다 / 입력칸 → 챗봇 입력칸에 커서
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/models/property_reports.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/common/analyze_gate.dart';
import 'package:jeonse_ai/screens/common/house_card.dart';
import 'package:jeonse_ai/screens/loading/loading_parts.dart';
import 'package:jeonse_ai/screens/loading/loading_tips.dart';
import 'package:jeonse_ai/state/chat_handoff.dart';
import 'package:jeonse_ai/state/journey_progress_store.dart';
import 'package:jeonse_ai/state/journey_schedule_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ko_finders.dart';

AnalysisReport _r(String id, {int viewedAgo = 10}) {
  final now = DateTime.now();
  final v = now.subtract(Duration(days: viewedAgo));
  return AnalysisReport(
    id: id,
    alias: '서초동 집',
    address: '서울 서초구 서초동 1557-8',
    analyzedAt: now,
    registryViewedAt:
        '${v.year}.${v.month.toString().padLeft(2, '0')}.${v.day.toString().padLeft(2, '0')}',
    grade: RiskGrade.danger,
    headline: 'x',
    nextAction: 'x',
    topRiskSummary: 'x',
    deposit: 100000000,
    marketPrice: null,
    seniorDebtAmount: 0,
    gaugeProgress: 0.5,
    evidences: const [],
  );
}

int _activeDot(WidgetTester tester) {
  for (var i = 0; i < kLoadingTips.length; i++) {
    final c = tester.widget<AnimatedContainer>(
      find.byKey(ValueKey('tip-dot-$i')),
    );
    if ((c.constraints?.maxWidth ?? 0) > 10) return i;
  }
  return -1;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    JourneyScheduleStore.instance.resetForTest();
    JourneyProgressStore.instance.resetForTest();
  });

  group('① 집 카드 연초록 줄', () {
    test('날짜가 없으면 다음 단계 이름', () async {
      final stages = await DummyContentRepository().journeyStages();
      final p = groupByProperty([_r('a')]).single;
      final (_, label) = houseJourneyLabel(p, stages);
      expect(label, '2단계 · 가계약금 보내기 전');
    });

    test('앞으로의 잔금일이 있으면 그 날짜 (다음 단계에 날짜가 없어도)', () async {
      final stages = await DummyContentRepository().journeyStages();
      final p = groupByProperty([_r('a')]).single;
      final now = DateTime.now();
      final balance = DateTime(now.year, now.month, now.day + 6);
      await JourneyScheduleStore.instance.save(
        p.key,
        JourneySchedule(dates: {JourneyDateKey.balance: balance}),
      );
      final (icon, label) = houseJourneyLabel(p, stages);
      expect(label, startsWith('잔금 D-6 · ${balance.month}/${balance.day} ('));
      expect(icon, Icons.calendar_today_outlined);
    });

    test('잔금일 줄 — 여정 시트 아랫줄', () {
      expect(houseBalanceLine(null), '잔금일 없음');
    });

    testWidgets('같은 날 뗀 등기부는 "0일 전"', (tester) async {
      final p = groupByProperty([_r('a', viewedAgo: 0)]).single;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: HouseCard(property: p, subline: houseAnalyzedLine(p)),
          ),
        ),
      );
      expect(find.koText('0일 전'), findsOneWidget);
      expect(find.koTextContaining('자 등기부'), findsOneWidget);
    });
  });

  testWidgets('② 분석 시작 시트 — [촬영하기][갤러리] + 인터넷등기소, 고른 쪽을 돌려준다', (
    tester,
  ) async {
    AnalyzeStart? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () async => picked = await showAnalyzeStartSheet(c),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(find.koText('매물 분석 시작하기'), findsOneWidget);
    expect(find.byKey(const ValueKey('registry-office-link')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('analyze-gallery')));
    await tester.pumpAndSettle();
    expect(picked, AnalyzeStart.gallery);
    expect(AnalyzeStart.fromQuery('camera'), AnalyzeStart.camera);
    expect(AnalyzeStart.fromQuery(null), isNull);
  });

  testWidgets('③ 꿀팁 — 6초마다 저절로, 손으로 되돌리면 그 팁을 다시 6초', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(20),
            child: LoadingTipCard(scale: 1),
          ),
        ),
      ),
    );
    expect(_activeDot(tester), 0);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(_activeDot(tester), 1);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(_activeDot(tester), 2);

    // 2번을 다시 읽고 싶어 오른쪽으로 민다
    await tester.fling(
      find.byKey(const ValueKey('loading-tip-pages')),
      const Offset(300, 0),
      800,
    );
    await tester.pumpAndSettle();
    expect(_activeDot(tester), 1);
    // 5초 뒤엔 아직 2번
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(_activeDot(tester), 1);
    // 6초가 차면 다시 3번
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(_activeDot(tester), 2);
  });

  test('④ 홈 → 챗봇 건네기', () {
    ChatHandoff.ask('  확정일자는 언제 받아요? ');
    expect(ChatHandoff.question.value, '확정일자는 언제 받아요?');
    ChatHandoff.question.value = null;
    ChatHandoff.focus();
    expect(ChatHandoff.focusInput.value, isTrue);
    ChatHandoff.focusInput.value = false;
  });
}
