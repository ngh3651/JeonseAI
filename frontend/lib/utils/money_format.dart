/// 금액 표기 유틸 — "1억 2,000만원" 스타일 (타깃 유저에게 익숙한 한국식 표기).
library;

String formatWon(int won) {
  if (won <= 0) return '0원';

  final int eok = won ~/ 100000000;
  final int man = (won % 100000000) ~/ 10000;

  final StringBuffer buf = StringBuffer();
  if (eok > 0) buf.write('$eok억');
  if (man > 0) {
    if (eok > 0) buf.write(' ');
    buf.write('${_comma(man)}만');
  }
  if (buf.isEmpty) buf.write(_comma(won)); // 1만원 미만 (더미에선 거의 없음)
  buf.write('원');
  return buf.toString();
}

String _comma(int n) {
  final String s = n.toString();
  final StringBuffer buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

/// "2026.06.27" 형식 날짜.
String formatDate(DateTime dt) {
  final String mm = dt.month.toString().padLeft(2, '0');
  final String dd = dt.day.toString().padLeft(2, '0');
  return '${dt.year}.$mm.$dd';
}

/// "7일 전 분석" / "오늘 분석" 형식.
String formatDaysAgo(DateTime dt) {
  final int days = DateTime.now().difference(dt).inDays;
  if (days <= 0) return '오늘 분석';
  return '$days일 전 분석';
}
