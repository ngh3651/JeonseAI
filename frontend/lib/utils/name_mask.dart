/// 사람 이름 가리기 — **서버와 같은 규칙** (`backend/app/services/formatting.py`의 `mask_name`,
/// `name_privacy.mask_text`): 첫 글자 + 나머지 ○ (`홍길동` → `홍○○`, `홍 길동` → `홍○○○`).
///
/// '사진 속 이름 가리기'가 켜져 있으면 [AnalysisReport.fromJson]이 리포트 JSON을 모델로 바꾸기 **직전 한 곳에서**
/// [maskNamesInReportJson]을 부른다 — 화면마다 따로 가리지 않는다(2026-10-22 "폰엔 원본, 서버엔 가린 사본").
/// 가릴 이름은 서버가 보낸 `personNames`다(회사·은행·관공서 이름은 서버가 처음부터 넣지 않는다).
library;

/// `홍길동` → `홍○○`. 한 글자 이하면 그대로(빈 이름은 `(이름없음)`) — 서버 `mask_name`과 같다.
String maskPersonName(String name) {
  final trimmed = name.trim();
  final runes = trimmed.runes.toList();
  if (runes.length <= 1) return trimmed.isEmpty ? '(이름없음)' : trimmed;
  return String.fromCharCode(runes.first) + '○' * (runes.length - 1);
}

/// 글자 속 [names]를 모두 가린다. **긴 이름부터** 바꾼다(`김철수`가 `철수`보다 먼저) — 서버 `mask_text`와 같다.
String maskNamesInText(String text, Iterable<String> names) {
  final sorted = <String>{
    for (final n in names)
      if (n.trim().isNotEmpty) n,
  }.toList()..sort((a, b) => b.runes.length.compareTo(a.runes.length));
  var out = text;
  for (final name in sorted) {
    if (out.contains(name)) out = out.replaceAll(name, maskPersonName(name));
  }
  return out;
}

/// 가리지 않는 칸 — 서버 `name_privacy._KEEP_FIELDS`와 같다.
/// 주소는 사람 이름 칸이 아니고, 등급(`위험`·`확인 필요`·`양호`)은 정해진 말이라 바뀌면 화면이 등급을 못 읽는다.
const Set<String> _keepKeys = {'address', 'grade'};

/// 리포트 JSON의 **깊은 사본** — 모든 글자 칸에서 `personNames`의 이름을 가린다. 이름 목록이 없으면 그대로 돌려준다.
Map<String, dynamic> maskNamesInReportJson(Map<String, dynamic> json) {
  final names = <String>[
    for (final n in (json['personNames'] as List? ?? const []))
      if (n is String) n,
  ];
  if (names.isEmpty) return json;
  return _maskMap(json, names);
}

Map<String, dynamic> _maskMap(Map<dynamic, dynamic> map, List<String> names) => <String, dynamic>{
  for (final entry in map.entries)
    '${entry.key}': _keepKeys.contains(entry.key) ? entry.value : _maskValue(entry.value, names),
};

Object? _maskValue(Object? value, List<String> names) {
  if (value is String) return maskNamesInText(value, names);
  if (value is List) return [for (final v in value) _maskValue(v, names)];
  if (value is Map) return _maskMap(value, names);
  return value;
}
