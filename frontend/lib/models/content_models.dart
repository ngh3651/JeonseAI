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
    this.termGlossary = const {},
    this.emphasis = const {},
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

  /// 본문에 나온 어려운 말 → 쉬운 설명 (계약 §2.3 termGlossary, 2026-08-14 D20).
  ///
  /// 근거 카드(`EvidenceItem.termGlossary`)와 **같은 구조·같은 규칙**이다 —
  /// 키가 본문에 글자 그대로 있어야 `indexOf`로 찾아 점선 밑줄을 붙일 수 있다.
  /// 서버는 검수된 용어(terms.json `verified=true`)만 내려보낸다.
  final Map<String, String> termGlossary;

  /// `{필드명: [굵게 그릴 부분 문자열, ...]}` (계약 §2.3 emphasis, 2026-08-14 D23).
  ///
  /// 필드명은 이 모델의 이름 그대로 — `result` · `commonPoint` · `advice`.
  /// **본문을 바꾸는 값이 아니라 가리키는 값**이라, 못 찾으면 굵기만 안 붙고 끝난다.
  final Map<String, List<String>> emphasis;

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
    // additive 필드 — 옛 서버 응답에는 없다. 없으면 빈 값이고 화면은 그대로 그려진다.
    termGlossary: {
      for (final e in (json['termGlossary'] as Map? ?? const {}).entries)
        e.key as String: e.value as String,
    },
    emphasis: {
      for (final e in (json['emphasis'] as Map? ?? const {}).entries)
        e.key as String: [
          for (final v in (e.value as List? ?? const [])) v as String,
        ],
    },
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

/// 챗봇 답 하나 (계약 §3.9 — 2026-08-14 S-12).
///
/// **거절도 답이다.** 예전에는 서버가 404를 주고 앱이 거절 문구를 하드코딩했는데,
/// 이제 사전 답·LLM 답·거절이 **같은 모양**으로 온다. 앱이 하는 일은 `outOfScope`를
/// 보고 유도 버튼을 붙일지 정하는 것뿐이다.
class GlossaryAnswer {
  const GlossaryAnswer({
    required this.answer,
    this.outOfScope = false,
    this.source = '',
    this.termGlossary = const {},
    this.term,
  });

  /// 화면에 그대로 그릴 문장 — 앱이 고쳐 쓰지 않는다.
  final String answer;

  /// true면 답변 아래에 유도 버튼(리포트/분석)을 붙인다. **경고색은 쓰지 않는다.**
  final bool outOfScope;

  /// 이 문장을 누가 썼는가 — "검수된 용어 사전" | 실제 모델명 | "준비된 문구".
  /// 말풍선 아래 회색 한 줄로 그대로 보여준다(2026-08-14 D26과 같은 정직성 원칙).
  final String source;

  /// 답변에 등장한 어려운 말 → 쉬운 설명. 근거 카드·판례와 **같은 메커니즘**.
  final Map<String, String> termGlossary;

  /// 사전 직격일 때만 그 용어명. 자연어 답변·거절이면 null.
  final String? term;

  /// 서버에 닿지 못했을 때(옛 서버의 404 포함) 쓰는 기본 거절 — 문구는 서버 것과 같다.
  static const GlossaryAnswer fallback = GlossaryAnswer(
    answer:
        '저는 부동산 용어를 쉽게 설명해 드리는 도우미예요. '
        '이 집이 안전한지는 안전도 리포트가 분석해 드려요.',
    outOfScope: true,
    source: '준비된 문구',
  );

  factory GlossaryAnswer.fromJson(Map<String, dynamic> json) => GlossaryAnswer(
    // 옛 서버는 `answer`가 없고 `description`만 준다 — 그때도 화면이 살아야 한다.
    answer: (json['answer'] as String?) ?? (json['description'] as String? ?? ''),
    outOfScope: json['outOfScope'] as bool? ?? false,
    source: json['source'] as String? ?? '',
    termGlossary: (json['termGlossary'] as Map<String, dynamic>? ?? const {})
        .map((k, v) => MapEntry(k, v as String)),
    term: json['term'] as String?,
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

/// 단계의 성격 — 화면이 도트·카드를 어떻게 그릴지 정한다 (S-11).
enum JourneyStageKind {
  /// 분석 기록이 있으면 **자동으로 끝난 단계** (사용자가 바꿀 수 없다)
  analysis,

  /// 지금 해야 할 일
  action,

  /// 1~2년 뒤 일 — 흐리게, 점선 도트
  later;

  /// 서버가 앱보다 먼저 새 값을 내보내면 평범한 '할 일'로 떨어뜨린다.
  static JourneyStageKind fromWire(String? value) => switch (value) {
    'analysis' => JourneyStageKind.analysis,
    'later' => JourneyStageKind.later,
    _ => JourneyStageKind.action,
  };
}

/// 이 단계에 붙는 사용자 일정 칸. **날짜 값은 기기에만 저장된다** — 서버는 키만 준다.
enum JourneyDateKey {
  downPayment('가계약금 보내는 날'),
  contract('계약서 쓰는 날'),
  balance('잔금 보내는 날'),
  moveIn('이사 오는 날'),

  /// 이사일 다음 날 — 사용자에게 묻지 않고 앱이 계산한다.
  moveInNext('입주 다음 날');

  const JourneyDateKey(this.label);

  final String label;

  /// 시트에서 직접 입력받는 칸 4개 (moveInNext는 계산값이라 묻지 않는다)
  static const List<JourneyDateKey> editable = [
    downPayment,
    contract,
    balance,
    moveIn,
  ];

  static JourneyDateKey? fromWire(String? value) {
    for (final k in JourneyDateKey.values) {
      if (k.name == value) return k;
    }
    return null;
  }
}

class JourneyStage {
  const JourneyStage({
    required this.title,
    required this.subtitle,
    required this.items,
    this.kind = JourneyStageKind.action,
    this.compare = false,
    this.askDates = false,
    this.agency,
    this.dateKey,
  });

  final String title;

  /// 단계명 아래 쉬운 부제 (예: "나머지 보증금을 보내는 날")
  final String subtitle;
  final List<JourneyItem> items;

  final JourneyStageKind kind;

  /// [다시 떼서 대조하기] 버튼을 붙일 단계인가 — 등기부를 다시 떼야 하는 시점.
  final bool compare;

  /// 이 단계에서 계약 일정 입력을 권할지 (계약서에 날짜가 적히는 시점)
  final bool askDates;

  /// 어디서 하는 일인지 알려주는 칩 (예: "주민센터에서")
  final String? agency;

  /// 이 단계에 붙는 일정 칸. 없으면 날짜와 무관한 단계.
  final JourneyDateKey? dateKey;

  /// 잔금 단계인가 — 이 앱이 가장 크게 다루는 하루.
  bool get isBalance => dateKey == JourneyDateKey.balance;

  factory JourneyStage.fromJson(Map<String, dynamic> json) => JourneyStage(
    title: json['title'] as String,
    subtitle: json['subtitle'] as String,
    items: [
      for (final i in json['items'] as List)
        JourneyItem.fromJson(i as Map<String, dynamic>),
    ],
    // 아래는 전부 선택 — 구버전 서버면 종전 체크리스트와 같은 모양이 된다.
    kind: JourneyStageKind.fromWire(json['kind'] as String?),
    compare: json['compare'] as bool? ?? false,
    askDates: json['askDates'] as bool? ?? false,
    agency: json['agency'] as String?,
    dateKey: JourneyDateKey.fromWire(json['dateKey'] as String?),
  );
}
