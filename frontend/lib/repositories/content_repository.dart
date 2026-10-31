/// 큐레이션 콘텐츠 저장소 — 판례·질문·용어·계약 여정 (인터페이스 + 더미).
///
/// 화면은 이 인터페이스에만 의존한다. D-3부터 실제 주입은 ApiContentRepository(서버)이고,
/// **DummyContentRepository는 위젯 테스트 전용**으로만 남는다(프로덕션 폴백 아님 —
/// docs/cleanup-tracker.md 참고). Phase E에서 서버 쪽이 큐레이션/LLM 실데이터로 교체된다.
///
/// D-3 인터페이스 변경: 판례·질문은 서버가 리포트 id에서 위험 패턴을 파생하므로
/// (api-contract.md §2.2 note) reportId 기반 + 전부 Future가 됐다.
library;

import '../models/ask_cards.dart';
import '../models/content_models.dart';

abstract class ContentRepository {
  /// 리포트의 위험 패턴에 매칭되는 판례 (없으면 빈 리스트 → 빈 상태 처리).
  Future<List<CaseMatch>> matchedCases(String reportId);

  /// 위험 요소별 질문 그룹. 위험 요소가 없어도 기본 질문 세트 포함.
  Future<List<QuestionGroup>> questionGroups(String reportId);

  /// 리포트 4장 '중개사에게 물어볼 질문' (계약 §3.6-2 · 2026-10-29). 최대 4개.
  /// [polish]: 상세 화면이면 true — why를 AI가 이 집 숫자로 다시 쓴다(서버가 검사).
  Future<AskCards> askCards(String reportId, {bool polish = false});

  /// 챗봇 추천 용어 칩.
  Future<List<GlossaryTerm>> glossaryTerms();

  /// 챗봇 — 최근 대화(마지막 = 이번 질문) → 답 하나 (계약 §3.21 · 2026-10-24).
  ///
  /// 판정 요구 알아채기·AI 답·검사·기본 문장은 전부 서버 쪽 일이다. 앱은 그리기만 한다.
  /// [reportId]: 사용자가 보던 리포트(2026-10-26) — 서버가 그 리포트(이 사용자 것만, 이름 가린 사본)를 알고 답한다.
  /// [journeys]: 이 폰의 계약 일정(2026-10-30) — 서버가 '다음 할 일'을 알고 답한다(저장하지 않는다).
  /// null이면 보내지 않는다(서버는 일정을 모르는 것으로 본다).
  Future<ChatReply> chat(
    List<ChatTurn> messages, {
    String? reportId,
    List<ChatJourney>? journeys,
  });

  /// 계약 여정 단계.
  Future<List<JourneyStage>> journeyStages();

  /// 판례 창고 상태(판례 수·마지막 업데이트 날짜, 계약 §3.19). 모르면 null — 화면은 날짜를 뺀다.
  Future<PrecedentStatus?> precedentStatus();
}

/// 위젯 테스트 전용 더미 (서버 없이 화면 흐름 테스트). 프로덕션 주입 금지.
class DummyContentRepository implements ContentRepository {
  @override
  Future<PrecedentStatus?> precedentStatus() async => null;

  @override
  Future<List<CaseMatch>> matchedCases(String reportId) async {
    return const [
      CaseMatch(
        riskPattern: '신탁등기',
        caseNo: '대법원 2022다123456 (예시)',
        summary:
            '신탁등기된 집을 신탁회사 동의 없이 임대해, 임차인이 대항력을 '
            '인정받지 못한 사례',
        result: '임차인이 보증금을 돌려받지 못함',
        commonPoint: '이 매물도 신탁등기가 설정되어 있어요',
      ),
      CaseMatch(
        riskPattern: '선순위 채권',
        caseNo: '수원지법 2021가단45678 (예시)',
        summary:
            '근저당이 시세에 육박한 집이 경매로 넘어가, 후순위 임차인이 '
            '배당을 거의 받지 못한 사례',
        result: '보증금 대부분 손실',
        commonPoint: '이 매물도 근저당 금액이 커요',
      ),
    ];
  }

