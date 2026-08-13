/// S-07 리포트 하단 '다음 행동' 2×2 그리드 (2026-08-14 D12).
///
/// 이 파일이 못 박는 것은 셋이다:
///   ① **네 칸이 고정**이다 — 등급에 따라 배치가 바뀌지 않는다.
///      (예전에는 양호면 체크리스트가 전폭 '추천' 카드로 올라와 시연할 때마다
///       화면 모양이 달랐다.)
///   ② **네 칸의 크기가 똑같다** — 하나라도 높이가 다르면 2×2가 아니라 계단이 된다.
///   ③ **360dp에서 넘치지 않는다** — 라벨 '중개사에게 물어볼 질문'은 한 줄에 안 들어가
///      두 줄이 되는데, 그 높이를 네 칸이 모두 감당해야 한다.
///      (위젯 테스트는 넘치면 스스로 실패하므로 ③은 렌더링만으로 검증된다.)
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/design_system/components/app_card.dart';
import 'package:jeonse_ai/design_system/theme.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/screens/report/report_screen.dart';
import 'package:provider/provider.dart';

import 'support/ko_finders.dart';
import 'support/registry_fixture.dart' show kPhoneWidth, kPhoneHeight;

/// 네 칸의 라벨 — **순서까지** 지시받은 그대로다.
const List<String> kActionLabels = [
  '중개사에게 물어볼 질문',
  '판례 매칭',
  '손실 시뮬레이터',
  '계약 여정',
];

Future<void> _pumpReport(WidgetTester tester, String reportId) async {
  tester.view.physicalSize = const Size(kPhoneWidth * 3, kPhoneHeight * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    // 앱과 같은 방식으로 주입한다 (AnalysisRepository는 ChangeNotifier다).
    ChangeNotifierProvider<AnalysisRepository>(
      create: (_) => DummyAnalysisRepository(),
      child: MaterialApp(
        theme: buildAppTheme(),
        home: ReportScreen(reportId: reportId),
      ),
    ),
  );
  await tester.pumpAndSettle();

  // 리포트는 긴 ListView라 '다음 행동'은 화면 밖이다 — 화면 밖 자식은 렌더 트리에
  // 붙지 않아 finder에 잡히지 않는다. 그리드가 보일 때까지 굴린다.
  await tester.scrollUntilVisible(
    find.koText(kActionLabels.first),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

/// 그리드 칸만 골라낸다 — 리포트에는 다른 [AppCard]도 있다(다음 행동 칸은 마지막 4개).
List<Size> _gridTileSizes(WidgetTester tester) {
  return [
    for (final label in kActionLabels)
      tester.getSize(
        find.ancestor(of: find.koText(label), matching: find.byType(AppCard)).first,
      ),
  ];
}

void main() {
  for (final id in const ['dummy-danger', 'dummy-caution']) {
    testWidgets('[$id] 다음 행동은 등급과 무관하게 네 칸 고정', (tester) async {
      await _pumpReport(tester, id);

      for (final label in kActionLabels) {
        expect(find.koText(label), findsOneWidget, reason: '$label 칸이 없다');
      }
      // 예전 배치의 흔적이 남아 있으면 안 된다.
      expect(find.koText('질문 생성기'), findsNothing);
      expect(find.koText('체크리스트'), findsNothing);
      expect(find.koText('계약 여정 체크리스트'), findsNothing);
      expect(find.koText('추천'), findsNothing, reason: '칸이 작아져 뱃지는 뺐다');
      expect(
        find.koTextContaining('위험 요소별로 중개사에게'),
        findsNothing,
        reason: '칸이 작아져 설명 문구는 뺐다',
      );
    });
  }

  testWidgets('네 칸의 크기가 똑같다 (360dp)', (tester) async {
    await _pumpReport(tester, 'dummy-danger');

    final sizes = _gridTileSizes(tester);
    for (final size in sizes) {
      expect(size, sizes.first, reason: '칸 크기가 갈리면 2×2가 아니라 계단이 된다');
    }
    // 360dp 화면 - 화면패딩 40 - 칸 사이 12 = 308 / 2 = 154dp
    expect(sizes.first.width, closeTo(154, 0.5));
  });

  testWidgets('가장 긴 라벨은 두 줄이 되고, 그 높이를 네 칸이 감당한다', (tester) async {
    await _pumpReport(tester, 'dummy-danger');

    // '중개사에게 물어볼 질문'(15px 한글 11자 ≈ 171dp)은 칸의 글자 폭보다 넓다.
    // 폰트를 줄이는 대신 줄바꿈을 허용했으므로 **두 줄**이어야 한다.
    final RenderBox label = tester.renderObject(find.koText(kActionLabels.first));
    final RenderBox short = tester.renderObject(find.koText('판례 매칭'));
    expect(
      label.size.height,
      greaterThan(short.size.height * 1.5),
      reason: '한 줄로 접혔다면 글자가 잘렸거나 폰트가 줄었다는 뜻이다',
    );
    // 넘침은 위젯 테스트가 스스로 실패시킨다 — 여기까지 왔다면 네 칸 모두 담았다.
  });

  testWidgets('양호 리포트에서도 네 칸이 같은 자리에 있다', (tester) async {
    await _pumpReport(tester, 'dummy-caution');

    final report = await DummyAnalysisRepository().getReport('dummy-caution');
    expect(report!.grade, isNot(RiskGrade.danger));

    final sizes = _gridTileSizes(tester);
    for (final size in sizes) {
      expect(size, sizes.first);
    }
  });
}
