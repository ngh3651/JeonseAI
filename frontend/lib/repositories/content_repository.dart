/// 큐레이션 콘텐츠 저장소 — 판례·질문·용어·계약 여정 (인터페이스 + 더미).
///
/// 화면은 이 인터페이스에만 의존한다. D-3부터 실제 주입은 ApiContentRepository(서버)이고,
/// **DummyContentRepository는 위젯 테스트 전용**으로만 남는다(프로덕션 폴백 아님 —
/// docs/cleanup-tracker.md 참고). Phase E에서 서버 쪽이 큐레이션/LLM 실데이터로 교체된다.
///
/// D-3 인터페이스 변경: 판례·질문은 서버가 리포트 id에서 위험 패턴을 파생하므로
/// (api-contract.md §2.2 note) reportId 기반 + 전부 Future가 됐다.
library;

import '../models/content_models.dart';

abstract class ContentRepository {
  /// 리포트의 위험 패턴에 매칭되는 판례 (없으면 빈 리스트 → 빈 상태 처리).
  Future<List<CaseMatch>> matchedCases(String reportId);

  /// 위험 요소별 질문 그룹. 위험 요소가 없어도 기본 질문 세트 포함.
  Future<List<QuestionGroup>> questionGroups(String reportId);

  /// 챗봇 추천 용어 칩.
  Future<List<GlossaryTerm>> glossaryTerms();

  /// 챗봇 질문 하나 → 답 하나 (계약 §3.9).
  ///
  /// **거절도 답으로 돌아온다**(`outOfScope=true`) — 예전처럼 null을 받아 앱이 문구를
  /// 지어내지 않는다. 판정 요구 차단·범위 밖 판별·LLM 생성은 전부 서버 쪽 일이다.
  Future<GlossaryAnswer> askGlossary(String query);

  /// 계약 여정 단계.
  Future<List<JourneyStage>> journeyStages();
}

/// 위젯 테스트 전용 더미 (서버 없이 화면 흐름 테스트). 프로덕션 주입 금지.
class DummyContentRepository implements ContentRepository {
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

  /// 서버 규칙(L1~L4)의 **아주 얇은 흉내** — 위젯 테스트가 서버 없이 두 갈래
  /// (사전 답 / 거절)를 그릴 수 있을 만큼만이다. 실제 판별은 전부 서버가 한다.
  @override
  Future<GlossaryAnswer> askGlossary(String query) async {
    final q = query.trim();
    for (final t in await glossaryTerms()) {
      if (q.contains(t.term)) {
        return GlossaryAnswer(
          answer: t.description,
          source: '검수된 용어 사전',
          term: t.term,
        );
      }
    }
    return GlossaryAnswer.fallback;
  }

  /// 계약 여정 9단계 — **정본은 서버의 `backend/data/journey_stages.json`이다.**
  /// 여기 값은 위젯 테스트가 서버 없이 같은 모양의 화면을 그릴 수 있게 둔 사본이라,
  /// 문구가 바뀌면 데이터 파일 쪽을 먼저 고치고 이쪽을 맞춘다.
  @override
  Future<List<JourneyStage>> journeyStages() async => const [
    JourneyStage(
      title: '집 둘러보고 등기부 분석하기',
      subtitle: '이미 끝난 단계예요',
      kind: JourneyStageKind.analysis,
      items: [],
    ),
    JourneyStage(
      title: '가계약금 보내기 전',
      subtitle: '적은 돈이라도 보내면 되돌리기 어려워요',
      compare: true,
      dateKey: JourneyDateKey.downPayment,
      items: [
        JourneyItem(
          text: '등기부를 다시 떼서 달라진 게 없는지 보기',
          why: '등기부는 뗀 날짜 기준으로만 유효해요',
        ),
        JourneyItem(
          text: '돌려받을 수 있는 조건을 문구로 남기기',
          why: '조건 없이 보내면 돌려받기 어려워요',
        ),
      ],
    ),
    JourneyStage(
      title: '계약서 쓰는 날',
      subtitle: '주소·특약을 등기부와 맞춰보기',
      compare: true,
      askDates: true,
      dateKey: JourneyDateKey.contract,
      items: [
        JourneyItem(
          text: '등기부를 다시 떼서 달라진 게 없는지 보기',
          why: '도장 찍는 날 기준으로 다시 봐야 해요',
        ),
        JourneyItem(
          text: '계약서 주소가 등기부와 같은지 확인하기',
          why: '주소가 다르면 엉뚱한 집에 계약하는 셈이 돼요',
        ),
        JourneyItem(
          text: '근저당 말소 등 필요한 특약 넣기',
          why: '구두 약속은 지켜지지 않을 수 있어요',
        ),
      ],
    ),
    JourneyStage(
      title: '잔금 보내는 날',
      subtitle: '가장 큰 돈이 나가는 날',
      compare: true,
      dateKey: JourneyDateKey.balance,
      items: [
        JourneyItem(
          text: '등기부를 다시 떼서 달라진 게 없는지 보기',
          why: '잔금 직전에 근저당을 새로 설정하는 방식이 많아요',
        ),
        JourneyItem(
          text: '돈 받는 계좌 주인이 집주인과 같은지 확인하기',
          why: '다른 사람 계좌로 보내면 돈을 되찾기 어려워요',
        ),
      ],
    ),
    JourneyStage(
      title: '이사 당일',
      subtitle: '주민센터에서 두 가지',
      agency: '주민센터에서',
      dateKey: JourneyDateKey.moveIn,
      items: [
        JourneyItem(text: '전입신고하기', why: '전입신고를 해야 대항력이 생겨요'),
        JourneyItem(
          text: '계약서에 확정일자 받기',
          why: '확정일자가 있어야 돌려받을 순위가 생겨요',
        ),
      ],
    ),
    JourneyStage(
      title: '입주 다음 날',
      subtitle: '대항력이 이날 0시에 생겨요',
      compare: true,
      dateKey: JourneyDateKey.moveInNext,
      items: [
        JourneyItem(
          text: '등기부를 다시 떼서 새 빚이 없는지 보기',
          why:
              '전입신고한 날과 대항력이 생기는 다음 날 0시 사이의 하루 틈에 '
              '근저당이 생기면 내 보증금보다 앞서요',
        ),
      ],
    ),
    JourneyStage(
      title: '보증보험 가입',
      subtitle: '보증기관에 신청해요',
      agency: 'HUG · HF · SGI',
      items: [
        JourneyItem(
          text: '전세보증금 반환보증 신청하기',
          why: '집주인이 못 돌려줘도 보증기관이 대신 돌려줘요',
        ),
        JourneyItem(
          text: '가입 요건과 신청 기한을 기관에서 확인하기',
          why: '기한 확인 필요 — 기관마다 조건이 달라요',
        ),
      ],
    ),
    JourneyStage(
      title: '만기 전',
      subtitle: '1~2년 뒤 일 · 기한 확인 필요',
      kind: JourneyStageKind.later,
      items: [JourneyItem(text: '갱신·퇴거 의사 알리기', why: '기한 확인 필요')],
    ),
    JourneyStage(
      title: '보증금 반환',
      subtitle: '1~2년 뒤 일',
      kind: JourneyStageKind.later,
      items: [
        JourneyItem(
          text: '보증금을 돌려받은 뒤 전출 신고하기',
          why: '받기 전에 이사하면 대항력을 잃을 수 있어요',
        ),
      ],
    ),
  ];
}
