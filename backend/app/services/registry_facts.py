"""등기부의 **살아 있는 위험 항목 사실** — 판례 맞춤 설명의 재료 (2026-10-24).

판례 카드의 '우리 매물과 공통점'·'이런 피해를 피하려면'을 Solar가 **이 집의 실제 숫자**로 쓰게 하려고,
가압류·근저당 같은 항목의 종류·접수일·금액·권리자 종류(기관/개인)를 리포트에 남긴다.

⚠ **판정에 쓰지 않는다**(규칙 엔진은 이 값을 읽지 않는다). 화면에도 그리지 않는다.
⚠ **이름은 남기지 않는다** — 권리자는 '기관'/'개인'만. 말소된 항목은 뺀다.
"""

from __future__ import annotations

import re

from ..schemas.contract import OwnerFacts, RiskFact
from ..schemas.internal import RegistryEntry, RegistryExtract, parse_amount
from .formatting import looks_like_institution

# (추출 필드, 화면 이름, 금액 키, 권리자 키)
_KINDS: tuple[tuple[str, str, str | None, str | None], ...] = (
    ("provisional_seizures", "가압류", "claim_amount", "claimant"),
    ("seizures", "압류", "claim_amount", "claimant"),
    ("provisional_dispositions", "가처분", "claim_amount", "claimant"),
    ("auction_commencements", "경매개시결정", "claim_amount", "claimant"),
    ("trust_registrations", "신탁", None, "trustee"),
    ("mortgages", "근저당", "max_claim_amount", "mortgagee"),
    ("jeonse_rights", "전세권", "deposit_amount", "holder"),
    ("lease_registrations", "임차권등기", "deposit_amount", "holder"),
)

MAX_FACTS = 12  # 재료가 너무 길어지지 않게 (프롬프트 길이)


def _holder_kind(name: object) -> str | None:
    text = str(name or "").strip()
    if not text:
        return None
    return "기관" if looks_like_institution(text) else "개인"


def _amount(entry: RegistryEntry, key: str | None) -> int | None:
    if key is None:
        return None
    raw = entry.model_dump()
    if raw.get("amount") is not None and key in ("max_claim_amount", "deposit_amount"):
        return int(raw["amount"])  # MoneyEntry는 금액을 amount로 정리해 둔다
    return parse_amount(raw.get(key))


def build(extract: RegistryExtract) -> list[RiskFact]:
    facts: list[RiskFact] = []
    for field, label, amount_key, holder_key in _KINDS:
        for e in getattr(extract, field, []) or []:
            if not e.is_active:
                continue
            raw = e.model_dump()
            facts.append(
                RiskFact(
                    kind=label,
                    receiptDate=(str(raw.get("receipt_date")).strip() or None) if raw.get("receipt_date") else None,
                    amount=_amount(e, amount_key),
                    holder=_holder_kind(raw.get(holder_key)) if holder_key else None,
                )
            )
            if len(facts) >= MAX_FACTS:
                return facts
    return facts


# ── 집주인 쪽 사실 (2026-10-29, 4장 질문 고르기 재료) ─────────────────────────

_DATE_RE = re.compile(r"(\d{4})\D{0,3}(\d{1,2})\D{0,3}(\d{1,2})")


def norm_date(raw: object) -> str | None:
    """'2026.8.12' · '2026년 8월 12일' · '2026-08-12' → '2026-08-12'. 못 읽으면 None (지어내지 않는다)."""
    m = _DATE_RE.search(str(raw or ""))
    if not m:
        return None
    y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
    if not (1900 <= y <= 2100 and 1 <= mo <= 12 and 1 <= d <= 31):
        return None
    return f"{y:04d}-{mo:02d}-{d:02d}"


def owner_facts(extract: RegistryExtract) -> OwnerFacts:
    """소유자 수·법인 여부·가장 최근 소유권 이전(보존)일 — **판정에 쓰지 않는다.** 이름은 남기지 않는다."""
    owners = [o for o in (extract.current_owners or []) if (o.name or "").strip()]
    corporate = any(looks_like_institution(o.name or "") for o in owners)
    latest: tuple[str, str | None] | None = None
    for e in extract.ownership_changes or []:
        if not e.is_active:
            continue
        raw = e.model_dump()
        date = norm_date(raw.get("receipt_date"))
        if not date:
            continue
        purpose = str(raw.get("purpose") or "")
        cause = "보존" if "보존" in purpose else (str(raw.get("cause") or "").strip() or None)
        if latest is None or date > latest[0]:
            latest = (date, cause)
    return OwnerFacts(
        ownerCount=len(owners),
        corporate=corporate,
        latestTransferDate=latest[0] if latest else None,
        latestCause=latest[1] if latest else None,
    )
