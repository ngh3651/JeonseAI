/// 계약 여정 계산 (2026-10-30 규혁 — '단계별 할 일' 체크가 유일한 정답).
///
/// 못 박는 것:
///   ① 뒤 단계에 날짜만 넣었다고 앞 단계를 끝난 것으로 짐작하지 않는다
///   ② 체크는 순서대로만 — 다음 하나만 켜고, 마지막 하나만 끈다
///   ③ 날짜가 미래인 단계는 체크 못 하고, 예전 체크도 그 앞에서 멈춘다
///   ④ 날짜가 지나면 그 단계와 앞 단계는 저절로 끝 — 풀 수 없다
///   ⑤ '다음'은 늘 체크 안 된 첫 단계 — 날짜 원·회색 띠·리포트 5장이 같은 단계를 본다
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/screens/journey/journey_logic.dart';
import 'package:jeonse_ai/state/journey_schedule_store.dart';

DateTime _day(int offset) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day + offset);
}

late List<JourneyStage> _stages;

JourneyProgress _p({
  Map<JourneyDateKey, DateTime> dates = const {},
  int checked = 0,
}) => JourneyProgress(
  stages: _stages,
  schedule: JourneySchedule(dates: dates),
  hasProperty: true,
  checkedThrough: checked,
);

void main() {
  setUpAll(() async {
    _stages = await DummyContentRepository().journeyStages();
    // 0 분석 · 1 가계약금 · 2 계약서 · 3 잔금 · 4 이사 · 5 입주 후 …
    expect(_stages[1].dateKey, JourneyDateKey.downPayment);
    expect(_stages[3].dateKey, JourneyDateKey.balance);
  });

  test('① 잔금 날짜만 넣어도 가계약금·계약서는 끝난 게 아니다', () {
    final p = _p(dates: {JourneyDateKey.balance: _day(8)});
    expect(p.isDone(0), isTrue);
    expect(p.isDone(1), isFalse);
    expect(p.isDone(2), isFalse);
    expect(p.currentIndex, 1);
    expect(p.circleState(0), CircleState.empty); // 가계약금
    expect(p.circleState(2), CircleState.future); // 잔금 D-8
    expect(p.nextLine, '다음은 ${_stages[1].title}');
  });

  test('② 순서대로만 켜고 끈다', () {
    final p = _p(checked: 1);
    expect(p.toggleBlockReason(2), isNull); // 다음 = 계약서
    expect(p.toggledThrough(2), 2);
    expect(p.toggleBlockReason(1), isNull); // 마지막으로 켠 것 = 풀기
    expect(p.toggledThrough(1), 0);
    expect(p.toggleBlockReason(4), '${_stages[2].chipLabel}부터 체크해 주세요');
    expect(_p(checked: 3).toggleBlockReason(1), '${_stages[3].chipLabel}부터 풀어 주세요');
    expect(p.toggleSilentlyIgnored(0), isTrue);
  });

  test('③ 날짜가 미래면 체크 못 하고, 예전 체크도 그 앞에서 멈춘다', () {
    final dates = {JourneyDateKey.moveIn: _day(6)};
    final p = _p(dates: dates, checked: 3);
    expect(p.toggleBlockReason(4), startsWith(slashDate(_day(6))));
    // 예전에 이사까지 켜 둔 기록 — 날짜가 미래라 이사 앞에서 멈춘다
    final old = _p(dates: dates, checked: 5);
    expect(old.isDone(3), isTrue);
    expect(old.isDone(4), isFalse);
    expect(old.currentIndex, 4);
    // 회색 띠도 이사 날을 가리킨다 (이사 단계가 대조 단계일 때)
    if (_stages[4].compare) expect(old.nextRecheckIndex, 4);
    // 오늘이면 체크할 수 있다
    expect(_p(dates: {JourneyDateKey.moveIn: _day(0)}, checked: 3).toggleBlockReason(4), isNull);
  });

  test('④ 날짜가 지나면 앞 단계까지 저절로 끝, 풀 수 없다', () {
    final p = _p(dates: {JourneyDateKey.contract: _day(-1)});
    expect(p.isDone(1), isTrue);
    expect(p.isDone(2), isTrue);
    expect(p.currentIndex, 3);
    expect(p.toggleBlockReason(2), '날짜가 지나 끝난 단계예요');
    expect(p.circleState(0), CircleState.passed);
    expect(p.circleState(1), CircleState.passed);
  });

  test('⑤ 다음 단계 = 리포트 5장 띠 · 날짜 원 · 단계 칩', () {
    final dates = {JourneyDateKey.balance: _day(8)};
    final p = _p(dates: dates, checked: 2);
    expect(p.currentIndex, 3);
    expect(p.headlineIndex, 3);
    expect(p.initialSelection, 3);
    expect(p.circleState(2), CircleState.current);
    expect(p.nextLine, '다음은 ${JourneyDateKey.balance.label} · 8일 뒤');
    // 다 끝나면 마지막 단계를 보여 준다
    final all = _p(checked: _stages.length - 1);
    expect(all.currentIndex, isNull);
    expect(all.headlineIndex, _stages.length - 1);
  });
}
