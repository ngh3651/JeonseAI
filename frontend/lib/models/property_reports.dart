/// 같은 집의 리포트 묶음 — **집 하나에 보이는 리포트는 항상 최신 1개** (2026-10-26 같은 집 덮어쓰기).
///
/// 같은 집 = 등기부에서 읽은 **주소가 같은** 리포트(띄어쓰기는 무시 — [journeyPropertyKey]).
/// 별칭·보증금은 사람이 바꿔 넣을 수 있어 집을 가르는 기준이 될 수 없다 → 늘 **가장 최근 분석의 값**을 쓴다.
///
/// - 홈 '최근 분석'·마이 '분석 이력'은 집마다 최신 1개만 보인다.
/// - 지난 리포트는 리포트 화면의 시계 버튼('이전 리포트')에서 최근 [kKeepReportVersions]건까지 본다.
/// - 서버도 같은 집은 최신 5건만 남기고 더 오래된 것을 지운다(`store.prune_versions`).
library;

import '../state/journey_schedule_store.dart';
import '../utils/korean_date.dart';
import 'analysis_report.dart';

/// 같은 집에 남기는 리포트 수 — 폰 원본 보관(최근 5건)·서버 정리와 같은 수.
const int kKeepReportVersions = 5;

/// 집 하나 = 주소가 같은 분석들의 묶음 (최신순).
class PropertyReports {
  PropertyReports({required this.key, required this.reports});

  final String key;

  /// 최신순. 비어 있지 않다.
  final List<AnalysisReport> reports;

  AnalysisReport get latest => reports.first;

  /// 맨 처음 분석 (이 묶음에서 가장 오래된 것)
  AnalysisReport get first => reports.last;

  String get alias => latest.alias;
  String get address => latest.address;

  /// 등기부에 인쇄된 열람일. 못 읽었으면 null — 분석일로 대신 채우지 않는다.
  DateTime? get registryViewedDate => parseRegistryViewedAt(latest.registryViewedAt);

  /// 등기부를 뗀 지 며칠 됐나. 날짜를 못 읽었으면 null.
  int? get registryAgeDays {
    final viewed = registryViewedDate;
    return viewed == null ? null : daysSince(viewed);
  }
}

/// 이력(최신순) → 집 묶음(최신 분석이 앞인 집부터).
List<PropertyReports> groupByProperty(List<AnalysisReport> reports) {
  final grouped = <String, List<AnalysisReport>>{};
  for (final report in reports) {
    grouped.putIfAbsent(journeyPropertyKey(report.address), () => []).add(report);
  }
  return [
    for (final entry in grouped.entries)
      PropertyReports(key: entry.key, reports: entry.value.take(kKeepReportVersions).toList()),
  ];
}

/// 집마다 최신 리포트 1개 (최신순) — 홈·마이 목록.
List<AnalysisReport> latestPerProperty(List<AnalysisReport> reports) => [
  for (final p in groupByProperty(reports)) p.latest,
];

/// 이 리포트와 같은 집의 리포트들 (최신순, 최대 [kKeepReportVersions]건). 이 리포트가 목록에 없으면 이 리포트 하나.
List<AnalysisReport> versionsOf(AnalysisReport report, List<AnalysisReport> history) {
  final key = journeyPropertyKey(report.address);
  final same = [
    for (final r in history)
      if (journeyPropertyKey(r.address) == key) r,
  ].take(kKeepReportVersions).toList();
  if (!same.any((r) => r.id == report.id)) return [report, ...same].take(kKeepReportVersions).toList();
  return same;
}
