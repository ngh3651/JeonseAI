/// 뷰어 테스트용 공통 재료 — 실제 등기부와 같은 구성을 흉내 낸다.
///
/// 집주인 이름 1 + 근저당 3 (= 표시 4곳, 그중 **위험은 3곳**), 그리고 말소 1건.
/// 이 조합이 이 기능에서 가장 많이 틀리는 자리다:
/// 뱃지는 3, 뷰어 표시는 4, 리포트 근저당은 4건 — 셋이 서로 다른 것이 정상이고,
/// 그 이유를 화면이 설명해야 한다.
library;

import 'dart:io';

import 'package:jeonse_ai/models/analysis_report.dart';
import 'package:jeonse_ai/models/compare_result.dart';
import 'package:jeonse_ai/models/risk_grade.dart';
import 'package:jeonse_ai/repositories/analysis_repository.dart';

/// 실기기 기준 화면 (SM-S931N: 1080x2340px, dpr 3 → 360x780dp)
const double kPhoneWidth = 360;
const double kPhoneHeight = 780;

/// 상태바 / 하단 제스처 바 — 앱이 못 쓰는 시스템 영역
const double kStatusBar = 30;
const double kGestureBar = 24;

// ⚠ 주소·별칭은 **지어낸 값**이다. 시안 번들의 실제 등기부 주소를 쓰지 않는다 —
//   그 번들은 실명·실주소가 있어 .gitignore 대상이고, 그 값을 테스트에 옮겨 적으면
//   ignore를 우회해 저장소에 남는다.
AnalysisReport buildFixtureReport() => AnalysisReport(
  id: 'r1',
  alias: '샘플빌라 제101호',
  address: '서울특별시 샘플구 샘플동 1-1 샘플빌라 제101호',
  analyzedAt: DateTime(2026, 7, 27),
  grade: RiskGrade.danger,
  headline: '계약 전 반드시 전문가 확인이 필요해요',
  nextAction: '전문가 상담부터 받으세요',
  topRiskSummary: '선순위 채권',
  deposit: 130000000,
  marketPrice: 200000000,
  seniorDebtAmount: 1400000000,
  gaugeProgress: 0.8,
  evidences: const [],
  highlights: [
    fixtureMark(1, 'owner', 1, 0.45, '집주인 이름 · 주식회사가나다'),
    fixtureMark(2, 'mortgage', 3, 0.25, '집에 잡힌 빚 (근저당권) · 5억원'),
    fixtureMark(3, 'mortgage', 3, 0.62, '집에 잡힌 빚 (근저당권) · 5억원'),
    fixtureMark(4, 'mortgage', 3, 0.77, '집에 잡힌 빚 (근저당권) · 4억원'),
  ],
  checkedNotes: const [
    '집주인 이름 1곳 — 사진에서 찾아 표시했어요',
    '집에 잡힌 빚(근저당) 1건은 **모두 말소된 것으로 확인**해 표시하지 않았어요 — 이미 정리된 빚이에요',
    '압류·가압류·신탁 같은 표시는 없었어요',
  ],
);

/// 본문은 백엔드 `highlight.py`의 실제 문구를 그대로 옮겼다 —
/// 카드 요약이 "첫 문장 자르기"로 제대로 나오는지 보려면 진짜 문장이어야 한다.
RegistryHighlight fixtureMark(
  int badge,
  String kind,
  int page,
  double y,
  String title,
) => RegistryHighlight(
  id: '$kind-$badge',
  page: page,
  kind: kind,
  badge: badge,
  box: HighlightBox(x: 0.5, y: y, w: 0.33, h: 0.02),
  title: title,
  body: kind == 'owner'
      ? '계약서에 적힌 집주인(임대인) 이름, 그리고 계약 자리에 나온 사람의 신분증이 이 이름과 같은지 확인하세요. '
            '하나라도 다르면 그날은 서명하지 마세요.\n대리인이 나왔다면 집주인의 위임장과 인감증명서를 함께 보여 달라고 하세요.'
      : '집이 경매로 넘어가면, 이 돈을 빌려준 곳이 내 보증금보다 먼저 돈을 가져갑니다. 그만큼 내가 못 받을 수 있어요.\n'
            '등기부에 적힌 이 금액은 실제 빚보다 크게 잡아 둔 한도(채권최고액)예요.',
  source: kind == 'owner'
      ? '등기부 갑구 — 이 앱이 사진에서 직접 찾은 위치'
      : '등기부 을구 — 이 앱이 사진에서 직접 찾은 위치',
);

