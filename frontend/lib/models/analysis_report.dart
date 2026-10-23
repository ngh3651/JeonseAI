/// 분석 리포트 더미 데이터 구조.
///
/// **이 구조는 향후 docs/data-contract.md의 API 응답 계약과 항상 동일한 형태를
/// 유지해야 한다** (CLAUDE.md 4절 더미↔실제 교체 규칙).
/// 등급·수치의 판정 기준은 Phase E-1(규칙 엔진)에서 출처 기반으로 확정한다 —
/// 여기 담기는 더미 값은 전부 "예시"다.
library;

import '../state/privacy_settings.dart';
import '../utils/name_mask.dart';
import 'market_price_source.dart';
import 'registry_mark_kind.dart';
import 'risk_grade.dart';

export 'market_price_source.dart' show MarketPriceAlternative, MarketPriceSource;

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
    this.explanationSource,
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

  /// 이 카드의 **설명 문장**을 누가 썼는가 (계약 §2.2, 2026-08-14 D26).
  ///
  /// 모델이 썼으면 실제 모델 문자열(예: `solar-pro2`), 검증에 걸려 미리 준비한
  /// 문장이 나갔으면 `준비된 문구`. **카드마다 다를 수 있다** — 설명 폴백은 필드
  /// 단위라, 한 리포트 안에서 어떤 카드는 모델 문장이고 어떤 카드는 준비된 문구다.
  ///
  /// null이면(옛 서버·옛 이력) 화면이 종전 라벨 '자동 생성'을 그대로 쓴다.
  /// ⚠ **판정 출처가 아니다.** 판정은 언제나 규칙 엔진이고, 그 출처는 [sourceText]다.
  final String? explanationSource;

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
    explanationSource: json['explanationSource'] as String?,
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

/// 사진 속 **실명·주민번호 자리** 하나 (api-contract.md §9.8 — 2026-10-22, P0-2b).
///
/// 서버는 **글자 없이 위치만** 보낸다. '사진 속 이름 가리기'가 켜지면 앱이 이 상자를 불투명하게 덮는다.
/// `x=0, y=0, w=1, h=1`은 "이 쪽은 이름 자리를 찾아보지 못했다(OCR 실패 등)"는 뜻 — 쪽 전체를 덮는다.
class PrivacyMask {
  const PrivacyMask({required this.page, required this.box});

  /// 업로드한 사진 순서 (0부터)
  final int page;

  /// 정규화 좌표 (0~1) — 하이라이트와 같은 방식
  final HighlightBox box;

  /// 쪽 전체를 덮는 상자인가 (서버가 그 쪽의 이름 자리를 찾아보지 못했다)
  bool get coversWholePage =>
      box.x <= 0 && box.y <= 0 && box.w >= 1 && box.h >= 1;

  factory PrivacyMask.fromJson(Map<String, dynamic> json) => PrivacyMask(
    page: json['page'] as int,
    box: HighlightBox.fromJson(json),
  );
}

/// 촬영 검사에서 문제가 있었던 사진 한 장 (api-contract.md §9.9 — 2026-10-22, P1-1).
///
/// **판정이 아니라 사진 품질**이다. 등급과 무관하다.
class CapturePageIssue {
  const CapturePageIssue({
    required this.index,
    this.issues = const [],
    this.severe = false,
    this.tip = '',
  });

  /// 업로드한 사진 순서 (0부터) — 화면에는 index+1쪽
  final int index;

  /// `blurry`·`too_dark`·`too_bright`·`low_contrast`·`no_text`·`low_resolution`·`cut_off`
  final List<String> issues;

  /// true = 서버가 분석하지 않고 거절한 장 (다시 찍어야 분석된다)
  final bool severe;

  /// 이유 + 다시 찍는 법 (서버가 쓴 쉬운 말 두 문장)
  final String tip;

  /// 한 단어 요약 — 사진 위 뱃지용. 여럿이면 먼저 고칠 것 하나(서버의 우선순위와 같은 순서).
  String get shortLabel {
    const order = [
      ('no_text', '글자 없음'),
      ('too_dark', '어두움'),
      ('too_bright', '빛 번짐'),
      ('blurry', '흐림'),
      ('low_contrast', '흐릿함'),
      ('low_resolution', '너무 작음'),
      ('cut_off', '잘림'),
    ];
    for (final (key, label) in order) {
      if (issues.contains(key)) return label;
    }
    return '확인 필요';
  }

  factory CapturePageIssue.fromJson(Map<String, dynamic> json) =>
      CapturePageIssue(
        index: json['index'] as int,
        issues: [
          for (final i in (json['issues'] as List? ?? const [])) i as String,
        ],
        severe: json['severe'] as bool? ?? false,
        tip: json['tip'] as String? ?? '',
      );
}

/// 촬영 검사 결과 (api-contract.md §9.9). 문제가 없는 장은 [pages]에 없다.
class CaptureCheck {
  const CaptureCheck({this.ok = true, this.pages = const []});

  final bool ok;
  final List<CapturePageIssue> pages;

