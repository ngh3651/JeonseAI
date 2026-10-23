/// 계약 지킴이 알림 — **언제·무엇을** 울릴지 계산하는 순수 함수 (2026-10-22, P1-2).
///
/// 플러그인(flutter_local_notifications)을 전혀 모른다. 일정과 '지금'을 넣으면 예약할 알림
/// 목록이 나온다 — 그래서 위젯·플러그인 없이 단위 테스트한다(test/journey_reminders_test.dart).
///
/// 울리는 때 (전부 **그 폰의 시각** 기준 — 사용자가 고른 날짜도 그 폰의 달력 날짜다):
///   ① 잔금일 하루 전 오전 9시     — 내일 잔금 전에 등기부를 다시 떼서 찍어 주세요
///   ② 잔금일 당일 오전 8시        — 입금 전 마지막 확인
///   ③ 이사(입주) 다음 날 오전 9시 — 대항력이 생기는 날, 새 빚이 없는지 확인
/// - **이미 지난 시각은 예약하지 않는다** (플러그인도 지난 시각은 거부한다).
/// - 문구의 법적 사실(대항력은 입주 다음 날 0시)은 여정 데이터(`journey_stages.json`)의
///   '입주 다음 날' 단계 문구를 그대로 따른다. 새 수치를 만들지 않는다.
library;

import 'dart:convert';

import '../models/content_models.dart';
import '../state/journey_schedule_store.dart';
import '../utils/korean_date.dart';

/// 알림 세 가지. [slot]은 알림 id 끝자리, [hour]는 울리는 시(그 폰의 시각).
enum JourneyReminderKind {
  /// 잔금일 하루 전 오전 9시
  balanceEve(slot: 0, hour: 9, dayOffset: -1),

  /// 잔금일 당일 오전 8시
  balanceDay(slot: 1, hour: 8, dayOffset: 0),

  /// 이사(입주) 다음 날 오전 9시
  moveInNext(slot: 2, hour: 9, dayOffset: 1);

  const JourneyReminderKind({
    required this.slot,
    required this.hour,
    required this.dayOffset,
  });

  final int slot;
  final int hour;

  /// 기준 날짜(잔금일·이사일)에서 며칠 떨어진 날에 울리나
  final int dayOffset;
}

/// 예약할 알림 하나.
class JourneyReminder {
  const JourneyReminder({
    required this.kind,
    required this.propertyKey,
    required this.fireAt,
    required this.title,
    required this.body,
    this.subText,
  });

  final JourneyReminderKind kind;

  /// 어느 집의 알림인가 (주소를 정규화한 매물 키 — [journeyPropertyKey])
  final String propertyKey;

  /// 울리는 때 (그 폰의 시각)
  final DateTime fireAt;
  final String title;
  final String body;

  /// 알림 머리줄의 작은 글씨(안드로이드). 계약 지킴이 패스가 있으면 "계약 지킴이 패스" — **표시만** 붙는다.
  final String? subText;

  /// 같은 집·같은 종류면 늘 같은 id — 날짜를 바꿔 다시 걸면 **덮어쓰고**, 지우면 이 id로 취소한다.
  int get id => journeyReminderId(propertyKey, kind);

  /// 알림을 눌렀을 때 앱이 받는 값 → 그 집의 여정 화면을 연다.
  String get payload => journeyReminderPayload(propertyKey);
}

/// 계약 지킴이 패스가 있을 때 알림 머리줄에 붙는 말.
const String kReminderPassSubText = '계약 지킴이 패스';

/// 알림 payload 앞머리. 다른 알림이 생겨도 헷갈리지 않게 붙인다.
const String _payloadPrefix = 'journey|';

String journeyReminderPayload(String propertyKey) => '$_payloadPrefix$propertyKey';

/// 알림 payload → 매물 키. 우리 알림이 아니면 null.
String? journeyKeyFromPayload(String? payload) {
  if (payload == null || !payload.startsWith(_payloadPrefix)) return null;
  final key = payload.substring(_payloadPrefix.length);
  return key.isEmpty ? null : key;
}