  @override
  Future<AskCards> askCards(String reportId, {bool polish = false}) async =>
      kDummyAskCards;

  @override
  Future<List<QuestionGroup>> questionGroups(String reportId) async {
    // 테스트 전용: 위험 요소 그룹 + 기본 그룹을 항상 반환 (서버는 리포트에서 파생)
    const riskLabels = ['신탁등기', '선순위 채권'];
    final groups = <QuestionGroup>[];

    if (riskLabels.contains('신탁등기')) {
      groups.add(
        const QuestionGroup(
          riskLabel: '신탁등기',
          items: [
            QuestionItem(
              question: '신탁원부(신탁 내용을 적은 서류)를 보여주실 수 있나요?',
              why: '신탁등기가 있으면 집주인 마음대로 계약을 못 할 수 있어요',
              safeAnswer: '신탁원부를 바로 보여주고, 임대 권한이 있음을 확인해 준다',
              riskyAnswer: '보여줄 수 없다거나 얼버무린다',
            ),
            QuestionItem(
              question: '신탁회사의 임대 동의서가 있나요?',
              why: '동의 없이 맺은 계약은 효력을 인정받지 못할 수 있어요',
              safeAnswer: '서면 동의서를 제시한다',
              riskyAnswer: '구두로 괜찮다고만 한다',
            ),
          ],
        ),
      );
    }

    if (riskLabels.contains('선순위 채권')) {
      groups.add(
        const QuestionGroup(
          riskLabel: '선순위 채권 · 근저당',
          items: [
            QuestionItem(
              question: '잔금일에 근저당을 말소해 주실 수 있나요?',
              why: '먼저 잡힌 빚이 남아 있으면 보증금을 못 돌려받을 위험이 커요',
              safeAnswer: '잔금일에 말소하겠다고 특약으로 넣어 준다',
              riskyAnswer: '말소 계획이 없다고 한다',
            ),
          ],
        ),
      );
    }

    // 위험 요소가 없어도 기본 질문은 제공 (빈 상태 방지)
    groups.add(
      const QuestionGroup(
        riskLabel: '어떤 집이든 꼭',
        items: [
          QuestionItem(
            question: '전세보증금 반환보증(보증보험)에 가입할 수 있는 집인가요?',
            why: '가입이 되면 보증기관이 보증금을 대신 돌려줘요',
            safeAnswer: '가입 가능하다고 확인해 준다',
            riskyAnswer: '가입이 안 된다거나 모른다고 한다',
          ),
          QuestionItem(
            question: '등기부등본상 소유자와 계약 당사자가 같은 사람인가요?',
            why: '실소유자가 아닌 사람과 계약하면 보증금을 지키기 어려워요',
            safeAnswer: '신분증과 등기부등본 소유자가 일치한다',
            riskyAnswer: '대리인인데 위임장이 없다',
          ),
        ],
      ),
    );

    return groups;
  }

  @override
  Future<List<GlossaryTerm>> glossaryTerms() async => const [
    GlossaryTerm(
      term: '신탁등기',
      description:
          '집의 관리 권한을 신탁회사에 맡겼다는 표시예요. 이 경우 '
          '집주인 단독으로는 전세 계약을 맺을 수 없는 경우가 많아, 신탁회사의 '
          '동의가 있었는지 꼭 확인해야 해요.',
    ),
    GlossaryTerm(
      term: '근저당',
      description:
          '집주인이 집을 담보로 돈을 빌렸다는 표시예요. 집이 경매로 '
          '넘어가면 돈을 빌려준 쪽(주로 은행)이 세입자보다 먼저 돈을 받아가요.',
    ),
    GlossaryTerm(
      term: '전세가율',
      description:
          '보증금이 집값의 몇 %인지를 나타내는 비율이에요. 높을수록 '
          '집값이 떨어졌을 때 보증금을 돌려받기 어려워져요.',
    ),
    GlossaryTerm(
      term: '확정일자',
      description:
          '전세 계약서에 날짜 도장을 받는 거예요. 이 날짜가 있어야 '
          '집이 경매로 넘어가도 보증금을 돌려받을 순위가 생겨요.',
    ),
    GlossaryTerm(
      term: '대항력',
      description:
          '집주인이 바뀌어도 세입자가 계속 살 수 있고 보증금을 '
          '주장할 수 있는 힘이에요. 전입신고 + 실제 거주로 생겨요.',
    ),
    GlossaryTerm(
      term: '우선변제권',
      description:
          '집이 경매로 넘어갔을 때 다른 채권자보다 먼저 보증금을 '
          '돌려받을 수 있는 권리예요. 대항력 + 확정일자가 있어야 해요.',
    ),
  ];

