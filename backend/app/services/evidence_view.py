"""근거 카드를 펼쳤을 때의 **이 집 숫자**와 **이 집에서 할 일** (2026-10-31 리포트 1장 개편).

규혁(2026-10-31): 근거 카드를 펼치면 긴 줄글(대시·괄호가 섞인 한 덩어리)이라 읽히지 않는다. 이 집에 맞춘 것이
한눈에 보여야 한다("와 정말 쏠쏠하게 뽑아준다") → 펼침을 **숫자 줄 · 기준 막대 · AI 설명 · 할 일**로 나눈다.

⚠ **규칙이 이미 낸 값만 옮긴다.** 숫자는 규칙 엔진의 facts(판정에 쓴 그 값)와 등기부 항목 사실(riskFacts)에서만 온다.
  새 판정·새 기준선을 만들지 않는다(기준선은 thresholds.py 상수 그대로). AI는 여기 없다 — AI 설명은 따로 있다.
⚠ 할 일은 기존 문구(근거 카드 기본 문장·사진 표시 문구·4장 질문)에 이미 있는 행동만, 이 집 숫자를 끼워 쓴다. 대시 없이.
⚠ 사람 이름은 넣지 않는다(근저당권자는 기관이면 이름, 사람이면 '개인' — rule_engine이 이미 가렸다).
"""

from __future__ import annotations

from ..schemas.contract import EvidenceMeter, EvidencePoint
from ..schemas.internal import EvidenceVerdict, Grade, RuleVerdict
from . import thresholds as T
from .formatting import format_won
from .mark_plans import dot

_OWNERSHIP_KINDS = ("경매개시결정", "압류", "가압류", "가처분", "신탁")


def _pt(label: str, value: str, tone: str = "plain") -> EvidencePoint:
    return EvidencePoint(label=label, value=value, tone=tone)


def build(ev: EvidenceVerdict, verdict: RuleVerdict, risk_facts: list | None = None) -> dict:
    """근거 하나 → {points, meter, todo}. 실패하면 빈 값(앱은 예전 상세 상자로 그린다)."""
    try:
        fn = _BUILDERS.get(ev.id)
        if fn is None:
            return {"points": [], "meter": None, "todo": []}
        points, meter, todo = fn(ev, verdict, list(risk_facts or []))
        return {"points": points, "meter": meter, "todo": todo}
    except Exception:  # noqa: BLE001 — 펼침 재료 하나 때문에 리포트를 잃지 않는다
        return {"points": [], "meter": None, "todo": []}


def _tone_for(grade: Grade) -> str:
    return {Grade.DANGER: "danger", Grade.CAUTION: "caution", Grade.GOOD: "ok"}[grade]


# ── 카드별 ───────────────────────────────────────────────────────────────────


def _jeonse(ev: EvidenceVerdict, verdict: RuleVerdict, _facts: list):
    f = ev.facts
    if f.get("whole_building"):
        return (
            [_pt("이 집", "단독·다가구로 보여요", "caution"),
             _pt("보증금", format_won(f.get("deposit") or verdict.deposit))],
            None,
            [
                "임대인에게 **전입세대 열람내역**과 **확정일자 부여현황**을 달라고 해서 앞순위 보증금 합계를 확인하세요",
                "다가구는 소액임차인 **최우선변제**도 다른 세입자와 나눠요. 손실 시뮬레이터(2장)에서 한도를 보세요",
            ],
        )
    pct = f.get("jeonse_ratio_pct")
    if pct is None:
        return (
            [_pt("보증금", format_won(f.get("deposit") or verdict.deposit)), _pt("시세", "못 구했어요", "caution")],
            None,
            ["매매 시세를 넣으면 바로 계산해요 (리포트 오른쪽 위 ✎)"],
        )
    points = [
        _pt("보증금", format_won(f.get("deposit") or verdict.deposit)),
        _pt("시세", format_won(f.get("market_price") or verdict.market_price or 0)),
    ]
    meter = EvidenceMeter(
        label="보증금 ÷ 시세",
        value=int(pct),
        marks=[T.JEONSE_RATIO_CAUTION_PCT, T.JEONSE_RATIO_DANGER_PCT],
        tone=_tone_for(ev.grade),
    )
    if ev.grade is Grade.GOOD:
        todo = ["시세가 맞는지 실거래가·공시가격으로 한 번 더 보세요", "잔금 날 아침 다시 떼서 새 빚이 없는지 대조하세요"]
    else:
        todo = [
            "계약 전에 **보증보험**에 들 수 있는지 보증기관에 물어보세요",
            "손실 시뮬레이터(2장)에서 경매 때 얼마를 돌려받는지 보세요",
        ]
    return points, meter, todo


