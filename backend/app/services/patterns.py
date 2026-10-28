"""위험 패턴 파생 (계약 §2.2 note) — 판례·질문 엔드포인트가 공용으로 쓴다.

evidences 중 grade ≠ "양호"인 항목의 id를 위험 패턴 라벨로 매핑한다.
(dummy_data.risk_labels의 승격판 — dummy_data는 E-6에서 삭제 예정)
"""

from __future__ import annotations

import re

from ..schemas.contract import Report
from ..schemas.internal import Grade, RuleVerdict
from . import thresholds as T

# 계약 §2.2에 기록된 고정 매핑 (blacklist는 패턴 매핑 없음)
ID_TO_LABEL = {
    "senior_debt": "선순위 채권",
    "ownership": "신탁등기",
    "jeonse_ratio": "전세가율",
    "insurance": "보증보험",
}
LABEL_TO_ID = {
    **{v: k for k, v in ID_TO_LABEL.items()},
    # 2026-10-29: 실제 문제 태그 → 그 문제를 다루는 근거 카드 (질문 그룹 조건·설명 재료 키)
    "압류·가압류": "ownership",
    "경매": "ownership",
    "임차권등기": "senior_debt",
}


def derive_from_report(report: Report) -> list[str]:
    """리포트의 근거 카드에서 위험 패턴 라벨 목록을 파생한다."""
    return [
        ID_TO_LABEL[e.id]
        for e in report.evidences
        if e.grade != "양호" and e.id in ID_TO_LABEL
    ]


# ══════════════════════════════════════════════════════════════════════════════
# 이 집에 **실제로 걸린 문제** 태그 (2026-10-29 QA — 판례·질문·'눈에 띈 위험'의 공통 재료)
# ══════════════════════════════════════════════════════════════════════════════
#
# 예전 `tags_from_report`는 카드 **문장 속 글자**로 태그를 골랐다. 그래서 빠진 쪽 때문에 '확인 필요'로
# 올라간 소유권 카드의 "신탁등기·압류·…경매개시결정은 **없었어요**"라는 글자를 보고 신탁·압류·경매
# 판례를 붙였다. 이제 규칙 엔진이 센 **건수**로 고르고, 그 결과를 리포트(`riskTags`)에 저장한다.

#: 태그 이름 — 판례 데이터(`data/precedents`)·질문 그룹(`data/questions.json` triggerPattern)과 같은 글자
TAG_RATIO = "전세가율"
TAG_SENIOR = "선순위 채권"
TAG_LEASE = "임차권등기"
TAG_TRUST = "신탁등기"
TAG_SEIZURE = "압류·가압류"
TAG_AUCTION = "경매"
TAG_INSURANCE = "보증보험"


def tags_from_verdict(verdict: RuleVerdict) -> list[str]:
    """판정 → 위험 태그 (결정적).

    보수적 선택 메모:
    - 사진 때문에 '확인 필요'로 올린 카드(`capped_reason`)는 이 집의 문제가 아니라 사진의 문제다 — 태그하지 않는다.
    - 전세가율: **실측 비율이 주의 기준(thresholds.JEONSE_RATIO_CAUTION_PCT)을 넘은 경우만**.
      시세가 없어 '확인 필요'가 된 카드에 깡통전세 판례를 붙이면 과잉 매칭이다.
    - 보증보험: 구조적 '확인 필요'(모든 리포트 공통)는 제외, 결격 신호(위험)일 때만.
    """
    tags: list[str] = []
    for ev in verdict.evidences:
        if ev.grade == Grade.GOOD or ev.facts.get("capped_reason"):
            continue
        if ev.id == "jeonse_ratio":
            pct = ev.facts.get("jeonse_ratio_pct")
            if pct is not None and pct > T.JEONSE_RATIO_CAUTION_PCT:
                tags.append(TAG_RATIO)
        elif ev.id == "senior_debt":
            # 실제 유효 채권이 1건이라도 있을 때만 (채권 0건 카드에 경매·배당 판례를 붙이지 않는다)
            debt_count = (
                ev.facts.get("mortgage_count", 0)
                + ev.facts.get("jeonse_right_count", 0)
                + ev.facts.get("unknown_amount_count", 0)
            )
            if debt_count > 0:
                tags.append(TAG_SENIOR)
            if ev.facts.get("lease_registration_count", 0) > 0:
                tags.append(TAG_LEASE)
        elif ev.id == "ownership":
            signals = ev.facts.get("signals", {})
            if signals.get("신탁등기", 0) > 0:
                tags.append(TAG_TRUST)
            if any(signals.get(k, 0) > 0 for k in ("압류", "가압류", "가처분")):
                tags.append(TAG_SEIZURE)
            if signals.get("경매개시결정", 0) > 0:
                tags.append(TAG_AUCTION)
        elif ev.id == "insurance" and ev.grade == Grade.DANGER:
            tags.append(TAG_INSURANCE)
    return list(dict.fromkeys(tags))  # 순서 보존 dedup


