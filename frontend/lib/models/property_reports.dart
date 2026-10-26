/// 같은 집의 리포트 묶음 — **집 하나에 보이는 리포트는 항상 최신 1개** (2026-10-26 같은 집 덮어쓰기).
///
/// 같은 집인가 (2026-10-27, 서버 `store.same_property`와 같은 규칙):
/// 1. **부동산고유번호**가 둘 다 있으면 그것만 본다 — 같으면 같은 집, 다르면 주소가 같아도 다른 집(같은 지번 다른 호실).
/// 2. 한쪽이라도 없으면 **주소**로 — 도로명 병기('[도로명주소] …')를 떼고 띄어쓰기를 무시한다([addressPropertyKey]).
///    주소는 읽을 때마다 글자가 조금씩 달라진다(실기기 2026-10-27: 같은 집이 둘로 갈림) → 고유번호가 먼저다.
/// 3. 주소를 못 읽은 리포트는 묶지 않는다(서로 다른 집일 수 있다).
///
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

/// 등기부 소재지 뒤에 붙는 도로명 병기 — 읽을 때마다 붙었다 빠졌다 해서 집 키에서 뺀다.
final RegExp _roadNote = RegExp(r'[\[(（]\s*도로명\s*주소\s*[\])）].*$');

/// 주소를 못 읽은 리포트의 자리표시(서버 `report_builder`) — 띄어쓰기를 뺀 꼴.
const String _unknownAddress = '주소미확인';

/// 주소로 같은 집을 가르는 키 — 도로명 병기를 떼고 띄어쓰기를 뺀 것. 주소를 못 읽었으면 null.
String? addressPropertyKey(String? address) {
  final head = (address ?? '').replaceFirst(_roadNote, '');
  final key = head.replaceAll(RegExp(r'\s+'), '');
  if (key.isEmpty || key.startsWith(_unknownAddress)) return null;
  return key;
}

/// 집 열쇠 — 이 폰의 계약 일정·진행 기록·알림이 이 값으로 저장된다.
/// 고유번호가 있으면 `고유번호:…`, 없으면 주소 키, 둘 다 없으면 그 리포트 하나만의 열쇠.
String propertyKeyFor({String? propertyId, String? address, String? reportId}) {
  if (propertyId != null && propertyId.isNotEmpty) return '고유번호:$propertyId';
  return addressPropertyKey(address) ?? '리포트:${reportId ?? ''}';
}

/// 집 하나 = 같은 집 분석들의 묶음 (최신순).
class PropertyReports {
  PropertyReports({required this.key, required this.reports});

  /// 집 열쇠 ([propertyKeyFor]) — 묶음 안에 고유번호가 하나라도 있으면 고유번호 열쇠.
  final String key;

  /// 최신순. 비어 있지 않다.
  final List<AnalysisReport> reports;

  AnalysisReport get latest => reports.first;

  /// 맨 처음 분석 (이 묶음에서 가장 오래된 것)
  AnalysisReport get first => reports.last;

  String get alias => latest.alias;
  String get address => latest.address;

  /// 예전 열쇠들 — 2026-10-27 전에는 '주소에서 띄어쓰기만 뺀 것'([journeyPropertyKey])으로 저장했다.
  /// 그 열쇠로 남은 일정·기록을 새 열쇠로 옮길 때 쓴다(`adoptLegacyPropertyKeys`).
  Set<String> get legacyKeys => {
    for (final r in reports) ...[
      journeyPropertyKey(r.address),
      if (addressPropertyKey(r.address) case final k?) k,
    ],
  }..remove(key);

  /// 등기부에 인쇄된 열람일. 못 읽었으면 null — 분석일로 대신 채우지 않는다.
  DateTime? get registryViewedDate =>
      parseRegistryViewedAt(latest.registryViewedAt);

  /// 등기부를 뗀 지 며칠 됐나. 날짜를 못 읽었으면 null.
  int? get registryAgeDays {
    final viewed = registryViewedDate;
    return viewed == null ? null : daysSince(viewed);
  }
}

/// 같은 집인가 — 맨 위 설명의 1·2·3.
bool sameProperty(AnalysisReport a, AnalysisReport b) {
  final pa = a.propertyId, pb = b.propertyId;
  if (pa != null && pa.isNotEmpty && pb != null && pb.isNotEmpty) {
    return pa == pb;
  }
  final ka = addressPropertyKey(a.address);
  return ka != null && ka == addressPropertyKey(b.address);
}

/// 이력(최신순) → 집 묶음(최신 분석이 앞인 집부터).
List<PropertyReports> groupByProperty(List<AnalysisReport> reports) {
  final groups = <List<AnalysisReport>>[];
  for (final report in reports) {
    List<AnalysisReport>? home;
    for (final g in groups) {
      if (g.any((r) => sameProperty(r, report)) &&
          // 고유번호가 다른 리포트가 이미 들어 있는 묶음엔 넣지 않는다(다른 집이 주소로 이어 붙지 않게)
          !g.any(
            (r) =>
                r.propertyId != null &&
                report.propertyId != null &&
                r.propertyId != report.propertyId,
          )) {
        home = g;
        break;
      }
    }
    if (home == null) {
      groups.add([report]);
    } else {
      home.add(report);
    }
  }
  return [
    for (final g in groups)
      PropertyReports(
        key: propertyKeyFor(
          propertyId: g
              .map((r) => r.propertyId)
              .firstWhere((p) => p != null && p.isNotEmpty, orElse: () => null),
          address: g.first.address,
          reportId: g.first.id,
        ),
        reports: g.take(kKeepReportVersions).toList(),
      ),
  ];
}

/// 집마다 최신 리포트 1개 (최신순) — 홈·마이 목록.
List<AnalysisReport> latestPerProperty(List<AnalysisReport> reports) => [
  for (final p in groupByProperty(reports)) p.latest,
];

/// 이 리포트와 같은 집의 리포트들 (최신순, 최대 [kKeepReportVersions]건). 이 리포트가 목록에 없으면 이 리포트 하나를 더한다.
List<AnalysisReport> versionsOf(
  AnalysisReport report,
  List<AnalysisReport> history,
) {
  final inHistory = history.any((r) => r.id == report.id);
  final all = inHistory ? history : [report, ...history];
  for (final p in groupByProperty(all)) {
    if (p.reports.any((r) => r.id == report.id)) return p.reports;
  }
  return [report];
}
