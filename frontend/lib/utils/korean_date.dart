/// 한국어 날짜 표기 — "8월 6일 (목)" · "7월 9일자" · 경과일.
///
/// 계약 여정(S-11)은 **등기부를 뗀 날**과 **사용자가 넣은 계약 일정**을 계속 견준다.
/// 그 두 종류의 날짜를 화면 여러 곳에서 같은 모양으로 쓰기 위해 한 곳에 모았다.
///
/// ⚠ 여기 함수들은 날짜를 **만들어내지 않는다.** 못 읽은 날짜는 null로 남고, 화면은
///   그 줄을 그리지 않거나 "확인 필요"로 말한다 (분석일로 대신 채우지 않는다).
library;

const List<String> _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

/// "목" (요일 한 글자)
String weekdayLabel(DateTime date) => _weekdays[date.weekday - 1];

/// "8월 6일"
String formatMonthDay(DateTime date) => '${date.month}월 ${date.day}일';

/// "8월 6일 (목)"
String formatMonthDayWeekday(DateTime date) =>
    '${formatMonthDay(date)} (${weekdayLabel(date)})';

/// "2026년 8월 1일"
String formatFullDate(DateTime date) =>
    '${date.year}년 ${date.month}월 ${date.day}일';

/// 등기부에 인쇄된 열람일 `YYYY.MM.DD` → DateTime. 못 읽으면 null.
DateTime? parseRegistryViewedAt(String? viewedAt) {
  final raw = viewedAt?.trim();
  if (raw == null || raw.isEmpty) return null;
  final m = RegExp(r'^(\d{4})[.\-/](\d{1,2})[.\-/](\d{1,2})').firstMatch(raw);
  if (m == null) return null;
  final year = int.parse(m.group(1)!);
  final month = int.parse(m.group(2)!);
  final day = int.parse(m.group(3)!);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return DateTime(year, month, day);
}

/// 오늘 자정 (날짜만 비교할 때 기준점)
DateTime today() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

/// [date]로부터 오늘까지 지난 날수. 미래면 음수.
int daysSince(DateTime date) =>
    today().difference(DateTime(date.year, date.month, date.day)).inDays;

/// 오늘부터 [date]까지 남은 날수. 오늘이면 0, 내일이면 1.
int daysUntil(DateTime date) =>
    DateTime(date.year, date.month, date.day).difference(today()).inDays;

/// "내일이에요" · "오늘이에요" · "3일 남았어요" · "지난 날짜예요"
String relativeDayLabel(DateTime date) {
  final days = daysUntil(date);
  if (days == 0) return '오늘이에요';
  if (days == 1) return '내일이에요';
  if (days > 1) return '$days일 남았어요';
  return '지난 날짜예요';
}
