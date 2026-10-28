// 분석 로딩 화면(S-06, 2026-10-28 다시 그림) — 시안 '분석로딩_시안.png' 완료 조건을 잰다.
//
// - 진행(단계·%·쪽수·남은 초)은 예상 시간 기준 → 시안 ①~④ 시각에 맞는 값
// - 꿀팁이 2줄이든 3줄이든 다른 요소가 1px도 움직이지 않는다
// - 세이프 4장이 바뀌는 동안 몸 위치가 튀지 않는다
// - 꿀팁은 글자 130%에서도 3줄 안 (실제 글꼴 Pretendard로 잰다)
// - 동작 줄이기 = 움직임 멈춤 + 세이프 한 장 고정
// - 일찍 끝나면 0.5초 안에 리포트로, 30초를 넘기면 99%·"거의 다 됐어요"로 기다린다

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeonse_ai/design_system/text/keep_all.dart';
import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';
import 'package:jeonse_ai/screens/loading/analysis_loading_screen.dart';
import 'package:jeonse_ai/screens/loading/loading_parts.dart';
import 'package:jeonse_ai/screens/loading/loading_tips.dart';
import 'package:provider/provider.dart';

import 'support/ko_finders.dart';

/// 답을 [answer]가 채워질 때까지 기다리는 저장소 (null이면 영영 안 끝남)
class _Repo extends AnalysisRepository {
  _Repo([this.answer]);

  final Completer<AnalysisReport>? answer;

  @override
  Future<AnalysisReport> analyze(AnalysisRequest request) =>
      (answer ?? Completer<AnalysisReport>()).future;

  @override
  Future<List<AnalysisReport>> getHistory() async => const [];

  @override
  Future<AnalysisReport?> getReport(String id) async => null;

  @override
  Future<void> deleteReport(String id) async {}

  @override
  Future<CompareResult> compareRegistry(
    String reportId,
    List<String> imagePaths,
  ) => Completer<CompareResult>().future;
}

Duration _s(num seconds) => Duration(milliseconds: (seconds * 1000).round());

Future<void> _open(
  WidgetTester tester, {
  int pages = 5,
  _Repo? repo,
  double textScale = 1,
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: '/loading',
    routes: [
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('홈')),
      ),
      GoRoute(
        path: '/loading',
        builder: (_, _) => AnalysisLoadingScreen(
          request: AnalysisRequest(
            imagePaths: [for (var i = 0; i < pages; i++) 'p$i'],
            deposit: 0,
          ),
        ),
      ),
      GoRoute(
        path: '/report/:id',
        builder: (_, state) =>
            Scaffold(body: Text('리포트 ${state.pathParameters['id']}')),
      ),
    ],
  );
  await tester.pumpWidget(
    ChangeNotifierProvider<AnalysisRepository>.value(
      value: repo ?? _Repo(),
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reduceMotion,
          ),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pump();
}

String _textOf(WidgetTester tester, String key) {
  final w = tester.widget(find.byKey(ValueKey(key)));
  final rich = find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(RichText),
  );
  final text = rich.evaluate().isNotEmpty
      ? (tester.widget<RichText>(rich.first).text.toPlainText())
      : w.toString();
  return stripWordJoiner(text);
}

int _visibleFrame(WidgetTester tester) {
  for (var i = 0; i < kInspectFrames.length; i++) {
    final o = tester.widget<Opacity>(find.byKey(ValueKey('inspect-frame-$i')));
    if (o.opacity == 1) return i;
  }
  return -1;
}

