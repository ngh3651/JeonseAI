/// 사진 위 표시(mark)의 **종류**와, 그 종류가 화면에서 갖는 의미.
///
/// 왜 enum으로 빼는가:
/// 지금 서버가 보내는 종류는 `owner` / `mortgage` / `jeonse` 셋뿐이지만, 이는 OCR이
/// 제대로 되는지 **먼저 확인하려고 좁혀 둔 것**이지 완성 형태가 아니다. 압류·가압류가
/// 추가될 예정이고, 집 주소처럼 "위험은 아니지만 계약 대상이 맞는지 확인할 곳"도
/// 초록 표시로 들어올 예정이다.
/// → 그래서 화면 곳곳에서 `kind == 'owner'`로 분기하지 않는다. 새 종류가 생기면
///   **아래 [MarkKind]에 한 줄만 추가**하면 색·개수·범례·문구가 전부 따라온다.
///
/// ⚠ 표시 전용이다. 여기 어떤 값도 위험 등급·점수를 만들거나 바꾸지 않는다
///   (api-contract §9.6 "표시와 판정 완전 분리").
library;

/// 표시의 **톤** — 색과 범례, 그리고 "위험 몇 곳"을 셀 때 포함 여부를 가르는 축.
///
/// 종류(kind)는 늘어나지만 톤은 이 둘로 수렴한다:
/// 사용자가 **눈으로 맞춰볼 것**인가([verify]), **따져 물어야 할 것**인가([risk]).
enum MarkTone {
  /// 대조할 곳(초록) — 위험이 아니다. 계약 상대·대상이 맞는지 확인하는 자리다.
  /// 이름·주소가 여기 들어온다. **"위험 n곳" 카운트에 넣지 않는다.**
  verify('대조할 곳', isRisk: false),

  /// 따져볼 곳(주황) — 보증금을 깎을 수 있는 권리. 빚·전세권·압류가 여기 들어온다.
  risk('따져볼 곳', isRisk: true);

  const MarkTone(this.legendVerb, {required this.isRisk});

  /// 범례 뒷말 — "이름처럼 **대조할 곳**"의 굵은 부분.
  final String legendVerb;

  /// 진입 카드의 "위험 n곳"에 셀 것인가.
  final bool isRisk;
}

/// 서버 `kind` 문자열 1개 = 여기 항목 1개.
///
/// **새 종류를 추가하는 법** — 아래에 한 줄만 더한다. 예:
/// ```dart
/// seizure('seizure', MarkTone.risk, shortNoun: '압류', countNoun: '압류', unit: '건'),
/// address('address', MarkTone.verify, shortNoun: '주소', countNoun: '집 주소', unit: '곳'),
/// ```
/// 색·범례·개수 문구는 전부 이 표에서 파생되므로 화면 코드는 건드릴 필요가 없다.
enum MarkKind {
  owner('owner', MarkTone.verify, shortNoun: '이름', countNoun: '집주인 이름', unit: '곳'),
  mortgage('mortgage', MarkTone.risk, shortNoun: '빚', countNoun: '빚', unit: '건'),
  jeonse('jeonse', MarkTone.risk, shortNoun: '전세권', countNoun: '전세권', unit: '건'),

  /// 앱이 모르는 종류 — 서버가 우리보다 먼저 새 kind를 내보낸 경우.
  ///
  /// **위험 쪽에 둔다.** 모르는 것을 초록(대조할 곳)으로 칠하면 "확인만 하면 되는
  /// 것"으로 읽혀 경고를 놓친다. 미탐이 오탐보다 훨씬 치명적이라는 보수적 편향
  /// (risk-scoring 3절)을 여기에도 그대로 적용한다.
  unknown('', MarkTone.risk, shortNoun: '확인할 것', countNoun: '확인할 항목', unit: '건');

  const MarkKind(
    this.key,
    this.tone, {
    required this.shortNoun,
    required this.countNoun,
    required this.unit,
  });

  /// 서버가 보내는 문자열 (`kind` 필드).
  final String key;

  final MarkTone tone;

  /// 범례 조립용 짧은 이름 — "**이름**처럼 대조할 곳".
  final String shortNoun;

