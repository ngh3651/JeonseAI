"""큐레이션 콘텐츠의 남은 자리 — 용어 챗봇 칩 목록 등.

원래는 D-3에서 **Flutter 앱 안의 더미를 그대로 이식**한 모듈이었다(앱 더미와 서버 더미가
글자까지 같아야 앱을 서버에 붙였을 때 화면이 그대로 나오기 때문). E-1에서 실판정이,
E-2·E-3에서 실문구·실판례가 붙으면서 그 역할은 대부분 끝났다.
예시 리포트(`dummy-example`)는 2026-10-29에 지웠다 — 아래 설명 참고. 실제 이력 저장소는
`services/store.py`다.
"""

from __future__ import annotations

from .services import terms
from .schemas.contract import (
    CaseMatch,
    GlossaryTerm,
)


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


# ── 예시 리포트는 2026-10-29에 지웠다 ─────────────────────────────────────────────
# 예전에는 깨끗한 등기부 한 장을 규칙 엔진에 통과시킨 '성산동 행복아파트'(`dummy-example`)를
# **모든 기기의 기록 목록 끝**에 붙였다(홈이 비어 보이지 않게). 실제 기록이 생긴 뒤로는 내 것이 아닌
# 집이 목록에 섞여 헷갈리게 했다 → 규혁 결정으로 지웠다. 기록이 0건이면 앱이 빈 화면 안내를 띄운다.
# 같은 견본 등기부는 테스트에만 남아 있다(`tests/test_clean_report.py`).

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
