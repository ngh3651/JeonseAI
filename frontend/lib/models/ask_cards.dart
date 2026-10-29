/// 리포트 4장 '중개사에게 물어볼 질문' (계약 §2.4-2 · 2026-10-29).
///
/// 질문 고르기·합격선 숫자·좋은 답·핑계·특약은 **서버**가 정한다(규칙 + 정해 둔 문구).
/// `why`만 AI가 이 집 숫자로 다시 쓸 수 있다(서버가 검사 통과분만 보낸다). 앱은 그리기만 한다.
library;

class AskPass {
  const AskPass({this.big, required this.text, this.sub, this.danger = false});

  /// 크게 쓰는 값 — '0원' (없을 수 있음)
  final String? big;
  final String text;
  final String? sub;

  /// sub를 빨강으로
  final bool danger;

  factory AskPass.fromJson(Map<String, dynamic> j) => AskPass(
    big: j['big'] as String?,
    text: (j['text'] as String?) ?? '',
    sub: j['sub'] as String?,
    danger: j['tone'] == 'danger',
  );
}

class AskCard {
  const AskCard({
    required this.id,
    required this.title,
    this.legal = false,
    this.facts = const [],
    required this.why,
    this.whyByAi = false,
    required this.ask,
    required this.okReply,
    required this.badReply,
    required this.counter,
    required this.passLine,
    this.docs = const [],
    required this.clause,
    required this.stopSub,
  });

  final String id;
  final String title;

  /// 집주인이 계약 때 보여 줘야 하는 서류를 받는 질문 (주택임대차보호법 제3조의7)
  final bool legal;
  final List<String> facts;
  final String why;
  final bool whyByAi;
  final String ask;
  final String okReply;
  final String badReply;
  final String counter;
  final AskPass passLine;
  final List<String> docs;
  final String clause;
  final String stopSub;

  factory AskCard.fromJson(Map<String, dynamic> j) => AskCard(
    id: j['id'] as String,
    title: j['title'] as String,
    legal: (j['legal'] as bool?) ?? false,
    facts: [for (final f in (j['facts'] as List?) ?? const []) f as String],
    why: (j['why'] as String?) ?? '',
    whyByAi: (j['whyByAi'] as bool?) ?? false,
    ask: j['ask'] as String,
    okReply: (j['okReply'] as String?) ?? '',
    badReply: (j['badReply'] as String?) ?? '',
    counter: (j['counter'] as String?) ?? '',
    passLine: AskPass.fromJson(
      (j['passLine'] as Map?)?.cast<String, dynamic>() ?? const {'text': ''},
    ),
    docs: [for (final d in (j['docs'] as List?) ?? const []) d as String],
    clause: (j['clause'] as String?) ?? '',
    stopSub: (j['stopSub'] as String?) ?? '',
  );
}

class AskCards {
  const AskCards({this.cards = const [], this.stop, this.shareText = ''});

  /// 최대 4개 (서버가 자른다)
  final List<AskCard> cards;

  /// 경매가 진행 중인 집 — 질문 대신 이 문장
  final String? stop;
  final String shareText;

  static const AskCards empty = AskCards();

  bool get isEmpty => cards.isEmpty && stop == null;

  factory AskCards.fromJson(Map<String, dynamic> j) => AskCards(
    cards: [
      for (final c in (j['cards'] as List?) ?? const [])
        AskCard.fromJson(c as Map<String, dynamic>),
    ],
    stop: j['stop'] as String?,
    shareText: (j['shareText'] as String?) ?? '',
  );
}
