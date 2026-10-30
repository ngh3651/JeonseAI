/// 챗봇이 아는 **내 계약 일정** (2026-10-30 — 규혁: "잔금이 내일인 걸 챗봇이 알아야 '다음에 뭐 해?'에 답한다").
///
/// 질문을 보낼 때 이 폰의 일정·여정 진행을 집마다 하나씩 만들어 함께 보낸다([ChatJourney]).
/// - 날짜는 여전히 **이 휴대폰에만 저장**한다 — 서버는 그 답을 쓰는 동안만 쓰고 남기지 않는다(대화와 같다).
/// - 집 묶기([groupByProperty])·단계 계산([JourneyProgress])은 홈·여정과 **같은 코드**다 — 챗봇이 다른 단계를 말하지 않게.
/// - 무엇이든 실패하면 null — 챗봇은 일정 없이 답한다(질문은 막히지 않는다).
/// - 저장소는 읽기만 한다(예전 열쇠로 남은 일정을 옮기는 일은 홈이 한다 — `adoptLegacyPropertyKeys`).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/content_models.dart';
import '../../models/property_reports.dart';
import '../../repositories/analysis_repository.dart';
import '../../repositories/content_repository.dart';
import '../../state/journey_progress_store.dart';
import '../../state/journey_schedule_store.dart';
import '../journey/journey_logic.dart';

/// 일정 모으기를 기다리는 최대 시간 — 넘으면 일정 없이 묻는다(답이 늦어지지 않게)
const Duration kChatJourneyTimeout = Duration(seconds: 4);

/// 한 번에 보내는 집 수 상한 — 최근에 분석한 집부터 (서버 상한 50보다 작게)
const int kChatJourneyMaxHouses = 30;

/// 단계 목록(서버의 고정 데이터)은 같은 저장소면 한 번만 받는다
ContentRepository? _stagesRepo;
Future<List<JourneyStage>>? _stagesFuture;

Future<List<JourneyStage>> _stagesOf(ContentRepository content) {
  final cached = _stagesFuture;
  if (cached != null && identical(_stagesRepo, content)) return cached;
  _stagesRepo = content;
  return _stagesFuture = content.journeyStages();
}

@visibleForTesting
void resetChatJourneyCache() {
  _stagesRepo = null;
  _stagesFuture = null;
}

/// 집마다 [ChatJourney] 하나 — 내 집이 없으면 빈 목록, 못 모으면 null.
Future<List<ChatJourney>?> collectChatJourneys({
  required AnalysisRepository analysis,
  required ContentRepository content,
  JourneyScheduleStore? schedules,
  JourneyProgressStore? progress,
  Duration timeout = kChatJourneyTimeout,
}) async {
  final sched = schedules ?? JourneyScheduleStore.instance;
  final prog = progress ?? JourneyProgressStore.instance;
  try {
    // 둘을 함께 출발시키고 기다린다
    final historyFuture = analysis.getHistory();
    final stagesFuture = _stagesOf(content);
    final history = await historyFuture.timeout(timeout);
    final List<JourneyStage> stages;
    try {
      stages = await stagesFuture.timeout(timeout);
    } catch (_) {
      _stagesFuture = null; // 다음 질문 때 다시 받는다
      rethrow;
    }
    final selectedKey = sched.selectedPropertyKey;
    return [
      for (final p in groupByProperty(history).take(kChatJourneyMaxHouses))
        _journeyOf(p, stages, sched, prog, selectedKey),
    ];
  } catch (e) {
    debugPrint('[챗봇] 일정을 모으지 못해 일정 없이 물어요 (${e.runtimeType})');
    return null;
  }
}

ChatJourney _journeyOf(
  PropertyReports p,
  List<JourneyStage> stages,
  JourneyScheduleStore sched,
  JourneyProgressStore prog,
  String? selectedKey,
) {
  // 예전 열쇠(주소 띄어쓰기만 뺀 것)로 남은 일정도 읽는다 — 홈이 옮겨 주기 전일 수 있다
  var key = p.key;
  if (sched.scheduleFor(key).isEmpty && prog.checkedThrough(key) == 0) {
    for (final legacy in p.legacyKeys) {
      if (!sched.scheduleFor(legacy).isEmpty || prog.checkedThrough(legacy) > 0) {
        key = legacy;
        break;
      }
    }
  }
  final schedule = sched.scheduleFor(key);
  final journey = JourneyProgress(
    stages: stages,
    schedule: schedule,
    hasProperty: true,
    checkedThrough: prog.checkedThrough(key),
  );
  return ChatJourney(
    reportId: p.latest.id,
    dates: schedule.toJson(),
    doneThrough: stages.isEmpty ? 0 : journey.doneThrough,
    selected:
        selectedKey != null &&
        (selectedKey == p.key || p.legacyKeys.contains(selectedKey)),
  );
}
