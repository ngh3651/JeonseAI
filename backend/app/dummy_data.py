"""더미 데이터 — **지금 Flutter 앱 코드 안의 더미를 그대로 이식**한 것.

출처(1:1 대응):
- frontend/lib/repositories/analysis_repository.dart (리포트·근거 카드, 위험/확인필요 2세트)
- frontend/lib/repositories/content_repository.dart (판례·질문·용어·여정)
- frontend/lib/utils/money_format.dart (formatWon)

앱과 서버의 더미가 100% 일치해야 D-3에서 앱을 서버에 연결했을 때 화면이 지금과 똑같이 나온다.
실제 추출·판정·LLM은 전부 Phase E에서 교체한다(여기서는 값만 옮긴다).

저장·삭제는 DB 없이 **메모리상 리스트로 흉내**만 낸다(서버 재시작 시 초기화).
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from .schemas.contract import (
    CaseMatch,
    Evidence,
    GlossaryTerm,
    JourneyItem,
    JourneyStage,
    Report,
)

KST = timezone(timedelta(hours=9))

# 앱에서 시연 시작 시 미리 있는 예시 리포트(홈 둘러보기용). 삭제 대상 아님(계약 §3.4).
EXAMPLE_IDS = {"dummy-danger", "dummy-caution"}


# ── 금액 포맷 (money_format.dart formatWon 이식) ────────────────────────────
def _comma(n: int) -> str:
    s = str(n)
    out = []
    for i, ch in enumerate(s):
        if i > 0 and (len(s) - i) % 3 == 0:
            out.append(",")
        out.append(ch)
    return "".join(out)


def format_won(won: int) -> str:
    if won <= 0:
        return "0원"
    eok = won // 100_000_000
    man = (won % 100_000_000) // 10_000
    parts: list[str] = []
    if eok > 0:
        parts.append(f"{eok}억")
    if man > 0:
        parts.append((" " if eok > 0 else "") + f"{_comma(man)}만")
    if not parts:
        parts.append(_comma(won))
    return "".join(parts) + "원"


def _round_half_up(x: float) -> int:
    """Dart double.round()(0.5는 반올림) 동작에 맞춘 반올림."""
    from math import floor

    return floor(x + 0.5)


# ── 위험 리포트 빌더 (analysis_repository.dart _buildDangerReport 이식) ──────
def build_danger_report(
    *,
    report_id: str,
    alias: str | None,
    analyzed_at: datetime,
    deposit: int,
    market_price: int | None,
    address: str = "서울 강남구 역삼동 123-45",  # 실단계: 표제부 추출 주소
) -> Report:
    senior_debt = 180_000_000  # 예시 채권최고액
    resolved_alias = alias.strip() if (alias and alias.strip()) else address

    # 전세가율 근거 — 시세가 있으면 계산해 보여주고, 없으면 '확인 필요'
    # (앱 원본: 시세 있으면 grade=확인 필요·statusLabel 없음 / 없으면 statusLabel+시세입력 버튼)
    if market_price is not None:
        pct = _round_half_up(deposit / market_price * 100)
        jeonse = Evidence(
            id="jeonse_ratio",
            title="보증금이 집값에 비해 높지 않나요?",
            termSubtitle="전세가율",
            grade="확인 필요",
            easyExplanation=(
                f"보증금이 입력하신 시세의 {pct}%를 차지해요(전세가율). "
                "시세가 내려가면 보증금을 다 돌려받기 어려울 수 있어요."
            ),
            detailText=(
                f"전세가율 {pct}% — 보증금 {format_won(deposit)} / "
                f"입력 시세 {format_won(market_price)} (예시 · 위험 기준선은 출처 확정 후 표시)"
            ),
            sourceText="HUG 공식 기준 등 확정 예정",
            termGlossary={
                "전세가율": (
                    "보증금이 집값의 몇 %인지 나타내는 비율이에요. 높을수록 "
                    "집값이 떨어졌을 때 보증금을 돌려받기 어려워져요."
                )
            },
        )
    else:
        jeonse = Evidence(
            id="jeonse_ratio",
            title="보증금이 집값에 비해 높지 않나요?",
            termSubtitle="전세가율",
            grade="확인 필요",
            statusLabel="확인 필요",
            easyExplanation=(
                "시세를 입력하지 않아 아직 계산할 수 없어요. "
                "국토부 실거래가·KB시세에서 확인한 금액을 입력하면 바로 알려드릴게요."
            ),
            sourceText="HUG 공식 기준 등 확정 예정",
            actionLabel="시세 입력하기",
        )

    return Report(
        id=report_id,
        alias=resolved_alias,
        address=address,
        analyzedAt=analyzed_at.isoformat(),
        grade="위험",
        gaugeProgress=0.22,
        headline="보증금을 지키기 어려운 신호가 보여요",
        # 상담처 전화번호는 Phase F에서 공식 홈페이지로 확인 후 병기
        nextAction="계약 전에 HUG 안심전세포털·대한법률구조공단 등에서 전문가 상담부터 받으세요",
        topRiskSummary="먼저 갚을 빚 신호 2건 · 소유권 이상",
        deposit=deposit,
        marketPrice=market_price,
        seniorDebtAmount=senior_debt,
        evidences=[
            Evidence(
                id="senior_debt",
                title="나보다 먼저 돈 받아갈 빚이 있나요?",
                termSubtitle="선순위 채권 · 근저당권",
                grade="위험",
                easyExplanation=(
                    "이 집에는 은행 빚(근저당권)이 크게 잡혀 있어요. 집이 경매로 넘어가면 "
                    "은행이 먼저 돈을 받아가고, 남는 금액에서 보증금을 돌려받게 돼요."
                ),
                detailText=(
                    "은행이 최대 받아갈 수 있다고 걸어둔 금액(채권최고액) "
                    "1억 8,000만원 · 근저당권 2건 (예시)"
                ),
                termGlossary={
                    "근저당권": (
                        "집주인이 집을 담보로 돈을 빌렸다는 표시예요. 집이 경매로 "
                        "넘어가면 돈을 빌려준 쪽(주로 은행)이 세입자보다 먼저 돈을 받아갈 수 있어요."
                    )
                },
                sourceText="HUG 공식 기준 등 확정 예정",
                actionLabel="중개사에게 물어볼 질문 보기",
            ),
            Evidence(
                id="ownership",
                title="집 소유권에 이상 신호가 있나요?",
                termSubtitle="신탁등기 · 압류 · 가압류",
                grade="위험",
                easyExplanation=(
                    "신탁등기가 설정되어 있어요. 집주인 마음대로 전세 계약을 "
                    "맺지 못할 수 있어서, 신탁회사의 동의가 있었는지 꼭 확인해야 해요."
                ),
                detailText="신탁등기 1건 (예시)",
                termGlossary={
                    "신탁등기": (
                        "집의 관리 권한을 신탁회사에 맡겼다는 표시예요. 이 경우 "
                        "집주인 단독으로는 전세 계약을 맺을 수 없는 경우가 많아요."
                    )
                },
                sourceText="HUG 공식 기준 등 확정 예정",
                actionLabel="중개사에게 물어볼 질문 보기",
            ),
            jeonse,
            Evidence(
                id="insurance",
                title="보증보험에 가입할 수 있나요?",
                termSubtitle="전세보증금 반환보증 (HUG 등)",
                grade="확인 필요",
                statusLabel="확인 필요",
                easyExplanation=(
                    "등기부만으로는 가입 가능 여부를 단정할 수 없어요. "
                    "가입 요건은 보증기관에서 직접 확인이 필요해요."
                ),
                sourceText="HUG 공식 기준 등 확정 예정",
                actionLabel="중개사에게 물어볼 질문 보기",
            ),
            Evidence(
                id="blacklist",
                title="집주인이 위험 명단에 있나요?",
                termSubtitle="악성임대인 공개 명단",
                grade="양호",
                easyExplanation=(
                    "공개 명단에서 발견되지 않았어요. 다만 명단에 없다고 "
                    "안전이 보장되는 건 아니에요 — 아래 질문으로 직접 확인하세요."
                ),
                sourceText="HUG 공식 기준 등 확정 예정",
                actionLabel="중개사에게 물어볼 질문 보기",
            ),
        ],
    )


def _build_caution_report(analyzed_at: datetime) -> Report:
    """예시 2 — 확인 필요 매물 (시세 미입력). analysis_repository.dart _cautionReport 이식."""
    return Report(
        id="dummy-caution",
        alias="정자동 빌라",
        address="경기 성남시 분당구 정자동 456-7",
        analyzedAt=analyzed_at.isoformat(),
        grade="확인 필요",
        gaugeProgress=0.55,
        headline="몇 가지를 확인한 뒤 결정해도 늦지 않아요",
        nextAction="보류하고, 아래 질문을 중개사에게 확인한 뒤 결정하세요",
        topRiskSummary="시세 미입력 · 입력하면 결과가 더 정확해져요",
        deposit=300_000_000,
        marketPrice=None,
        seniorDebtAmount=50_000_000,
        evidences=[
            Evidence(
                id="jeonse_ratio",
                title="보증금이 집값에 비해 높지 않나요?",
                termSubtitle="전세가율",
                grade="확인 필요",
                statusLabel="확인 필요",
                easyExplanation=(
                    "시세를 입력하지 않아 아직 계산할 수 없어요. "
                    "국토부 실거래가·KB시세에서 확인한 금액을 입력하면 바로 알려드릴게요."
                ),
                sourceText="HUG 공식 기준 등 확정 예정",
                actionLabel="시세 입력하기",
            ),
            Evidence(
                id="senior_debt",
                title="나보다 먼저 돈 받아갈 빚이 있나요?",
                termSubtitle="선순위 채권 · 근저당권",
                grade="양호",
                easyExplanation=(
                    "등기부에서 큰 빚은 보이지 않았어요. "
                    "다만 계약 직전에는 최신 등기부로 다시 확인하세요."
                ),
                detailText="근저당권 1건 · 채권최고액 5,000만원 (예시)",
                sourceText="HUG 공식 기준 등 확정 예정",
            ),
            Evidence(
                id="ownership",
                title="집 소유권에 이상 신호가 있나요?",
                termSubtitle="신탁등기 · 압류 · 가압류",
                grade="양호",
                easyExplanation="압류·가압류·신탁 같은 이상 신호는 보이지 않았어요. (예시)",
                sourceText="HUG 공식 기준 등 확정 예정",
            ),
            Evidence(
                id="insurance",
                title="보증보험에 가입할 수 있나요?",
                termSubtitle="전세보증금 반환보증 (HUG 등)",
                grade="확인 필요",
                statusLabel="확인 필요",
                easyExplanation=(
                    "등기부만으로는 가입 가능 여부를 단정할 수 없어요. "
                    "가입 요건은 보증기관에서 직접 확인이 필요해요."
                ),
                sourceText="HUG 공식 기준 등 확정 예정",
                actionLabel="중개사에게 물어볼 질문 보기",
            ),
            Evidence(
                id="blacklist",
                title="집주인이 위험 명단에 있나요?",
                termSubtitle="악성임대인 공개 명단",
                grade="양호",
                easyExplanation=(
                    "공개 명단에서 발견되지 않았어요. 다만 명단에 없다고 "
                    "안전이 보장되는 건 아니에요 — 아래 질문으로 직접 확인하세요."
                ),
                sourceText="HUG 공식 기준 등 확정 예정",
                actionLabel="중개사에게 물어볼 질문 보기",
            ),
        ],
    )


# ── 인메모리 이력 (앱 _history = [caution, danger], 최신순) ─────────────────
_now = datetime.now(KST)
_HISTORY: list[Report] = [
    _build_caution_report(_now - timedelta(hours=1)),
    build_danger_report(
        report_id="dummy-danger",
        alias="역삼동 오피스텔",
        analyzed_at=_now - timedelta(days=7),
        deposit=120_000_000,
        market_price=200_000_000,
    ),
]


def get_history() -> list[Report]:
    return list(_HISTORY)


def get_report(report_id: str) -> Report | None:
    for r in _HISTORY:
        if r.id == report_id:
            return r
    return None


def add_analysis(*, deposit: int, market_price: int | None, alias: str | None) -> Report:
    """analyze() 이식 — 위험 템플릿을 사용자 입력으로 채워 새 리포트를 만들고 이력 맨 앞에 넣는다."""
    report = build_danger_report(
        report_id=f"analysis-{int(datetime.now().timestamp() * 1000)}",
        alias=alias,
        analyzed_at=datetime.now(KST),
        deposit=deposit,
        market_price=market_price,
    )
    _HISTORY.insert(0, report)
    return report


def remove_report(report_id: str) -> None:
    global _HISTORY
    _HISTORY = [r for r in _HISTORY if r.id != report_id]


# (위험 패턴 파생은 services/patterns.py로 승격됨 — E-2)
# ── 판례 (content_repository.dart matchedCases 이식) — E-3에서 data/cases.json으로 교체 ──
def matched_cases(risk_patterns: list[str]) -> list[CaseMatch]:
    if not risk_patterns:
        return []
    return [
        CaseMatch(
            riskPattern="신탁등기",
            caseNo="대법원 2022다123456 (예시)",
            summary=(
                "신탁등기된 집을 신탁회사 동의 없이 임대해, 임차인이 대항력을 "
                "인정받지 못한 사례"
            ),
            result="임차인이 보증금을 돌려받지 못함",
            commonPoint="이 매물도 신탁등기가 설정되어 있어요",
        ),
        CaseMatch(
            riskPattern="선순위 채권",
            caseNo="수원지법 2021가단45678 (예시)",
            summary=(
                "근저당이 시세에 육박한 집이 경매로 넘어가, 후순위 임차인이 "
                "배당을 거의 받지 못한 사례"
            ),
            result="보증금 대부분 손실",
            commonPoint="이 매물도 근저당 금액이 커요",
        ),
    ]


# (질문 생성기는 services/questions.py + data/questions.json으로 승격됨 — E-2)


# ── 용어 챗봇 (content_repository.dart glossaryTerms / lookupTerm 이식) ──────
_GLOSSARY: list[GlossaryTerm] = [
    GlossaryTerm(
        term="신탁등기",
        description=(
            "집의 관리 권한을 신탁회사에 맡겼다는 표시예요. 이 경우 "
            "집주인 단독으로는 전세 계약을 맺을 수 없는 경우가 많아, 신탁회사의 "
            "동의가 있었는지 꼭 확인해야 해요."
        ),
    ),
    GlossaryTerm(
        term="근저당",
        description=(
            "집주인이 집을 담보로 돈을 빌렸다는 표시예요. 집이 경매로 "
            "넘어가면 돈을 빌려준 쪽(주로 은행)이 세입자보다 먼저 돈을 받아가요."
        ),
    ),
    GlossaryTerm(
        term="전세가율",
        description=(
            "보증금이 집값의 몇 %인지를 나타내는 비율이에요. 높을수록 "
            "집값이 떨어졌을 때 보증금을 돌려받기 어려워져요."
        ),
    ),
    GlossaryTerm(
        term="확정일자",
        description=(
            "전세 계약서에 날짜 도장을 받는 거예요. 이 날짜가 있어야 "
            "집이 경매로 넘어가도 보증금을 돌려받을 순위가 생겨요."
        ),
    ),
    GlossaryTerm(
        term="대항력",
        description=(
            "집주인이 바뀌어도 세입자가 계속 살 수 있고 보증금을 "
            "주장할 수 있는 힘이에요. 전입신고 + 실제 거주로 생겨요."
        ),
    ),
    GlossaryTerm(
        term="우선변제권",
        description=(
            "집이 경매로 넘어갔을 때 다른 채권자보다 먼저 보증금을 "
            "돌려받을 수 있는 권리예요. 대항력 + 확정일자가 있어야 해요."
        ),
    ),
]


def glossary_terms() -> list[GlossaryTerm]:
    return list(_GLOSSARY)


def lookup_term(query: str) -> GlossaryTerm | None:
    q = query.strip()
    for t in _GLOSSARY:
        if t.term in q:  # Dart: q.contains(t.term)
            return t
    return None


# ── 계약 여정 (content_repository.dart journeyStages 이식) ──────────────────
_JOURNEY: list[JourneyStage] = [
    JourneyStage(
        title="계약 전",
        subtitle="등기부 분석과 안전도 확인",
        items=[
            JourneyItem(
                text="등기부등본을 떼어 안전도 리포트로 분석하기",
                why="계약서에 도장을 찍기 전에 위험을 미리 확인해야 해요",
            ),
            JourneyItem(
                text="중개사에게 물어볼 질문 준비하기",
                why="현장에서 무엇을 확인해야 할지 미리 알고 가면 놓치지 않아요",
            ),
        ],
    ),
    JourneyStage(
        title="계약 체결",
        subtitle="계약서 검토와 특약",
        items=[
            JourneyItem(
                text="계약서 주소가 등기부와 같은지 확인하기",
                why="주소가 다르면 엉뚱한 집에 계약하는 셈이 될 수 있어요",
            ),
            JourneyItem(
                text="근저당 말소 등 필요한 특약 넣기",
                why="구두 약속은 지켜지지 않을 수 있어 서면으로 남겨야 해요",
            ),
        ],
    ),
    JourneyStage(
        title="잔금일",
        subtitle="나머지 보증금을 보내는 날",
        items=[
            JourneyItem(
                text="잔금 보내기 직전에 등기부 다시 확인하기",
                why="계약 후 잔금일 사이에 새 빚이 잡혔을 수 있어요",
            ),
        ],
    ),
    JourneyStage(
        title="입주하고 나서 꼭 할 일",
        subtitle="전입신고·확정일자 — 보증금을 지키는 가장 중요한 단계",
        items=[
            JourneyItem(
                text="이사 당일 바로 전입신고하기",
                why="전입신고를 해야 대항력이 생겨 보증금을 지킬 수 있어요",
            ),
            JourneyItem(
                text="계약서에 확정일자 받기",
                why="확정일자가 있어야 경매 시 보증금을 돌려받을 순위가 생겨요",
            ),
        ],
    ),
    JourneyStage(
        title="보증보험 가입",
        subtitle="보증금을 대신 돌려받는 안전장치",
        items=[
            JourneyItem(
                text="전세보증금 반환보증에 가입하기",
                why="집주인이 보증금을 못 돌려줘도 보증기관이 대신 돌려줘요",
            ),
        ],
    ),
    JourneyStage(
        title="만기 전",
        subtitle="계약 종료 준비",
        items=[
            JourneyItem(
                text="만기 6주 전까지 갱신·퇴거 의사 알리기",
                why="기한을 놓치면 원치 않게 계약이 자동 연장될 수 있어요",
            ),
        ],
    ),
    JourneyStage(
        title="보증금 반환",
        subtitle="보증금을 돌려받고 마무리",
        items=[
            JourneyItem(
                text="보증금을 돌려받은 뒤 전출 신고하기",
                why="보증금을 받기 전에 이사하면 대항력을 잃을 수 있어요",
            ),
        ],
    ),
]


def journey_stages() -> list[JourneyStage]:
    return list(_JOURNEY)
