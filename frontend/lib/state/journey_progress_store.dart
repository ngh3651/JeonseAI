/// 계약 여정의 **진행 기록** — 단계 완료(수동 켜고 끄기)·등기부 대조 기록·알림 켜짐 여부 (2026-10-26 여정 디자인).
///
/// 날짜([JourneyScheduleStore])처럼 **이 휴대폰에만** 저장한다 — 서버로 보내지 않는다.
/// 집마다 따로(집 열쇠 = 고유번호, 없으면 주소 — `propertyKeyFor`).
///
/// - 단계 완료: 날짜가 지나면 저절로 완료. 칩을 한 번 더 누르면 사용자가 켜고 끌 수 있다(이 값이 우선).
///   대조를 마치면 그 단계가 자동으로 완료된다.
/// - 대조 기록: 날짜·단계·결과(변동 없음 / 변동 N건)·바뀐 줄 — '등기부 변동 기록'과 '이전 리포트' 꼬리말에 쓴다.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 대조로 바뀐 한 줄 (예: "을구 · 근저당 1건 새로 생김" / "접수 2026년 10월 20일 · 채권최고액 1억 2천만원").
@immutable
class CompareLogLine {
  const CompareLogLine({required this.title, this.detail = ''});

  final String title;
  final String detail;

  Map<String, dynamic> toJson() => {'title': title, 'detail': detail};

  factory CompareLogLine.fromJson(Map<String, dynamic> json) => CompareLogLine(
    title: json['title'] as String? ?? '',
    detail: json['detail'] as String? ?? '',
  );
}

/// 변동 항목의 갈래 — 새로 생김 · 없어짐 · 내용이 달라짐(집주인)
enum CompareLogItemKind { added, removed, changed }

/// 대조로 바뀐 **한 건** (2026-10-27 변동 내용 시안 — 한 건에 한 줄).
@immutable
class CompareLogItem {
  const CompareLogItem({
    required this.kind,
    required this.label,
    this.receiptDate,
    this.note,
  });

  final CompareLogItemKind kind;

  /// 종류 이름 (압류 · 근저당권 …) — 집주인 줄이면 서버 제목("집주인이 달라요")
  final String label;

  /// 접수일 — 못 읽었으면 null
  final DateTime? receiptDate;

  /// 이름 아래 흐린 한 줄 — 금액("채권최고액 …" · "금액 확인 필요") 또는 집주인 줄의 "기준 김○○ → 이번 이○○"
  final String? note;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'label': label,
    if (receiptDate != null)
      'receiptDate':
          '${receiptDate!.year.toString().padLeft(4, '0')}-'
          '${receiptDate!.month.toString().padLeft(2, '0')}-'
          '${receiptDate!.day.toString().padLeft(2, '0')}',
    if (note != null) 'note': note,
  };

  factory CompareLogItem.fromJson(Map<String, dynamic> json) => CompareLogItem(
    kind: CompareLogItemKind.values.firstWhere(
      (k) => k.name == json['kind'],
      orElse: () => CompareLogItemKind.added,
    ),
    label: json['label'] as String? ?? '',
    receiptDate: DateTime.tryParse(json['receiptDate'] as String? ?? ''),
    note: json['note'] as String?,
  );
}

/// 대조 기록 한 건.
@immutable
class CompareLogEntry {
  const CompareLogEntry({
    required this.at,
    required this.changedCount,
    this.stageIndex,
    this.stageTitle,
    this.reportId,
    this.viewedAt,
    this.lines = const [],
    this.items = const [],
    this.reanalysis = false,
    this.compared = true,
    this.fromReport = false,
  });

  /// 이 기록의 결과를 **리포트의 '전 리포트와 견준 결과'**로 다시 그린다 — 리포트가 보충본으로 바뀐 기록 (2026-10-27)
  final bool fromReport;

  /// 바뀐 건들 — 한 건에 한 줄 (2026-10-27). 옛 기록이면 비어 있고 [lines]로 그린다.
  final List<CompareLogItem> items;

  int get addedCount =>
      items.where((i) => i.kind != CompareLogItemKind.removed).length;
  int get removedCount =>
      items.where((i) => i.kind == CompareLogItemKind.removed).length;

  /// 없어진 것만 있다 — 위험이 줄어든 대조. 빨강으로 칠하지 않는다.
  bool get onlyRemoved => items.isNotEmpty && addedCount == 0;

