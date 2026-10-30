/// 이 폰에 남은 내 기록을 **모두** 지운다 — 회원 탈퇴 (2026-10-30 보안).
///
/// 서버 기록은 탈퇴 API가 지운다. 여기서는 폰에만 있던 것을 지운다:
/// 원본 사진·실명 리포트 · 임시 사진 사본 · 계약 일정과 예약 알림 · 여정 기록 · 챗봇 지난 대화 · 동의 기록(다음에 다시 묻는다).
/// 하나가 실패해도 나머지는 계속 지운다.
library;

import 'package:flutter/foundation.dart';

import '../repositories/chat_history_repository.dart';
import '../state/consent_store.dart';
import '../state/journey_progress_store.dart';
import '../state/journey_schedule_store.dart';
import '../state/registry_photo_store.dart';
import 'journey_reminder_service.dart';

Future<void> wipeThisPhone({ChatHistoryRepository? chats}) async {
  Future<void> step(String what, Future<void> Function() run) async {
    try {
      await run();
    } catch (e) {
      debugPrint('[폰 정리] $what 지우기 실패 (${e.runtimeType})');
    }
  }

  await step('원본 사진', () => RegistryPhotoStore.instance.purgeAll());
  // 촬영·변환 때 임시 폴더에 생긴 사진 사본도 — 앱을 다시 켤 때까지 기다리지 않는다(2026-10-30 보안 리뷰)
  await step('임시 사진 사본', () => RegistryPhotoStore.sweepTempCopies());
  await step('계약 일정', () async {
    final schedules = JourneyScheduleStore.instance;
    for (final key in schedules.scheduledKeys.toList()) {
      await schedules.save(key, const JourneySchedule());
      await JourneyReminderService.instance.sync(
        propertyKey: key,
        alias: '',
        schedule: const JourneySchedule(),
      );
    }
    await schedules.select(null);
  });
  await step('여정 기록', () => JourneyProgressStore.instance.forgetAll());
  if (chats != null) {
    await step('챗봇 대화', () async {
      for (final c in await chats.list()) {
        await chats.delete(c.id);
      }
    });
  }
  await step('동의 기록', () => ConsentStore.instance.forget());
}
