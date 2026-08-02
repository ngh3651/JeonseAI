"""규칙 엔진 — 등기부 추출 결과 + 사용자 입력 → 위험 판정(RuleVerdict).

가드레일(CLAUDE.md 3절): 위험 판정은 이 모듈만 만든다. LLM은 판정 JSON을 받아
설명 문장만 생성하며(E-2), 이 모듈의 출력을 바꿀 수 없다.

보수적 편향의 구조적 강제:
- 모든 "유효" 판단은 `is_canceled is not True` — 말소 여부 불명은 유효로 간주.
- 금액 해석 실패(None)는 합산에서 빠지는 대신 '금액 미상'으로 등급을 끌어올린다(0 치환 금지).
- 문서 불완전(주소·소유자 미추출, 배열 키 누락)이면 모든 근거 카드의 하한을
  '확인 필요'로 강제한다(`floor_caution` 단일 지점).

판정 수치는 thresholds.py 상수만 사용한다(출처는 docs/decisions.md와 1:1).
"""

from __future__ import annotations

import json
from pathlib import Path

from ..schemas.internal import (
    EvidenceVerdict,
    Grade,
    RegistryExtract,
    RuleVerdict,
    floor_caution,
    worst,
)
from . import price_normalize, thresholds as T
from .formatting import format_won, round_half_up

# 판정 출처 문구([판정] sourceText — 계약 §2.2). 리포트 화면 칩에 그대로 노출되므로
# 사용자 언어로 짧게 유지한다 ("검증 중"·"수동 대조" 같은 내부 프로세스 용어 금지 —
# 서연 리뷰 2026-07-07). 임시값·검증 대기 추적은 화면이 아니라 thresholds.py 주석과
# decisions.md(2026-07-06 기준 ①②③·임시 조치)가 담당한다 — rule-auditor 대조 지점.
_SRC_JEONSE = "HUG 담보인정비율 90% · 부동산원 80% 기준"
_SRC_SENIOR = "HUG 전세보증금반환보증 가입요건"
_SRC_OWNERSHIP = "HUG 가입요건(권리침해) · 법제처 생활법령정보(신탁)"
_SRC_LEASE = "주택임대차보호법 제3조의3"
_SRC_INSURANCE = "HUG 가입요건 — 등기부만으로 최종 확인 불가"
_SRC_BLACKLIST = "HUG 안심전세포털 공개 명단"

_DATA_DIR = Path(__file__).resolve().parents[2] / "data"

# 명단 미구축(대조 불가) 상태 라벨 — 종합 계산 임시 제외 판별에도 사용
# (임시 조치: 김시원 명단 데이터 도착 시 원복 — decisions.md 2026-07-06)
BLACKLIST_PENDING_LABEL = "명단 대조 아직 안 됨"

# 소유권 이상 신호로 보는 갑구 필드 (필드명, 한글 라벨)
_OWNERSHIP_FIELDS = (
    ("trust_registrations", "신탁등기"),
    ("seizures", "압류"),
    ("provisional_seizures", "가압류"),
    ("provisional_dispositions", "가처분"),
    ("auction_commencements", "경매개시결정"),
)


def load_blacklist() -> list[dict]:
    """data/blacklist.json에서 실제 항목(is_sample 아님)만 읽는다. 실패 시 빈 목록(대조 불가)."""
    try:
        raw = json.loads((_DATA_DIR / "blacklist.json").read_text(encoding="utf-8"))
        entries = raw.get("entries", [])
        return [e for e in entries if isinstance(e, dict) and not e.get("is_sample")]
    except (OSError, ValueError):
        return []


