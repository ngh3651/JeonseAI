// 판례 화면 '이 매물에서 눈에 띈 위험' = 이 집에 **실제로 걸린 문제** (2026-10-29 QA).
//
// 서버가 보낸 riskTags를 그대로 쓰고, 없는 옛 기록은 카드 상세의 **건수**로만 고른다 —
// "신탁·압류·경매는 없었어요" 같은 문장 속 글자나, 모든 집의 보증보험 '확인 필요'로 고르지 않는다.
import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/models/analysis_report.dart';

Map<String, dynamic> _report({
  List<String>? riskTags,
  required List<Map<String, dynamic>> evidences,
}) => {
  'id': 'r1',
  'alias': '샘플빌라',
  'address': '서울특별시 샘플구 샘플로 1',
  'analyzedAt': '2026-10-29T10:00:00+09:00',
  'grade': '확인 필요',
  'gaugeProgress': 0.5,
  'headline': '확인할 게 몇 가지 있어요',
  'nextAction': '확인하세요',
  'topRiskSummary': '사진 다시 확인 필요',
  'deposit': 200000000,
  'marketPrice': 400000000,
  'seniorDebtAmount': 0,
  'evidences': evidences,
  'riskTags': ?riskTags,
};

Map<String, dynamic> _ev(
  String id,
  String grade, {
  String? detail,
  String? status,
}) => {
  'id': id,
  'title': id,
  'termSubtitle': id,
  'grade': grade,
  'statusLabel': status,
  'easyExplanation': '설명',
  'detailText': detail,
};

void main() {
  test('서버 riskTags가 있으면 그대로 쓴다', () {
    final r = AnalysisReport.fromJson(
      _report(
        riskTags: ['압류·가압류', '경매'],
        evidences: [_ev('insurance', '확인 필요')],
      ),
    );
    expect(r.riskLabels, ['압류·가압류', '경매']);
  });

  test('riskTags 빈 목록 = 걸린 문제 없음 (보증보험 확인 필요로 채우지 않는다)', () {
    final r = AnalysisReport.fromJson(
      _report(
        riskTags: [],
        evidences: [_ev('insurance', '확인 필요'), _ev('ownership', '확인 필요')],
      ),
    );
    expect(r.riskLabels, isEmpty);
  });

  test('옛 기록: "없었어요" 문장과 보증보험 구조적 확인 필요는 위험이 아니다', () {
    final r = AnalysisReport.fromJson(
      _report(
        evidences: [
          _ev(
            'ownership',
            '확인 필요',
            status: '확인 필요',
            detail: '지금 살아 있는 신탁등기·압류·가압류·가처분·경매개시결정은 없었어요 (이미 지워진 건 뺐어요)',
          ),
          _ev('insurance', '확인 필요', status: '확인 필요'),
          _ev(
            'jeonse_ratio',
            '확인 필요',
            status: '확인 필요',
            detail: '보증금이 시세의 50%예요 · 1쪽이 빠졌어요 — 그래서 결과를 확정하지 않았어요',
          ),
          _ev(
            'senior_debt',
            '확인 필요',
            status: '확인 필요',
            detail: '지금 살아 있는 빚 0원 · 0건 (이미 지워진 빚은 뺐어요)',
          ),
        ],
      ),
    );
    expect(r.riskLabels, isEmpty);
  });

  test('옛 기록: 건수가 있는 것만 고른다', () {
    final r = AnalysisReport.fromJson(
      _report(
        evidences: [
          _ev(
            'ownership',
            '위험',
            detail: '가압류 1건 · 경매개시결정 1건 (지금 살아 있는 것만 세었어요)',
          ),
          _ev(
            'senior_debt',
            '위험',
            detail: '지금 살아 있는 빚 1억 8,000만원 · 2건 · 임차권등기 1건 (이미 지워진 빚은 뺐어요)',
          ),
          _ev(
            'jeonse_ratio',
            '위험',
            detail: '보증금이 시세의 92%예요 — 보증금 3억 / 시세 3억 2,600만원',
          ),
          _ev('insurance', '위험', detail: '보증보험에 못 들 수 있는 신호: 가압류 1건'),
        ],
      ),
    );
    expect(
      r.riskLabels,
      unorderedEquals(['압류·가압류', '경매', '선순위 채권', '임차권등기', '전세가율', '보증보험']),
    );
  });
}
