"""근거 카드를 펼쳤을 때의 **이 집 숫자**와 **이 집에서 할 일** (2026-10-31 리포트 1장 개편).

규혁(2026-10-31): 근거 카드를 펼치면 긴 줄글(대시·괄호가 섞인 한 덩어리)이라 읽히지 않는다. 이 집에 맞춘 것이
한눈에 보여야 한다("와 정말 쏠쏠하게 뽑아준다") → 펼침을 **숫자 줄 · 기준 막대 · AI 설명 · 할 일**로 나눈다.

⚠ **규칙이 이미 낸 값만 옮긴다.** 숫자는 규칙 엔진의 facts(판정에 쓴 그 값)와 등기부 항목 사실(riskFacts)에서만 온다.
  새 판정·새 기준선을 만들지 않는다(기준선은 thresholds.py 상수 그대로). AI는 여기 없다 — AI 설명은 따로 있다.
⚠ 할 일은 기존 문구(근거 카드 기본 문장·사진 표시 문구·4장 질문)에 이미 있는 행동만, 이 집 숫자를 끼워 쓴다. 대시 없이.
⚠ 사람 이름은 넣지 않는다(근저당권자는 기관이면 이름, 사람이면 '개인' — rule_engine이 이미 가렸다).
"""

from __future__ import annotations

from ..schemas.contract import (
    EvidenceHero,
    EvidenceMeter,
    EvidencePoint,
    EvidenceVisual,
    VisualCheck,
    VisualCut,
    VisualQueueItem,
    VisualResult,
)
from ..schemas.internal import EvidenceVerdict, Grade, RuleVerdict
from . import debt_order, thresholds as T
from .formatting import format_won
from .mark_plans import dot
from .rule_engine import BLACKLIST_PENDING_LABEL

_OWNERSHIP_KINDS = ("경매개시결정", "압류", "가압류", "가처분", "신탁")


def _pt(label: str, value: str, tone: str = "plain") -> EvidencePoint:
    return EvidencePoint(label=label, value=value, tone=tone)


_EMPTY = {"points": [], "meter": None, "todo": [], "hero": None, "visual": None}


def build(ev: EvidenceVerdict, verdict: RuleVerdict, risk_facts: list | None = None, loss=None) -> dict:
    """근거 하나 → {points, meter, todo, hero, visual}. 실패하면 빈 값(앱은 예전 상세 상자로 그린다).

    [loss]: 손실 예상(`loss_estimate.estimate` 결과 — 리포트 2장·손실 시뮬레이터와 **같은 계산**). 빚 카드 그림의
    '경매로 팔리는 값'·'돌려받을 돈'에만 쓴다. 없으면 그 두 칸을 비운다.
    """
    try:
        fn = _BUILDERS.get(ev.id)
        if fn is None:
            return dict(_EMPTY)
        points, meter, todo = fn(ev, verdict, list(risk_facts or []))
    except Exception:  # noqa: BLE001 — 펼침 재료 하나 때문에 리포트를 잃지 않는다
        return dict(_EMPTY)
    out = {"points": points, "meter": meter, "todo": todo, "hero": None, "visual": None}
    # 2026-11-01 리디자인 — 큰 한 줄 + 그림. 여기서 실패해도 숫자 줄·할 일은 그대로 나간다.
    try:
        out["visual"], replaced = _visual(ev, verdict, points, loss)
        if replaced is not None:
            out["points"] = replaced
        out["hero"] = _hero(ev, verdict, out["visual"])
    except Exception:  # noqa: BLE001
        out["visual"], out["hero"] = None, None
    return out


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
            "계약 전에 **보증보험**에 들 수 있는지 보증기관(주택도시보증공사 등)에 물어보세요",
            "손실 시뮬레이터(2장)에서 경매 때 얼마를 돌려받는지 보세요",
        ]
    return points, meter, todo