#: 근거 카드 상세(`detailText`)에서 'N건'을 읽는 패턴 — 저장된 옛 리포트 전용
def _count(detail: str, label: str) -> int:
    m = re.search(rf"{re.escape(label)}\s*(\d+)\s*건", detail)
    return int(m.group(1)) if m else 0


def tags_from_report(report: Report) -> list[str]:
    """저장된 Report → 위험 태그. `riskTags`가 있으면 그것을 쓴다(2026-10-29부터 만든 리포트).

    없으면(옛 리포트) 근거 카드 상세의 **건수**('가압류 1건')로 다시 파생한다 — 낱말만 보지 않는다.
    "…없었어요"처럼 건수가 없는 문장에서는 아무것도 고르지 않는다.
    """
    if report.riskTags is not None:
        return list(report.riskTags)
    tags: list[str] = []
    for ev in report.evidences:
        if ev.grade == "양호":
            continue
        detail = ev.detailText or ""
        if ev.id == "jeonse_ratio":
            # 비율 때문에 주의·위험이 된 카드만 상태 칸이 비어 있다(시세 없음·단독·다가구·사진 때문은 상태 칸이 있다)
            if ev.statusLabel is None and "%" in detail:
                tags.append(TAG_RATIO)
        elif ev.id == "senior_debt":
            m = re.search(r"빚\s*[\d,억만천원\s]*·\s*(\d+)\s*건", detail)
            mortgages = int(m.group(1)) if m else 0
            if mortgages or _count(detail, "전세권") or _count(detail, "금액을 못 읽은 것"):
                tags.append(TAG_SENIOR)
            if _count(detail, "임차권등기"):
                tags.append(TAG_LEASE)
        elif ev.id == "ownership":
            if _count(detail, "신탁등기"):
                tags.append(TAG_TRUST)
            if any(_count(detail, k) for k in ("압류", "가압류", "가처분")):
                tags.append(TAG_SEIZURE)
            if _count(detail, "경매개시결정"):
                tags.append(TAG_AUCTION)
        elif ev.id == "insurance" and ev.grade == "위험":
            tags.append(TAG_INSURANCE)
    return list(dict.fromkeys(tags))


#: 전세가율 카드가 이 상태면 '단독·다가구라 비율을 쓰지 않음'(rule_engine.WHOLE_BUILDING_PENDING_LABEL과 같은 글자)
_WHOLE_BUILDING_LABEL = "이 집 유형에는 쓸 수 없어요"


def question_patterns(tags: list[str], evidences, market_price: int | None) -> list[str]:
    """질문 그룹을 고를 패턴 — 실제 문제 태그 + 전세가율을 **따져 볼 수 없는** 경우(시세 없음·단독·다가구).

    시세가 없거나 단독·다가구면 '시세 자료를 보여 주세요'·'앞순위 보증금' 같은 질문이 꼭 필요하다
    (문제 태그는 아니지만 사용자가 물어야 할 것). 사진 때문에 올라간 카드는 여기 들어오지 않는다.
    `evidences`: `.id`·`.grade`·(있으면) `.statusLabel`/`.status_label`을 가진 것들.
    """
    out = list(tags)
    if TAG_RATIO not in out:
        for e in evidences:
            if e.id != "jeonse_ratio" or e.grade == "양호":
                continue
            status = getattr(e, "statusLabel", None) or getattr(e, "status_label", None)
            if market_price is None or status == _WHOLE_BUILDING_LABEL:
                out.append(TAG_RATIO)
    return out
