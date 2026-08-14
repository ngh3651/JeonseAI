"""예시 리포트·큐레이션 콘텐츠 — 홈 화면이 비어 있지 않게 하는 씨앗.

원래는 D-3에서 **Flutter 앱 안의 더미를 그대로 이식**한 모듈이었다(앱 더미와 서버 더미가
글자까지 같아야 앱을 서버에 붙였을 때 화면이 그대로 나오기 때문). E-1에서 실판정이,
E-2·E-3에서 실문구·실판례가 붙으면서 그 역할은 대부분 끝났고, 지금 남은 것은 둘이다:

- **예시 리포트 1건** — 2026-08-14(D13)부터 손으로 적지 않고 **규칙 엔진이 만든다**.
- **계약 여정 단계** — 아직 큐레이션 원문이 여기 있다(향후 data/로 이관 — cleanup-tracker).

저장은 DB 없이 메모리로 흉내만 낸다(서버 재시작 시 초기화). 실제 이력 저장소는
`services/store.py`다.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from .services import terms
from .schemas.contract import (
    CaseMatch,
    GlossaryTerm,
    Report,
)
from .schemas.internal import RegistryExtract

KST = timezone(timedelta(hours=9))

# 앱에서 시연 시작 시 미리 있는 예시 리포트(홈 둘러보기용). 삭제 대상 아님(계약 §3.4).
EXAMPLE_IDS = {"dummy-example"}


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


# ══════════════════════════════════════════════════════════════════════════════
# 예시 리포트 — **규칙 엔진이 실제로 만든다** (2026-08-14 D13)
# ══════════════════════════════════════════════════════════════════════════════
#
# 예전에는 위험·확인필요 두 건을 **손으로 적어** 두었다. 그때는 D-3 단계라 서버 더미가
# 앱 더미와 글자까지 같아야 했기 때문인데, E-1에서 실판정이 붙은 뒤로는 그 전제가
# 사라졌고 손으로 적은 값만 남았다. 그 값들은 이미 낡아 있었다 —
# `sourceText="HUG 공식 기준 등 확정 예정"`은 출처가 확정된 지금 **거짓말**이고,
# `detailText`의 "(예시)" 표기는 실제 분석 결과와 모양이 달라 한눈에 티가 났다.
#
# 그래서 예시를 **깨끗한 등기부 한 장을 규칙 엔진에 통과시킨 결과**로 바꿨다.
#   ⑴ 등급·근거 카드·출처 문구가 전부 실제 분석과 **같은 경로**에서 나온다.
#   ⑵ 판정 기준이 바뀌면 예시도 **저절로 따라온다** — 손으로 고칠 값이 없다.
#   ⑶ 시연 영상에서 홈 화면에 실제 촬영 분석(위험)과 나란히 놓이는데, 그 대비가
#      "손으로 적은 가짜"가 아니라 같은 엔진의 다른 입력이 된다.
#
# ⚠ **한 건만 둔다.** 예전 2건은 홈 이력을 채우려는 것이었으나, 시연에서는 실제 분석이
#   그 자리를 채운다. 예시가 여럿이면 어느 것이 방금 찍은 것인지 흐려진다.

#: 예시로 쓸 **깨끗한 매물**의 등기부 — 빚도 압류도 신탁도 없는 집.
#: ⚠ 이름·주소는 지어낸 값이다(실제 등기부의 값을 옮겨 적지 않는다).
#: ⚠ 주소에 **동·호수가 있어야** 한다. 없으면 단독·다가구로 보여 전세가율 판정이
#:   보류되고(`price_normalize.is_whole_building`), 종합 등급이 거기 붙들린다.
_EXAMPLE_REGISTRY: dict = {
    **{key: [] for key in RegistryExtract.LIST_KEYS},
    "address": "서울특별시 마포구 성산동 100-1 행복아파트 제102동 제501호",
    "exclusive_area_sqm": 59.9,
    "current_owners": [{"name": "홍길동", "share": "단독소유"}],
    "ownership_changes": [
        {"rank_number": "2", "receipt_date": "2019-03-14", "cause": "매매", "is_canceled": False}
    ],
}

#: 보증금 2억 4,000만원 / 시세 5억원 = 전세가율 48%.
#: HUG 담보인정비율 90%·부동산원 80% 기준 모두 아래라 '양호'로 떨어진다.
_EXAMPLE_DEPOSIT = 240_000_000
_EXAMPLE_MARKET_PRICE = 500_000_000
_EXAMPLE_ID = "dummy-example"
_EXAMPLE_ALIAS = "성산동 행복아파트"


def build_example_report() -> Report:
    """깨끗한 등기부 1건을 **실제 규칙 엔진에 통과시켜** 예시 리포트를 만든다.

    ⚠ `report_builder`를 **함수 안에서** 불러온다. 모듈 맨 위에서 부르면
      `report_builder → store → dummy_data → report_builder` 순환 import가 된다.
      호출 시점(첫 이력 조회)에는 세 모듈이 모두 적재를 마친 뒤다.

    ⚠ `use_llm=False` — 예시 문구까지 Solar를 부르면 서버가 뜰 때마다 크레딧이 샌다.
      폴백 문구도 결정적 템플릿이라 실제 분석과 같은 문장 구조로 나온다.
    """
    from .services import report_builder

    return report_builder.build_report(
        RegistryExtract.from_raw(_EXAMPLE_REGISTRY),
        deposit=_EXAMPLE_DEPOSIT,
        market_price=_EXAMPLE_MARKET_PRICE,
        alias=_EXAMPLE_ALIAS,
        report_id=_EXAMPLE_ID,
        # 홈 카드가 '오늘'로 보이게 — 하루가 지나면 앱이 '오래된 분석' 배너를 띄운다.
        analyzed_at=datetime.now(KST) - timedelta(hours=3),
        use_llm=False,
    )


# ── 인메모리 이력 — **첫 조회 때 만든다** ────────────────────────────────────
# 모듈을 읽는 시점에 만들면 위 순환 import에 걸린다(build_example_report 주석 참고).
_HISTORY: list[Report] | None = None


def get_history() -> list[Report]:
    global _HISTORY
    if _HISTORY is None:
        _HISTORY = [build_example_report()]
    return list(_HISTORY)


# 2026-08-14(D13): `add_analysis` · `get_report` · `remove_report`를 지웠다.
# 셋 다 D-2 시절 이 모듈이 직접 저장소 노릇을 하던 흔적으로, **이미 어디서도 부르지
# 않았다**(실제 이력은 `services/store.py`, 분석은 `report_builder.analyze`가 맡는다).
# `add_analysis`가 붙들고 있던 `build_danger_report`(손으로 적은 위험 리포트 150줄)도
# 함께 사라졌다 — 그 값들은 출처 문구가 낡아 실제 분석과 어긋나 있었다.

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
# 2026-08-05: 하드코딩 6개를 없앴다. 용어 원천은 `backend/data/terms.json` 하나다
# (`services/terms.py`). 리포트 툴팁과 챗봇이 **같은 설명**을 쓰게 하려는 것이다 —
# 예전에는 두 곳이 따로 있어 '신탁등기' 설명이 서로 달랐다.
# ⚠ 응답 로직은 바꾸지 않았다(칩 목록 + 부분 문자열 조회). 데이터 원천만 옮겼다.


def glossary_terms() -> list[GlossaryTerm]:
    """추천 칩 목록 — terms.json 에서 chatbot_chip=true 인 것만."""
    return [GlossaryTerm(term=t.term, description=t.description) for t in terms.chatbot_terms()]


def lookup_term(query: str) -> GlossaryTerm | None:
    """입력에서 용어 찾기 — 별칭 포함, 가장 긴 표기 우선(terms.lookup).

    못 찾으면 None → 라우터가 404 → 앱이 '범위 밖' 거절 문구를 띄운다(가드레일 유지).
    """
    found = terms.lookup(query)
    return GlossaryTerm(term=found.term, description=found.description) if found else None


# ── 계약 여정 단계는 2026-08-14(S-11)부터 `data/journey_stages.json`에 있다 ────────
# 로더는 `services/journey.py`. 큰레이션 문구를 비개발 팀원이 직접 고칠 수 있게 옆으로 옮겼다
# (cleanup-tracker.md "계약 여정 단계 → data/ 이관" 항목 완료).
