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
    this.sourceUrl,
    this.advice,
    this.curated = false,
    this.matchedTags = const [],
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

  /// 판결문 원문 링크 — 사용자가 직접 확인할 수 있어야 "지어내지 않았다"가 검증된다
  final String? sourceUrl;

  /// "이런 피해를 피하려면" — 큐레이션 문구 (없을 수 있음)
  final String? advice;

  /// 문구를 사람이 검수했는지.
  ///
  /// 출처(법원·사건번호·링크)는 어느 카드든 공식 DB로 확인된 것이지만,
  /// 쉬운 말 요약까지 사람이 읽은 판례는 아직 일부다. false면 화면에 그 사실을
  /// 밝힌다 — 검수된 것과 안 된 것을 **섞어서 내보내지 않기 위한** 표시다.
  final bool curated;

  /// 이 판례가 우리 매물의 어떤 위험과 겹쳤는지 (계약 §2.3 matchedTags).
  ///
  /// 카드 맨 위 소제목으로 쓴다 — 본문을 다 읽기 전에 "이 판례가 무엇에 관한
  /// 경고인지"를 먼저 알려야 카드가 눈으로 훑어진다. 서버 정렬도 이 개수가
  /// 1순위 키라, 위쪽 카드일수록 뱃지가 많은 것이 자연스럽게 보인다.
  /// 비어 있으면 [riskPattern] 하나로 대신한다.
  final List<String> matchedTags;

  /// 화면에 그릴 위험 태그 — 비어 있으면 riskPattern으로 폴백.
  List<String> get displayTags =>
      matchedTags.isNotEmpty ? matchedTags : [riskPattern];

  factory CaseMatch.fromJson(Map<String, dynamic> json) => CaseMatch(
    riskPattern: json['riskPattern'] as String,
    caseNo: json['caseNo'] as String,
    summary: json['summary'] as String,
    result: json['result'] as String,
    commonPoint: json['commonPoint'] as String,
    sourceUrl: json['sourceUrl'] as String?,
    advice: json['advice'] as String?,
    curated: json['curated'] as bool? ?? false,
    matchedTags:
        (json['matchedTags'] as List?)?.map((e) => e as String).toList() ??
        const [],
  );
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

  factory QuestionItem.fromJson(Map<String, dynamic> json) => QuestionItem(
    question: json['question'] as String,
    why: json['why'] as String,
    safeAnswer: json['safeAnswer'] as String,
    riskyAnswer: json['riskyAnswer'] as String,
  );
}

class QuestionGroup {
  const QuestionGroup({required this.riskLabel, required this.items});

  /// 위험 요소 이름 (예: "신탁등기")
  final String riskLabel;
  final List<QuestionItem> items;

  factory QuestionGroup.fromJson(Map<String, dynamic> json) => QuestionGroup(
    riskLabel: json['riskLabel'] as String,
    items: [
      for (final i in json['items'] as List)
        QuestionItem.fromJson(i as Map<String, dynamic>),
    ],
  );
}

/// S-12 용어 챗봇 — 용어 설명.
class GlossaryTerm {
  const GlossaryTerm({required this.term, required this.description});

  final String term;
  final String description;

  factory GlossaryTerm.fromJson(Map<String, dynamic> json) => GlossaryTerm(
    term: json['term'] as String,
    description: json['description'] as String,
  );
}

/// S-11 계약 여정 체크리스트 — 단계별 할 일.
class JourneyItem {
  const JourneyItem({required this.text, required this.why});

  final String text;

  /// "왜 해야 하나요?" 펼침 설명
  final String why;

  factory JourneyItem.fromJson(Map<String, dynamic> json) =>
      JourneyItem(text: json['text'] as String, why: json['why'] as String);
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

  factory JourneyStage.fromJson(Map<String, dynamic> json) => JourneyStage(
    title: json['title'] as String,
    subtitle: json['subtitle'] as String,
    items: [
      for (final i in json['items'] as List)
        JourneyItem.fromJson(i as Map<String, dynamic>),
    ],
  );
}