def evaluate(
    extract: RegistryExtract,
    *,
    deposit: int,
    market_price: int | None = None,
    blacklist_entries: list[dict] | None = None,
    supplementary: object | None = None,  # 추가 서류 확인(소액임차인 등) 대비 자리 — 팀 미결, 미사용
) -> RuleVerdict:
    """추출 결과와 입력값으로 근거 카드 5종을 판정하고 종합 등급을 결합한다."""
    if blacklist_entries is None:
        blacklist_entries = load_blacklist()

    # 단독·다가구(통건물 등기) 판별 — 전세가율 판정을 보류시키는 안전망.
    # 주소가 없을 때도 True가 되지만 그쪽은 doc_incomplete가 이미 막고 있어 방향이 같다.
    whole_building = price_normalize.is_whole_building(extract.address or "")

    ev_jeonse = _judge_jeonse_ratio(deposit, market_price, whole_building=whole_building)
    ev_senior, senior_total = _judge_senior_debt(extract, deposit, market_price)
    ev_ownership = _judge_ownership(extract)
    ev_insurance = _judge_insurance(extract, supplementary)
    ev_blacklist = _judge_blacklist(extract, blacklist_entries)

    evidences = [ev_jeonse, ev_senior, ev_ownership, ev_insurance, ev_blacklist]

    # 문서 신뢰도 게이트: 불완전하면 어떤 항목도 '양호'가 될 수 없다 (단일 강제 지점)
    doc_flags = _doc_flags(extract)
    if extract.doc_incomplete:
        for ev in evidences:
            if ev.grade is Grade.GOOD:
                ev.grade = floor_caution(ev.grade)
                ev.status_label = ev.status_label or "확인 필요"
                note = "등기부 페이지 누락·추출 실패 가능성 — 원본으로 재확인 필요"
                ev.detail_text = f"{ev.detail_text} · {note}" if ev.detail_text else note

    # 종합 등급: worst-of. 단 insurance의 '확인 필요'는 계산에서 제외(위험이면 반영).
    # 화면에는 insurance를 항상 표시한다 — 계산 제외일 뿐 숨기지 않는다. (decisions.md 2026-07-06)
    pool = [ev.grade for ev in (ev_jeonse, ev_senior, ev_ownership)]
    # 악성임대인 '명단 대조 아직 안 됨'(명단 미구축)도 임시로 계산 제외 — 매물 위험이 아니라
    # 우리 데이터 준비 상태의 문제이기 때문. 카드는 항상 표시. 김시원 명단 도착 시 원복.
    # (decisions.md 2026-07-06 임시 조치)
    if ev_blacklist.status_label != BLACKLIST_PENDING_LABEL:
        pool.append(ev_blacklist.grade)
    if ev_insurance.grade is Grade.DANGER:
        pool.append(ev_insurance.grade)
    overall = worst(pool)

    return RuleVerdict(
        grade=overall,
        gauge_progress=_gauge(overall, evidences),
        deposit=deposit,
        market_price=market_price,
        senior_debt_amount=senior_total,
        address=extract.address,
        evidences=evidences,
        doc_flags=doc_flags,
    )


# ── 근거 카드별 판정 ─────────────────────────────────────────────────────────


# 단독·다가구 전세가율 보류 문구 (계산 제외 판별에도 쓰인다)
WHOLE_BUILDING_PENDING_LABEL = "이 집 유형에는 쓸 수 없어요"


def _judge_jeonse_ratio(
    deposit: int, market_price: int | None, *, whole_building: bool = False
) -> EvidenceVerdict:
    # ── 단독·다가구 안전망 [2026-08-03] ──────────────────────────────────────
    # 다가구는 등기부가 **건물 1개에 1부**라, 앞순위 세입자들의 보증금 합계가
    # 등기부에 나오지 않는다. 건물 시세 20억에 내 보증금 2억이면 전세가율 10%지만,
    # 앞선 7세대가 18억을 넣어 놨다면 경매에서 한 푼도 못 받는다.
    # 즉 이 유형의 **낮은 전세가율은 안전 신호가 아니라 의미 없는 숫자**다.
    # 그래서 시세를 알아도 '양호'를 만들지 않는다 — 계산 자체를 하지 않는다.
    if whole_building:
        return EvidenceVerdict(
            id="jeonse_ratio",
            grade=Grade.CAUTION,
            status_label=WHOLE_BUILDING_PENDING_LABEL,
            detail_text=(
                "단독·다가구로 보여 전세가율을 쓰지 않았어요 — 이 유형은 등기부가 건물 1개에 "
                "1부뿐이라 **나보다 먼저 들어온 세입자들의 보증금 합계가 등기부에 나오지 않습니다.** "
                "시세 대비 내 보증금 비율이 낮게 나와도 안전하다는 뜻이 아니에요. "
                "임대인에게 '전입세대 열람내역'과 '확정일자 부여현황'을 요구해 앞순위 보증금을 "
                "직접 확인하세요."
            ),
            source_text=_SRC_JEONSE,
            action_label="앞순위 보증금 확인하기",
            facts={
                "jeonse_ratio_pct": None,
                "deposit": deposit,
                "market_price": market_price,
                "whole_building": True,
            },
        )

    if market_price is None or market_price <= 0:
        return EvidenceVerdict(
            id="jeonse_ratio",
            grade=Grade.CAUTION,
            status_label="확인 필요",
            detail_text=None,
            source_text=_SRC_JEONSE,
            action_label="시세 입력하기",
            facts={"jeonse_ratio_pct": None, "deposit": deposit, "market_price": None},
        )

    ratio_raw = deposit / market_price * 100
    pct = round_half_up(ratio_raw)  # 표시용 — 비교는 원값으로
    # 비교는 반올림 전 원값: 90.2%가 90%로 내려가 '초과' 판정을 놓치면 미탐(false negative)
    # 방향의 완화가 되므로 금지 (rule-auditor 2026-07-06 지적 반영, decisions.md '초과' 문언대로)
    if ratio_raw > T.JEONSE_RATIO_DANGER_PCT:
        grade = Grade.DANGER
    elif ratio_raw > T.JEONSE_RATIO_CAUTION_PCT:
        grade = Grade.CAUTION
    else:
        grade = Grade.GOOD
    detail = (
        f"전세가율 {pct}% — 보증금 {format_won(deposit)} / 입력 시세 {format_won(market_price)}"
        f" (주의 {T.JEONSE_RATIO_CAUTION_PCT}% 초과 · 위험 {T.JEONSE_RATIO_DANGER_PCT}% 초과)"
    )
    return EvidenceVerdict(
        id="jeonse_ratio",
        grade=grade,
        detail_text=detail,
        source_text=_SRC_JEONSE,
        facts={"jeonse_ratio_pct": pct, "deposit": deposit, "market_price": market_price},
    )


