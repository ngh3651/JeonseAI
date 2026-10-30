/// 챗봇에 함께 보내는 **내 계약 일정** (2026-10-30) — 홈·여정과 같은 집 묶기·단계 계산을 쓰는지 못 박는다.
///
///   ① 같은 집(고유번호)은 리포트가 여러 개여도 한 줄이고, 그 집의 **최신** 리포트 id로 보낸다.
///   ② 날짜는 넣은 칸만 'YYYY-MM-DD'로, 끝난 단계는 여정 계산(JourneyProgress.doneThrough) 그대로.
///   ③ 계약 여정에서 고른 집에 표시가 붙는다.
///   ④ 기록을 못 불러오면 null(일정 없이 묻는다) — 질문을 막지 않는다.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/chatbot/chat_journeys.dart';
import 'package:jeonse_ai/state/journey_progress_store.dart';
import 'package:jeonse_ai/state/journey_schedule_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Repo extends AnalysisRepository {
  _Repo(this.reports, {this.fail = false});

  final List<AnalysisReport> reports;
  final bool fail;

  @override
  Future<AnalysisReport> analyze(AnalysisRequest request) async => reports.first;

  @override
  Future<List<AnalysisReport>> getHistory() async {
    if (fail) throw Exception('연결 실패');
    return reports;
  }

  @override
  Future<AnalysisReport?> getReport(String id) async => null;

  @override
  Future<void> deleteReport(String id) async {}

  @override
  Future<CompareResult> compareRegistry(String id, List<String> paths) async =>
      const CompareResult(
        outcome: CompareOutcome.noBaseline,
        headline: '기준 없음',
        baseline: CompareDoc(),
        current: CompareDoc(),
      );
}

AnalysisReport _report(String id, {required String pid, required int daysAgo}) {
  final now = DateTime.now();
  return AnalysisReport(
    id: id,
    alias: '집 $pid',
    address: '서울 마포구 망원동 $pid',
    analyzedAt: now.subtract(Duration(days: daysAgo)),
    grade: RiskGrade.caution,
    headline: '확인이 필요해요',
    nextAction: '확인 후 결정하세요',
    topRiskSummary: '예시',
    deposit: 100000000,
    marketPrice: null,
    seniorDebtAmount: 0,
    gaugeProgress: 0.5,
    evidences: const [],
    propertyId: pid,
  );
}

DateTime _day(int offset) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day + offset);
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  late JourneyScheduleStore schedules;
  late JourneyProgressStore progress;
  final content = DummyContentRepository(); // 여정 9단계(서버와 같은 순서)

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    resetChatJourneyCache();
    schedules = JourneyScheduleStore.instance..resetForTest();
    progress = JourneyProgressStore.instance..resetForTest();
    await schedules.restore();
    await progress.restore();
  });

  test('① 같은 집은 한 줄 · 최신 리포트 id ② 날짜·끝난 단계 ③ 고른 집', () async {
    final newer = _report('r-new', pid: '111', daysAgo: 1);
    final older = _report('r-old', pid: '111', daysAgo: 20);
    final other = _report('r-other', pid: '222', daysAgo: 5);
    const key = '고유번호:111';
    await schedules.save(
      key,
      const JourneySchedule()
          .copyWith(JourneyDateKey.downPayment, _day(-17))
          .copyWith(JourneyDateKey.contract, _day(0))
          .copyWith(JourneyDateKey.balance, _day(1)),
    );
    await progress.setCheckedThrough(key, 2);
    await schedules.select(key);

    final stages = await content.journeyStages();
    final out = await collectChatJourneys(
      analysis: _Repo([newer, other, older]),
      content: content,
      schedules: schedules,
      progress: progress,
    );

    expect(out, isNotNull);
    expect(out!.map((j) => j.reportId), ['r-new', 'r-other']);
    final mine = out.first;
    expect(mine.dates, {
      'downPayment': _ymd(_day(-17)),
      'contract': _ymd(_day(0)),
      'balance': _ymd(_day(1)),
    });
    // 가계약금 날짜가 지났고 계약서 단계까지 체크 → 여정 화면과 같은 계산
    final contractIndex = stages.indexWhere((s) => s.dateKey == JourneyDateKey.contract);
    expect(mine.doneThrough, contractIndex);
    expect(mine.selected, isTrue);
    expect(out.last.dates, isEmpty);
    expect(out.last.selected, isFalse);
    expect(mine.toJson()['reportId'], 'r-new');
  });

  test('④ 기록을 못 불러오면 null — 일정 없이 묻는다', () async {
    final out = await collectChatJourneys(
      analysis: _Repo(const [], fail: true),
      content: content,
      schedules: schedules,
      progress: progress,
    );
    expect(out, isNull);
  });

  test('집이 없으면 빈 목록 — 서버는 "넣은 일정 없음"으로 본다', () async {
    final out = await collectChatJourneys(
      analysis: _Repo(const []),
      content: content,
      schedules: schedules,
      progress: progress,
    );
    expect(out, isEmpty);
  });
}