def _over(flag, pct, limit) -> bool | None:
    """기준을 넘었나 — 규칙 엔진이 **원값**으로 견준 결과(flag)를 쓴다. 옛 리포트(flag 없음)만 표시값으로."""
    if flag is not None:
        return bool(flag)
    return None if pct is None else pct > limit


def _senior_items(f: dict) -> list[dict]:
    """먼저 받아갈 빚(근저당 + 전세권)을 **받는 순서대로** 한 줄로 — {kind, order, rank_number, receipt_date, holder, amount}.

    옛 판정(전세권 얼굴 없음·order 없음)도 그대로 그린다: 순서 번호가 없으면 순위번호·접수일 순으로 늘어놓고 'N순위'를 붙이지 않는다.
    """
    items: list[dict] = []
    for m in f.get("mortgages") or []:
        items.append({
            "kind": "근저당", "order": m.get("order"), "rank_number": m.get("rank_number"),
            "receipt_date": m.get("receipt_date"), "holder": m.get("mortgagee"),
            "amount": m.get("max_claim_amount"), "amount_unknown": m.get("amount_unknown"),
        })
    for j in f.get("jeonse_rights") or []:
        items.append({
            "kind": "전세권", "order": j.get("order"), "rank_number": j.get("rank_number"),
            "receipt_date": j.get("receipt_date"), "holder": j.get("holder"),
            "amount": j.get("amount"), "amount_unknown": j.get("amount_unknown"),
        })
    if items and all(i.get("order") for i in items):
        items.sort(key=lambda i: i["order"])
    else:
        items.sort(key=debt_order.sort_key)
    return items