  /// 여정의 [대조하기]가 아니라 **다시 분석**(홈 등)으로 생긴 줄 — 제목 "다시 분석" (2026-10-27).
  /// 이 폰에 저장하지 않는다 — 서버 리포트(`changeFromPrevious`)에서 그때그때 만든다.
  final bool reanalysis;

  /// 바로 전 리포트와 견줘 봤나. false면(옛 리포트라 견준 기록이 없음) '변동 없음/N건' 꼬리표를 달지 않는다.
  final bool compared;

  /// 대조한 날 (그 폰의 날짜)
  final DateTime at;

  /// 새로 생기거나 바뀐 줄 수. 0이면 '변동 없음'
  final int changedCount;

  /// 어느 단계에서 대조했나 (0부터). 배너 등 단계 밖에서 했으면 null
  final int? stageIndex;

  /// 그 단계 제목 (예: "계약서 쓰는 날") — 기록 줄 제목 "계약서 쓰는 날 대조"
  final String? stageTitle;

  /// 이번 대조로 만들어진 새 리포트 id (이전 리포트 꼬리말에 "변동 없음/변동 N건")
  final String? reportId;

  /// 새 등기부의 열람일 ("2026.10.24") — 못 읽었으면 null
  final String? viewedAt;

  final List<CompareLogLine> lines;

  bool get changed => changedCount > 0;

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'changedCount': changedCount,
    'stageIndex': stageIndex,
    'stageTitle': stageTitle,
    'reportId': reportId,
    'viewedAt': viewedAt,
    'lines': [for (final l in lines) l.toJson()],
    'items': [for (final i in items) i.toJson()],
    if (fromReport) 'fromReport': true,
  };

  factory CompareLogEntry.fromJson(Map<String, dynamic> json) =>
      CompareLogEntry(
        at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
        changedCount: (json['changedCount'] as num?)?.toInt() ?? 0,
        stageIndex: (json['stageIndex'] as num?)?.toInt(),
        stageTitle: json['stageTitle'] as String?,
        reportId: json['reportId'] as String?,
        viewedAt: json['viewedAt'] as String?,
        lines: [
          for (final l in (json['lines'] as List?) ?? const [])
            CompareLogLine.fromJson((l as Map).cast<String, dynamic>()),
        ],
        items: [
          for (final i in (json['items'] as List?) ?? const [])
            CompareLogItem.fromJson((i as Map).cast<String, dynamic>()),
        ],
        fromReport: json['fromReport'] as bool? ?? false,
      );
}

class JourneyProgressStore extends ChangeNotifier {
  JourneyProgressStore._();

  static final JourneyProgressStore instance = JourneyProgressStore._();

  static const String _key = 'journey_progress_v1';

  /// 매물 키 → (단계 번호 → 체크). 1부터 이어진 true만 센다([checkedThrough]).
  final Map<String, Map<int, bool>> _manual = {};

  /// 매물 키 → 대조 기록 (최신이 앞)
  final Map<String, List<CompareLogEntry>> _logs = {};

  /// 알림이 켜져 있나 — '일정마다 오전 8시에 알려 드려요' 줄을 보일지. 모르면 null(줄을 숨긴다).
  bool? _notificationsOn;

  bool _restored = false;

  bool? get notificationsOn => _notificationsOn;

