/// 계약 여정의 **진행 기록** — 단계 완료(수동 켜고 끄기)·등기부 대조 기록·알림 켜짐 여부 (2026-10-26 여정 디자인).
///
/// 날짜([JourneyScheduleStore])처럼 **이 휴대폰에만** 저장한다 — 서버로 보내지 않는다.
/// 집마다 따로(매물 키 = 주소에서 띄어쓰기를 뺀 것, [journeyPropertyKey]).
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
  });

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
  };

  factory CompareLogEntry.fromJson(Map<String, dynamic> json) => CompareLogEntry(
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
  );
}

class JourneyProgressStore extends ChangeNotifier {
  JourneyProgressStore._();

  static final JourneyProgressStore instance = JourneyProgressStore._();

  static const String _key = 'journey_progress_v1';

  /// 매물 키 → (단계 번호 → 사용자가 정한 완료 여부). 없으면 날짜로 정한다.
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
            for (final l in e.value as List) CompareLogEntry.fromJson((l as Map).cast<String, dynamic>()),
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

  /// 사용자가 정한 완료 여부. 정하지 않았으면 null.
  bool? manualDone(String propertyKey, int stageIndex) => _manual[propertyKey]?[stageIndex];

  Future<void> setDone(String propertyKey, int stageIndex, bool done) async {
    (_manual[propertyKey] ??= {})[stageIndex] = done;
    notifyListeners();
    await _persist();
  }

  List<CompareLogEntry> logFor(String propertyKey) => List.unmodifiable(_logs[propertyKey] ?? const []);

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
    final stage = entry.stageIndex;
    if (stage != null) (_manual[propertyKey] ??= {})[stage] = true;
    notifyListeners();
    await _persist();
  }

  Future<void> setNotificationsOn(bool? on) async {
    if (_notificationsOn == on) return;
    _notificationsOn = on;
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
            for (final e in _logs.entries) e.key: [for (final l in e.value) l.toJson()],
          },
          'notificationsOn': _notificationsOn,
        }),
      );
    } catch (e) {
      debugPrint('[여정진행] 저장하지 못했어요 (${e.runtimeType}) — 이번 세션에만 남습니다');
    }
  }
}
