// 라이브 스모크 테스트 — **로컬 서버가 켜져 있을 때만** 명시적으로 실행한다:
//   (backend)  .\.venv\Scripts\python.exe -m uvicorn app.main:app --port 8000
//   (frontend) flutter test test_live/api_live_test.dart
//
// 기본 `flutter test`(test/ 폴더)에는 포함되지 않는다 — 서버 의존이라 분리했다.
//
// 2026-08-14(D13) 개편: 원래 이 파일은 D-3 시절 **"서버 더미가 앱 더미와 글자까지
// 같은가"** 를 재는 파리티 테스트였다. E-1에서 실판정이, E-2·E-3에서 실문구·실판례가
// 붙으면서 그 전제는 사라졌고(앱은 이제 실제 분석을 받는다), 예시 리포트도 손으로 적은
// 2건에서 **규칙 엔진이 만드는 1건**으로 바뀌었다. 그래서 목적을 바꿨다 —
// 이제 이 파일이 재는 것은 **Api 리포지토리가 서버 응답을 앱 모델로 제대로 푸는가**다.
//
// ⚠ 예시 리포트의 문구·수치는 규칙 엔진 산출물이라 기준이 바뀌면 함께 바뀐다.
//   그래서 문장을 그대로 비교하지 않고 **모양(등급·필드 유무·개수)** 만 본다.
//   판정값 자체는 백엔드 `tests/test_example_report.py`가 지킨다.
import 'package:flutter_test/flutter_test.dart';

import 'package:jeonse_ai/models/content_models.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/api_analysis_repository.dart';
import 'package:jeonse_ai/repositories/api_content_repository.dart';
import 'package:jeonse_ai/services/api_client.dart';

const String kExampleId = 'dummy-example';

void main() {
  final analysis = ApiAnalysisRepository();
  final content = ApiContentRepository();

  test('이력 목록: 예시 리포트 1건이 양호로 온다', () async {
    final history = await analysis.getHistory();
    expect(history, isNotEmpty);

    final example = history.firstWhere((r) => r.id == kExampleId);
    expect(example.grade, RiskGrade.ok, reason: '홈에서 실제 분석(위험)과 대비되는 자리다');
    expect(example.seniorDebtAmount, 0);
    expect(example.marketPrice, isNotNull);
    expect(example.alias, isNotEmpty);
  });

  test('리포트 단건: 근거 5종이 모두 오고 판정 필드가 채워진다', () async {
    final report = (await analysis.getReport(kExampleId))!;

    expect(report.evidences.map((e) => e.id).toSet(), {
      'jeonse_ratio',
      'senior_debt',
      'ownership',
      'insurance',
      'blacklist',
    });
    // 심각한 것부터 — 규칙 엔진의 정렬 규칙(_SEVERITY_ORDER)이 응답에 살아 있는지.
    expect(report.evidences.first.grade, isNot(RiskGrade.ok));
    // 모든 근거에 출처가 붙어 있어야 한다 ("근거 없는 말은 하지 않는다").
    for (final e in report.evidences) {
      expect(e.sourceText, isNotNull, reason: '${e.id}에 출처가 없다');
      expect(e.easyExplanation, isNotEmpty);
    }
    expect(report.headline, isNotEmpty);
    expect(report.topRiskSummary, isNotEmpty);
  });

  test('없는 리포트 id → null (404 매핑)', () async {
    expect(await analysis.getReport('does-not-exist'), isNull);
  });

  test('판례: 깨끗한 매물이라 매칭이 없어도 500이 아니다', () async {
    // 위험 패턴이 없으면 빈 목록이 정상이다 — 앱은 "딱 맞는 판례가 아직 없어요"를 띄운다.
    // (D7: 임베딩·검색·설명이 터져도 500 대신 빈 목록)
    final cases = await content.matchedCases(kExampleId);
    expect(cases, isA<List>());
  });

  test('질문: 위험 패턴이 없어도 기본 그룹은 온다', () async {
    final groups = await content.questionGroups(kExampleId);
    expect(groups, isNotEmpty);
    expect(groups.map((g) => g.riskLabel), contains('어떤 집이든 꼭'));
  });

  test('여정: 9단계 + 대조 버튼 플래그 (2026-08-14 S-11 재설계)', () async {
    final stages = await content.journeyStages();

    expect(stages.length, 9);
    expect(stages.first.title, '집 둘러보고 등기부 분석하기');
    expect(stages.first.kind, JourneyStageKind.analysis);
    // 등기부를 다시 떼는 단계는 2·3·4·6단계 — 이 화면의 존재 이유다
    expect(stages.where((s) => s.compare).length, 4);
    expect(stages.any((s) => s.dateKey == JourneyDateKey.balance), isTrue);
  });

  test('용어: 목록 조회 / 사전 직격 / 판정 요구 거절 (2026-08-14 S-12)', () async {
    final terms = await content.glossaryTerms();
    expect(terms, isNotEmpty);
    expect(terms.map((t) => t.term), contains('신탁등기'));

    // ① 사전에 있는 용어 → 검수된 문장 그대로 (LLM 호출 0회)
    final found = await content.askGlossary('신탁등기가 뭐예요?');
    expect(found.term, '신탁등기');
    expect(found.outOfScope, isFalse);
    expect(found.source, '검수된 용어 사전');

    // ② 판정 요구 → **200 + 거절**(404 아님). LLM에 닿기 전에 규칙이 막는다.
    final refused = await content.askGlossary('이 집 계약해도 돼요?');
    expect(refused.outOfScope, isTrue);
    expect(refused.term, isNull);
    expect(refused.answer, contains('안전도 리포트'));
  });

  test('예시 리포트 삭제 → 403 ApiException (계약 §3.4)', () async {
    await expectLater(
      analysis.deleteReport(kExampleId),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 403),
      ),
    );
  });
}