  Future<void> restore() async {
    if (_restored) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        final decoded = (jsonDecode(raw) as Map).cast<String, dynamic>();
        for (final e in ((decoded['manual'] as Map?) ?? const {}).entries) {
          _manual[e.key as String] = {
            for (final s in (e.value as Map).entries)
              int.parse(s.key as String): s.value as bool,
          };
        }
        for (final e in ((decoded['logs'] as Map?) ?? const {}).entries) {
          _logs[e.key as String] = [
            for (final l in e.value as List)
              CompareLogEntry.fromJson((l as Map).cast<String, dynamic>()),
          ];
        }
        _notificationsOn = decoded['notificationsOn'] as bool?;
      }
    } catch (e) {
      debugPrint('[여정진행] 저장본을 읽지 못했어요 (${e.runtimeType}) — 빈 기록으로 시작합니다');
    }
    _restored = true;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _manual.clear();
    _logs.clear();
    _notificationsOn = null;
    _restored = false;
  }

  /// 앞에서부터 이어서 체크한 마지막 단계 번호(0 = 분석만) — 체크는 순서대로만 한다 (2026-10-30).
  /// 예전에 건너뛰며 켜 둔 기록(1·3·5)은 앞에서부터 이어진 것(1)만 센다.
  int checkedThrough(String propertyKey) {
    final m = _manual[propertyKey];
    if (m == null) return 0;
    int k = 0;
    while (m[k + 1] == true) {
      k++;
    }
    return k;
  }

  /// 1단계부터 [through]단계까지 체크로 저장한다 (나머지는 지운다).
  Future<void> setCheckedThrough(String propertyKey, int through) async {
    _manual[propertyKey] = {for (int i = 1; i <= through; i++) i: true};
    notifyListeners();
    await _persist();
  }

  List<CompareLogEntry> logFor(String propertyKey) =>
      List.unmodifiable(_logs[propertyKey] ?? const []);

  /// 이 리포트를 만든 대조 기록 (이전 리포트 꼬리말용). 없으면 null.
  CompareLogEntry? logForReport(String reportId) {
    for (final list in _logs.values) {
      for (final e in list) {
        if (e.reportId == reportId) return e;
      }
    }
    return null;
  }

  /// 대조를 마쳤다 — 기록을 맨 위에 넣고, 그 단계를 완료로 켠다.
  Future<void> addCompare(String propertyKey, CompareLogEntry entry) async {
    (_logs[propertyKey] ??= []).insert(0, entry);
    // 그 단계에서 대조했다 = 그 단계까지 끝났다 (체크는 앞에서부터 이어진다)
    final stage = entry.stageIndex;
    if (stage != null && stage > checkedThrough(propertyKey)) {
      _manual[propertyKey] = {for (int i = 1; i <= stage; i++) i: true};
    }
    notifyListeners();
    await _persist();
  }

  /// [oldReportId] 리포트를 [newReportId]가 **대신했다** (빠진 쪽 보충·흐린 장 다시 찍기, 2026-10-27).
  /// 그 리포트를 가리키던 대조 기록을 새 리포트로 옮기고, 결과는 새 리포트의 '전 리포트와 견준 결과'로 다시 그리게 표시한다
  /// ([CompareLogEntry.fromReport]) — 덜 찍은 서류로 낸 틀린 숫자가 남지 않고, 기록이 두 줄이 되지 않게.
  Future<void> replaceReportId(String oldReportId, String newReportId) async {
    var touched = false;
    for (final list in _logs.values) {
      for (int i = 0; i < list.length; i++) {
        final e = list[i];
        if (e.reportId != oldReportId) continue;
        list[i] = CompareLogEntry(
          at: e.at,
          changedCount: e.changedCount,
          stageIndex: e.stageIndex,
          stageTitle: e.stageTitle,
          reportId: newReportId,
          viewedAt: e.viewedAt,
          lines: e.lines,
          items: e.items,
          compared: e.compared,
          fromReport: true,
        );
        touched = true;
      }
    }
    if (!touched) return;
    notifyListeners();
    await _persist();
  }

  Future<void> setNotificationsOn(bool? on) async {
    if (_notificationsOn == on) return;
    _notificationsOn = on;
    notifyListeners();
    await _persist();
  }

  /// 이 열쇠에 남은 기록(완료 표시·대조 기록)이 있나.
  bool hasRecord(String propertyKey) =>
      (_manual[propertyKey]?.isNotEmpty ?? false) ||
      (_logs[propertyKey]?.isNotEmpty ?? false);

  /// 예전 열쇠([from])의 기록을 새 열쇠([to])로 옮긴다 — 새 열쇠에 이미 있는 것은 그대로 둔다 (2026-10-27 집 열쇠 변경).
  Future<void> adoptKey(String from, String to) async {
    final manual = _manual.remove(from);
    final logs = _logs.remove(from);
    if (manual == null && logs == null) return;
    if (manual != null) _manual[to] = {...manual, ...?_manual[to]};
    if (logs != null) {
      _logs[to] = [...?_logs[to], ...logs]..sort((a, b) => b.at.compareTo(a.at));
    }
    notifyListeners();
    await _persist();
  }

  /// 집을 지우면 그 집의 기록도 지운다.
  Future<void> forget(String propertyKey) async {
    _manual.remove(propertyKey);
    _logs.remove(propertyKey);
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode({
          'manual': {
            for (final e in _manual.entries)
              e.key: {for (final s in e.value.entries) '${s.key}': s.value},
          },
          'logs': {
            for (final e in _logs.entries)
              e.key: [for (final l in e.value) l.toJson()],
          },
          'notificationsOn': _notificationsOn,
        }),
      );
    } catch (e) {
      debugPrint('[여정진행] 저장하지 못했어요 (${e.runtimeType}) — 이번 세션에만 남습니다');
    }
  }
}
