/// 분석 리포트 더미 데이터 구조.
///
/// **이 구조는 향후 docs/data-contract.md의 API 응답 계약과 항상 동일한 형태를
/// 유지해야 한다** (CLAUDE.md 4절 더미↔실제 교체 규칙).
/// 등급·수치의 판정 기준은 Phase E-1(규칙 엔진)에서 출처 기반으로 확정한다 —
/// 여기 담기는 더미 값은 전부 "예시"다.
library;

import 'registry_mark_kind.dart';
import 'risk_grade.dart';

/// 분석 요청 — S-04 매물 검색이 수집한 입력값 (더미↔실제 공통 계약 원형).
///
/// 실단계(E-1)에서는 [imagePaths]가 Upstage Information Extract로 넘어가고,
/// [marketPrice]는 PriceSource(수동 입력 → 실거래가 API)에서 온다.
class AnalysisRequest {
  const AnalysisRequest({
    required this.imagePaths,
    required this.deposit,
    this.marketPrice,
    this.alias,
  });

  final List<String> imagePaths;
  final int deposit;
  final int? marketPrice;
  final String? alias;
}

/// 근거 카드 한 항목 (S-07 근거 카드 목록의 원소).
class EvidenceItem {
  const EvidenceItem({
    required this.id,
    required this.title,
    required this.termSubtitle,
    required this.grade,
    this.statusLabel,
    required this.easyExplanation,
    this.detailText,
    this.sourceText,
    this.actionLabel,
    this.termGlossary = const {},
  });

  /// 항목 식별자: jeonse_ratio | senior_debt | ownership | insurance | blacklist
  final String id;

  /// 쉬운 질문형 제목 (IA.md §6 — 전문용어는 부제로)
  final String title;

  /// 전문용어 부제
  final String termSubtitle;

  final RiskGrade grade;

  /// 등급 라벨 대신 표시할 상태 (예: "확인 필요", "페이지 누락")
  final String? statusLabel;

  /// 쉬운 설명 — 실단계에서는 Solar Pro 생성 슬롯 (판정 변경 금지, 문장만)
  final String easyExplanation;

  /// 상세 수치
  final String? detailText;

  /// 판정 출처 (E-1 확정 전에는 슬롯 표기)
  final String? sourceText;

  /// 다음 행동 버튼 라벨 — 보수적 문구에는 반드시 행동을 짝짓는다 (IA.md §0)
  final String? actionLabel;

  /// 쉬운 설명 속 용어 → 툴팁 설명 (용어가 easyExplanation 본문에 등장해야 함)
  final Map<String, String> termGlossary;

  /// 서버 JSON(api-contract.md §2.2 Evidence) → 모델.
  factory EvidenceItem.fromJson(Map<String, dynamic> json) => EvidenceItem(
    id: json['id'] as String,
    title: json['title'] as String,
    termSubtitle: json['termSubtitle'] as String,
    grade: RiskGrade.fromLabel(json['grade'] as String),
    statusLabel: json['statusLabel'] as String?,
    easyExplanation: json['easyExplanation'] as String,
    detailText: json['detailText'] as String?,
    sourceText: json['sourceText'] as String?,
    actionLabel: json['actionLabel'] as String?,
    termGlossary: (json['termGlossary'] as Map<String, dynamic>? ?? const {})
        .map((k, v) => MapEntry(k, v as String)),
  );
}