/// 알림 id — 매물 키의 FNV-1a 해시(27비트) × 4 + 종류 칸.
///
/// ⚠ Dart의 `String.hashCode`는 실행마다 같다는 보장이 없어 쓰지 않는다 — id가 바뀌면 옛 알림을
///   취소하지 못한다. 결과는 2^29보다 작아 안드로이드 알림 id(32비트 정수) 범위 안이다.
int journeyReminderId(String propertyKey, JourneyReminderKind kind) {
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode(propertyKey)) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return (hash & 0x07FFFFFF) * 4 + kind.slot;
}

/// 그 집의 알림 id 세 개 (취소할 때 — 날짜가 없어져도 지워야 한다).
List<int> journeyReminderIds(String propertyKey) => [
  for (final kind in JourneyReminderKind.values)
    journeyReminderId(propertyKey, kind),
];

/// 일정 → 예약할 알림 목록 (울리는 순서대로). 지난 시각은 빠진다.
///
/// [alias]는 알림 제목 뒤에 붙는 집 이름(예: "정자동 빌라") — 집이 여럿일 때 어느 집인지 알게.
/// [withPass]면 알림 머리줄에 "계약 지킴이 패스"를 붙인다(표시만 — 울리는 때·문구는 같다).
List<JourneyReminder> planJourneyReminders({
  required String propertyKey,
  required String alias,
  required JourneySchedule schedule,
  required DateTime now,
  bool withPass = false,
}) {
  final String suffix = alias.trim().isEmpty ? '' : ' · ${alias.trim()}';
  final out = <JourneyReminder>[];

  void add(JourneyReminderKind kind, DateTime? base, String title, String body) {
    if (base == null) return;
    final fireAt = DateTime(
      base.year,
      base.month,
      base.day + kind.dayOffset,
      kind.hour,
    );
    if (!fireAt.isAfter(now)) return; // 지난 시각은 예약하지 않는다
    out.add(
      JourneyReminder(
        kind: kind,
        propertyKey: propertyKey,
        fireAt: fireAt,
        title: '$title$suffix',
        body: body,
        subText: withPass ? kReminderPassSubText : null,
      ),
    );
  }

  final DateTime? balance = schedule.balance;
  add(
    JourneyReminderKind.balanceEve,
    balance,
    '내일 잔금 보내는 날이에요',
    '내일 잔금 전에 등기부를 다시 떼서 찍어 주세요. 새로 생긴 빚이 없는지 대조해 드려요',
  );
  add(
    JourneyReminderKind.balanceDay,
    balance,
    '오늘 잔금 보내는 날이에요',
    '입금 전 마지막 확인 — 오늘 뗀 등기부로 대조해 주세요',
  );
  add(
    JourneyReminderKind.moveInNext,
    schedule.dates[JourneyDateKey.moveIn],
    '입주 다음 날 등기부 확인',
    '대항력은 오늘 0시부터 생겨요 — 그 사이 새 빚이 생기지 않았는지 등기부를 떼서 대조해 주세요',
  );

  out.sort((a, b) => a.fireAt.compareTo(b.fireAt));
  return out;
}

/// 오늘 앱 안 배너로 말할 때 — 알림 세 가지와 **같은 날**이다 (알림을 끈 사람도 그날 앱을 열면 본다).
///
/// 잔금 당일 > 잔금 하루 전 > 입주 다음 날 순서로 하나만 고른다(잔금이 가장 큰돈이 나가는 날이다).
JourneyReminderKind? journeyAlertToday(JourneySchedule schedule, {DateTime? now}) {
  final DateTime t = now ?? DateTime.now();
  final DateTime today = DateTime(t.year, t.month, t.day);
  int? daysFromToday(DateTime? d) =>
      d == null ? null : DateTime(d.year, d.month, d.day).difference(today).inDays;

  final int? balance = daysFromToday(schedule.balance);
  if (balance == 0) return JourneyReminderKind.balanceDay;
  if (balance == 1) return JourneyReminderKind.balanceEve;
  if (daysFromToday(schedule.dates[JourneyDateKey.moveIn]) == -1) {
    return JourneyReminderKind.moveInNext;
  }
  return null;
}

/// "8월 5일 (화) 오전 9시" — 저장 뒤 안내 한 줄에 쓴다.
String describeReminderTime(DateTime fireAt) {
  final int h = fireAt.hour;
  final String half = h < 12 ? '오전' : '오후';
  final int h12 = h % 12 == 0 ? 12 : h % 12;
  return '${formatMonthDayWeekday(fireAt)} $half $h12시';
}
