/// 계약 여정의 **계산** — 어느 단계가 끝났고, 지금은 어디이고, 날짜 원을 어떻게 칠할지 (2026-10-26 여정 디자인).
///
/// 위젯을 모른다 — 일정·단계·수동 완료 값을 넣으면 답이 나온다(단위 테스트: test/journey_logic_test.dart).
///
/// 규칙 (확정 디자인 규칙 5·6장):
/// - 1단계(분석)는 집이 있으면 **항상 완료**.
/// - 나머지는 날짜가 지나면 완료. 사용자가 칩을 한 번 더 눌러 켜고 끈 값이 있으면 그 값이 우선.
/// - 날짜 없이 비어 있는 앞 단계는 **순서로 추정**한다 — 뒤 단계 날짜가 다가왔으면(지났거나 현재) 앞 단계는 지난 것으로 본다.
/// - 현재 = 아직 안 지난 날짜 중 가장 이른 단계. 날짜가 하나도 없으면 현재는 없다.
/// - 8·9단계(1~2년 뒤 일)는 날짜가 없고 진행 표시에 세지 않는다.
library;

import '../../models/content_models.dart';
import '../../state/journey_schedule_store.dart';
import '../../utils/korean_date.dart';

/// 일정 카드의 날짜 원 4개 (가계약금 · 계약서 · 잔금 · 이사).
const List<JourneyDateKey> kScheduleCircleKeys = JourneyDateKey.editable;

/// 날짜 원 이름 (원 아래 글자)
String circleLabel(JourneyDateKey key) => switch (key) {
  JourneyDateKey.downPayment => '가계약금',
  JourneyDateKey.contract => '계약서',
  JourneyDateKey.balance => '잔금',
  JourneyDateKey.moveIn => '이사',
  JourneyDateKey.moveInNext => '입주 후',
};

/// 회색 띠 "10/26 **계약서 날**에 다시 떼기"의 날 이름
String recheckDayLabel(JourneyDateKey key) => switch (key) {
  JourneyDateKey.downPayment => '가계약금 날',
  JourneyDateKey.contract => '계약서 날',
  JourneyDateKey.balance => '잔금 날',
  JourneyDateKey.moveIn => '이사 날',
  JourneyDateKey.moveInNext => '입주 다음 날',
};

/// "10/26"
String slashDate(DateTime d) => '${d.month}/${d.day}';

/// "10/26 (월)"
String slashDateWeekday(DateTime d) => '${slashDate(d)} (${weekdayLabel(d)})';

enum CircleState {
  /// 날짜 없음 — 회색 바탕 + "+" (잔금은 연초록 + 초록 "+")
  empty,

  /// 지남 (날짜 있음 또는 순서로 추정) — 초록 꽉 찬 원 + 흰 체크
  passed,

  /// 다음 일정 — 연초록 바탕 + 진초록 "D-2", 1.14배
  current,

  /// 앞으로 — 흰 바탕 + 초록 테두리 + "D-6"
  future,
}

/// 진행 상태 묶음 — 화면 한 번 그릴 때 한 번 계산한다.
class JourneyProgress {
  JourneyProgress({
    required this.stages,
    required this.schedule,
    required this.hasProperty,
    bool? Function(int stageIndex)? manualDone,
  }) : _manual = manualDone ?? ((_) => null);

  final List<JourneyStage> stages;
  final JourneySchedule schedule;
  final bool hasProperty;
  final bool? Function(int stageIndex) _manual;

  DateTime? dateOf(int i) {
    final key = stages[i].dateKey;
    return key == null ? null : schedule[key];
  }

  /// 날짜로만 본 '지남' (오늘은 아직 안 지남)
  bool _datePassed(int i) {
    final d = dateOf(i);
    return d != null && daysUntil(d) < 0;
  }

  /// 날짜 없는 앞 단계를 순서로 추정 — 뒤쪽 날짜 단계 중 지났거나 오늘·다가온(현재) 것이 있으면 지난 것으로 본다.
  bool _inferredPassed(int i) {
    if (stages[i].dateKey == null || dateOf(i) != null) return false;
    final cur = currentIndex;
    for (int j = i + 1; j < stages.length; j++) {
      if (dateOf(j) == null) continue;
      if (_datePassed(j) || j == cur) return true;
    }
    return false;
  }

  /// 이 단계가 끝났나 (수동 값 우선).
  bool isDone(int i) {
    final stage = stages[i];
    if (stage.kind == JourneyStageKind.analysis) return hasProperty;
    final manual = _manual(i);
    if (manual != null) return manual;
    return _datePassed(i) || _inferredPassed(i);
  }

