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

/// 판례 창고 상태 (계약 §3.19 — 2026-10-24 판례 자동 업데이트).
class PrecedentStatus {
  const PrecedentStatus({this.docCount, this.updatedAt});

  /// 창고에 든 판례 수
  final int? docCount;

  /// 마지막 업데이트 날짜 "YYYY-MM-DD" (모르면 null)
  final String? updatedAt;

  /// 화면 표기 "2026.10.24 기준" — 날짜를 모르면 null(지어내지 않는다).
  String? get asOfLabel {
    final d = updatedAt;
    if (d == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d)) return null;
    return '${d.replaceAll('-', '.')} 기준';
  }

  factory PrecedentStatus.fromJson(Map<String, dynamic> json) => PrecedentStatus(
    docCount: (json['docCount'] as num?)?.toInt(),
    updatedAt: json['updatedAt'] as String?,
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

/// 챗봇 대화 한 줄 (계약 §3.21 — 2026-10-24).
///
/// 서버는 대화를 저장하지 않는다 — 앱이 최근 대화를 통째로 보내야 "더 쉽게" 같은 이어 묻기가 된다.
class ChatTurn {
  const ChatTurn.user(this.content) : isUser = true;
  const ChatTurn.bot(this.content) : isUser = false;

  final bool isUser;
  final String content;

  Map<String, dynamic> toJson() => {
    'role': isUser ? 'user' : 'assistant',
    'content': content,
  };
}

/// 챗봇 질문과 함께 보내는 **이 폰의 계약 일정** 한 집 (계약 §3.21 `ChatJourney` · 2026-10-30).
///
/// 규혁: "잔금이 내일인 걸 챗봇이 알아야 '다음에 뭐 해?'에 답한다". 서버는 이 답을 쓰는 동안만 쓰고
/// **저장하지 않는다**(대화와 같다). 날짜를 저장하는 곳은 여전히 이 휴대폰뿐이다([JourneyScheduleStore]).
class ChatJourney {
  const ChatJourney({
    required this.reportId,
    this.dates = const {},
    this.doneThrough = 0,
    this.selected = false,
  });

  /// 그 집의 최신 리포트 id — 서버가 '내 집' 묶음에서 같은 집을 찾는다
  final String reportId;

  /// downPayment | contract | balance | moveIn → 'YYYY-MM-DD' (넣지 않은 날은 없다)
  final Map<String, String> dates;

  /// 끝난 마지막 단계 번호(0 = 분석만) — 여정 화면과 같은 계산(`JourneyProgress.doneThrough`)
  final int doneThrough;

  /// 계약 여정에서 고른 집인가
  final bool selected;

  Map<String, dynamic> toJson() => {
    'reportId': reportId,
    'dates': dates,
    'doneThrough': doneThrough,
    'selected': selected,
  };
}

/// 챗봇 답 하나 (계약 §3.21 `ChatResponse`).
///
/// `answer`에는 줄바꿈과 `**굵게**` 표시가 들어 있다 — 화면이 굵게 그린다. 출처 라벨·유도 버튼은 없다
/// (2026-10-24 규혁: "여기선 딱 챗봇만"). 판정 칸도 없다 — 판정은 리포트만 한다.
class ChatReply {
  const ChatReply({required this.answer, this.mode = 'normal', this.model = ''});

  final String answer;

  /// normal(AI 답) · careful(판정 요구라 판단 없이 답함) · fallback(AI 대신 기본 문장)
  final String mode;

  /// 답을 쓴 모델(예: solar-pro2). 기본 문장이면 빈 문자열.
  final String model;

  factory ChatReply.fromJson(Map<String, dynamic> json) => ChatReply(
    answer: json['answer'] as String? ?? '',
    mode: json['mode'] as String? ?? 'normal',
    model: json['model'] as String? ?? '',
  );
}

/// S-11 계약 여정 체크리스트 — 단계별 할 일.
class JourneyItem {
  const JourneyItem({required this.text, required this.why, this.where, this.termGlossary = const {}});

  /// 할 일 한 줄 제목
  final String text;

  /// "왜 ·" 펼침 설명 — `**굵게**` 표시가 들어 있을 수 있다
  final String why;

  /// "어디서 ·" 장소·전화·비용. 없으면 그 줄을 그리지 않는다 (2026-10-26)
  final String? where;

  /// "왜" 속 어려운 말 → 풀이 (2026-10-31) — 초록 밑줄, 누르면 뜻. 옛 서버면 비어 있다.
  final Map<String, String> termGlossary;

  factory JourneyItem.fromJson(Map<String, dynamic> json) => JourneyItem(
    text: json['text'] as String,
    why: json['why'] as String,
    where: (json['where'] as String?)?.trim().isEmpty ?? true ? null : json['where'] as String,
    termGlossary: {
      for (final e in ((json['termGlossary'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}',
    },
  );
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
    this.chip,
  });

  final String title;

  /// 단계 칩 줄의 짧은 이름 (예: "가계약금"). 없으면 [title]
  final String? chip;

  String get chipLabel => (chip == null || chip!.trim().isEmpty) ? title : chip!;

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
    chip: json['chip'] as String?,
  );
}
