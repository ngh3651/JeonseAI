"""'이 집 신호' — 설명 AI가 **이 집의 핵심**을 짚을 수 있게 등기부 사실을 이어 붙인 문장들 (2026-11-01).

규혁(2026-11-01): "누구나 할 수 있는 뻔한 말이 아니라 이 집 상황에 진짜 알맞은 핵심을 짚어야 한다. 같은 틀에 숫자만
바꿔 넣는 게 아니라." — 데이터에는 이미 있는데 AI에게 이어 보라고 시키지 않던 사실들을 문장 하나씩으로 건넨다.

⚠ **판정이 아니다.** 등급·점수·기준선에 아무 영향이 없고(rule_engine은 이 파일을 모른다), 새 기준 숫자도 없다.
  "위험하다"·"의심된다" 같은 평가는 쓰지 않는다 — 사실만 말하고, 무엇이 중요한지는 설명 AI가 이 집에 맞춰 고른다.
⚠ 사람 이름은 넣지 않는다 — 근저당권자는 rule_engine이 이미 가린 값(`이○○`)만, 집주인 이름은 아예 없다.
"""

from __future__ import annotations

from datetime import date

from ..schemas.internal import RegistryExtract, RuleVerdict
from .formatting import format_won
from .mark_plans import dot
from .registry_facts import norm_date, owner_facts


def _months_between(a: str, b: str) -> int | None:
    try:
        da, db = date.fromisoformat(a), date.fromisoformat(b)
    except ValueError:
        return None
    months = (db.year - da.year) * 12 + (db.month - da.month)
    if db.day < da.day:
        months -= 1
    return months if months >= 0 else None


def is_individual(mortgagee: str | None) -> bool:
    """가린 이름(`이○○`)이면 사람 — rule_engine이 기관명은 그대로, 사람은 가려 둔다."""
    return "○" in str(mortgagee or "")


def build(extract: RegistryExtract, verdict: RuleVerdict) -> list[str]:
    """등기부 사실 → '이 집 신호' 문장들. 실패하면 빈 목록(설명은 신호 없이도 나간다)."""
    try:
        return _build(extract, verdict)
    except Exception:  # noqa: BLE001 — 설명 재료 하나 때문에 리포트를 잃지 않는다
        return []


def _build(extract: RegistryExtract, verdict: RuleVerdict) -> list[str]:
    out: list[str] = []
    senior = next((e for e in verdict.evidences if e.id == "senior_debt"), None)
    mortgages = list((senior.facts.get("mortgages") if senior else None) or [])
    of = owner_facts(extract)
    bought = of.latestTransferDate  # 'YYYY-MM-DD'
    cause = of.latestCause or "소유권 이전"
    verb = {"매매": "사면서", "보존": "새로 등기하면서"}.get(cause, f"{cause}로 넘겨받으면서")

    # ① 집을 산(넘겨받은) 날 바로 잡힌 근저당 — 집값을 대출로 치렀다는 사실
    if bought:
        for m in mortgages:
            if norm_date(m.get("receipt_date")) == bought and m.get("max_claim_amount"):
                who = m.get("mortgagee") or "빌려준 곳"
                # 근저당을 '잡는' 쪽은 돈을 빌려준 곳이다 — 집주인이 잡았다고 읽히지 않게(2026-11-01 감사).
                # 빌린 사람(채무자)이 집주인이 아닐 수도 있어(남의 빚 담보) '집주인이 빌렸다'고도 쓰지 않는다.
                out.append(
                    f"집주인이 {dot(bought)}에 이 집을 {verb} 같은 날 {who}의 근저당 "
                    f"{format_won(m['max_claim_amount'])}이 잡혔어요(이 집을 담보로 빌린 돈)"
                )
                break

    # ② 빌려준 곳이 사람(개인)인 근저당 — 은행과 달리 갚았는지 말로만 확인하기 어렵다(사실만)
    for m in mortgages:
        if is_individual(m.get("mortgagee")):
            # 'N순위' = 살아 있는 빚끼리의 받는 순서(2026-11-01, debt_order) — 등기부 칸 번호(말소된 줄도 센다)가 아니다
            rank = f"{m['order']}순위 " if m.get("order") else ""
            amt = f" {format_won(m['max_claim_amount'])}" if m.get("max_claim_amount") else ""
            when = f" ({dot(m.get('receipt_date'))})" if dot(m.get("receipt_date")) else ""
            out.append(f"{rank}근저당{amt}은 은행이 아니라 개인({m['mortgagee']})이 빌려줬어요{when}")

    # ③ 빚이 여러 번에 나눠 잡힘 — 날짜 순서 그대로
    dated = sorted({d for m in mortgages if (d := norm_date(m.get("receipt_date")))})
    if len(mortgages) >= 2 and len(dated) >= 2:
        out.append(f"근저당이 {len(mortgages)}건이에요 · {dot(dated[0])}부터 {dot(dated[-1])}까지 나눠 잡혔어요")

    # ④ 집주인이 이 집을 가진 기간 — 등기부를 뗀 날 기준(못 읽었으면 말하지 않는다)
    viewed = norm_date(verdict.registry_viewed_at)
    if bought and viewed:
        months = _months_between(bought, viewed)
        if months is not None:
            span = f"{months // 12}년 {months % 12}개월" if months >= 12 else f"{months}개월"
            span = span.replace(" 0개월", "")
            out.append(f"집주인이 이 집을 가진 지 {span}이에요 (등기부를 뗀 {dot(viewed)} 기준)")

    # ⑤ 소유권이 여러 번 바뀜
    changes = (verdict.ownership_history or {}).get("change_count") or 0
    if changes >= 2:
        out.append(f"이 등기부에 남은 소유권 이전이 {changes}번이에요")

    # ⑥ 압류·가압류·가처분 — 건수와 가장 최근 날짜
    seized = [e for f in ("seizures", "provisional_seizures", "provisional_dispositions")
              for e in getattr(extract, f) if e.is_active]
    if seized:
        dates = sorted({d for e in seized if (d := norm_date(e.model_dump().get("receipt_date")))})
        tail = f" (가장 최근 {dot(dates[-1])})" if dates else ""
        out.append(f"압류·가압류·가처분이 {len(seized)}건 걸려 있어요{tail}")

    # ⑦ 처리 중인 등기 신청
    if getattr(extract, "pending_application", False):
        out.append("이 등기부를 뗀 날 등기소에서 처리 중인 신청이 있었어요")
    return out


def loss_summary(loss) -> dict | None:
    """손실 예상 → 설명 재료(숫자는 계산 결과 그대로). 계산을 못 했으면 None."""
    if loss is None or getattr(loss, "status", None) not in ("ok", "debt_exceeds"):
        return None
    out: dict = {
        "보증금_원": loss.deposit,
        "돌려받을_돈_원": loss.expectedReturn,
        "못_돌려받는_돈_원": loss.expectedLoss,
        "계산": "경매로 팔리면 먼저 갚을 빚부터 가져가고 남은 돈에서 보증금을 돌려받는다는 계산(대법원 경매 매각통계)",
    }
    if loss.status == "ok":
        out["예상_낙찰가_원"] = loss.expectedSale
        out["매각가율_pct"] = loss.ratePct
    else:
        out["빚이_시세_이상"] = True
    if (getattr(loss, "priorityAmount", 0) or 0) > 0:
        out["최우선변제_원"] = loss.priorityAmount
    return out