def _judge_senior_debt(
    extract: RegistryExtract, deposit: int, market_price: int | None
) -> tuple[EvidenceVerdict, int]:
    active_mortgages = [m for m in extract.mortgages if m.is_active]
    active_jeonse = [j for j in extract.jeonse_rights if j.is_active]
    active_lease = [l for l in extract.lease_registrations if l.is_active]

    known_amounts = [e.amount for e in (*active_mortgages, *active_jeonse) if e.amount is not None]
    unknown_count = sum(1 for e in (*active_mortgages, *active_jeonse) if e.amount_unknown)
    total_known = sum(known_amounts)

    # 비교는 반올림 전 원값(초과 판정 완화 금지 — 보수적 편향), 표시는 반올림값
    senior_raw: float | None = None
    combined_raw: float | None = None
    senior_pct: int | None = None
    combined_pct: int | None = None
    if market_price and market_price > 0:
        senior_raw = total_known / market_price * 100
        combined_raw = (total_known + deposit) / market_price * 100
        senior_pct = round_half_up(senior_raw)
        combined_pct = round_half_up(combined_raw)

    reasons: list[str] = []
    if active_lease:
        # 임차권등기 = 과거 보증금 미반환 사고의 증거 (주임법 §3-3, 조건부 채택)
        reasons.append(f"임차권등기 {len(active_lease)}건 — 과거 보증금 미반환 신호")
    if senior_raw is not None and senior_raw > T.SENIOR_DEBT_RATIO_DANGER_PCT:
        reasons.append(f"선순위채권 합계가 시세의 {senior_pct}% (기준 {T.SENIOR_DEBT_RATIO_DANGER_PCT}% 초과)")
    if combined_raw is not None and combined_raw > T.COMBINED_RATIO_DANGER_PCT:
        reasons.append(f"보증금+선순위채권이 시세의 {combined_pct}% (기준 {T.COMBINED_RATIO_DANGER_PCT}% 초과)")

    if reasons:
        grade = Grade.DANGER
        status = None
    elif unknown_count > 0:
        grade = Grade.CAUTION
        status = "확인 필요"
        reasons.append(f"금액 미상 채권 {unknown_count}건 — 원본 등기부로 확인 필요")
    elif market_price is None and total_known > 0:
        grade = Grade.CAUTION
        status = "확인 필요"
        reasons.append("시세 미입력 — 채권 규모가 과한지 비율로 판단할 수 없음")
    else:
        grade = Grade.GOOD
        status = None

    parts = [f"유효 채권최고액 등 합계 {format_won(total_known)}"]
    parts.append(f"근저당 {len(active_mortgages)}건")
    if active_jeonse:
        parts.append(f"선순위 전세권 {len(active_jeonse)}건")
    if active_lease:
        parts.append(f"임차권등기 {len(active_lease)}건")
    if unknown_count:
        parts.append(f"금액 미상 {unknown_count}건")
    detail = " · ".join(parts) + " (말소 제외)"
    if reasons:
        detail += " — " + " / ".join(reasons)

    source = _SRC_LEASE if active_lease else _SRC_SENIOR
    verdict = EvidenceVerdict(
        id="senior_debt",
        grade=grade,
        status_label=status,
        detail_text=detail,
        source_text=source,
        facts={
            "senior_debt_total": total_known,
            "mortgage_count": len(active_mortgages),
            "jeonse_right_count": len(active_jeonse),
            "lease_registration_count": len(active_lease),
            "unknown_amount_count": unknown_count,
            "senior_ratio_pct": senior_pct,
            "combined_ratio_pct": combined_pct,
        },
    )
    return verdict, total_known


