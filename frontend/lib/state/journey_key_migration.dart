/// 집 열쇠 옮기기 (2026-10-27) — 예전 열쇠로 저장된 계약 일정·진행 기록·알림을 새 열쇠로 옮긴다.
///
/// 예전엔 '주소에서 띄어쓰기만 뺀 것'이 집 열쇠였다. 주소는 읽을 때마다 글자가 조금씩 달라져
/// 같은 집이 둘로 갈렸다 → 이제 고유번호(없으면 도로명 병기를 뗀 주소)가 열쇠다([propertyKeyFor]).
/// 이미 넣어 둔 잔금일 등이 사라지지 않게, 집 묶음을 볼 때마다 조용히 옮긴다(옮길 게 없으면 아무 일도 안 한다).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/property_reports.dart';
import '../services/journey_reminder_service.dart';
import 'journey_progress_store.dart';
import 'journey_schedule_store.dart';

bool _moving = false;

/// [properties]의 예전 열쇠에 남은 것을 새 열쇠로 옮긴다. 화면을 그리는 중에 불러도 된다(다음 틈에 한다).
void adoptLegacyPropertyKeys(
  List<PropertyReports> properties, {
  JourneyScheduleStore? schedules,
  JourneyProgressStore? progress,
  JourneyReminderService? reminders,
}) {
  final store = schedules ?? JourneyScheduleStore.instance;
  final moves = <(String, PropertyReports)>[];
  final saved = store.scheduledKeys.toSet();
  for (final p in properties) {
    for (final old in p.legacyKeys) {
      if (saved.contains(old) || store.selectedPropertyKey == old) {
        moves.add((old, p));
      }
    }
  }
  final progressStore = progress ?? JourneyProgressStore.instance;
  final progressMoves = <(String, String)>[
    for (final p in properties)
      for (final old in p.legacyKeys)
        if (progressStore.hasRecord(old)) (old, p.key),
  ];
  if (moves.isEmpty && progressMoves.isEmpty) return;
  // 화면이 여러 번 그려져도 한 번만 — 옮기는 중이면 다음 그리기에서 다시 본다
  if (_moving) return;
  _moving = true;
  scheduleMicrotask(() async {
    try {
      final svc = reminders ?? JourneyReminderService.instance;
      for (final (old, p) in moves) {
        final from = store.scheduleFor(old);
        if (!from.isEmpty) {
          final to = store.scheduleFor(p.key);
          // 새 열쇠에 이미 일정이 있으면 그쪽이 최신이다 — 예전 것은 지우기만
          final keep = to.isEmpty ? from : to;
          await store.save(p.key, keep);
          await store.save(old, const JourneySchedule());
          // 예전 열쇠로 걸린 알림을 지우고 새 열쇠로 다시 건다(같은 날 두 번 울리지 않게)
          await svc.sync(
            propertyKey: old,
            alias: p.alias,
            schedule: const JourneySchedule(),
          );
          await svc.sync(propertyKey: p.key, alias: p.alias, schedule: keep);
        }
        if (store.selectedPropertyKey == old) await store.select(p.key);
      }
      for (final (old, key) in progressMoves) {
        await progressStore.adoptKey(old, key);
      }
    } catch (e) {
      debugPrint('[집열쇠] 예전 일정을 옮기지 못했어요 (${e.runtimeType}) — 다음에 다시 시도합니다');
    } finally {
      _moving = false;
    }
  });
}