void main() {
  setUpAll(() async {
    final loader = FontLoader('Pretendard');
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Pretendard-$w.otf'));
    }
    await loader.load();
  });

  group('진행 계산 (30초 기준)', () {
    test('시안 ①~④ 시각의 %', () {
      expect((loadingProgress(_s(4)) * 100).floor(), inInclusiveRange(18, 22));
      expect((loadingProgress(_s(13)) * 100).floor(), inInclusiveRange(58, 62));
      expect((loadingProgress(_s(20)) * 100).floor(), inInclusiveRange(81, 85));
      expect((loadingProgress(_s(29)) * 100).floor(), 99);
      // 30초를 넘겨도 99%에서 멈춘다 — 100%는 서버가 답했을 때만
      expect(loadingProgress(_s(90)), 0.99);
      // 처음엔 빨리, 끝으로 갈수록 천천히
      expect(
        loadingProgress(_s(5)) - loadingProgress(_s(0)),
        greaterThan(loadingProgress(_s(25)) - loadingProgress(_s(20))),
      );
    });

    test('단계 나누기 0~8 읽기 · 8~15 갑구 · 15~22 을구 · 22~28 판례 · 그 뒤 마무리', () {
      expect(loadingStageAt(_s(4)), LoadingStage.read);
      expect(loadingStageAt(_s(13)), LoadingStage.gap);
      expect(loadingStageAt(_s(20)), LoadingStage.eul);
      expect(loadingStageAt(_s(25)), LoadingStage.precedent);
      expect(loadingStageAt(_s(29)), LoadingStage.finish);
      expect(loadingStageAt(_s(120)), LoadingStage.finish);
    });

    test('쪽수 — 올린 장수가 1·3·8장일 때', () {
      for (final n in [1, 3, 8]) {
        expect(loadingPageAt(Duration.zero, n), 1);
        expect(loadingPageAt(_s(7.99), n), n);
        expect(loadingPageAt(_s(20), n), n);
        // 읽기 동안 고르게 오르고 N을 넘지 않는다
        var last = 0;
        for (var ms = 0; ms <= 8000; ms += 100) {
          final p = loadingPageAt(Duration(milliseconds: ms), n);
          expect(p, inInclusiveRange(last, n));
          last = p;
        }
      }
      expect(loadingPageAt(_s(4), 5), 3); // 시안 ① "3 / 5쪽"
    });

    test('남은 초', () {
      expect(loadingTimeText(_s(4)), '약 26초 남았어요');
      expect(loadingTimeText(_s(29)), '약 1초 남았어요');
      expect(loadingTimeText(_s(31)), '거의 다 됐어요');
    });

    test('세이프 10초 한 바퀴', () {
      expect(inspectFrameAt(0), 0);
      expect(inspectFrameAt(2.7), 1);
      expect(inspectFrameAt(3.0), 2);
      expect(inspectFrameAt(3.6), 3);
      expect(inspectFrameAt(4.2), 2);
      expect(inspectFrameAt(9.8), 1);
      expect(inspectFrameAt(10.1), 0);
    });
  });

  group('리포트 꿀팁 문구', () {
    test('굵게는 팁마다 1곳', () {
      for (final tip in kLoadingTips) {
        expect('**'.allMatches(tip).length, 2, reason: tip);
      }
    });

    for (final scale in [1.0, 1.3]) {
      test('글자 $scale배에서도 카드 본문 3줄 안 (폭 360 화면)', () {
        // 카드 폭 360-20*2, 안쪽 18*2 → 본문 폭 284
        for (final tip in kLoadingTips) {
          final painter = TextPainter(
            text: keepAllSpan(
              TextSpan(
                style: kTipBodyStyle,
                children: tipSpans(
                  tip,
                  bold: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            textDirection: TextDirection.ltr,
            textScaler: TextScaler.linear(scale),
          )..layout(maxWidth: 284);
          final lines = painter.computeLineMetrics().length;
          expect(lines, lessThanOrEqualTo(3), reason: '$tip → $lines줄');
          painter.dispose();
        }
      });
    }
  });

  group('화면', () {
    testWidgets('시안 ①~④: 제목 · 쪽수 · % · 남은 초', (tester) async {
      await _open(tester);
      await tester.pump(_s(4));
      expect(find.koText('AI가 등기부를 한 장씩 읽고 있어요'), findsOneWidget);
      expect(_textOf(tester, 'loading-page'), '3 / 5쪽');
      expect(_textOf(tester, 'loading-time'), '약 26초 남았어요');
      expect(find.koText(kLoadingTipsTitle), findsOneWidget);

      await tester.pump(_s(9));
      expect(find.koText('집주인과 압류를 살펴보고 있어요'), findsOneWidget);
      expect(_textOf(tester, 'loading-page'), '5 / 5쪽');
      await tester.pump(_s(7));
      expect(find.koText('집에 걸린 빚을 살펴보고 있어요'), findsOneWidget);
      await tester.pump(_s(9));
      expect(find.koText('리포트를 정리하고 있어요'), findsOneWidget);
      expect(_textOf(tester, 'loading-percent'), '99%');
      expect(tester.takeException(), isNull);
    });

    test('단계 제목이 360 폭에서 한 줄 (글자 줄이지 않고)', () {
      for (final st in LoadingStage.values) {
        final painter = TextPainter(
          text: TextSpan(
            text: keepAll(st.title),
            style: const TextStyle(
              fontFamily: 'Pretendard',
              fontSize: 19,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        expect(painter.width, lessThanOrEqualTo(320), reason: st.title);
        painter.dispose();
      }
    });

    for (final scale in [1.0, 1.3]) {
      testWidgets('팁이 바뀌어도 다른 요소가 1px도 안 움직인다 (글자 $scale배)', (tester) async {
        await _open(tester, textScale: scale);
        Map<String, Rect> snap() => {
          for (final k in [
            'loading-mascot',
            'loading-percent',
            'loading-tip-card',
          ])
            k: tester.getRect(find.byKey(ValueKey(k))),
          'steps': tester.getRect(find.byType(LoadingSteps)),
          'bar': tester.getRect(find.byType(LoadingBar)),
        };
        await tester.pump(_s(1));
        final first = snap();
        // 팁을 모두 거친다 (6초마다)
        for (var i = 0; i < kLoadingTips.length; i++) {
          await tester.pump(_s(6));
          await tester.pump(_s(0.5)); // 바뀌는 중간도 본다
          final now = snap();
          for (final k in first.keys) {
            if (k == 'loading-mascot') {
              // 세이프는 통통(4px)만 — 왼쪽·폭·높이는 그대로
              expect(now[k]!.left, closeTo(first[k]!.left, 0.01));
              expect(now[k]!.width, closeTo(first[k]!.width, 0.01));
              expect(now[k]!.height, closeTo(first[k]!.height, 0.01));
            } else {
              expect(now[k], first[k], reason: '$k (팁 ${i + 1})');
            }
          }
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('세이프 그림이 바뀌어도 자리·크기 그대로, 4장 모두 나온다', (tester) async {
      await _open(tester);
      final seen = <int>{};
      Rect? base;
      for (var ms = 0; ms < 10000; ms += 100) {
        await tester.pump(const Duration(milliseconds: 100));
        seen.add(_visibleFrame(tester));
        final r = tester.getRect(find.byKey(const ValueKey('loading-mascot')));
        base ??= r;
        expect(r.left, closeTo(base.left, 0.01));
        expect(r.width, closeTo(base.width, 0.01));
        expect(r.height, closeTo(base.height, 0.01));
        expect((r.top - base.top).abs(), lessThanOrEqualTo(4.01)); // 통통 4px 안
      }
      expect(seen, {0, 1, 2, 3});
    });

    testWidgets('동작 줄이기 — 세이프는 들여다보는 한 장, 화면은 멈춤', (tester) async {
      await _open(tester, reduceMotion: true);
      await tester.pump(_s(4));
      expect(_visibleFrame(tester), 2);
      await tester.pump(_s(5));
      expect(_visibleFrame(tester), 2);
      // 제목·퍼센트는 그대로 바뀐다
      expect(find.koText('집주인과 압류를 살펴보고 있어요'), findsOneWidget);
      // 통통 움직임 멈춤 — 세이프 자리가 그대로
      final a = tester.getRect(find.byKey(const ValueKey('loading-mascot')));
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.getRect(find.byKey(const ValueKey('loading-mascot'))), a);
    });

    testWidgets('일찍 끝나면 남은 단계 체크 + 100% 뒤 0.5초 안에 리포트로', (tester) async {
      final answer = Completer<AnalysisReport>();
      await _open(tester, repo: _Repo(answer));
      await tester.pump(_s(3));
      answer.complete(_report);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(_textOf(tester, 'loading-percent'), '100%');
      expect(find.koText('리포트를 정리하고 있어요'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.koText('리포트 r-1'), findsOneWidget);
    });

    testWidgets('30초를 넘기면 99% · 거의 다 됐어요 · 마무리로 기다린다', (tester) async {
      await _open(tester);
      await tester.pump(_s(45));
      expect(_textOf(tester, 'loading-percent'), '99%');
      expect(_textOf(tester, 'loading-time'), '거의 다 됐어요');
      expect(find.koText('리포트를 정리하고 있어요'), findsOneWidget);
    });
  });
}

final AnalysisReport _report = AnalysisReport(
  id: 'r-1',
  alias: '샘플빌라',
  address: '서울특별시 샘플구 샘플동 1-1',
  analyzedAt: DateTime(2026, 10, 28),
  grade: RiskGrade.caution,
  headline: '확인이 필요해요',
  nextAction: '확인하세요',
  topRiskSummary: '선순위 채권',
  deposit: 120000000,
  marketPrice: null,
  seniorDebtAmount: 0,
  gaugeProgress: 0.5,
  evidences: const [],
);