def _senior(ev: EvidenceVerdict, verdict: RuleVerdict, _facts: list):
    f = ev.facts
    total = f.get("senior_debt_total") or 0
    count = (f.get("mortgage_count") or 0) + (f.get("jeonse_right_count") or 0)
    points = [_pt("먼저 받아갈 빚", f"{format_won(total)} · {count}건" if count else "없음",
                  "danger" if ev.grade is Grade.DANGER else ("ok" if not total else "plain"))]
    for m in (f.get("mortgages") or [])[:3]:
        label = f"{m['rank_number']}순위 근저당" if m.get("rank_number") else "근저당"
        bits = [dot(m.get("receipt_date")), m.get("mortgagee")]
        if m.get("max_claim_amount") is not None:
            bits.append(format_won(m["max_claim_amount"]))
        elif m.get("amount_unknown"):
            bits.append("금액 못 읽음")
        points.append(_pt(label, " · ".join(b for b in bits if b)))
    if f.get("lease_registration_count"):
        points.append(_pt("임차권등기", f"{f['lease_registration_count']}건", "danger"))
    combined = f.get("combined_ratio_pct")
    if combined is not None:
        points.append(_pt("빚 + 내 보증금", f"시세의 {combined}% (기준 {T.COMBINED_RATIO_DANGER_PCT}%)",
                          "danger" if combined > T.COMBINED_RATIO_DANGER_PCT else "plain"))
    meter = None
    senior_pct = f.get("senior_ratio_pct")
    if senior_pct is not None and total:
        meter = EvidenceMeter(label="빚 ÷ 시세", value=int(senior_pct), marks=[T.SENIOR_DEBT_RATIO_DANGER_PCT],
                              tone=_tone_for(ev.grade))
    todo: list[str] = []
    if f.get("lease_registration_count"):
        todo.append("임차권등기가 **말소**된 등기부를 받은 뒤에 계약하세요")
    if f.get("unknown_amount_count"):
        todo.append("을구에 적힌 빚 금액(채권최고액)을 등기부 원본에서 확인하세요")
    if f.get("mortgage_count"):
        todo.append("잔금 날 근저당을 **말소**할지 그대로 둘지 중개사에게 묻고, 특약으로 남기세요")
        todo.append("지금 남은 빚은 집주인 **대출 잔액 확인서(부채증명원)**로 확인하세요")
    if not todo:
        todo.append("잔금 날 아침 다시 떼서 새 빚이 생기지 않았는지 대조하세요")
    return points, meter, todo


def _ownership(ev: EvidenceVerdict, verdict: RuleVerdict, facts: list):
    found = [x for x in facts if getattr(x, "kind", None) in _OWNERSHIP_KINDS]
    points: list[EvidencePoint] = []
    for x in found[:4]:
        bits = [dot(x.receiptDate), format_won(x.amount) if x.amount else None,
                x.holder if x.holder == "기관" else ("개인" if x.holder else None)]
        points.append(_pt(x.kind, " · ".join(b for b in bits if b) or "기록 있음", "danger"))
    signals = ev.facts.get("signals") or {}
    if not points:
        if ev.grade is Grade.DANGER:
            points = [_pt(k, f"{n}건", "danger") for k, n in signals.items() if n]
        else:
            points = [_pt("신탁·압류·가압류·가처분·경매", "없음", "ok")]
    todo: list[str] = []
    if signals.get("경매개시결정"):
        todo.append("이 집은 **계약금을 보내지 마세요**. 경매가 어떻게 정리되는지 묻고, 답이 분명하지 않으면 넘기세요")
    if signals.get("압류") or signals.get("가압류") or signals.get("가처분"):
        todo.append("압류·가압류가 **풀린 등기부**를 직접 확인한 뒤에 계약하세요")
    if signals.get("신탁등기"):
        todo.append("**신탁원부**와 신탁회사 **동의서 원본**을 받기 전에는 돈을 보내지 마세요")
    if not todo:
        todo.append("잔금 날 아침 다시 떼서 새로 생긴 압류·가압류가 없는지 대조하세요")
    return points, None, todo