  /// 서버 챗봇의 **아주 얇은 흉내** — 위젯 테스트가 서버 없이 대화를 그릴 수 있을 만큼만.
  @override
  Future<ChatReply> chat(
    List<ChatTurn> messages, {
    String? reportId,
    List<ChatJourney>? journeys,
  }) async {
    final q = messages.isEmpty ? '' : messages.last.content.trim();
    for (final t in await glossaryTerms()) {
      if (q.contains(t.term)) {
        return ChatReply(answer: '**${t.term}**은 ${t.description}');
      }
    }
    return const ChatReply(answer: '안녕하세요!\n전세 이야기라면 편하게 물어보세요.');
  }

  /// 계약 여정 9단계 — **정본은 서버의 `backend/data/journey_stages.json`이다.**
  /// 여기 값은 위젯 테스트가 서버 없이 같은 모양의 화면을 그릴 수 있게 둔 사본이라,
  /// 문구가 바뀌면 데이터 파일 쪽을 먼저 고치고 이쪽을 맞춘다.
  @override
  Future<List<JourneyStage>> journeyStages() async => const [
    JourneyStage(
      title: '집 둘러보고 등기부 분석하기',
      chip: '분석',
      subtitle: '리포트가 못 보는 것 챙기기',
      kind: JourneyStageKind.analysis,
      items: [
        JourneyItem(
          text: '등록된 중개사인지 조회',
          why: '자격 없는 사람이 중개사인 척하는 **사기**가 있어요',
          where: '국가공간정보포털 · 이름·상호로 검색',
        ),
        JourneyItem(
          text: '건축물대장 떼어 보기',
          why: '\'위반건축물\'이거나 \'근린생활시설\'이면 **보증보험·전세대출이 막힐 수 있어요**',
          where: '정부24 · 무료',
        ),
      ],
    ),
    JourneyStage(
      title: '가계약금 보내기 전',
      chip: '가계약금',
      subtitle: '**적은 돈이라도 보내면 되돌리기 어려워요**',
      compare: true,
      dateKey: JourneyDateKey.downPayment,
      items: [
        JourneyItem(
          text: '등기부 다시 떼서 대조',
          why: '등기부는 **뗀 날짜 기준으로만** 맞는 정보예요',
          where: '인터넷등기소 · 열람 700원',
        ),
        JourneyItem(
          text: '보증보험 가입 가능 확인',
          why: '가입이 안 되는 집은 문제가 생겨도 **대신 돌려줄 곳이 없어요**',
          where: 'HUG ☎1566-9009 · 중개사',
        ),
        JourneyItem(
          text: '집주인 계좌로만 보내기',
          why: '중개사·대리인·가족 계좌로 보낸 돈은 **되찾기 어려워요**',
        ),
        JourneyItem(
          text: '반환 조건 문자로 남기기',
          why: '"보증보험·대출이 안 되면 돌려준다"를 꼭 문자로 남기세요. "계약금의 일부"라고 쓰면 이미 계약한 걸로 봐서 그만둘 때 **계약금 전체를 물어야** 할 수 있어요. "가계약금은 해약금으로 한다"처럼 쓰세요',
        ),
        JourneyItem(
          text: '재촉하면 멈추기',
          why: '"오늘 안 보내면 나가요"로 서두르게 한 뒤 **가계약금만 받고 사라지는** 사기가 흔해요',
        ),
      ],
    ),
    JourneyStage(
      title: '계약서 쓰는 날',
      chip: '계약서',
      subtitle: '**사기의 대부분이 이날 일어나요**',
      compare: true,
      dateKey: JourneyDateKey.contract,
      items: [
        JourneyItem(
          text: '도장 직전 등기부 대조',
          why: '도장 찍는 날 기준으로 다시 봐야 해요',
          where: '인터넷등기소 · 열람 700원',
        ),
        JourneyItem(
          text: '신분증 진짜인지 확인',
          why: '위조 신분증 사기가 있어요. **대리인이면 위임장·인감증명서 + 집주인과 영상통화**',
          where: '정부24 · ☎1382',
        ),
        JourneyItem(
          text: '주소·호수·이름 대조',
          why: '하나라도 다르면 **엉뚱한 집이나 엉뚱한 사람과** 계약하는 셈이에요',
          where: '계약서 ↔ 등기부',
        ),
        JourneyItem(
          text: '세금 체납·다른 세입자 보증금 기록 받기',
          why: '밀린 세금은 등기부에 안 보이는데 **내 보증금보다 먼저** 가져가요. 중개사가 주는 중개대상물 확인·설명서 4번 칸에 **열람 동의** 체크를 받으세요',
          where: '집주인이 보여줘야 하는 서류 (법)',
        ),
        JourneyItem(
          text: '확정일자 받기',
          why: '계약한 날 바로 받을 수 있어요. 전월세 신고를 하면 **자동으로** 붙어요',
          where: '주민센터 · 인터넷등기소 · 전월세 신고(30일 안)',
        ),
        JourneyItem(
          text: '전월세 신고 누가 할지 정하기',
          why: '보증금 6천만원이 넘거나 월세가 30만원이 넘으면 계약하고 **30일 안에** 신고해야 해요. 안 하면 과태료라 누가 할지 계약서 특약에 적어 두세요',
          where: '주민센터 · 부동산거래관리시스템(온라인)',
        ),
      ],
    ),
    JourneyStage(
      title: '잔금 보내는 날',
      chip: '잔금',
      subtitle: '**가장 큰 돈이 나가는 날**',
      compare: true,
      dateKey: JourneyDateKey.balance,
      items: [
        JourneyItem(
          text: '이체 직전 등기부 대조',
          why: '잔금 직전에 이 집에 **새 빚(근저당)**이 생기는 일이 있어요. 계좌를 열어 둔 채 떼어 보고 바로 보내요',
          where: '인터넷등기소 · 열람 700원',
        ),
        JourneyItem(
          text: '\'신청사건\' 표시 보기',
          why: '등기가 아직 처리 중이면 등기부에 **신청사건 처리중**이 찍혀요. 새 빚일 수 있어 무엇인지 확인될 때까지 보내지 마세요',
          where: '이 앱이 사진에서 찾아 줘요 · 인터넷등기소',
        ),
        JourneyItem(
          text: '계좌 주인 = 집주인',
          why: '집주인 이름처럼 꾸민 **모임통장 사기**가 있어요. 이름 뒤에 괄호나 다른 글자가 붙어 있으면 멈추세요',
        ),
        JourneyItem(
          text: '전 세입자 나가는지 확인',
          why: '그 사람이 돈을 못 받고 남아 있으면 **내 앞 순서**가 돼요',
          where: '전입세대확인서 · 주민센터',
        ),
        JourneyItem(
          text: '근저당 몫은 은행에 직접',
          why: '집주인에게 주면 **빚을 안 갚을 수 있어요**',
          where: '집주인 대출 은행 계좌',
        ),
      ],
    ),
    JourneyStage(
      title: '이사 당일',
      chip: '이사',
      subtitle: '**오늘 꼭 전입신고**',
      agency: '주민센터·정부24',
      dateKey: JourneyDateKey.moveIn,
      items: [
        JourneyItem(
          text: '이삿날 바로 전입신고',
          why: '이사 + 전입신고를 마쳐야 **대항력**이 생겨요. 하루 늦으면 빈틈도 하루 길어져요',
          where: '정부24 · 주민센터',
        ),
        JourneyItem(
          text: '확정일자도 같이 받기',
          why: '대항력과 확정일자가 **둘 다** 있어야 순서대로 돌려받아요',
          where: '주민센터',
        ),
        JourneyItem(text: '실제로 들어가 살기', why: '전입신고만 하고 안 살면 **대항력이 생기지 않아요**'),
      ],
    ),
    JourneyStage(
      title: '입주 다음 날',
      chip: '입주 후',
      subtitle: '**대항력이 이날 0시에 생겨요**',
      compare: true,
      dateKey: JourneyDateKey.moveInNext,
      items: [
        JourneyItem(
          text: '등기부로 새 빚 확인',
          why: '전입한 날부터 다음 날 0시 사이의 **하루 틈**에 근저당이 생기면 내 보증금보다 앞서요',
          where: '인터넷등기소 · 열람 700원',
        ),
      ],
    ),
    JourneyStage(
      title: '보증보험 가입',
      chip: '보증보험',
      subtitle: '**입주하자마자 · 늦어도 계약 기간 절반 전에**',
      agency: 'HUG · HF · SGI',
      items: [
        JourneyItem(
          text: '입주하자마자 신청',
          why: '늦을수록 그사이 새 빚이 생겨 **거절될 수 있어요**',
          where: 'HUG ☎1566-9009 · HF ☎1688-8114 · SGI ☎1670-7000',
        ),
        JourneyItem(
          text: '마감 = 계약 기간 절반 전',
          why: '2년 계약이면 **1년 안에** 신청해야 해요 (HUG 기준, 기관마다 달라요)',
        ),
        JourneyItem(
          text: '서류 챙기기',
          why: '보증금을 실제로 냈고 이 집에 산다는 증거예요',
          where: '확정일자 계약서 · 이체 기록 · 전입세대확인서',
        ),
        JourneyItem(
          text: '대출 은행에 먼저 묻기',
          why: '대출 때문에 **가입이 막히거나**, 은행에서 함께 가입하기도 해요',
          where: '대출받은 은행',
        ),
      ],
    ),
    JourneyStage(
      title: '만기 전',
      chip: '만기 전',
      subtitle: '**만기 6개월 전부터 챙기기**',
      kind: JourneyStageKind.later,
      items: [
        JourneyItem(
          text: '6~2개월 전에 알리기',
          why: '아무도 말하지 않으면 **같은 조건으로 자동 연장**돼요',
        ),
        JourneyItem(
          text: '기록이 남게 알리기',
          why: '보증보험으로 돌려받을 때 **언제 알렸는지** 증거가 필요해요',
          where: '문자 · 내용증명(우체국)',
        ),
        JourneyItem(
          text: '집주인 바뀌었는지 보기',
          why: '몰래 **돈 없는 사람에게 집을 넘기는** 사기가 있어요',
          where: '인터넷등기소 · 열람 700원',
        ),
        JourneyItem(
          text: '계약갱신요구권 쓰기',
          why: '한 번, 2년 더 살 수 있고 보증금은 **5%까지만** 올릴 수 있어요',
        ),
      ],
    ),
    JourneyStage(
      title: '보증금 반환',
      chip: '반환',
      subtitle: '**돈 받기 전에 주소 빼지 않기**',
      kind: JourneyStageKind.later,
      items: [
        JourneyItem(
          text: '다 받은 뒤에 이사·전출',
          why: '받기 전에 주소를 빼면 **대항력과 순서가 사라져요**',
        ),
        JourneyItem(
          text: '못 받으면 임차권등기',
          why: '**등기부에 올라간 걸 확인한 뒤** 이사하면 순서가 지켜져요',
          where: '집 주소 관할 법원 · 대법원 전자소송',
        ),
        JourneyItem(
          text: '보증기관에 바로 연락',
          why: '집주인 대신 **보증기관이 돌려주는** 절차가 시작돼요',
          where: '가입한 보증기관',
        ),
      ],
    ),
  ];
}


