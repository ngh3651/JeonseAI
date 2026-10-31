/// 잔금 당일 빈틈 (2026-10-31) — '신청사건 처리중'이 찍힌 등기부.
///
///   ① 사진에서 보기: 신청사건은 **대조할 곳**(초록)이고, 진입 카드 미리보기는 이 줄부터
///   ② 다시 떼서 대조: 다른 줄이 모두 그대로여도 '달라진 것 없어요'라고 하지 않고 멈춤 띠를 맨 위에
///   ③ 변동 기록에도 한 줄 남는다
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/registry_mark_kind.dart';
import 'package:jeonse_ai/screens/journey/journey_compare_flow.dart';
import 'package:jeonse_ai/screens/report/registry_entry_card.dart';
import 'package:jeonse_ai/state/journey_progress_store.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show fixtureMark;

CompareResult _result({bool pending = true, bool debtAdded = false}) =>
    CompareResult.fromJson({
      'result': 'changed',
      'headline': pending ? '처리 중인 등기 신청이 있어요' : '달라진 점은 없었어요',
      'subline': '4가지를 모두 맞춰봤어요',
      'baseline': {'reportId': 'base', 'viewedAt': '2026.10.20', 'grade': '양호'},
      'current': {'reportId': 'cur', 'viewedAt': '2026.10.31', 'grade': '확인 필요'},
      'comparedCount': 4,
      'totalCount': 4,
      'rows': [
        if (pending)
          {
            'group': 'pending',
            'kind': 'changed',
            'tone': 'danger',
            'marker': '!',
            'title': '처리 중인 등기 신청이 있어요',
            'subtitle': '아직 등기부에 적히지 않은 변화예요. 무엇인지 확인될 때까지 잔금을 보내지 마세요',
            'detail': '신청사건 처리중 · 끝나면 접수한 때로 거슬러 효력이 생겨요',
          },
        {
          'group': 'owner',
          'kind': 'same',
          'tone': 'neutral',
          'marker': '=',
          'title': '집주인 · 그대로예요',
        },
        {
          'group': 'debt',
          'kind': debtAdded ? 'added' : 'same',
          'tone': debtAdded ? 'danger' : 'neutral',
          'marker': debtAdded ? '+' : '=',
          'title': debtAdded ? '새로 생긴 빚이 있어요' : '빚 · 그대로예요',
          if (debtAdded)
            'items': [
              {'label': '근저당권', 'receiptDate': '2026-10-31', 'amountText': '채권최고액 1억원'},
            ],
        },
      ],
      'notices': <String>[],
    });

void main() {
  test('① 신청사건은 따져볼 곳(주황)이고 미리보기는 이 줄부터', () {
    expect(MarkKind.fromKey('pending_application').tone, MarkTone.risk);
    final marks = [
      fixtureMark(1, 'owner', 0, 0.2, '집주인 이름'),
      fixtureMark(2, 'mortgage', 1, 0.4, '집에 잡힌 빚 (근저당권) · 1억원'),
      fixtureMark(3, 'pending_application', 0, 0.05, '처리 중인 등기 신청 (신청사건)'),
    ];
    expect(previewMarkOf(marks)!.kind, 'pending_application');
    // 신청사건이 없으면 예전처럼 가장 무거운 따져볼 곳
    expect(previewMarkOf(marks.sublist(0, 2))!.kind, 'mortgage');
  });

  test('② 대조 결과 — 멈춤 줄을 찾고, 변동 기록에도 남는다', () {
    final r = _result();
    expect(pendingRowOf(r)?.title, '처리 중인 등기 신청이 있어요');
    final items = compareLogItems(r);
    expect(items.first.label, '신청사건 처리중');
    expect(items.first.kind, CompareLogItemKind.changed);
    expect(pendingRowOf(_result(pending: false)), isNull);
  });

  testWidgets('② 다른 줄이 그대로여도 멈춤 띠가 맨 위에 보인다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: PendingApplicationBanner(row: pendingRowOf(_result())!)),
      ),
    );
    expect(find.byKey(const ValueKey('compare-pending-banner')), findsOneWidget);
    expect(find.koTextContaining('잔금을 보내지 마세요'), findsOneWidget);
    expect(find.koTextContaining('접수한 때로 거슬러'), findsOneWidget);
  });
}