def _senior(ev: EvidenceVerdict, verdict: RuleVerdict, _facts: list):
    f = ev.facts
    total = f.get("senior_debt_total") or 0
    count = (f.get("mortgage_count") or 0) + (f.get("jeonse_right_count") or 0)
    points = [_pt("먼저 받아갈 빚", f"{format_won(total)} · {count}건" if count else "없음",
                  "danger" if ev.grade is Grade.DANGER else ("ok" if not total else "plain"))]
    # 2026-11-01: 'N순위'는 등기부 칸 번호가 아니라 **살아 있는 빚끼리의 받는 순서**(debt_order). 전세권도 같은 줄에 선다.
    for item in _senior_items(f)[:3]:
        bits = [dot(item.get("receipt_date")), item.get("holder")]
        if item.get("amount") is not None:
            bits.append(format_won(item["amount"]))
        elif item.get("amount_unknown"):
            bits.append("금액 못 읽음")
        points.append(_pt(debt_order.label(item["kind"], item.get("order")), " · ".join(b for b in bits if b)))
    if f.get("lease_registration_count"):
        points.append(_pt("임차권등기", f"{f['lease_registration_count']}건", "danger"))
    combined = f.get("combined_ratio_pct")
    if combined is not None:
        over = _over(f.get("combined_over_limit"), combined, T.COMBINED_RATIO_DANGER_PCT)
        points.append(_pt("빚 + 내 보증금", f"시세의 {combined}% (기준 {T.COMBINED_RATIO_DANGER_PCT}%)",
                          "danger" if over else "plain"))
    meter = None
    senior_pct = f.get("senior_ratio_pct")
    if senior_pct is not None and total:
        meter = EvidenceMeter(label="빚 ÷ 시세", value=int(senior_pct), marks=[T.SENIOR_DEBT_RATIO_DANGER_PCT],
                              tone=_tone_for(ev.grade))
    todo: list[str] = []
    if f.get("lease_registration_count"):
        todo.append("임차권등기가 **지워진(말소)** 등기부를 받은 뒤에 계약하세요")
    if f.get("unknown_amount_count"):
        todo.append("을구에 적힌 빚 금액(채권최고액)을 등기부 원본에서 확인하세요")
    if f.get("mortgage_count"):
        todo.append("잔금 날 이 빚을 갚고 등기부에서 **지우는지(말소)** 중개사에게 묻고, 답을 계약서 **특약**에 적으세요")
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
        todo.append("이 집은 **계약금을 보내지 마세요**. 경매가 어떻게 정리되는지 묻고, 답이 분명하지 않으면 이 집은 계약하지 마세요")
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
    blacklist = next((e for e in verdict.evidences if e.id == "blacklist"), None)
    pending = next((e for e in verdict.evidences if e.id == "pending"), None)
    # ①줄은 **권리침해만** — 빚 조건을 넘어 위험이 된 카드(2026-11-01)의 빚 신호는 ②③줄이 말한다.
    #   옛 리포트(rights_signals 없음)는 예전처럼 disqualify_signals 전체가 권리침해였다.
    signals = ev.facts.get("rights_signals")
    if signals is None:
        signals = ev.facts.get("disqualify_signals") or []
    sf = senior.facts if senior else {}
    jf = jeonse.facts if jeonse else {}
    sp, cp, jp = sf.get("senior_ratio_pct"), sf.get("combined_ratio_pct"), jf.get("jeonse_ratio_pct")
    # ✓·색은 규칙 엔진이 **원값**으로 견준 결과로 칠한다(2026-10-31 감사 — 60.3%가 '60% 이하 ✓'로 보이면 안 된다)
    senior_over = _over(sf.get("senior_over_limit"), sp, T.SENIOR_DEBT_RATIO_DANGER_PCT)
    combined_over = _over(sf.get("combined_over_limit"), cp, T.COMBINED_RATIO_DANGER_PCT)
    jeonse_over = _over(jf.get("over_caution"), jp, T.JEONSE_RATIO_CAUTION_PCT)

    def check(over: bool | None) -> str:
        return "caution" if over is None else ("danger" if over else "ok")

    points = [
        _pt("압류·경매·신탁·임차권등기", "있음" if signals else "없음", "danger" if signals else "ok"),
        _pt(f"빚이 시세의 {T.SENIOR_DEBT_RATIO_DANGER_PCT}% 이하",
            f"{sp}%" if sp is not None else "시세 몰라 못 봄", check(senior_over)),
        _pt(f"빚 + 보증금이 {T.COMBINED_RATIO_DANGER_PCT}% 이하",
            f"{cp}%" if cp is not None else "시세 몰라 못 봄", check(combined_over)),
        _pt(f"보증금이 시세의 {T.JEONSE_RATIO_CAUTION_PCT}% 이하",
            f"{jp}%" if jp is not None else "시세 몰라 못 봄", check(jeonse_over)),
    ]
    # ④ 공개 명단 · ⑤ 처리 중인 신청 — '양호'가 되려면 둘 다 확인돼야 한다(규칙 엔진과 같은 조건)
    if blacklist is not None:
        if blacklist.grade is Grade.GOOD or blacklist.facts.get("capped_reason"):
            points.append(_pt("악성임대인 공개 명단", "같은 이름 없음", "ok"))
        elif str(blacklist.status_label or "").startswith("명단 일치"):
            points.append(_pt("악성임대인 공개 명단", "같은 이름 있음", "caution"))
        else:
            points.append(_pt("악성임대인 공개 명단", "아직 못 맞춰 봤어요", "caution"))
    if pending is not None:
        points.append(_pt("처리 중인 등기 신청", "있음", "caution"))
    ask = "계약 전에 **보증보험**에 들 수 있는지 보증기관(주택도시보증공사 등)에 물어보세요"
    if ev.grade is Grade.GOOD:
        todo = [ask, "입주하자마자 **보증보험**을 신청하세요"]
    elif ev.grade is Grade.DANGER:
        todo = ["보증보험이 안 되면 계약을 없던 일로 하고 계약금을 돌려받는다는 **특약**을 넣으세요"]
    else:
        waiting = ev.facts.get("waiting_for") or []
        todo = [ask]
        if "pending" in waiting:
            todo.insert(0, "처리가 끝난 등기부를 다시 떼어 **이 앱으로 대조**하세요")
        if "blacklist" in waiting:
            todo.append("**안심전세포털**에서 집주인 이름을 직접 확인하세요")
    return points, None, todo