/// 원본 사진 위 표시 1건의 좌표 — **0~1로 정규화** (api-contract.md §9.4).
///
/// 픽셀이 아니라 비율인 이유: 화면 표시 크기는 기기·회전·줌에 따라 달라진다.
/// 앱은 `정규화값 × 화면에 그린 이미지 크기`로 되돌린다.
class HighlightBox {
  const HighlightBox({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  final double x;
  final double y;
  final double w;
  final double h;

  factory HighlightBox.fromJson(Map<String, dynamic> json) => HighlightBox(
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    w: (json['w'] as num).toDouble(),
    h: (json['h'] as num).toDouble(),
  );
}

/// 원본 사진 위 표시 1건 (api-contract.md §9.3).
///
/// **표시 전용이다.** 등급·점수에 영향을 주지 않으며, 서버가 이 목록을 비워 보내도
/// 리포트는 지금과 똑같이 동작한다.
class RegistryHighlight {
  const RegistryHighlight({
    required this.id,
    required this.page,
    required this.kind,
    required this.badge,
    required this.box,
    required this.title,
    required this.body,
    this.caution,
    this.source,
  });

  final String id;

  /// 업로드한 사진 순서 (0부터) — 몇 번째 사진에 그릴지
  final int page;

  /// `owner` | `mortgage` | `jeonse` — **늘어난다.** 화면은 이 문자열을 직접
  /// 비교하지 말고 [markKind]로 받아 쓴다(색·범례·개수가 거기서 파생된다).
  final String kind;

  /// 화면 뱃지 번호 (1부터). 색만으로 정보를 전달하지 않기 위함(접근성)
  final int badge;

  final HighlightBox box;
  final String title;
  final String body;
  final String? caution;

  /// 이 문장이 어디서 왔는지 — 근거 카드의 sourceText와 같은 역할.
  /// 없으면 시트 문장이 "앱이 그냥 하는 말"로 읽힌다(2026-07-27 서연 리뷰).
  final String? source;

  /// 표시 종류 — 서버가 앱보다 먼저 새 kind를 내보내면 [MarkKind.unknown]으로
  /// 떨어져 **위험 색**으로 그려진다(모르는 것을 안전 색으로 칠하지 않는다).
  MarkKind get markKind => MarkKind.fromKey(kind);

  /// 카드에 쓸 한 줄 요약 — **[body]의 첫 문장**이다.
  ///
  /// 시안이 요구한 `oneLiner`(별도 한 줄 요약) 필드는 **백엔드에 없다**
  /// (`backend/app/schemas/contract.py`의 `Highlight` 확인, 2026-07-27).
  /// 없는 문구를 앱이 지어내면 **그 문장만 출처가 없어져**, "근거 있는 말만 한다"는
  /// 이 앱의 성질이 카드에서부터 깨진다. 그래서 서버가 준 본문에서 잘라 쓴다.
  /// 자르는 위치는 첫 마침표(또는 첫 줄바꿈)이며, 문장을 고치거나 덧붙이지 않는다.
  String get summary {
    final text = body.trim();
    final ends = <int>[
      // 마침표는 포함해서 자르고(문장으로 읽히게), 줄바꿈은 그 앞에서 자른다.
      for (final mark in const ['. ', '.\n'])
        if (text.contains(mark)) text.indexOf(mark) + 1,
      if (text.contains('\n')) text.indexOf('\n'),
      if (text.endsWith('.')) text.length,
    ];
    if (ends.isEmpty) return text;
    ends.sort();
    return text.substring(0, ends.first).trim();
  }

  bool get isOwner => kind == 'owner';

  factory RegistryHighlight.fromJson(Map<String, dynamic> json) =>
      RegistryHighlight(
        id: json['id'] as String,
        page: json['page'] as int,
        kind: json['kind'] as String,
        badge: json['badge'] as int,
        box: HighlightBox.fromJson(json['box'] as Map<String, dynamic>),
        title: json['title'] as String,
        body: json['body'] as String,
        caution: json['caution'] as String?,
        source: json['source'] as String?,
      );
}

class AnalysisReport {
  const AnalysisReport({
    required this.id,
    required this.alias,
    required this.address,
    required this.analyzedAt,
    required this.grade,
    required this.headline,
    required this.nextAction,
    required this.topRiskSummary,
    required this.deposit,
    required this.marketPrice,
    required this.seniorDebtAmount,
    required this.gaugeProgress,
    required this.evidences,
    this.highlights = const [],
    this.highlightNotice,
    this.checkedNotes = const [],
    this.registryViewedAt,
  });

  final String id;

  /// 매물 별칭 — 미입력 시 표제부 추출 소재지 주소가 기본값 (IA.md S-04)
  final String alias;

  /// 표제부 소재지 주소
  final String address;

  final DateTime analyzedAt;

  final RiskGrade grade;

  /// 결론 한 줄 (결론 헤더에 크게)
  final String headline;

  /// "지금 해야 할 일" 한 문장 (등급별 문구 방향은 IA.md §6 표 참조)
  final String nextAction;

  /// 최대 위험 요인 한 줄 — 홈 이력 카드의 비교용 노출 (IA.md S-03)
  final String topRiskSummary;

  /// 예정 보증금 (원) — S-04에서 사용자 필수 입력
  final int deposit;

  /// 매매 시세 (원) — 선택 입력. null이면 전세가율 카드는 "확인 필요"
  final int? marketPrice;

  /// 선순위 채권 합계 (원) — 손실 시뮬레이터 계산 입력 (더미 단계 예시값)
  final int seniorDebtAmount;

  /// 게이지 시각 슬롯 (0~1, 예시) — 점수 체계는 E-1에서 확정
  final double gaugeProgress;

  /// 근거 카드 목록 (S-07 §2)
  final List<EvidenceItem> evidences;

  /// 원본 사진 위 표시 목록 (api-contract.md §9 — **선택**).
  /// 서버가 좌표를 못 구하면 빈 목록으로 온다. 그래도 리포트는 정상 동작한다.
  final List<RegistryHighlight> highlights;

  /// 사진 묶음 안내 한 줄 (다른 등기부 섞임·순서 어긋남·쪽 누락). 없으면 null.
  final String? highlightNotice;

  /// "무엇을 찾아봤고 무엇을 왜 표시하지 않았는지" 요약. 표시 전용.
  /// 침묵하면 사용자가 "AI가 안 봤다"로 읽어 리포트 신뢰까지 깎인다.
  final List<String> checkedNotes;

  /// 등기부에 인쇄된 **열람일시** `YYYY.MM.DD`. 못 읽으면 null.
  ///
  /// [analyzedAt](분석일)과 **다른 날짜다.** 등기부는 열람 시점의 스냅샷이라,
  /// 그 뒤에 잡힌 근저당은 이 서류에 없다 — 계약 직전 근저당 설정은 실제 전세사기
  /// 수법이다(실측 샘플: 열람 7/9, 분석 7/27로 18일 차이).
  /// ⚠ null일 때 [analyzedAt]으로 대신 채우지 않는다. 분석일을 보여 주면 "오늘 서류"로
  ///   믿게 만들어 아무것도 안 쓰느니만 못하다. **없으면 그 줄 자체를 그리지 않는다.**
  final String? registryViewedAt;

  /// 서버 JSON(api-contract.md §2.1 Report) → 모델.
  factory AnalysisReport.fromJson(Map<String, dynamic> json) => AnalysisReport(
    id: json['id'] as String,
    alias: json['alias'] as String,
    address: json['address'] as String,
    analyzedAt: DateTime.parse(json['analyzedAt'] as String),
    grade: RiskGrade.fromLabel(json['grade'] as String),
    headline: json['headline'] as String,
    nextAction: json['nextAction'] as String,
    topRiskSummary: json['topRiskSummary'] as String,
    deposit: json['deposit'] as int,
    marketPrice: json['marketPrice'] as int?,
    seniorDebtAmount: json['seniorDebtAmount'] as int,
    gaugeProgress: (json['gaugeProgress'] as num).toDouble(),
    evidences: [
      for (final e in json['evidences'] as List)
        EvidenceItem.fromJson(e as Map<String, dynamic>),
    ],
    // 서버가 이 필드를 안 보내도(구버전) 빈 목록으로 동작한다.
    highlights: [
      for (final h in (json['highlights'] as List? ?? const []))
        RegistryHighlight.fromJson(h as Map<String, dynamic>),
    ],
    highlightNotice: json['highlightNotice'] as String?,
    checkedNotes: [
      for (final n in (json['checkedNotes'] as List? ?? const [])) n as String,
    ],
    // 구버전 서버는 이 필드를 안 보낸다 → null → 앱은 그 줄을 그리지 않는다.
    registryViewedAt: json['registryViewedAt'] as String?,
  );

  /// 위험/확인 필요 등급인 근거의 패턴 라벨 — 판례 매칭·질문 생성기 입력.
  /// evidence id를 사람이 읽는 위험 패턴 이름으로 매핑한다.
  List<String> get riskLabels {
    const idToLabel = {
      'senior_debt': '선순위 채권',
      'ownership': '신탁등기',
      'jeonse_ratio': '전세가율',
      'insurance': '보증보험',
    };
    return [
      for (final e in evidences)
        if (e.grade != RiskGrade.ok && idToLabel.containsKey(e.id))
          idToLabel[e.id]!,
    ];
  }
}