def _judge_ownership(extract: RegistryExtract) -> EvidenceVerdict:
    counts = {
        label: sum(1 for e in getattr(extract, field) if e.is_active)
        for field, label in _OWNERSHIP_FIELDS
    }
    total = sum(counts.values())

    if total > 0:
        found = " · ".join(f"{label} {n}건" for label, n in counts.items() if n > 0)
        grade = Grade.DANGER
        detail = f"{found} (유효 기준, 말소 제외)"
    else:
        grade = Grade.GOOD
        detail = "유효한 신탁등기·압류·가압류·가처분·경매개시결정 없음 (말소 제외)"

    return EvidenceVerdict(
        id="ownership",
        grade=grade,
        detail_text=detail,
        source_text=_SRC_OWNERSHIP,
        facts={"signals": counts, "signal_total": total},
    )


def _judge_insurance(extract: RegistryExtract, supplementary: object | None) -> EvidenceVerdict:
    """보증보험 — 등기부만으로는 '양호' 판정이 구조적으로 불가능하다.

    supplementary: 추가 서류(전입세대열람 등) 확인 로직이 붙을 자리.
    '서비스 한계 명시 vs 추가 서류 업로드'는 팀 미결이라 지금은 사용하지 않는다.
    """
    disqualify = [
        f"{label} {n}건"
        for field, label in _OWNERSHIP_FIELDS
        for n in [sum(1 for e in getattr(extract, field) if e.is_active)]
        if n > 0
    ]
    lease_count = sum(1 for l in extract.lease_registrations if l.is_active)
    if lease_count:
        disqualify.append(f"임차권등기 {lease_count}건")

    if disqualify:
        return EvidenceVerdict(
            id="insurance",
            grade=Grade.DANGER,
            detail_text="가입 결격 신호: " + " · ".join(disqualify) + " (HUG 권리침해 결격 사유)",
            source_text=_SRC_INSURANCE,
            facts={"disqualify_signals": disqualify},
        )
    return EvidenceVerdict(
        id="insurance",
        grade=Grade.CAUTION,
        status_label="확인 필요",
        detail_text="등기부만으로는 가입 가능을 단정할 수 없음 — 보증기관에서 직접 확인 필요 (서비스 한계)",
        source_text=_SRC_INSURANCE,
        facts={"disqualify_signals": []},
    )


def _judge_blacklist(extract: RegistryExtract, entries: list[dict]) -> EvidenceVerdict:
    owner_names = [o.name.strip() for o in extract.current_owners if o.name and o.name.strip()]

    if not owner_names:
        return EvidenceVerdict(
            id="blacklist",
            grade=Grade.CAUTION,
            status_label="확인 필요",
            detail_text="소유자 이름을 추출하지 못해 명단 대조 불가",
            source_text=_SRC_BLACKLIST,
            facts={"matched": [], "list_size": len(entries)},
        )
    if not entries:
        return EvidenceVerdict(
            id="blacklist",
            grade=Grade.CAUTION,
            status_label=BLACKLIST_PENDING_LABEL,
            detail_text="악성임대인 명단 대조를 아직 못 했어요(큐레이션 준비 중) — 안심전세포털에서 직접 확인 필요",
            source_text=_SRC_BLACKLIST,
            facts={"matched": [], "list_size": 0},
        )

    listed = {e.get("name", "").strip() for e in entries if e.get("name")}
    matched = sorted(set(owner_names) & listed)
    if matched:
        # 동명이인 가능성 때문에 '위험' 단정 대신 강한 '확인 필요' + 직접 확인 유도
        return EvidenceVerdict(
            id="blacklist",
            grade=Grade.CAUTION,
            status_label="명단 일치 — 직접 확인 필요",
            detail_text=f"공개 명단과 이름 일치: {', '.join(matched)} (동명이인 가능성 — 단정 아님)",
            source_text=_SRC_BLACKLIST,
            facts={"matched": matched, "list_size": len(entries)},
        )
    return EvidenceVerdict(
        id="blacklist",
        grade=Grade.GOOD,
        detail_text=f"공개 명단 {len(entries)}건과 대조 — 일치 없음 (명단에 없어도 안전 보장 아님)",
        source_text=_SRC_BLACKLIST,
        facts={"matched": [], "list_size": len(entries)},
    )


# ── 종합 파생 ────────────────────────────────────────────────────────────────


def _doc_flags(extract: RegistryExtract) -> list[str]:
    flags: list[str] = []
    if extract.address is None:
        flags.append("주소 미추출")
    if not extract.current_owners:
        flags.append("현재 소유자 미추출")
    for key in extract.missing_fields:
        flags.append(f"{key} 항목 누락")
    return flags


def _gauge(overall: Grade, evidences: list[EvidenceVerdict]) -> float:
    """gaugeProgress = 근거 점수 평균을 종합 등급 구간에 클램프 (decisions.md 2026-07-06)."""
    avg = sum(T.EVIDENCE_SCORE[e.grade] for e in evidences) / len(evidences)
    lo, hi = T.GAUGE_BANDS[overall]
    return round(min(hi, max(lo, avg)), 2)