/// 위젯 테스트 전용 4장 예시 (서울 빌라 — 산 날 대출이 같이 잡힌 집).
const AskCards kDummyAskCards = AskCards(
  shareText: '안녕하세요. 전세 계약 전에 확인하고 싶은 게 있어요.',
  cards: [
    AskCard(
      id: 'debt',
      title: '잔금 날 빚 정리',
      facts: ['2026.8.12 · 집주인이 이 집을 삼', '2026.8.12 · 근저당 4,800만원'],
      why: '집을 산 같은 날 대출이 잡혔어요. 안 갚고 두면 경매 때 보증금 2,704만원이 모자라요.',
      ask: '잔금 날 이 근저당을 갚고 말소해 주실 수 있나요? 갚는 돈은 제가 은행에 직접 보낼게요.',
      okReply: '네, 특약에 넣고 잔금 날 같이 은행에 가요.',
      badReply: '집주인분이 알아서 갚으세요. 다들 그래요.',
      counter: '그럼 계약서 특약에 적어 주실 수 있을까요?',
      passLine: AskPass(text: '잔금 날 말소 · 특약에 글로', sub: '안 되면 경매 때 2,704만원을 못 받는 계산이에요', danger: true),
      docs: ['계약서 특약', '말소 접수증'],
      clause: '임대인은 잔금 날 근저당(채권최고액 4,800만원)을 말소한다.',
      stopSub: '이 빚이 남으면 경매 때 2,704만원을 못 받는 계산이에요',
    ),
    AskCard(
      id: 'tax',
      title: '집주인 밀린 세금',
      legal: true,
      facts: ['압류 0건 · 세금은 납세증명서로 확인'],
      why: '밀린 세금은 경매 때 보증금보다 먼저 빠질 수 있어요.',
      ask: '계약하는 날 집주인분 국세·지방세 납세증명서를 보여 주실 수 있나요?',
      okReply: '네, 집주인분께 떼 오시라고 할게요.',
      badReply: '그런 건 요즘 다들 안 떼요.',
      counter: '계약할 때 집주인이 보여 줘야 하는 서류예요\n(주택임대차보호법 제3조의7)',
      passLine: AskPass(big: '0원', text: '빚을 말소하면 2,096만원까지'),
      docs: ['국세 납세증명서', '지방세 납세증명서'],
      clause: '임대인은 잔금 날 전까지 밀린 국세·지방세를 모두 내고 납세증명서를 보여 준다.',
      stopSub: '세금을 확인할 수 없으면 보증금이 얼마나 깎일지 알 수 없어요',
    ),
    AskCard(
      id: 'recent',
      title: '산 지 2개월 된 집',
      facts: ['2026.8.12 · 매매로 집주인이 바뀜'],
      why: '산 지 얼마 안 돼 바로 세를 놓는 집이에요.',
      ask: '계약 기간에 이 집을 파시거나 대출을 더 받으실 계획이 있으세요?',
      okReply: '없어요. 생기면 미리 알려 드릴게요.',
      badReply: '집주인 사정은 저도 잘 몰라요.',
      counter: '그럼 ‘팔거나 대출을 늘리면 미리 알린다’를 특약에 넣어 주세요',
      passLine: AskPass(text: '특약 2줄 — 잔금 다음 날까지 새 담보 금지 · 팔거나 대출 늘리면 미리 알림'),
      docs: ['계약서 특약'],
      clause: '임대인은 잔금 다음 날까지 이 집에 새 담보(근저당 등)를 잡지 않는다.',
      stopSub: '계약 뒤 새 집주인·새 대출이 생기면 보증금 순서가 밀릴 수 있어요',
    ),
  ],
);
