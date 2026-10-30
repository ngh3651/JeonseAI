/// 계약 여정의 **계산** — 어느 단계가 끝났고, 다음은 어디이고, 날짜 원을 어떻게 칠할지.
///
/// 위젯을 모른다 — 일정·단계·체크 값을 넣으면 답이 나온다(단위 테스트: test/journey_logic_test.dart).
/// 여정 화면과 리포트 5장 미리보기가 **이 계산 하나**를 같이 쓴다 — 두 화면이 다른 단계를 말할 수 없다.
///
/// 규칙 (2026-10-30 규혁 — '단계별 할 일' 체크가 유일한 정답):
/// - 1단계(분석)는 집이 있으면 **항상 완료**.
/// - 체크는 **순서대로만** — 다음 단계 하나만 켤 수 있고, 마지막으로 켠 단계 하나만 끌 수 있다.
///   그래서 끝난 단계는 늘 앞에서부터 이어져 있고, '다음'은 늘 체크 안 된 첫 단계다.
/// - 날짜가 **지나면**(다음 날부터) 그 단계와 앞 단계는 저절로 끝난 것으로 본다.
/// - 날짜가 **미래**인 단계는 그날이 올 때까지 체크할 수 없다 — 예전에 켜 둔 체크도 그 앞에서 멈춘다.
/// - 뒤 단계에 날짜만 넣었다고 앞 단계를 끝난 것으로 짐작하지 않는다.
/// - 8·9단계(1~2년 뒤 일)는 날짜가 없다.
library;

