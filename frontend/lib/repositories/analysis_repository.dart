/// 분석 저장소 인터페이스 — **화면(위젯)은 이 인터페이스에만 의존한다** (CLAUDE.md 4절).
///
/// Phase C: DummyAnalysisRepository (로컬 더미)
/// Phase D~: ApiAnalysisRepository (서버 호출) 로 구현만 교체한다.
library;

import 'package:flutter/foundation.dart';

import '../models/analysis_report.dart';
import '../models/risk_grade.dart';
import '../utils/money_format.dart';

/// ChangeNotifier — 이력이 바뀌면(분석·삭제) 구독 중인 홈 등이 갱신된다.
abstract class AnalysisRepository extends ChangeNotifier {
  /// 등기부 이미지 + 입력값(보증금 등)으로 분석을 실행하고 이력에 추가한다.
  Future<AnalysisReport> analyze(AnalysisRequest request);

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
class DummyAnalysisRepository extends AnalysisRepository {
  /// 예시 1 — 위험 매물 (7일 전 분석: 재열람 배너 확인용).
  /// analyze()도 이 빌더로 새 리포트를 만든다 — 사용자 입력(보증금·시세·별칭)만 바뀜.
  static final AnalysisReport _dangerReport = _buildDangerReport(
    id: 'dummy-danger',
    alias: '역삼동 오피스텔',
    analyzedAt: DateTime.now().subtract(const Duration(days: 7)),
    deposit: 120000000,
    marketPrice: 200000000,
  );

  /// 위험 템플릿 리포트를 사용자 입력으로 채워 만든다.
  /// 근저당·신탁 등 등기 근거는 예시 고정이고, 보증금·시세 의존 항목만 입력을 반영한다.
  static AnalysisReport _buildDangerReport({
    required String id,
    required String alias,
    required DateTime analyzedAt,
    required int deposit,
    int? marketPrice,
    String address = '서울 강남구 역삼동 123-45', // 실단계: 표제부 추출 주소
  }) {
    const seniorDebt = 180000000; // 예시 채권최고액

    // 전세가율 근거 — 시세가 있으면 계산해 보여주고, 없으면 '확인 필요'
    final EvidenceItem jeonseEvidence = marketPrice != null
        ? EvidenceItem(
            id: 'jeonse_ratio',
            title: '보증금이 집값에 비해 높지 않나요?',
            termSubtitle: '전세가율',
            grade: RiskGrade.caution,
            easyExplanation:
                '보증금이 입력하신 시세의 ${(deposit / marketPrice * 100).round()}%를 '
                '차지해요(전세가율). 시세가 내려가면 보증금을 다 돌려받기 어려울 수 있어요.',
            detailText:
                '전세가율 ${(deposit / marketPrice * 100).round()}% — '
                '보증금 ${formatWon(deposit)} / 입력 시세 ${formatWon(marketPrice)} '
                '(예시 · 위험 기준선은 출처 확정 후 표시)',
            sourceText: 'HUG 공식 기준 등 확정 예정',
            termGlossary: const {
              '전세가율':
                  '보증금이 집값의 몇 %인지 나타내는 비율이에요. 높을수록 '
                  '집값이 떨어졌을 때 보증금을 돌려받기 어려워져요.',
            },
          )
        : const EvidenceItem(
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
          );

    return AnalysisReport(
      id: id,
      alias: alias,
      address: address,
      analyzedAt: analyzedAt,
      grade: RiskGrade.danger,
      headline: '보증금을 지키기 어려운 신호가 보여요',
      // 상담처 전화번호는 Phase F에서 공식 홈페이지로 확인 후 병기
      nextAction: '계약 전에 HUG 안심전세포털·대한법률구조공단 등에서 전문가 상담부터 받으세요',
      topRiskSummary: '먼저 갚을 빚 신호 2건 · 소유권 이상',
      deposit: deposit,
      marketPrice: marketPrice,
      seniorDebtAmount: seniorDebt,
      gaugeProgress: 0.22,
      evidences: [
        const EvidenceItem(
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
        const EvidenceItem(
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
        jeonseEvidence,
        const EvidenceItem(
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
        const EvidenceItem(
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
  }

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

  // 이력은 기기 로컬 단일 저장, 계정 구분 없음 (decisions.md 2026-07-03).
  // 시연 시작 시 위험·확인 필요 2건이 이미 있는 상태로 보여준다 (비교 컷).
  final List<AnalysisReport> _history = [_cautionReport, _dangerReport];

  @override
  Future<AnalysisReport> analyze(AnalysisRequest request) async {
    // 더미: 실제 추출·판정 대신, 시연 임팩트가 큰 '위험' 템플릿을 사용자 입력으로 채워
    // 새 리포트를 만든다. (실단계 E-1에서 규칙 엔진 판정으로 교체)
    final report = _buildDangerReport(
      id: 'analysis-${DateTime.now().millisecondsSinceEpoch}',
      alias: (request.alias?.trim().isNotEmpty ?? false)
          ? request.alias!.trim()
          : '역삼동 오피스텔', // 실단계에선 표제부 추출 주소가 기본 별칭
      analyzedAt: DateTime.now(),
      deposit: request.deposit,
      marketPrice: request.marketPrice,
    );
    _history.insert(0, report);
    notifyListeners();
    return report;
  }

  @override
  Future<List<AnalysisReport>> getHistory() async =>
      List.unmodifiable(_history);

  @override
  Future<AnalysisReport?> getReport(String id) async {
    for (final r in _history) {
      if (r.id == id) return r;
    }
    return null;
  }

  @override
  Future<void> deleteReport(String id) async {
    _history.removeWhere((r) => r.id == id);
    notifyListeners();
  }
}
