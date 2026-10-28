/// 분석 로딩 화면의 **"리포트 꿀팁"** (2026-10-28) — 몇 초마다 바뀐다.
///
/// 2026-10-28 바꿈: 부동산 상식 팁("알고 계셨나요?") → **리포트에서 눌러 볼 기능** 안내.
/// 부스 시연에서 로딩 30초 동안 "리포트가 뜨면 이걸 눌러 보세요"를 미리 말해 두려는 것이다(규혁 결정).
/// 판정에 쓰지 않는 안내 문장이다(숫자 기준 없음). 버튼 이름은 앱 화면의 실제 이름 그대로 쓴다.
///
/// 문장 규칙
/// - `**굵게**`는 한 팁에 **1곳만**(핵심 말 = 버튼 이름).
/// - 카드 본문이 **3줄 높이로 고정**이라, 글자 크기 130%에서도 3줄 안에 들어가야 한다
///   (`test/analysis_loading_test.dart`가 잰다). 넘치면 글자를 줄이지 말고 문장을 줄인다.
library;

import 'package:flutter/painting.dart';

/// 카드 윗줄 제목
const String kLoadingTipsTitle = '리포트 꿀팁';

const List<String> kLoadingTips = [
  '**판례 매칭**에서 이 집과 비슷한 상황의 실제 판례를 볼 수 있어요.',
  '**내가 올린 사진에서 보기**를 누르면 근거가 된 줄을 내 사진에서 바로 찾아 줘요.',
  '**손실 시뮬레이터**로 경매에 넘어가면 보증금을 얼마나 돌려받을지 계산해 보세요.',
  // 알림 시각 = services/journey_reminders.dart 의 kReminderHour (일정마다 오전 8시)
  '**계약 여정**에 날짜를 넣어 두세요. 그날 오전 8시에 꼭 챙길 일을 알려 줘요.',
];

/// `**굵게**` 표시를 글자 조각으로 나눈다 — 굵은 조각은 [bold] 모양으로.
List<TextSpan> tipSpans(String tip, {required TextStyle bold}) {
  final spans = <TextSpan>[];
  final parts = tip.split('**');
  for (var i = 0; i < parts.length; i++) {
    if (parts[i].isEmpty) continue;
    spans.add(TextSpan(text: parts[i], style: i.isOdd ? bold : null));
  }
  return spans;
}

/// 굵게 표시를 뺀 맨글
String tipPlain(String tip) => tip.replaceAll('**', '');