def _insurance(ev: EvidenceVerdict, verdict: RuleVerdict, _facts: list):
    senior = next((e for e in verdict.evidences if e.id == "senior_debt"), None)
    jeonse = next((e for e in verdict.evidences if e.id == "jeonse_ratio"), None)
    signals = ev.facts.get("disqualify_signals") or []
    sp = senior.facts.get("senior_ratio_pct") if senior else None
    cp = senior.facts.get("combined_ratio_pct") if senior else None
    jp = jeonse.facts.get("jeonse_ratio_pct") if jeonse else None

    def check(ok: bool | None) -> str:
        return "ok" if ok is True else ("danger" if ok is False else "caution")

    points = [
        _pt("압류·경매·신탁·임차권등기", "있음" if signals else "없음", check(not signals)),
        _pt(f"빚이 시세의 {T.SENIOR_DEBT_RATIO_DANGER_PCT}% 이하",
            f"{sp}%" if sp is not None else "시세 몰라 못 봄",
            check(None if sp is None else sp <= T.SENIOR_DEBT_RATIO_DANGER_PCT)),
        _pt(f"빚 + 보증금이 {T.COMBINED_RATIO_DANGER_PCT}% 이하",
            f"{cp}%" if cp is not None else "시세 몰라 못 봄",
            check(None if cp is None else cp <= T.COMBINED_RATIO_DANGER_PCT)),
        _pt(f"전세가율 {T.JEONSE_RATIO_CAUTION_PCT}% 이하",
            f"{jp}%" if jp is not None else "시세 몰라 못 봄",
            check(None if jp is None else jp <= T.JEONSE_RATIO_CAUTION_PCT)),
    ]
    if ev.grade is Grade.GOOD:
        todo = ["계약 전에 보증기관(HUG·HF·SGI)에 가입할 수 있는지 한 번 더 물어보세요", "입주하자마자 신청하세요"]
    elif ev.grade is Grade.DANGER:
        todo = ["보증보험이 안 되면 계약을 없던 일로 하고 계약금을 돌려받는다는 **특약**을 넣으세요"]
    else:
        todo = ["보증기관(HUG·HF·SGI)에 가입할 수 있는지 먼저 물어보세요"]
    return points, None, todo


def _blacklist(ev: EvidenceVerdict, verdict: RuleVerdict, _facts: list):
    matched = ev.facts.get("matched") or []
    size = ev.facts.get("list_size")
    if matched:
        points = [_pt("공개 명단", f"이름·나이가 같은 사람 {len(matched)}명", "caution")]
        todo = ["**안심전세포털**에서 직접 확인하고, 중개사에게도 꼭 물어보세요"]
    elif size:
        points = [_pt("공개 명단", f"{size:,}명과 맞춰봤어요 · 같은 사람 없음", "ok")]
        todo = ["명단에 없어도 안심할 수는 없어요. 중개사에게 집주인 체납·다른 보증금 사고를 물어보세요"]
    else:
        points = [_pt("공개 명단", "아직 맞춰보지 못했어요", "caution")]
        todo = ["**안심전세포털**에서 집주인 이름을 직접 확인하세요"]
    return points, None, todo


def _pending(ev: EvidenceVerdict, verdict: RuleVerdict, _facts: list):
    points = [_pt("등기부 상태", "신청사건 처리중", "caution")]
    if verdict.registry_viewed_at:
        points.append(_pt("뗀 날", verdict.registry_viewed_at))
    points.append(_pt("효력", "처리가 끝나면 접수한 때로 거슬러 생겨요"))
    todo = [
        "중개사에게 **무슨 신청인지**(근저당·말소 등) 물어보세요",
        "처리가 끝난 등기부를 다시 떼어 **이 앱으로 대조**하세요",
        "그 전에는 계약금·잔금을 **보내지 마세요**",
    ]
    return points, None, todo


_BUILDERS = {
    "jeonse_ratio": _jeonse,
    "senior_debt": _senior,
    "ownership": _ownership,
    "insurance": _insurance,
    "blacklist": _blacklist,
    "pending": _pending,
}