  /// 칩을 눌러 완료를 켜고 끌 수 있나 — 분석 단계는 늘 완료라 못 바꾼다.
  bool canToggle(int i) => stages[i].kind != JourneyStageKind.analysis;

  int? _current;
  bool _currentComputed = false;

  /// 현재 단계 — 아직 안 지난 날짜 중 가장 이른 것(사용자가 완료로 켠 단계는 건너뛴다). 없으면 null.
  int? get currentIndex {
    if (_currentComputed) return _current;
    _currentComputed = true;
    int? best;
    int bestDays = 1 << 30;
    for (int i = 0; i < stages.length; i++) {
      final d = dateOf(i);
      if (d == null) continue;
      if (_manual(i) == true) continue;
      final days = daysUntil(d);
      if (days >= 0 && days < bestDays) {
        best = i;
        bestDays = days;
      }
    }
    _current = best;
    return best;
  }

  /// "9단계 중 N단계"의 N(1부터) — 현재, 없으면 아직 안 끝난 첫 단계(모두 끝났으면 마지막).
  int get stepNumber {
    final cur = currentIndex;
    if (cur != null) return cur + 1;
    for (int i = 0; i < stages.length; i++) {
      if (!isDone(i)) return i + 1;
    }
    return stages.length;
  }

  /// 처음 열 때 고를 단계 — 현재, 없으면 아직 안 끝난 첫 단계.
  int get initialSelection => stepNumber - 1;

  /// 대조 버튼이 붙는 단계인가 — 대조 단계이면서 아직 안 끝났다.
  bool showsCompare(int i) => stages[i].compare && !isDone(i);

  /// 회색 띠가 가리킬 단계 — 아직 안 끝났고, 대조 버튼이 있고, 날짜가 있는 첫 단계.
  int? get nextRecheckIndex {
    for (int i = 0; i < stages.length; i++) {
      if (showsCompare(i) && dateOf(i) != null) return i;
    }
    return null;
  }

  /// 날짜가 없을 때 회색 띠가 가리킬 단계 — 아직 안 끝난 첫 대조 단계.
  int? get firstOpenCompareIndex {
    for (int i = 0; i < stages.length; i++) {
      if (showsCompare(i)) return i;
    }
    return null;
  }

  // ── 일정 카드의 날짜 원 ──────────────────────────────────────────────

  /// 날짜 원 4개 중 '다음 일정'(아직 안 지난 가장 이른 날) 번호. 없으면 null.
  int? get currentCircle {
    int? best;
    int bestDays = 1 << 30;
    for (int c = 0; c < kScheduleCircleKeys.length; c++) {
      final d = schedule[kScheduleCircleKeys[c]];
      if (d == null) continue;
      final days = daysUntil(d);
      if (days >= 0 && days < bestDays) {
        best = c;
        bestDays = days;
      }
    }
    return best;
  }

  CircleState circleState(int c) {
    final d = schedule[kScheduleCircleKeys[c]];
    if (d != null) {
      if (daysUntil(d) < 0) return CircleState.passed;
      return c == currentCircle ? CircleState.current : CircleState.future;
    }
    // 날짜 없음 — 뒤 원 중 지났거나 '다음 일정'인 날짜가 있으면 지난 것으로 추정
    final cur = currentCircle;
    for (int j = c + 1; j < kScheduleCircleKeys.length; j++) {
      final dj = schedule[kScheduleCircleKeys[j]];
      if (dj == null) continue;
      if (daysUntil(dj) < 0 || j == cur) return CircleState.passed;
    }
    return CircleState.empty;
  }

  /// 원 c와 c+1 사이 선을 채우나 — 앞 원이 지났고 뒤 원이 지났거나 다음 일정일 때.
  bool segmentFilled(int c) {
    final a = circleState(c);
    final b = circleState(c + 1);
    return a == CircleState.passed &&
        (b == CircleState.passed || b == CircleState.current);
  }

  /// "다음은 계약서 쓰는 날 · 2일 뒤" — 다음 일정이 없으면 null.
  String? get nextLine {
    final c = currentCircle;
    if (c == null) return null;
    final key = kScheduleCircleKeys[c];
    final days = daysUntil(schedule[key]!);
    final when = days == 0 ? '오늘' : (days == 1 ? '내일' : '$days일 뒤');
    return '다음은 ${key.label} · $when';
  }
}

/// "D-2" · "D-DAY" · "D+4"
String dDayLabel(DateTime date) {
  final days = daysUntil(date);
  if (days == 0) return 'D-DAY';
  if (days > 0) return 'D-$days';
  return 'D+${-days}';
}