  /// 개수 문구용 이름 — "**집주인 이름** 1곳".
  final String countNoun;

  /// 개수 단위 — 곳/건.
  final String unit;

  bool get isRisk => tone.isRisk;

  /// 서버 문자열 → 종류. 모르는 값은 [unknown](= 위험 취급)으로 떨어진다.
  static MarkKind fromKey(String key) {
    for (final k in values) {
      if (k != unknown && k.key == key) return k;
    }
    return unknown;
  }
}

/// 범례 한 칸.
class MarkLegendEntry {
  const MarkLegendEntry(this.tone, this.label);

  final MarkTone tone;
  final String label;
}

/// 범례·개수 문구 조립 — **화면에 실제로 있는 종류만** 가지고 만든다.
///
/// 고정 문구를 박아 두면 압류가 추가된 날 범례가 조용히 거짓말을 한다
/// ("빚처럼 따져볼 곳"이라고 써 놓고 주황 표시 중 절반이 압류인 상태).
abstract final class MarkLegend {
  /// 표시에 등장한 종류들 → 톤별 범례 한 줄씩.
  ///
  /// `[owner, mortgage]` → `이름처럼 대조할 곳` / `빚처럼 따져볼 곳`
  /// `[owner, mortgage, jeonse]` → `이름처럼 대조할 곳` / `빚·전세권처럼 따져볼 곳`
  static List<MarkLegendEntry> fromKinds(Iterable<MarkKind> kinds) {
    final present = kinds.toSet();
    final byTone = <MarkTone, List<MarkKind>>{};
    // MarkKind 선언 순서를 유지한다 — 범례 순서가 화면마다 흔들리지 않게.
    for (final kind in MarkKind.values) {
      if (present.contains(kind)) {
        (byTone[kind.tone] ??= <MarkKind>[]).add(kind);
      }
    }
    return [
      for (final tone in MarkTone.values)
        if (byTone[tone] != null)
          MarkLegendEntry(
            tone,
            '${byTone[tone]!.map((k) => k.shortNoun).join('·')}처럼 ${tone.legendVerb}',
          ),
    ];
  }

  /// 종류별 개수를 사람 말로 — `집주인 이름 1곳과 빚 3건`.
  ///
  /// 진입 카드 부제처럼 **전체 내역**을 적을 때 쓴다(뱃지의 "위험 n곳"과 다르다:
  /// 뱃지는 위험만 세고, 이 문구는 대조할 곳까지 전부 센다).
  static String countPhrase(Iterable<MarkKind> kinds) {
    final counts = <MarkKind, int>{};
    for (final kind in kinds) {
      counts[kind] = (counts[kind] ?? 0) + 1;
    }
    final parts = [
      for (final kind in MarkKind.values)
        if ((counts[kind] ?? 0) > 0)
          '${kind.countNoun} ${counts[kind]}${kind.unit}',
    ];
    if (parts.isEmpty) return '';
    if (parts.length == 1) return parts.first;
    final head = parts.sublist(0, parts.length - 1).join(', ');
    return '$head${_wa(head)} ${parts.last}';
  }

  /// 위험 톤인 표시만 센다 — 진입 카드 뱃지의 "위험 n곳".
  static int riskCount(Iterable<MarkKind> kinds) =>
      kinds.where((k) => k.isRisk).length;

  /// 앞 글자에 받침이 있으면 `과`, 없으면 `와`.
  /// (지금 단위는 곳·건뿐이라 늘 '과'지만, 단위가 '개'·'명'으로 늘어도 안 깨지게 둔다)
  static String _wa(String s) => _hasFinalConsonant(s) ? '과' : '와';

  /// 앞 글자에 받침이 있으면 `을`, 없으면 `를` — [countPhrase] 뒤에 붙일 조사.
  static String eul(String s) => _hasFinalConsonant(s) ? '을' : '를';

  static bool _hasFinalConsonant(String s) {
    if (s.isEmpty) return false;
    final code = s.runes.last;
    // 완성형 한글 음절이 아니면 판단할 수 없다 — 흔한 쪽('과')으로 둔다.
    if (code < 0xAC00 || code > 0xD7A3) return true;
    return (code - 0xAC00) % 28 != 0;
  }
}
