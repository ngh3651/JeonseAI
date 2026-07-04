/// 큐레이션 콘텐츠 모델 (판례·질문·용어·계약 여정).
///
/// **모든 데이터는 Phase C 더미다.** 실제 판례·질문·용어는 E-2·E-3에서 채워지며
/// (비개발 팀원 큐레이션 분담 후보 — docs/plan.md), 구조는 향후 API 계약과 동일 형태를
/// 유지한다. 판례·위험 기준 등 수치·출처가 필요한 항목은 E 단계에서 출처와 함께 확정한다.
library;

/// S-08 판례 매칭 — 위험 패턴별 큐레이션 판례.
class CaseMatch {
  const CaseMatch({
    required this.riskPattern,
    required this.caseNo,
    required this.summary,
    required this.result,
    required this.commonPoint,
  });

  /// 우리 매물의 위험 패턴 (칩 표시)
  final String riskPattern;

  /// 사건번호 (예시)
  final String caseNo;

  /// 사건 한 줄 요약
  final String summary;

  /// 결과
  final String result;

  /// 우리 매물과의 공통점
  final String commonPoint;
}

/// S-10 질문 생성기 — 위험 요소별 질문 + 답변 판별 가이드.
class QuestionItem {
  const QuestionItem({
    required this.question,
    required this.why,
    required this.safeAnswer,
    required this.riskyAnswer,
  });

  final String question;

  /// 왜 물어봐야 하는지 한 줄
  final String why;

  /// 이런 답이면 안심
  final String safeAnswer;

  /// 이런 답이면 보류
  final String riskyAnswer;
}

class QuestionGroup {
  const QuestionGroup({required this.riskLabel, required this.items});

  /// 위험 요소 이름 (예: "신탁등기")
  final String riskLabel;
  final List<QuestionItem> items;
}

/// S-12 용어 챗봇 — 용어 설명.
class GlossaryTerm {
  const GlossaryTerm({required this.term, required this.description});

  final String term;
  final String description;
}

/// S-11 계약 여정 체크리스트 — 단계별 할 일.
class JourneyItem {
  const JourneyItem({required this.text, required this.why});

  final String text;

  /// "왜 해야 하나요?" 펼침 설명
  final String why;
}

class JourneyStage {
  const JourneyStage({
    required this.title,
    required this.subtitle,
    required this.items,
  });

  final String title;

  /// 단계명 아래 쉬운 부제 (예: "나머지 보증금을 보내는 날")
  final String subtitle;
  final List<JourneyItem> items;
}