def _blacklist(ev: EvidenceVerdict, verdict: RuleVerdict, _facts: list):
    """카드 등급·상태로 가른다 — 집주인 이름을 못 읽은 경우를 '같은 사람 없음'으로 말하지 않게(2026-10-31 감사)."""
    matched = ev.facts.get("matched") or []
    size = ev.facts.get("list_size")
    label = str(ev.status_label or "")
    if label.startswith("명단 일치"):
        # 대조는 **이름만** 한다(출생연도는 아직 못 읽는다) — 동명이인일 수 있다
        n = f" {len(matched)}명" if matched else ""
        points = [_pt("공개 명단", f"이름이 같은 사람{n}", "caution")]
        todo = ["**안심전세포털**에서 이름과 나이를 직접 맞춰 보고, 중개사에게도 꼭 물어보세요"]
    elif ev.grade is Grade.GOOD or ev.facts.get("capped_reason"):
        # 사진이 빠져 '확인 필요'로 올라간 카드(capped_reason)도 대조 자체는 했다 — 같은 이름이 없었던 것은 사실이다
        # 2026-11-01: 값 칸(오른쪽, 좁다)엔 결과만 짧게 — '1,978명과 맞춰봤어요 · 같은 / 이름 없음'처럼 접혔다. 몇 명과 맞춰 봤는지는 둘째 줄.
        points = [EvidencePoint(label="공개 명단", value="같은 이름 없음", tone="ok",
                                sub=f"{size:,}명과 맞춰봤어요" if size else "명단과 맞춰봤어요")]
        todo = ["명단에 없어도 안심할 수는 없어요. 중개사에게 집주인 체납·다른 보증금 사고를 물어보세요"]
    elif label == BLACKLIST_PENDING_LABEL:
        points = [_pt("공개 명단", "아직 맞춰보지 못했어요", "caution")]
        todo = ["**안심전세포털**에서 집주인 이름을 직접 확인하세요"]
    else:
        points = [_pt("공개 명단", "집주인 이름을 못 읽어 못 맞춰 봤어요", "caution")]
        todo = ["**안심전세포털**에서 집주인 이름을 직접 확인하세요"]
    return points, None, todo


def _pending(ev: EvidenceVerdict, verdict: RuleVerdict, _facts: list):
    points = [_pt("등기부 상태", "신청사건 처리중", "caution")]
    if verdict.registry_viewed_at:
        points.append(_pt("뗀 날", verdict.registry_viewed_at))
    points.append(_pt("효력", "늦게 끝나도 접수한 때 생긴 걸로 쳐요"))
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


# ── 2026-11-01 리디자인: 맨 위 큰 한 줄(hero) · 그림 하나(visual) ─────────────────────────────────
# ⚠ 규칙이 이미 낸 값만 쓴다. 새 수치·새 기준 없음. 사진이 빠져 확정 못 한 카드(capped_reason)는 큰 말을 하지 않는다.


def _won(n: int | None) -> str:
    return "0원" if not n else format_won(n)


def _short_lender(name: str | None) -> str:
    """'주식회사가상은행' → '가상은행'. 사람이면 이미 '이○○'으로 가려져 있다(rule_engine._mortgage_fact)."""
    n = (name or "").strip()
    for cut in ("주식회사", "(주)", "㈜", "유한회사"):
        n = n.replace(cut, "")
    return n.strip() or "빚"


