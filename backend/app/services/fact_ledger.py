"""AI 문장의 숫자가 **맞는 뜻으로** 쓰였나 — 이 집 숫자 장부와 '숫자 뜻' 검사 (2026-11-01).

규혁(2026-11-01 실기기): 판례 '우리 매물과 공통점'이 "이 집도 **3억 6,000만원** 선순위 근저당이 있어요"라고 썼다.
이 집의 먼저 갚을 빚은 근저당 2건, **합계 4억 1,200만원**이다. 한 건만 '선순위'로 말해 빚이 그것뿐인 것처럼 읽혔고,
같은 화면의 다른 카드는 4억 1,200만원이라고 했다. "틀린 정보를 기록했다간 우리를 믿고 사기를 당했을 때 고소당할 빌미가 된다."

지금까지 그물(`text_guard` 숫자 화이트리스트)은 **그 숫자가 재료 어딘가에 있나**만 봤다. 3억 6,000만원은 재료에 있으니 통과했고,
"보증금은 4억원이에요"처럼 시세를 보증금 자리에 써도 통과했다(4억원도 재료에 있다).

그래서 숫자마다 **바로 옆 낱말로 자리(뜻)를 읽고**, 이 집 장부의 그 자리 값과 맞는지 본다.
- 자리를 못 읽으면(옆에 '보증금'·'시세'·'빚' 같은 말이 없으면) 그 숫자는 화이트리스트만 본다 — AI 문장을 틀에 가두지 않는다.
- 자리를 읽었는데 그 자리 값이 아니면 → 그 칸을 버린다(설명·판례는 한 번 고쳐 쓰게 하고, 그래도 안 되면 준비된 문구).
- **'선순위'·'먼저 갚을 빚'** 자리에 빚 한 건 금액만 쓰면(빚이 2건 이상인데) → 합계를 쓰거나 모든 건을 함께 써야 한다.
- 'N순위'는 살아 있는 빚끼리의 받는 순서(debt_order)만 — 등기부 칸 번호를 순위라고 부르면 버린다.

⚠ **판정을 하지 않는다.** 문장이 장부와 어긋나는지만 본다. 장부 값은 전부 규칙 엔진·손실 계산이 이미 낸 값이다.
⚠ 판례 이야기 문장('판례 속 집은 …')은 이 집 장부와 견주지 않는다(`skip_precedent`) — 그 숫자는 판례의 숫자다.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Iterable

from . import text_guard as G
from . import thresholds as T
from .formatting import format_won

# ══════════════════════════════════════════════════════════════════════════════
# 장부
# ══════════════════════════════════════════════════════════════════════════════


@dataclass
class Ledger:
    """이 집 숫자 장부 — 자리 이름 → 값. 모르는 자리는 비워 둔다(비면 그 자리는 견주지 않는다)."""

    money: dict[str, set[int]] = field(default_factory=dict)
    pct: dict[str, set[float]] = field(default_factory=dict)
    senior_items: list[int] = field(default_factory=list)  # 먼저 받아갈 빚 한 건 한 건(받는 순서대로)
    senior_total: int | None = None
    orders: int = 0  # 받는 순서를 아는 빚의 수(0 = 순서를 모른다)
    back_zero: bool = False  # 경매로 가면 돌려받을 돈이 0원이다(손실 계산 결과)

    def add_money(self, role: str, *values: int | None) -> None:
        for v in values:
            if v is not None and v > 0:
                self.money.setdefault(role, set()).add(int(v))

    def add_pct(self, role: str, *values: float | None) -> None:
        for v in values:
            if v is not None:
                self.pct.setdefault(role, set()).add(float(v))


def _base(
    *,
    deposit: int | None,
    market: int | None,
    senior_total: int | None,
    senior: list[tuple[int | None, int | None]],  # (금액, 받는 순서)
    seizures: Iterable[int | None] = (),
    leases: Iterable[int | None] = (),
    loss: Any = None,
    pcts: dict[str, float | None] | None = None,
) -> Ledger:
    led = Ledger()
    led.add_money("deposit", deposit)
    led.add_money("market", market)
    items = [a for a, _ in senior if a]
    led.senior_items = items
    led.senior_total = senior_total if senior_total else (sum(items) or None)
    led.add_money("senior_total", led.senior_total)
    led.add_money("senior_item", *items, led.senior_total)
    if senior and all(o for _, o in senior):
        led.orders = len(senior)
    if led.senior_total and deposit:
        led.add_money("combined", led.senior_total + deposit)
    led.add_money("seizure", *seizures)
    led.add_money("lease", *leases)
    if loss is not None:
        status = getattr(loss, "status", None)
        if status in ("ok", "debt_exceeds"):
            led.add_money("sale", getattr(loss, "expectedSale", None))
            back = getattr(loss, "expectedReturn", None)
            lost = getattr(loss, "expectedLoss", None)
            # '돌려받을 돈 0원'·'못 받는 돈 = 보증금 전부'도 사실이다 — 0은 text_guard가 늘 허용한다
            led.add_money("return", back)
            led.add_money("loss", lost)
            led.back_zero = back == 0
            led.add_pct("sale_rate", getattr(loss, "ratePct", None))
        led.add_money(
            "priority",
            getattr(loss, "priorityAmount", None) or None,
            getattr(loss, "priorityLimit", None),
            getattr(loss, "priorityCap", None),
        )
    for k, v in (pcts or {}).items():
        led.add_pct(k, v)
    led.add_pct(
        "threshold",
        T.JEONSE_RATIO_CAUTION_PCT,
        T.JEONSE_RATIO_DANGER_PCT,
        T.SENIOR_DEBT_RATIO_DANGER_PCT,
        T.COMBINED_RATIO_DANGER_PCT,
        50,  # 최우선변제 '낙찰가의 절반'(시행령 제10조 ②) — 퍼센트로 말할 때
    )
    return led


def for_verdict(verdict: Any, risk_facts: Iterable[Any] = (), loss: Any = None) -> Ledger:
    """규칙 판정(+ 등기 항목 사실 · 손실 계산) → 장부. 설명(이 집 핵심) 검사에 쓴다."""
    senior_ev = next((e for e in verdict.evidences if e.id == "senior_debt"), None)
    jeonse_ev = next((e for e in verdict.evidences if e.id == "jeonse_ratio"), None)
    sf = senior_ev.facts if senior_ev else {}
    jf = jeonse_ev.facts if jeonse_ev else {}
    senior: list[tuple[int | None, int | None]] = [
        (m.get("max_claim_amount"), m.get("order")) for m in (sf.get("mortgages") or [])
    ] + [(j.get("amount"), j.get("order")) for j in (sf.get("jeonse_rights") or [])]
    facts = list(risk_facts or [])
    return _base(
        deposit=verdict.deposit,
        market=verdict.market_price,
        senior_total=sf.get("senior_debt_total") or verdict.senior_debt_amount,
        senior=senior,
        seizures=[getattr(f, "amount", None) for f in facts if getattr(f, "kind", None) in ("가압류", "압류")],
        leases=[getattr(f, "amount", None) for f in facts if getattr(f, "kind", None) == "임차권등기"],
        loss=loss,
        pcts={
            "senior": sf.get("senior_ratio_pct"),
            "combined": sf.get("combined_ratio_pct"),
            "jeonse": jf.get("jeonse_ratio_pct"),
        },
    )


def for_report(report: Any, loss: Any = None) -> Ledger:
    """저장된 리포트(+ 손실 계산) → 장부. 판례 공통점 검사에 쓴다."""
    facts = list(getattr(report, "riskFacts", None) or [])
    senior = [(f.amount, getattr(f, "order", None)) for f in facts if f.kind in ("근저당", "전세권")]
    pcts: dict[str, float | None] = {}
    for ev in getattr(report, "evidences", None) or []:
        meter = getattr(ev, "meter", None)
        if meter is not None and getattr(meter, "label", "") == "빚 ÷ 시세":
            pcts["senior"] = meter.value
        if meter is not None and getattr(meter, "label", "") == "보증금 ÷ 시세":
            pcts["jeonse"] = meter.value
        for p in getattr(ev, "points", None) or []:
            if getattr(p, "label", "") == "빚 + 내 보증금":
                m = re.search(r"(\d+(?:\.\d+)?)\s*%", p.value or "")
                if m:
                    pcts["combined"] = float(m.group(1))
    return _base(
        deposit=getattr(report, "deposit", None),
        market=getattr(report, "marketPrice", None),
        senior_total=getattr(report, "seniorDebtAmount", None),
        senior=senior,
        seizures=[f.amount for f in facts if f.kind in ("가압류", "압류")],
        leases=[f.amount for f in facts if f.kind == "임차권등기"],
        loss=loss,
        pcts=pcts,
    )


def sheet(led: Ledger, senior_lines: list[str] | None = None) -> dict:
    """AI에게 건넬 **이 집 숫자표**(정본) — 같은 숫자를 같은 이름으로 부르게 한다. 장부에 있는 값만."""
    out: dict = {}

    def one(role: str) -> str | None:
        vals = sorted(led.money.get(role) or ())
        return format_won(vals[0]) if len(vals) == 1 else None

    if (v := one("deposit")):
        out["내_보증금"] = v
    if (v := one("market")):
        out["시세"] = v
    if led.senior_total:
        n = len(led.senior_items)
        out["먼저_갚을_빚_합계"] = format_won(led.senior_total) + (f" ({n}건)" if n else "")
        if senior_lines:
            out["먼저_갚을_빚_한_건씩"] = senior_lines
        if n >= 2:
            out["빚을_말하는_법"] = (
                "'선순위'·'먼저 갚을 빚'이라고 할 때는 합계를 쓰세요. 한 건만 말할 때는 '1순위 근저당 ○○원'처럼 받는 순서를 붙이세요"
            )
    if (v := one("sale")):
        out["경매로_팔리는_값"] = v
    if (v := one("return")):
        out["경매로_가면_돌려받을_돈"] = v
    elif led.back_zero:
        out["경매로_가면_돌려받을_돈"] = "0원"
    if (v := one("loss")):
        out["못_돌려받는_돈"] = v
    pr = sorted(led.money.get("priority") or ())
    if pr:
        out["최우선변제"] = "먼저 받는 돈(최우선변제) 기준에 쓰인 금액: " + " · ".join(format_won(x) for x in pr)
    out["먼저_받는_쪽"] = "경매로 팔리면 **돈을 빌려준 곳**(근저당권자·전세권자)이 순서대로 먼저 받아요. 빚을 진 집주인이 아니에요"
    return out


# ══════════════════════════════════════════════════════════════════════════════
# 자리 낱말
# ══════════════════════════════════════════════════════════════════════════════

#: 금액 자리 — (자리, 패턴). 문장 안 그 금액의 앞뒤 토막에서 찾는다.
_MONEY_ROLES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("loss", re.compile(r"못\s*(돌려|받)|잃|손실|날리|날릴|떼일|떼이")),
    ("return", re.compile(r"(?<!못\s)(?<!못)돌려\s*받|되돌려\s*받|내\s*몫|건질|건지")),
    ("priority", re.compile(r"최우선|소액\s*임차")),
    ("sale", re.compile(r"낙찰|경매로\s*팔리|팔리는\s*값|매각")),
    ("combined", re.compile(r"(더하|합치|합하)(면|고|니)|까지\s*(더|합)|빚\s*[+＋]\s*(내\s*)?보증금|빚과\s*(내\s*)?보증금")),
    ("senior_total", re.compile(
        r"먼저\s*(갚|받아|가져)[가-힣\s]{0,8}빚|선순위|빚\s*(합계|모두|전부|총)|빚이\s*모두|빚은\s*모두"
    )),
    ("senior_item", re.compile(r"근저당|채권\s*최고액|빚\s*최대\s*한도|전세권")),
    ("lease", re.compile(r"임차권\s*등기")),
    ("seizure", re.compile(r"가압류|압류")),
    ("deposit", re.compile(r"보증금|전세금")),
    ("market", re.compile(r"시세|집값|매매\s*가|집\s*가격")),
)
#: 이 말이 붙으면 '보증금·시세·낙찰가' 자체가 아니라 거기서 **덜어 낸 값**이다 ("보증금 중 5,000만원")
_DERIVED_RE = re.compile(r"중\s|중에|절반|남은|남는|빼고|뺀|빼면|차이|나머지|만큼|의\s*\d")
_DERIVABLE = {"deposit", "market", "sale"}

#: 퍼센트 자리 — 앞에 있는 것이 이긴다(합친 비율 > 전세가율 > 빚 비율 > 매각가율 > 기준)
_PCT_ROLES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("combined", re.compile(r"(더하|합치|합하)(면|고|니)|까지\s*(더|합)|빚\s*[+＋]\s*(내\s*)?보증금|빚과\s*(내\s*)?보증금")),
    ("jeonse", re.compile(r"전세가율|보증금(이|은|는)?\s*(시세|집값|매매\s*가)")),
    ("senior", re.compile(r"빚|선순위|근저당|채권")),
    ("sale_rate", re.compile(r"매각가율|낙찰|팔리")),
)
_THRESHOLD_RE = re.compile(r"기준|넘으면|넘지|이하|이상|요건|조건|선을")

_ROLE_NAME = {
    "deposit": "내 보증금", "market": "시세", "senior_total": "먼저 갚을 빚 합계", "senior_item": "빚(근저당·전세권)",
    "combined": "빚과 보증금을 더한 돈", "sale": "경매로 팔리는 값", "return": "돌려받을 돈", "loss": "못 돌려받는 돈",
    "priority": "최우선변제", "seizure": "가압류·압류 금액", "lease": "임차권등기 보증금",
}
_PCT_NAME = {"combined": "빚과 보증금을 더한 비율", "jeonse": "전세가율(보증금 ÷ 시세)", "senior": "빚 ÷ 시세 비율",
             "sale_rate": "매각가율", "threshold": "판정 기준"}

#: 문장 경계 — 마침표·물음표·느낌표(숫자 사이 소수점은 빼고)·줄바꿈
_SENT_END = re.compile(r"(?<!\d)[.!?。](?!\d)|\n")
#: 금액 여럿을 잇는 말 — 이것만 사이에 있으면 같은 자리로 묶는다("3억 6,000만원과 5,200만원 선순위 근저당")
_LIST_GLUE = re.compile(r"^\s*(과|와|이랑|랑|하고|및|그리고|,|·|/)\s*$")
#: 한 문장 안의 마디 경계 — 금액의 자리는 **같은 마디** 안의 낱말로만 읽는다
#: ("빚이 4억 1,200만원이라 시세 4억원보다 많아요"의 '시세'는 뒤 금액의 자리다)
_CLAUSE_CUT = re.compile(
    r"[,，;/—–]|\s·\s|(?:^|(?<=[가-힣]))(고|며|면서|는데|은데|인데|지만|아서|어서|라서|니까|이라|라|보다|예요|이에요|에요)\s"
)
#: 뒤쪽은 짧게만 본다 — 금액 바로 뒤에 붙는 말("3억원 선순위 근저당", "5,000만원을 돌려받아요")
_AFTER_WINDOW = 14
#: 'N순위' (선순위·후순위·우선순위·앞순위는 숫자가 없어 걸리지 않는다)
_ORDER_RE = re.compile(r"(?<![\d.])(\d+)\s*순위")
_PRECEDENT_RE = re.compile(r"판례")


_LINE_END = re.compile(r"([.!?。]|[요다죠까])\s*$")


def _sentences(text: str) -> list[str]:
    """문장들. 판례 말풍선은 **문장 가운데서 줄을 바꾼다**("이 집도 3억 6,000만원\n선순위 근저당이 있어요") —
    줄 끝이 문장 끝(…요 · …다 · 마침표)이 아니고 다음 줄이 새 문단(`**머리말**`)도 아니면 이어 붙인다."""
    lines = [ln.strip() for ln in (text or "").replace("\r", "").split("\n")]
    joined: list[str] = []
    buf = ""
    for ln in lines:
        if not ln:
            continue
        if buf and (ln.startswith("**") or _LINE_END.search(buf)):
            joined.append(buf)
            buf = ln
        else:
            buf = f"{buf} {ln}" if buf else ln
    if buf:
        joined.append(buf)
    out: list[str] = []
    for chunk in joined:
        start = 0
        for m in _SENT_END.finditer(chunk):
            out.append(chunk[start: m.end()])
            start = m.end()
        if start < len(chunk):
            out.append(chunk[start:])
    return [x for x in out if x.strip()]


def _money_roles(seg: str) -> set[str]:
    roles = {role for role, rx in _MONEY_ROLES if rx.search(seg)}
    if _DERIVED_RE.search(seg):
        roles -= _DERIVABLE  # '보증금 중 5,000만원' — 보증금 자체가 아니다
    return roles


def _clause_before(seg: str) -> str:
    """금액 **앞** 토막에서 같은 마디만 — 마지막 마디 경계 뒤."""
    cut = 0
    for m in _CLAUSE_CUT.finditer(seg):
        cut = m.end()
    return seg[cut:]


def _clause_after(seg: str) -> str:
    """금액 **뒤** 토막에서 같은 마디만 — 첫 마디 경계 앞, 길어야 몇 글자."""
    m = _CLAUSE_CUT.search(seg)
    head = seg[: m.start()] if m else seg
    return head[:_AFTER_WINDOW]


def _has_batchim(word: str) -> bool:
    """마지막 글자에 받침이 있나 — 괄호 앞 말로 본다('빚(근저당·전세권)' → '빚')."""
    w = re.sub(r"\(.*?\)", "", word).strip()
    if not w:
        return False
    c = w[-1]
    if "가" <= c <= "힣":
        return (ord(c) - 0xAC00) % 28 != 0
    return c in "013678"  # 영·일·삼·육·칠·팔


def _wa(word: str) -> str:
    return f"{word}{'과' if _has_batchim(word) else '와'}"


def _eun(word: str) -> str:
    return f"{word}{'은' if _has_batchim(word) else '는'}"


def _won_list(values: Iterable[int]) -> str:
    return " · ".join(format_won(v) for v in sorted(values))


def _close(value: float, targets: Iterable[float]) -> bool:
    return G._supported(value, list(targets))


# ══════════════════════════════════════════════════════════════════════════════
# 검사
# ══════════════════════════════════════════════════════════════════════════════


def check(text: str, led: Ledger | None, *, skip_precedent: bool = False) -> str | None:
    """문장 숫자가 이 집 장부와 어긋나면 **AI에게 돌려줄 쉬운 사유**, 아니면 None. 장부가 없으면 None."""
    if not text or led is None:
        return None
    for sent in _sentences(text):
        if skip_precedent and _PRECEDENT_RE.search(sent):
            continue
        reason = _check_orders(sent, led) or _check_money(sent, led) or _check_pct(sent, led)
        if reason:
            return reason
    return None


#: 'N순위' 바로 뒤에 이 말이 오면 **빚 한 건**의 순서다 — 세입자 차례(빚 다음 번호)는 못 쓴다
_DEBT_AFTER_ORDER = re.compile(r"^\s*(의\s*)?(근저당|전세권|빚|저당|채권|담보)")


def _check_orders(sent: str, led: Ledger) -> str | None:
    for m in _ORDER_RE.finditer(sent):
        n = int(m.group(1))
        # 세입자 차례(빚 다음)까지는 말할 수 있다 — "내 보증금은 3순위예요"(빚 2건 뒤). 빚 한 건이면 빚 수까지만.
        top = led.orders if _DEBT_AFTER_ORDER.match(sent[m.end():]) else led.orders + 1
        if led.orders and 1 <= n <= top:
            continue
        if led.orders:
            return (
                f"'{m.group(0)}'는 이 집에 없는 순서예요. 'N순위'는 살아 있는 빚끼리의 받는 순서(1~{led.orders}순위)만 쓰고,"
                " 등기부의 칸 번호를 순위라고 부르지 마세요"
            )
        return f"'{m.group(0)}'처럼 순위 번호를 쓰지 마세요. 이 집 빚의 받는 순서는 확실하지 않아요"
    return None


def _check_money(sent: str, led: Ledger) -> str | None:
    spans = [(s, e, chunk, value) for s, e, chunk, value in G.money_spans(sent) if value >= 10_000]
    if not spans:
        return None
    # 이웃 금액끼리 '과·와·,'로만 이어져 있으면 한 자리로 묶는다
    groups: list[list[int]] = [[0]]
    for i in range(1, len(spans)):
        between = sent[spans[i - 1][1]: spans[i][0]]
        if _LIST_GLUE.match(between):
            groups[-1].append(i)
        else:
            groups.append([i])
    for gi, group in enumerate(groups):
        first, last = group[0], group[-1]
        prev_end = spans[groups[gi - 1][-1]][1] if gi > 0 else 0
        next_start = spans[groups[gi + 1][0]][0] if gi + 1 < len(groups) else len(sent)
        before = _clause_before(sent[prev_end: spans[first][0]])
        after = _clause_after(sent[spans[last][1]: next_start])
        roles = _money_roles(before) | _money_roles(after)
        known = {r for r in roles if led.money.get(r)}
        if not known:
            continue
        values = [spans[i][3] for i in group]
        chunks = [spans[i][2] for i in group]
        # ① '선순위·먼저 갚을 빚' 자리에 빚 한 건만 — 합계도, 모든 건도 아니면 버린다
        explicit_item = bool(_ORDER_RE.search(before)) or bool(_ORDER_RE.search(after[:6]))
        if "senior_total" in roles and len(led.senior_items) >= 2 and led.senior_total and not explicit_item:
            whole = _close(sum(values), [led.senior_total]) or any(_close(v, [led.senior_total]) for v in values)
            if not whole:
                return (
                    f"'{', '.join(chunks)}'만 '선순위·먼저 갚을 빚'으로 쓰면 빚이 그것뿐인 것처럼 읽혀요."
                    f" 이 집의 먼저 갚을 빚은 {len(led.senior_items)}건, 합계 {format_won(led.senior_total)}이에요."
                    " 합계를 쓰거나, 한 건만 말할 때는 '1순위 근저당 ○○원'처럼 받는 순서를 붙여 주세요"
                )
        # ② 자리를 읽었는데 그 자리 값이 아니다
        for v, chunk in zip(values, chunks):
            allowed = set().union(*(led.money[r] for r in known))
            if _close(v, allowed):
                continue
            if len(group) > 1 and _close(sum(values), allowed):
                continue  # '3억 6,000만원과 5,200만원'처럼 나눠 쓴 합계
            role = next(iter(sorted(known)))
            name = _ROLE_NAME.get(role, role)
            return (
                f"'{chunk}'은(는) 이 집의 {_wa(name)} 맞지 않아요."
                f" 이 집 {_eun(name)} {_won_list(led.money[role])}이에요. 숫자를 그 자리에 맞게 고쳐 주세요"
            )
    return None


def _check_pct(sent: str, led: Ledger) -> str | None:
    spans = G.percent_spans(sent)
    for i, (s, e, chunk, value) in enumerate(spans):
        prev_end = spans[i - 1][1] if i > 0 else 0
        next_start = spans[i + 1][0] if i + 1 < len(spans) else len(sent)
        before = _clause_before(sent[prev_end:s])
        after = _clause_after(sent[e:next_start])
        # 앞 마디에서 먼저 찾고, 없으면 뒤에서("집값의 103%가 이미 빚이에요")
        role = next((name for name, rx in _PCT_ROLES if rx.search(before)), None)
        if role is None:
            role = next((name for name, rx in _PCT_ROLES if rx.search(after)), None)
        threshold = bool(_THRESHOLD_RE.search(before) or _THRESHOLD_RE.search(after))
        allowed: set[float] = set()
        if role and led.pct.get(role):
            allowed |= led.pct[role]
        if threshold:
            allowed |= led.pct.get("threshold", set())
        if not allowed:
            continue
        if _close(value, allowed):
            continue
        name = _PCT_NAME.get(role or "threshold", "비율")
        vals = " · ".join(f"{v:g}%" for v in sorted(led.pct.get(role or "threshold", allowed)))
        return f"'{chunk}'은(는) 이 집의 {_wa(name)} 맞지 않아요. 이 집 {_eun(name)} {vals}예요. 숫자를 그 자리에 맞게 고쳐 주세요"
    return None
