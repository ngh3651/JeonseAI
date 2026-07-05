// D-3 라이브 파리티 테스트 — **로컬 서버가 켜져 있을 때만** 명시적으로 실행한다:
//   (backend)  .\.venv\Scripts\python.exe -m uvicorn app.main:app --port 8000
//   (frontend) flutter test test_live/api_live_test.dart
//
// 목적: Api 리포지토리가 서버 응답을 앱 모델로 정확히 파싱하고, 내용이
// 기존 앱 더미와 100% 일치하는지(=화면이 지금과 똑같이 나올지) 확인한다.
// 기본 `flutter test`(test/ 폴더)에는 포함되지 않는다 — 서버 의존이라 분리.
import 'package:flutter_test/flutter_test.dart';

import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/api_analysis_repository.dart';
import 'package:jeonse_ai/repositories/api_content_repository.dart';
import 'package:jeonse_ai/services/api_client.dart';

void main() {
  final analysis = ApiAnalysisRepository();
  final content = ApiContentRepository();

  test('이력 목록: 예시 2건이 앱 더미와 동일 (최신순)', () async {
    final history = await analysis.getHistory();
    expect(history.length, greaterThanOrEqualTo(2));
    expect(history[0].id, 'dummy-caution');
    expect(history[0].alias, '정자동 빌라');
    expect(history[0].grade, RiskGrade.caution);
    expect(history[0].deposit, 300000000);
    expect(history[0].marketPrice, isNull);
    expect(history[1].id, 'dummy-danger');
    expect(history[1].alias, '역삼동 오피스텔');
    expect(history[1].grade, RiskGrade.danger);
  });

  test('리포트 단건: 근거 5종·용어 툴팁·문구가 앱 더미와 동일', () async {
    final report = (await analysis.getReport('dummy-danger'))!;
    expect(report.headline, '보증금을 지키기 어려운 신호가 보여요');
    expect(report.topRiskSummary, '먼저 갚을 빚 신호 2건 · 소유권 이상');
    expect(report.seniorDebtAmount, 180000000);
    expect(report.gaugeProgress, closeTo(0.22, 1e-9));
    expect(report.evidences.map((e) => e.id).toList(), [
      'senior_debt',
      'ownership',
      'jeonse_ratio',
      'insurance',
      'blacklist',
    ]);
    final senior = report.evidences.first;
    expect(senior.grade, RiskGrade.danger);
    expect(senior.title, '나보다 먼저 돈 받아갈 빚이 있나요?');
    expect(senior.termGlossary.containsKey('근저당권'), isTrue);
    expect(
      report.evidences[2].detailText,
      contains('전세가율 60%'), // 1.2억/2억 계산 파리티
    );
    // 위험 패턴 파생(앱 파생 로직) — 판례·질문 화면 칩과 동일해야 함
    expect(report.riskLabels, ['선순위 채권', '신탁등기', '전세가율', '보증보험']);
  });

  test('없는 리포트 id → null (404 매핑)', () async {
    expect(await analysis.getReport('does-not-exist'), isNull);
  });

  test('판례: 위험 리포트 → 2건, 패턴이 앱 더미와 동일', () async {
    final cases = await content.matchedCases('dummy-danger');
    expect(cases.map((c) => c.riskPattern).toList(), ['신탁등기', '선순위 채권']);
    expect(cases.first.result, '임차인이 보증금을 돌려받지 못함');
  });

  test('질문: 위험 리포트 → 3그룹 / 확인필요 리포트 → 기본 그룹만', () async {
    final dangerGroups = await content.questionGroups('dummy-danger');
    expect(dangerGroups.map((g) => g.riskLabel).toList(), [
      '신탁등기',
      '선순위 채권 · 근저당',
      '어떤 집이든 꼭',
    ]);
    // 확인필요 매물: 위험 패턴이 전세가율·보증보험뿐 → 전용 그룹 없음, 기본만
    final cautionGroups = await content.questionGroups('dummy-caution');
    expect(cautionGroups.map((g) => g.riskLabel).toList(), ['어떤 집이든 꼭']);
  });

  test('여정: 7단계 제목이 앱 더미와 동일', () async {
    final stages = await content.journeyStages();
    expect(stages.map((s) => s.title).toList(), [
      '계약 전',
      '계약 체결',
      '잔금일',
      '입주하고 나서 꼭 할 일',
      '보증보험 가입',
      '만기 전',
      '보증금 반환',
    ]);
  });

  test('용어: 목록 6개 / 조회 성공 / 범위 밖 → null(404)', () async {
    final terms = await content.glossaryTerms();
    expect(terms.map((t) => t.term).toList(), [
      '신탁등기',
      '근저당',
      '전세가율',
      '확정일자',
      '대항력',
      '우선변제권',
    ]);
    final found = await content.lookupTerm('신탁등기가 뭐예요?');
    expect(found!.term, '신탁등기');
    expect(await content.lookupTerm('이 집 계약해도 돼요?'), isNull);
  });

  test('예시 리포트 삭제 → 403 ApiException (계약 §3.4)', () async {
    await expectLater(
      analysis.deleteReport('dummy-danger'),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 403),
      ),
    );
  });
}
