/// 등기부 대조 결과 (api-contract.md §2.9 — S-11 계약 여정).
///
/// **문구는 전부 서버가 준다.** 앱은 값에서 문장을 지어내지 않는다 — 화면 하단의
/// "대조 · 규칙 기반 — AI가 판단하지 않았어요" 고지가 거짓말이 되지 않게 하는
/// 경계다. 앱이 덧붙이는 것은 딱 하나, 사용자의 **계약 일정(기기에만 저장)**과
/// 접수일을 견준 한 줄이다(그 날짜는 서버가 모른다).
library;

import 'risk_grade.dart';

/// 대조 결과 4갈래 (계약 §2.9 `result`).
enum CompareOutcome {
  /// 대조했다 — 달라진 점이 있을 수도, 없을 수도 있다
  changed,

  /// 일부는 대조하지 못했다 (빠진 쪽·못 읽은 항목)
  partial,

  /// 견줄 기준이 없다 — 이 기능 이전에 분석한 이력
  noBaseline,

  /// 다른 집이라 대조를 차단했다
  differentProperty;

  /// 서버가 앱보다 먼저 새 값을 내보내면 **가장 보수적인 쪽**으로 떨어뜨린다.
  /// 모르는 결과를 '대조 완료'로 그리면 "달라진 게 없다"로 읽힌다.
  static CompareOutcome fromWire(String? value) => switch (value) {
    'changed' => CompareOutcome.changed,
    'no_baseline' => CompareOutcome.noBaseline,
    'different_property' => CompareOutcome.differentProperty,
    _ => CompareOutcome.partial,
  };
}

/// 결과 한 줄의 성격.
enum CompareRowKind {
  added,
  removed,
  changed,
  same,
  unknown,
  grade;

  static CompareRowKind fromWire(String? value) {
    for (final k in CompareRowKind.values) {
      if (k.name == value) return k;
    }
    return CompareRowKind.unknown;
  }
}

/// 줄의 색 톤 — 실제 색 매핑은 화면이 토큰으로 한다(모델은 색을 모른다).
enum CompareTone {
  danger,
  caution,
  neutral;

  static CompareTone fromWire(String? value) => switch (value) {
    'danger' => CompareTone.danger,
    'caution' => CompareTone.caution,
    _ => CompareTone.neutral,
  };
}

/// 줄에 붙는 행동.
enum CompareAction {
  /// 빠진 쪽을 다시 찍어 올린다
  recapture,

  /// 이 집을 새로 분석한다
  analyze;

  static CompareAction? fromWire(String? value) {
    for (final a in CompareAction.values) {
      if (a.name == value) return a;
    }
    return null;
  }
}

/// 대조에 참여한 등기부 한 쪽.
class CompareDoc {
  const CompareDoc({
    this.reportId,
    this.alias,
    this.address,
    this.viewedAt,
    this.analyzedAt,
    this.grade,
    this.pageCount,
  });

  final String? reportId;
  final String? alias;
  final String? address;

  /// 등기부에 인쇄된 열람일 `YYYY.MM.DD`. 못 읽었으면 null — 분석일로 대신 채우지 않는다.
  final String? viewedAt;
  final String? analyzedAt;
  final RiskGrade? grade;

  /// 이번에 올린 사진 장수
  final int? pageCount;

  factory CompareDoc.fromJson(Map<String, dynamic> json) => CompareDoc(
    reportId: json['reportId'] as String?,
    alias: json['alias'] as String?,
    address: json['address'] as String?,
    viewedAt: json['viewedAt'] as String?,
    analyzedAt: json['analyzedAt'] as String?,
    grade: json['grade'] == null
        ? null
        : RiskGrade.fromLabel(json['grade'] as String),
    pageCount: json['pageCount'] as int?,
  );
}