import '../../models/content_models.dart';
import '../../state/journey_progress_store.dart';
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

  /// 끝남 (체크했거나 날짜가 지남) — 초록 꽉 찬 원 + 흰 체크
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
    this.checkedThrough = 0,
  });

  /// 이 집의 일정·체크를 저장소에서 읽어 만든다 — 여정 화면과 리포트 5장이 같은 값을 쓰게.
  factory JourneyProgress.forProperty(
    List<JourneyStage> stages,
    String propertyKey, {
    JourneyScheduleStore? scheduleStore,
    JourneyProgressStore? progressStore,
  }) {
    final sched = scheduleStore ?? JourneyScheduleStore.instance;
    final prog = progressStore ?? JourneyProgressStore.instance;
    return JourneyProgress(
      stages: stages,
      schedule: sched.scheduleFor(propertyKey),
      hasProperty: true,
      checkedThrough: prog.checkedThrough(propertyKey),
    );
  }

  final List<JourneyStage> stages;
  final JourneySchedule schedule;
  final bool hasProperty;

  /// 사용자가 앞에서부터 체크해 둔 마지막 단계 번호(0 = 분석만).
  final int checkedThrough;

  DateTime? dateOf(int i) {
    final key = stages[i].dateKey;
    return key == null ? null : schedule[key];
  }

  /// 날짜가 지났다 (오늘은 아직 안 지남)
  bool _datePassed(int i) {
    final d = dateOf(i);
    return d != null && daysUntil(d) < 0;
  }

  /// 날짜가 아직 오지 않았다 (오늘은 왔음)
  bool _dateFuture(int i) {
    final d = dateOf(i);
    return d != null && daysUntil(d) > 0;
  }

  int? _doneThroughCache;

  /// 끝난 마지막 단계 번호. 집이 없으면 -1.
  int get doneThrough {
    if (_doneThroughCache != null) return _doneThroughCache!;
    if (!hasProperty || stages.isEmpty) return _doneThroughCache = -1;
    // 날짜가 지난 마지막 단계까지는 저절로 끝
    int auto = 0;
    for (int i = 0; i < stages.length; i++) {
      if (_datePassed(i)) auto = i;
    }
    // 체크는 날짜가 미래인 첫 단계 앞에서 멈춘다
    int cap = stages.length - 1;
    for (int i = 1; i < stages.length; i++) {
      if (_dateFuture(i)) {
        cap = i - 1;
        break;
      }
    }
    final int checked = checkedThrough.clamp(0, cap);
    return _doneThroughCache = (auto > checked ? auto : checked).clamp(
      0,
      stages.length - 1,
    );
  }

  /// 날짜가 지나서 끝난 마지막 단계 — 이 단계까지는 체크를 풀 수 없다.
  int get _autoThrough {
    int auto = 0;
    for (int i = 0; i < stages.length; i++) {
      if (_datePassed(i)) auto = i;
    }
    return auto;
  }

  /// 이 단계가 끝났나.
  bool isDone(int i) => i <= doneThrough;

  /// 다음 단계 = 체크 안 된 첫 단계. 다 끝났거나 집이 없으면 null.
  int? get currentIndex {
    if (!hasProperty) return null;
    final n = doneThrough + 1;
    return n < stages.length ? n : null;
  }

  /// 리포트 5장 띠가 보여 줄 단계 — 다음 단계, 다 끝났으면 마지막 단계.
  int? get headlineIndex {
    if (!hasProperty || stages.isEmpty) return null;
    return currentIndex ?? stages.length - 1;
  }

  /// "9단계 중 N단계"의 N(1부터) — 다음 단계, 모두 끝났으면 마지막.
  int get stepNumber {
    final cur = currentIndex;
    if (cur != null) return cur + 1;
    return stages.isEmpty ? 0 : (hasProperty ? stages.length : 1);
  }

  /// 처음 열 때 고를 단계 — 다음 단계.
  int get initialSelection => stepNumber == 0 ? 0 : stepNumber - 1;

  /// 칩을 눌러 체크를 켜거나 끌 수 있나 — 안 되면 그 이유(한 줄), 되면 null.
  /// 분석 단계는 늘 완료라 조용히 무시한다([toggleSilentlyIgnored]).
  String? toggleBlockReason(int i) {
    if (!hasProperty || i <= 0 || i >= stages.length) return null;
    final int done = doneThrough;
    if (i == done + 1) {
      final d = dateOf(i);
      if (_dateFuture(i)) return '${slashDate(d!)}부터 체크할 수 있어요';
      return null; // 체크
    }
    if (i == done) {
      if (i <= _autoThrough) return '날짜가 지나 끝난 단계예요';
      return null; // 풀기
    }
    if (i > done + 1) return '${stages[done + 1].chipLabel}부터 체크해 주세요';
    // i < done — 앞 단계는 뒤에서부터 풀어야 한다
    if (i <= _autoThrough) return '날짜가 지나 끝난 단계예요';
    return '${stages[done].chipLabel}부터 풀어 주세요';
  }

  bool toggleSilentlyIgnored(int i) => i <= 0;

  /// [i]를 눌렀을 때 저장할 '체크한 마지막 단계' — 켜면 i, 끄면 i-1. 못 바꾸면 null.
  int? toggledThrough(int i) {
    if (toggleSilentlyIgnored(i) || toggleBlockReason(i) != null) return null;
    return isDone(i) ? i - 1 : i;
  }

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

  int _stageOfCircle(int c) =>
      stages.indexWhere((s) => s.dateKey == kScheduleCircleKeys[c]);

  CircleState circleState(int c) {
    final d = schedule[kScheduleCircleKeys[c]];
    final s = _stageOfCircle(c);
    if (s >= 0 && isDone(s)) return CircleState.passed;
    if (s < 0 && d != null && daysUntil(d) < 0) return CircleState.passed;
    if (d == null) return CircleState.empty;
    return (s >= 0 && s == currentIndex) ? CircleState.current : CircleState.future;
  }

  /// 원 c와 c+1 사이 선을 채우나 — 앞 원이 끝났고 뒤 원이 끝났거나 다음 일정일 때.
  bool segmentFilled(int c) {
    final a = circleState(c);
    final b = circleState(c + 1);
    return a == CircleState.passed &&
        (b == CircleState.passed || b == CircleState.current);
  }

  /// "다음은 계약서 쓰는 날 · 2일 뒤" / 날짜 없는 다음 단계면 "다음은 가계약금 보내기 전". 다 끝났으면 null.
  String? get nextLine {
    final n = currentIndex;
    if (n == null) return null;
    final key = stages[n].dateKey;
    final d = dateOf(n);
    if (key == null || d == null) return '다음은 ${stages[n].title}';
    final days = daysUntil(d);
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