def _queue(ev: EvidenceVerdict, verdict: RuleVerdict, points: list, loss):
    f = ev.facts
    total = int(f.get("senior_debt_total") or 0)
    if not total or f.get("unknown_amount_count") or f.get("capped_reason"):
        return None, None  # 금액을 모르는 빚이 있으면 줄을 정직하게 그릴 수 없다
    # 근저당·전세권을 **받는 순서대로** 한 줄에 세운다(2026-11-01 — 전엔 전세권을 맨 뒤 '전세권 등'으로 몰았다:
    # 을구 1번 전세권 · 2번 근저당이면 순서가 거꾸로 그려졌다).
    ms = [m for m in _senior_items(f) if m.get("amount")]
    items = [VisualQueueItem(label=_short_lender(m.get("holder")) if m["kind"] == "근저당" else "전세권",
                             amount=int(m["amount"]), kind="debt")
             for m in ms]
    rest = total - sum(i.amount for i in items)
    if rest > 0:  # 얼굴(항목 사실)이 없는 옛 판정의 전세권 등 — 빚 카드 합계에 들어간 나머지
        items.append(VisualQueueItem(label="전세권 등", amount=rest, kind="debt"))
    deposit = int(verdict.deposit or 0)
    items.append(VisualQueueItem(label="내 보증금", amount=deposit, kind="mine"))

    cut = result = None
    if loss is not None and verdict.market_price:
        status = getattr(loss, "status", None)
        back = getattr(loss, "expectedReturn", None)
        if status == "ok" and getattr(loss, "expectedSale", None):
            cut = VisualCut(label="경매로 팔리는 값", amount=int(loss.expectedSale))
        elif status == "debt_exceeds":
            cut = VisualCut(label="집값(시세)", amount=int(verdict.market_price))
        if status in ("ok", "debt_exceeds") and back is not None:
            tone = "ok" if back >= deposit else ("danger" if back <= 0 else "caution")
            sub = f"내 보증금 {format_won(deposit)} 중"
            if (getattr(loss, "priorityAmount", 0) or 0) > 0:
                sub += " · 최우선변제 포함"
            result = VisualResult(label="경매로 가면 돌려받을 돈", sub=sub, value=_won(back), tone=tone)

    # 숫자 줄 = 그림의 칸(같은 색 점). 합계·빚+보증금 %는 그림과 큰 한 줄이 말하므로 뺀다.
    rows: list[EvidencePoint] = []
    for i, m in enumerate(ms[:4]):
        sub = " · ".join(b for b in (dot(m.get("receipt_date")), m.get("holder")) if b) or None
        rows.append(EvidencePoint(label=debt_order.label(m["kind"], m.get("order")), value=format_won(m["amount"]),
                                  sub=sub, dot=i))
    if rest > 0:
        rows.append(EvidencePoint(label="전세권 등", value=format_won(rest), dot=len(ms)))
    rows += [p for p in points if p.label == "임차권등기"]
    visual = EvidenceVisual(type="queue", items=[i.model_dump() for i in items], cut=cut, result=result)
    return visual, rows


def _checks(ev: EvidenceVerdict, points: list):
    items = [VisualCheck(ok={"ok": True, "danger": False}.get(p.tone), label=p.label, value=p.value) for p in points]
    if not items:
        return None
    return EvidenceVisual(type="checks", items=[i.model_dump() for i in items],
                          passed=sum(1 for i in items if i.ok is True), total=len(items))


def _visual(ev: EvidenceVerdict, verdict: RuleVerdict, points: list, loss):
    """(그림, 바꿔 쓸 숫자 줄 | None)"""
    if ev.id == "senior_debt":
        return _queue(ev, verdict, points, loss)
    if ev.id == "insurance":
        return _checks(ev, points), None
    if ev.id == "jeonse_ratio":
        pct = ev.facts.get("jeonse_ratio_pct")
        if pct is None or ev.facts.get("whole_building"):
            return None, None
        return EvidenceVisual(type="zones", value=int(pct),
                              zones=[T.JEONSE_RATIO_CAUTION_PCT, T.JEONSE_RATIO_DANGER_PCT],
                              tone=_tone_for(ev.grade)), None
    return None, None


