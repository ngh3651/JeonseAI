/// 분석 저장소 인터페이스 — **화면(위젯)은 이 인터페이스에만 의존한다** (CLAUDE.md 4절).
///
/// Phase C: DummyAnalysisRepository (로컬 더미)
/// Phase D~: ApiAnalysisRepository (서버 호출) 로 구현만 교체한다.
library;

import '../models/analysis_report.dart';
import '../models/risk_grade.dart';

abstract class AnalysisRepository {
  /// 등기부 이미지 + 입력값(보증금 등)으로 분석을 실행한다.
  /// 상세 요청 파라미터는 C-3(S-04 화면)에서 확정.
  Future<AnalysisReport> analyze();

  /// 최근 분석 이력 (최신순).
  Future<List<AnalysisReport>> getHistory();

  /// 리포트 단건 조회 (이력 재열람).
  Future<AnalysisReport?> getReport(String id);

  /// 이력 삭제.
  Future<void> deleteReport(String id);
}

/// 더미 구현 — 위험 vs 확인 필요 2세트 (plan.md C-2: 시나리오 B 대비 컷의 원형).
///
/// 모든 수치·등급은 **예시**다. 실제 판정은 E-1 규칙 엔진이 출처 기반 기준으로 내린다.
class DummyAnalysisRepository implements AnalysisRepository {
  /// 예시 1 — 위험 매물 (7일 전 분석: 재열람 배너 확인용)
  static final AnalysisReport _dangerReport = AnalysisReport(
    id: 'dummy-danger',
    alias: '역삼동 오피스텔',
    address: '서울 강남구 역삼동 123-45',
    analyzedAt: DateTime.now().subtract(const Duration(days: 7)),
    grade: RiskGrade.danger,
    headline: '보증금을 지키기 어려운 신호가 보여요',
    // 상담처 전화번호는 Phase F에서 공식 홈페이지로 확인 후 병기
    nextAction: '계약 전에 HUG 안심전세포털·대한법률구조공단 등에서 전문가 상담부터 받으세요',
    topRiskSummary: '먼저 갚을 빚 신호 2건 · 소유권 이상',
    deposit: 120000000,
    marketPrice: 200000000,
    seniorDebtAmount: 180000000,
    gaugeProgress: 0.22,
    evidences: const [
      EvidenceItem(
        id: 'senior_debt',
        title: '나보다 먼저 돈 받아갈 빚이 있나요?',
        termSubtitle: '선순위 채권 · 근저당권',
        grade: RiskGrade.danger,
        easyExplanation:
            '이 집에는 은행 빚(근저당권)이 크게 잡혀 있어요. 집이 경매로 넘어가면 '
            '은행이 먼저 돈을 받아가고, 남는 금액에서 보증금을 돌려받게 돼요.',
        detailText:
            '은행이 최대 받아갈 수 있다고 걸어둔 금액(채권최고액) '
            '1억 8,000만원 · 근저당권 2건 (예시)',
        termGlossary: {
          '근저당권':
              '집주인이 집을 담보로 돈을 빌렸다는 표시예요. 집이 경매로 '
              '넘어가면 돈을 빌려준 쪽(주로 은행)이 세입자보다 먼저 돈을 받아갈 수 있어요.',
        },
        sourceText: 'HUG 공식 기준 등 확정 예정',
        actionLabel: '중개사에게 물어볼 질문 보기',
      ),
      EvidenceItem(
        id: 'ownership',
        title: '집 소유권에 이상 신호가 있나요?',
        termSubtitle: '신탁등기 · 압류 · 가압류',
        grade: RiskGrade.danger,
        easyExplanation:
            '신탁등기가 설정되어 있어요. 집주인 마음대로 전세 계약을 '
            '맺지 못할 수 있어서, 신탁회사의 동의가 있었는지 꼭 확인해야 해요.',
        detailText: '신탁등기 1건 (예시)',
        termGlossary: {
          '신탁등기':
              '집의 관리 권한을 신탁회사에 맡겼다는 표시예요. 이 경우 '
              '집주인 단독으로는 전세 계약을 맺을 수 없는 경우가 많아요.',
        },
        sourceText: 'HUG 공식 기준 등 확정 예정',
        actionLabel: '중개사에게 물어볼 질문 보기',
      ),
      EvidenceItem(
        id: 'jeonse_ratio',
        title: '보증금이 집값에 비해 높지 않나요?',
        termSubtitle: '전세가율',
        grade: RiskGrade.caution,
        easyExplanation:
            '보증금이 입력하신 시세의 60%를 차지해요(전세가율). '
            '시세가 내려가면 보증금을 다 돌려받기 어려울 수 있어요.',
        detailText:
            '전세가율 60% — 보증금 1억 2,000만원 / 입력 시세 2억원 '
            '(예시 · 위험 기준선은 출처 확정 후 표시)',
        sourceText: 'HUG 공식 기준 등 확정 예정',
        termGlossary: {
          '전세가율':
              '보증금이 집값의 몇 %인지 나타내는 비율이에요. 높을수록 '
              '집값이 떨어졌을 때 보증금을 돌려받기 어려워져요.',
        },
      ),
      EvidenceItem(
        id: 'insurance',
        title: '보증보험에 가입할 수 있나요?',
        termSubtitle: '전세보증금 반환보증 (HUG 등)',
        grade: RiskGrade.caution,
        statusLabel: '확인 필요',
        easyExplanation:
            '등기부만으로는 가입 가능 여부를 단정할 수 없어요. '
            '가입 요건은 보증기관에서 직접 확인이 필요해요.',
        sourceText: 'HUG 공식 기준 등 확정 예정',
        actionLabel: '중개사에게 물어볼 질문 보기',
      ),
      EvidenceItem(
        id: 'blacklist',
        title: '집주인이 위험 명단에 있나요?',
        termSubtitle: '악성임대인 공개 명단',
        grade: RiskGrade.ok,
        easyExplanation:
            '공개 명단에서 발견되지 않았어요. 다만 명단에 없다고 '
            '안전이 보장되는 건 아니에요 — 아래 질문으로 직접 확인하세요.',
        sourceText: 'HUG 공식 기준 등 확정 예정',
        actionLabel: '중개사에게 물어볼 질문 보기',
      ),
    ],
  );