class CompareRow {
  const CompareRow({
    required this.kind,
    required this.tone,
    required this.marker,
    required this.title,
    this.subtitle,
    this.detail,
    this.receiptDate,
    this.gradeBefore,
    this.gradeAfter,
    this.action,
    this.actionLabel,
  });

  final CompareRowKind kind;
  final CompareTone tone;

  /// 왼쪽 원 안에 그리는 글자: `+` `−` `≠` `=` `?` `!`
  final String marker;
  final String title;
  final String? subtitle;

  /// 회색 상세 박스 — 줄바꿈으로 여러 줄이 올 수 있다.
  final String? detail;

  /// 새로 생긴 항목의 접수일. 앱이 **기기에 저장된 계약 일정**과 견줘
  /// "계약서 쓴 다음 날이에요" 한 줄을 덧붙이는 데만 쓴다.
  final DateTime? receiptDate;

  final RiskGrade? gradeBefore;
  final RiskGrade? gradeAfter;

  final CompareAction? action;
  final String? actionLabel;

  factory CompareRow.fromJson(Map<String, dynamic> json) => CompareRow(
    kind: CompareRowKind.fromWire(json['kind'] as String?),
    tone: CompareTone.fromWire(json['tone'] as String?),
    marker: json['marker'] as String? ?? '·',
    title: json['title'] as String,
    subtitle: json['subtitle'] as String?,
    detail: json['detail'] as String?,
    receiptDate: DateTime.tryParse(json['receiptDate'] as String? ?? ''),
    gradeBefore: json['gradeBefore'] == null
        ? null
        : RiskGrade.fromLabel(json['gradeBefore'] as String),
    gradeAfter: json['gradeAfter'] == null
        ? null
        : RiskGrade.fromLabel(json['gradeAfter'] as String),
    action: CompareAction.fromWire(json['action'] as String?),
    actionLabel: json['actionLabel'] as String?,
  );
}

class CompareResult {
  const CompareResult({
    required this.outcome,
    required this.headline,
    this.subline,
    required this.baseline,
    required this.current,
    this.daysBetween,
    this.comparedCount = 0,
    this.totalCount = 0,
    this.rows = const [],
    this.notices = const [],
    this.identityBasis,
    this.newReportId,
  });

  final CompareOutcome outcome;
  final String headline;
  final String? subline;
  final CompareDoc baseline;
  final CompareDoc current;

  /// 두 서류를 뗀 날의 차이(일). 한쪽이라도 못 읽었으면 null.
  final int? daysBetween;
  final int comparedCount;
  final int totalCount;
  final List<CompareRow> rows;

  /// 대조 자체에 대한 고지 (같은 집인지 확인 못 함 등)
  final List<String> notices;

  /// 같은 집인지 무엇으로 확인했나 — "고유번호" | "소재지" | null(확인 못 함)
  final String? identityBasis;

  /// 이번에 뗀 서류로 만들어진 새 리포트 id. **다른 집이면 null.**
  final String? newReportId;

  factory CompareResult.fromJson(Map<String, dynamic> json) => CompareResult(
    outcome: CompareOutcome.fromWire(json['result'] as String?),
    headline: json['headline'] as String,
    subline: json['subline'] as String?,
    baseline: CompareDoc.fromJson(
      json['baseline'] as Map<String, dynamic>? ?? const {},
    ),
    current: CompareDoc.fromJson(
      json['current'] as Map<String, dynamic>? ?? const {},
    ),
    daysBetween: json['daysBetween'] as int?,
    comparedCount: json['comparedCount'] as int? ?? 0,
    totalCount: json['totalCount'] as int? ?? 0,
    rows: [
      for (final r in (json['rows'] as List? ?? const []))
        CompareRow.fromJson(r as Map<String, dynamic>),
    ],
    notices: [
      for (final n in (json['notices'] as List? ?? const [])) n as String,
    ],
    identityBasis: json['identityBasis'] as String?,
    newReportId: json['newReportId'] as String?,
  );
}