def _hero(ev: EvidenceVerdict, verdict: RuleVerdict, visual) -> EvidenceHero | None:
    f = ev.facts
    if f.get("capped_reason"):
        return None  # 사진이 빠져 확정 못 한 카드 — 큰 말을 하지 않는다
    if ev.id == "senior_debt":
        total = int(f.get("senior_debt_total") or 0)
        pct = f.get("senior_ratio_pct")
        if total and pct is not None:
            if ev.grade is Grade.GOOD:  # 기준 안 — 겁주는 말('이미 빚')을 쓰지 않는다
                return EvidenceHero(text=f"빚은 집값의 {pct}%예요", accent=f"{pct}%")
            return EvidenceHero(text=f"집값의 {pct}%가 이미 빚이에요", accent=f"{pct}%")
        if f.get("lease_registration_count"):
            return EvidenceHero(text="전 세입자가 보증금을 못 받은 기록이 있어요", accent="못 받은 기록")
        if f.get("unknown_amount_count"):
            n = f["unknown_amount_count"]
            return EvidenceHero(text=f"금액을 못 읽은 빚이 {n}건 있어요", accent=f"{n}건")
        if total:
            return EvidenceHero(text=f"먼저 받아갈 빚이 {format_won(total)} 있어요", accent=format_won(total))
        return EvidenceHero(text="먼저 받아갈 빚은 보이지 않았어요")
    if ev.id == "jeonse_ratio":
        pct = f.get("jeonse_ratio_pct")
        if f.get("whole_building"):
            return EvidenceHero(text="단독·다가구라 이 비율로는 볼 수 없어요")
        return EvidenceHero(text=f"보증금은 시세의 {pct}%예요", accent=f"{pct}%") if pct is not None else None
    if ev.id == "insurance":
        if visual is None or not visual.total:
            return None
        failed = sum(1 for i in visual.items if i.get("ok") is False)
        unknown = sum(1 for i in visual.items if i.get("ok") is None)
        if failed:
            return EvidenceHero(text=f"가입 조건 {visual.total}개 중 {failed}개가 막혀요", accent=f"{failed}개")
        if unknown:
            return EvidenceHero(text=f"가입 조건 {visual.total}개 중 {unknown}개를 아직 몰라요", accent=f"{unknown}개")
        return EvidenceHero(text=f"가입 조건 {visual.total}개를 모두 통과했어요", accent="모두 통과")
    if ev.id == "ownership":
        sig = f.get("signals") or {}
        if sig.get("경매개시결정"):
            return EvidenceHero(text="경매가 이미 시작된 집이에요", accent="경매")
        if sig.get("신탁등기"):
            return EvidenceHero(text="집이 신탁회사에 맡겨져 있어요", accent="신탁회사")
        n = sum(int(sig.get(k) or 0) for k in ("압류", "가압류", "가처분"))
        if n:
            kinds = "·".join(k for k in ("압류", "가압류", "가처분") if sig.get(k))
            return EvidenceHero(text=f"{kinds} {n}건이 걸려 있어요", accent=f"{n}건")
        if ev.grade is Grade.GOOD:
            return EvidenceHero(text="압류·경매·신탁 기록은 보이지 않았어요")
        return None
    if ev.id == "blacklist":
        label = str(ev.status_label or "")
        if label.startswith("명단 일치"):
            return EvidenceHero(text="공개 명단에 같은 이름이 있어요", accent="같은 이름")
        if ev.grade is Grade.GOOD:
            size = f.get("list_size")
            return EvidenceHero(text=f"공개 명단 {size:,}명과 맞춰 봤어요" if size else "공개 명단과 맞춰 봤어요")
        if label == BLACKLIST_PENDING_LABEL:
            return EvidenceHero(text="아직 공개 명단과 맞춰 보지 못했어요")
        return EvidenceHero(text="집주인 이름을 못 읽었어요")
    if ev.id == "pending":
        return EvidenceHero(text="등기소에서 처리 중인 신청이 있어요", accent="처리 중")
    return None