/// 사진 5장을 임시 폴더에 만든다. **내용은 중요하지 않다** — 파일이 존재해야
/// `RegistryPhotoStore.pathsFor`가 경로를 돌려주고 화면이 자리를 잡는다.
/// (디코딩은 실패하고 errorBuilder가 받는다.)
Future<List<String>> writeFixturePhotos(Directory dir, {int count = 5}) async {
  final paths = <String>[];
  for (var i = 0; i < count; i++) {
    final f = File('${dir.path}/page_$i.jpg');
    await f.writeAsBytes(const [0xFF, 0xD8, 0xFF, 0xD9]);
    paths.add(f.path);
  }
  return paths;
}

extension FixtureMarkText on RegistryHighlight {
  /// 본문만 갈아끼운 사본 — 카드 요약 줄 수를 달리 만들 때 쓴다.
  RegistryHighlight copyForTest(String newBody) => RegistryHighlight(
    id: id,
    page: page,
    kind: kind,
    badge: badge,
    box: box,
    title: title,
    body: newBody,
    caution: caution,
    source: source,
  );
}

class FakeAnalysisRepository extends AnalysisRepository {
  FakeAnalysisRepository(this.report);

  final AnalysisReport report;

  @override
  Future<AnalysisReport> analyze(AnalysisRequest request) async => report;

  @override
  Future<List<AnalysisReport>> getHistory() async => [report];

  @override
  Future<AnalysisReport?> getReport(String id) async => report;

  @override
  Future<void> deleteReport(String id) async {}

  /// 이 픽스처의 리포트에는 대조 기준 스냅샷이 없다(서버가 분석하며 남기는 것이다).
  /// 그래서 실기기에서 옛 이력을 눌렀을 때와 같은 "기준 없음" 갈래가 나온다.
  @override
  Future<CompareResult> compareRegistry(
    String reportId,
    List<String> imagePaths,
  ) async => CompareResult(
    outcome: CompareOutcome.noBaseline,
    headline: '이 분석은 비교 기준으로 쓸 수 없어요',
    subline: '지금 한 번 떼어 기준을 만들어 두면, 다음에 뗄 때부터 달라진 점을 알려드릴 수 있어요.',
    baseline: CompareDoc(reportId: reportId, alias: report.alias),
    current: const CompareDoc(),
  );
}

/// **최악 조합** 리포트 — 15종이 전부 등장하고 종류당 상한(5건)도 채운다.
///
/// 왜 따로 두나 (2026-07-28 design-reviewer 지적): [buildFixtureReport]는
/// `owner` + `mortgage`뿐이라 **3종 시절 세계**를 잰다. 하단 크롬(범례·회색 줄)이
/// 15종에서 얼마나 커지는지는 그 픽스처로 절대 드러나지 않는다.
/// 문서 영역 하한 400dp를 지키는 테스트는 **최악 조합으로 재야** 의미가 있다.
AnalysisReport buildWorstCaseReport() {
  const kinds = [
    'address', 'area', 'separate_land', 'doc_title', 'owner',
    'provisional_seizure', 'seizure', 'auction', 'trust',
    'mortgage', 'jeonse', 'lease_registration', 'joint_collateral',
    'pending_application', 'viewed_at',
  ];
  final marks = <RegistryHighlight>[];
  var badge = 1;
  for (final kind in kinds) {
    marks.add(fixtureMark(badge, kind, badge % 4 + 1, 0.1 + (badge % 8) * 0.1,
        '$kind · 최악 조합 표시'));
    badge++;
  }
  return AnalysisReport(
    id: 'r1',
    alias: '샘플빌라 제101호',
    address: '서울특별시 샘플구 샘플동 1-1 샘플빌라 제101호',
    analyzedAt: DateTime(2026, 7, 27),
    grade: RiskGrade.danger,
    headline: '계약 전 반드시 전문가 확인이 필요해요',
    nextAction: '전문가 상담부터 받으세요',
    topRiskSummary: '선순위 채권',
    deposit: 130000000,
    marketPrice: 200000000,
    seniorDebtAmount: 1400000000,
    gaugeProgress: 0.8,
    evidences: const [],
    highlights: marks,
    checkedNotes: const [
      '집에 잡힌 빚(근저당) 2건은 **모두 말소된 것으로 확인**해 표시하지 않았어요 — 이미 정리된 빚이에요',
      '압류는 8건 중 큰 것부터 5건만 사진에 표시했어요. 나머지 3건은 화면이 가려져서 표시하지 않았어요 — 리포트의 근거 목록에는 8건 다 들어 있어요',
      '사진 순서가 등기부 쪽수와 달라 자동으로 맞췄어요 — 다시 올리지 않으셔도 돼요',
      '서류 내용을 2가지 방법으로 교차 확인했어요 — 빚(근저당) 3건, 가압류 3건 외 2종 일치',
    ],
  );
}
