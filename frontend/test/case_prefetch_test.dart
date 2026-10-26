/// 판례 미리 불러오기 (2026-10-26) — 리포트를 열 때 뒤에서 받아 두고, 판례 화면은 그걸 바로 쓴다.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/repositories/content_repository.dart';
import 'package:jeonse_ai/state/case_prefetch.dart';

class _Repo implements ContentRepository {
  int calls = 0;
  Completer<List<CaseMatch>> next = Completer();

  @override
  Future<List<CaseMatch>> matchedCases(String reportId) {
    calls++;
    return next.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _case = CaseMatch(
  riskPattern: '선순위 채권',
  caseNo: '2020다1',
  summary: '요약',
  result: '결과',
  commonPoint: '공통점',
);

void main() {
  setUp(CasePrefetch.clear);

  test('리포트를 열 때 받기 시작하고, 판례 화면은 같은 요청을 이어서 쓴다(두 번 안 부름)', () async {
    final repo = _Repo();
    CasePrefetch.warm(repo, 'r1');
    final shown = CasePrefetch.get(repo, 'r1');
    expect(repo.calls, 1);
    repo.next.complete([_case]);
    expect(await shown, [_case]);
    expect(await CasePrefetch.get(repo, 'r1'), [_case]);
    expect(repo.calls, 1, reason: '받아 둔 것을 바로 쓴다');
  });

  test('빈 목록·실패는 기억하지 않는다 — 다음에 다시 시도', () async {
    final repo = _Repo();
    final first = CasePrefetch.get(repo, 'r2');
    repo.next.complete(const []);
    expect(await first, isEmpty);
    await Future<void>.delayed(Duration.zero);
    repo.next = Completer()..completeError(Exception('끊김'));
    await expectLater(CasePrefetch.get(repo, 'r2'), throwsException);
    await Future<void>.delayed(Duration.zero);
    repo.next = Completer()..complete([_case]);
    expect(await CasePrefetch.get(repo, 'r2'), [_case]);
    expect(repo.calls, 3);
  });
}