  /// 예시 2 — 확인 필요 매물 (오늘 분석, 시세 미입력)
  static final AnalysisReport _cautionReport = AnalysisReport(
    id: 'dummy-caution',
    alias: '정자동 빌라',
    address: '경기 성남시 분당구 정자동 456-7',
    analyzedAt: DateTime.now().subtract(const Duration(hours: 1)),
    grade: RiskGrade.caution,
    headline: '몇 가지를 확인한 뒤 결정해도 늦지 않아요',
    nextAction: '보류하고, 아래 질문을 중개사에게 확인한 뒤 결정하세요',
    topRiskSummary: '시세를 입력하면 결과가 더 정확해져요',
    deposit: 300000000,
    marketPrice: null,
    seniorDebtAmount: 50000000,
    gaugeProgress: 0.55,
    evidences: const [
      EvidenceItem(
        id: 'jeonse_ratio',
        title: '보증금이 집값에 비해 높지 않나요?',
        termSubtitle: '전세가율',
        grade: RiskGrade.caution,
        statusLabel: '확인 필요',
        easyExplanation:
            '시세를 입력하지 않아 아직 계산할 수 없어요. '
            '국토부 실거래가·KB시세에서 확인한 금액을 입력하면 바로 알려드릴게요.',
        sourceText: 'HUG 공식 기준 등 확정 예정',
        actionLabel: '시세 입력하기',
      ),
      EvidenceItem(
        id: 'senior_debt',
        title: '나보다 먼저 돈 받아갈 빚이 있나요?',
        termSubtitle: '선순위 채권 · 근저당권',
        grade: RiskGrade.ok,
        easyExplanation:
            '등기부에서 큰 빚은 보이지 않았어요. '
            '다만 계약 직전에는 최신 등기부로 다시 확인하세요.',
        detailText: '근저당권 1건 · 채권최고액 5,000만원 (예시)',
        sourceText: 'HUG 공식 기준 등 확정 예정',
      ),
      EvidenceItem(
        id: 'ownership',
        title: '집 소유권에 이상 신호가 있나요?',
        termSubtitle: '신탁등기 · 압류 · 가압류',
        grade: RiskGrade.ok,
        easyExplanation: '압류·가압류·신탁 같은 이상 신호는 보이지 않았어요. (예시)',
        sourceText: 'HUG 공식 기준 등 확정 예정',
      ),
      EvidenceItem(
        id: 'insurance',
        title: '보증보험에 가입할 수 있나요?',
        termSubtitle: '전세보증금 반환보증 (HUG 등)',
        grade: RiskGrade.caution,
        statusLabel: '확인 필요',
        easyExplanation:
            '등기부만으로는 가입 가능 여부를 단정할 수 없어요. '
            '가입 요건은 보증기관에서 직접 확인이 필요해요.',
        sourceText: 'HUG 공식 기준 등 확정 예정',
        actionLabel: '중개사에게 물어볼 질문 보기',
      ),
      EvidenceItem(
        id: 'blacklist',
        title: '집주인이 위험 명단에 있나요?',
        termSubtitle: '악성임대인 공개 명단',
        grade: RiskGrade.ok,
        easyExplanation:
            '공개 명단에서 발견되지 않았어요. 다만 명단에 없다고 '
            '안전이 보장되는 건 아니에요 — 아래 질문으로 직접 확인하세요.',
        sourceText: 'HUG 공식 기준 등 확정 예정',
        actionLabel: '중개사에게 물어볼 질문 보기',
      ),
    ],
  );

  List<AnalysisReport> get _all => [_cautionReport, _dangerReport]; // 최신순

  @override
  Future<AnalysisReport> analyze() {
    // S-04(매물 검색) 화면과 함께 C-3에서 연결
    throw UnimplementedError('C-3에서 구현');
  }

  @override
  Future<List<AnalysisReport>> getHistory() async => _all;

  @override
  Future<AnalysisReport?> getReport(String id) async {
    for (final r in _all) {
      if (r.id == id) return r;
    }
    return null;
  }

  @override
  Future<void> deleteReport(String id) async {}
}