  /// 그 장의 문제 (없으면 null)
  CapturePageIssue? issueFor(int index) {
    for (final p in pages) {
      if (p.index == index) return p;
    }
    return null;
  }

  factory CaptureCheck.fromJson(Map<String, dynamic> json) => CaptureCheck(
    ok: json['ok'] as bool? ?? true,
    pages: [
      for (final p in (json['pages'] as List? ?? const []))
        CapturePageIssue.fromJson(p as Map<String, dynamic>),
    ],
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
    this.comparable = false,
    this.privacyMasks = const [],
    this.privacyMasksReady = false,
    this.captureCheck,
    this.personNames = const [],
    this.sourceJson,
    this.namesHidden = false,
    this.marketPriceSource = MarketPriceSource.unknown,
    this.marketPriceAsOf,
    this.marketPriceSampleCount,
    this.marketPriceGapPct,
    this.marketPriceAlternatives = const [],
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

  /// 이 분석을 **다음 등기부와 견줄 기준으로 쓸 수 있는가** (계약 §2.1, S-11 대조).
  ///
  /// false면 [다시 떼서 대조하기]는 사진을 받기 전에 "기준 없음" 화면으로 간다 —
  /// 찍게 해 놓고 마지막에 못 한다고 말하지 않기 위해서다. 옛 서버·옛 이력이면 false.
  final bool comparable;

  /// 사진 속 실명·주민번호 **자리** (api-contract.md §9.8). '사진 속 이름 가리기'가 켜지면 전부 덮는다.
  final List<PrivacyMask> privacyMasks;

  /// 서버가 [privacyMasks]를 **실제로 만들었는가**. false = 이 기능 전 기록(또는 만들다 실패) —
  /// 이름이 어디 있는지 모르므로, 가리기가 켜져 있으면 사진을 **통째로** 덮는다([namesUnlocatedOn]).
  final bool privacyMasksReady;

  /// 이 쪽은 **이름 자리를 모르는가** — 가리기가 켜졌을 때 쪽 전체를 덮어야 하는가.
  ///
  /// 서버가 위치를 안 보냈거나(옛 기록) 그 쪽을 못 찾아봤다고 알렸을 때(쪽 전체 상자) true.
  /// "가리기 켜면 화면에 실명 0건"(NOW.md P0-2)을 지키는 마지막 방어선이다 — 모르면 덮는다.
  bool namesUnlocatedOn(int page) =>
      !privacyMasksReady ||
      privacyMasks.any((m) => m.page == page && m.coversWholePage);

  /// 촬영 검사 결과 (api-contract.md §9.9). null = 검사하지 않은 옛 기록이거나 서버에서 끔.
  /// 문제가 있으면 리포트가 "몇 쪽이 왜 — 그 장만 다시 찍기"를 권한다(판정은 그대로).
  final CaptureCheck? captureCheck;

  /// 이 등기부의 **사람 이름** 목록 (api-contract.md §9.11 — 2026-10-22). 분석 응답·폰 원본에는 실명,
  /// 서버 기록 사본에는 가린 꼴(`홍○○`)이다. '사진 속 이름 가리기'가 켜지면 [AnalysisReport.fromJson]이
  /// 이 이름들을 화면의 **모든 글자**에서 가린다(회사·은행 이름은 서버가 넣지 않는다 — 그대로 보인다).
  final List<String> personNames;

  /// 이 모델을 만든 **원본 JSON**(가리기 전). 스위치가 바뀌면 [withCurrentPrivacy]가 이것으로 다시 만든다.
  /// 서버 JSON에서 만들지 않은 모델(더미·테스트)은 null.
  final Map<String, dynamic>? sourceJson;

  /// 만들 때 이름을 가렸는가 — 그때의 '사진 속 이름 가리기' 값.
  final bool namesHidden;

  /// 지금 스위치 값에 맞춘 모델. 같으면 자기 자신, 다르면 [sourceJson]으로 **같은 한 곳**([AnalysisReport.fromJson])을
  /// 다시 거쳐 만든다 — 열려 있는 화면이 스위치 리스너에서 부른다(화면마다 따로 가리지 않는다).
  AnalysisReport withCurrentPrivacy() {
    final source = sourceJson;
    if (source == null || PrivacySettings.instance.hideNamesInPhotos == namesHidden) return this;
    return _otherVariant[this] ??= AnalysisReport.fromJson(source);
  }

  /// 반대쪽 스위치 값으로 만든 모델을 한 번만 만들어 둔다(다시 그릴 때마다 JSON을 새로 읽지 않게).
  static final Expando<AnalysisReport> _otherVariant = Expando('namesHiddenVariant');

  /// 이 쪽에서 가릴 상자들 (쪽 전체 상자는 빼고 — 그건 [namesUnlocatedOn]이 따로 말한다).
  List<HighlightBox> privacyBoxesOn(int page) => [
    for (final m in privacyMasks)
      if (m.page == page && !m.coversWholePage) m.box,
  ];

  // ── 시세 출처 (api-contract.md §2.8 · 2026-08-03 추가, 전부 선택) ──────────
  // 서버가 안 보내면 unknown/null — 앱은 출처 줄을 그리지 않거나 "확인 필요"로 말한다.

  /// [marketPrice]가 어디서 왔는지. 직접 입력인지 자동 조회인지 화면에 **반드시** 밝힌다.
  final MarketPriceSource marketPriceSource;

  /// 기준일(공시·기준시가) 또는 조회 기간(실거래가 `2026-02~2026-07`).
  final String? marketPriceAsOf;

  /// 실거래가일 때의 표본 수 — 1건짜리 시세를 5건짜리처럼 보여 주면 안 된다.
  final int? marketPriceSampleCount;

  /// 실거래가가 공시 기준보다 몇 % 높은지. 둘 다 있을 때만 온다.
  /// ⚠ **판정이 아니라 정보다.** 임계값의 권위 있는 출처가 없어 등급을 바꾸지 않는다.
  final int? marketPriceGapPct;

  /// 채택되지 않은 다른 후보들 — "왜 이 값을 썼나"를 펼쳐 보여 주기 위한 것.
  final List<MarketPriceAlternative> marketPriceAlternatives;

  /// 서버 JSON(api-contract.md §2.1 Report) → 모델.
  ///
  /// ★ '사진 속 이름 가리기'가 켜져 있으면 **여기 한 곳에서** `personNames`를 모든 글자에서 가린다
  /// (서버와 같은 규칙 — `utils/name_mask.dart`). 화면마다 따로 가리지 않는다(2026-10-22).
  factory AnalysisReport.fromJson(Map<String, dynamic> json) {
    final hide = PrivacySettings.instance.hideNamesInPhotos;
    return AnalysisReport._fromWire(
      hide ? maskNamesInReportJson(json) : json,
      source: json,
      namesHidden: hide,
    );
  }

  factory AnalysisReport._fromWire(
    Map<String, dynamic> json, {
    required Map<String, dynamic> source,
    required bool namesHidden,
  }) => AnalysisReport(
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
    // 구버전 서버·옛 이력이면 없음 → false(대조 기준으로 쓸 수 없음)로 본다.
    comparable: json['comparable'] as bool? ?? false,
    // 사진 속 실명 자리 (§9.8). 옛 서버·옛 이력이면 없음 → 준비 안 됨(false) → 가리기가 켜지면 통째로 덮는다.
    privacyMasks: [
      for (final m in (json['privacyMasks'] as List? ?? const []))
        PrivacyMask.fromJson(m as Map<String, dynamic>),
    ],
    privacyMasksReady: json['privacyMasksReady'] as bool? ?? false,
    // 촬영 검사 (§9.9). 옛 서버·옛 이력이면 없음(null).
    captureCheck: json['captureCheck'] is Map<String, dynamic>
        ? CaptureCheck.fromJson(json['captureCheck'] as Map<String, dynamic>)
        : null,
    // 시세 출처 (§2.8). 구버전 서버면 unknown/null — 앱은 출처 줄을 숨긴다.
    marketPriceSource: MarketPriceSource.fromWire(
      json['marketPriceSource'] as String?,
    ),
    marketPriceAsOf: json['marketPriceAsOf'] as String?,
    marketPriceSampleCount: json['marketPriceSampleCount'] as int?,
    marketPriceGapPct: json['marketPriceGapPct'] as int?,
    marketPriceAlternatives: [
      for (final a in (json['marketPriceAlternatives'] as List? ?? const []))
        MarketPriceAlternative.fromJson(a as Map<String, dynamic>),
    ],
    // 사람 이름 목록 (§9.11). 옛 서버·옛 기록이면 없음 → 빈 목록(글자 가리기 없음 — 그때는 서버가 이미 가렸다).
    personNames: [
      for (final n in (json['personNames'] as List? ?? const []))
        if (n is String) n,
    ],
    sourceJson: source,
    namesHidden: namesHidden,
  );

  /// 위험/확인 필요 등급인 근거의 패턴 라벨 — 판례 매칭·질문 생성기 입력.
  /// evidence id를 사람이 읽는 위험 패턴 이름으로 매핑한다.
  List<String> get riskLabels {
    const idToLabel = {
      'senior_debt': '선순위 채권',
      'jeonse_ratio': '전세가율',
      'insurance': '보증보험',
    };
    final labels = <String>[];
    for (final e in evidences) {
      if (e.grade == RiskGrade.ok) continue;
      if (e.id == 'ownership') {
        // 소유권 카드는 신탁·압류·경매가 한 칸에 모인다 — 상세 문장으로 실제로 무엇인지 가른다
        // (2026-10-24: 가압류만 있는 집이 '소유권을 맡긴 집(신탁)'으로 보이던 것을 고침).
        final d = e.detailText ?? '';
        final found = <String>[
          if (d.contains('신탁')) '신탁등기',
          if (d.contains('압류') || d.contains('가처분')) '압류·가압류',
          if (d.contains('경매')) '경매',
        ];
        labels.addAll(found.isEmpty ? const ['신탁등기'] : found);
      } else if (idToLabel.containsKey(e.id)) {
        labels.add(idToLabel[e.id]!);
      }
    }
    return labels;
  }
}
