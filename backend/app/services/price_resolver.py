"""여러 시세 소스를 하나로 — **채택 규칙**과 **괴리 탐지**.

들어오는 후보는 최대 4개다:
  · 사용자가 직접 넣은 값 (manual)
  · 국토부 실거래가 (actual_trade)          — market_price.py
  · 국토부 공동주택 공시가격 × 140% (official_price) — official_price.py
  · 국세청 오피스텔 기준시가 (tax_base)      — official_price.py

════════════════════════════════════════════════════════════════════════════
채택 규칙: **낮은 쪽을 쓴다. 평균이 아니다.** [2026-08-03 확정]

시세를 높게 잡으면 전세가율이 낮게 나오고, 그러면 위험한 집을 '안전하다'고 말하게
된다 — **미탐(false negative)**이다. 우리가 가장 피해야 하는 방향의 오류다.
평균을 쓰면 높은 값이 낮은 값을 끌어올려 같은 방향으로 틀린다.
════════════════════════════════════════════════════════════════════════════

괴리 = 전세사기 탐지 신호 (정보 계층):
실거래가는 조작할 수 있지만 공시가격은 정부가 매긴다. 신축 빌라를 실제 가치보다
비싸게 매매한 것처럼 신고(자전거래)해 부풀린 실거래가를 근거로 전세보증금을 높게
책정하는 것이 빌라 전세사기의 전형이다. 실거래가가 공시 기준보다 비정상적으로
높으면 이 수법을 의심할 수 있다(인터뷰 U7 신축빌라 · U8 시세 부풀리기).

⚠ **괴리는 판정 룰이 아니다.** 임계값의 권위 있는 출처가 없다. 리포트에 정보로만
  싣고 질문 생성기로 착지시킨다(U7 처리와 동일한 판단).
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field

_log = logging.getLogger("jeonseai")

SOURCE_MANUAL = "manual"
SOURCE_ACTUAL_TRADE = "actual_trade"
SOURCE_OFFICIAL_PRICE = "official_price"
SOURCE_TAX_BASE = "tax_base"

# 공시 기준(정부가 매긴 값) 계열 — 괴리 계산의 기준선이 된다.
PUBLIC_SOURCES = (SOURCE_OFFICIAL_PRICE, SOURCE_TAX_BASE)

SOURCE_LABELS = {
    SOURCE_MANUAL: "직접 입력",
    SOURCE_ACTUAL_TRADE: "국토부 실거래가",
    SOURCE_OFFICIAL_PRICE: "공시가격 기준",
    SOURCE_TAX_BASE: "국세청 기준시가",
}

# ── 괴리 임계값 ──────────────────────────────────────────────────────────────
#
# ⚠ **잠정값 — 실측 후 조정.** 판정에 쓰이지 않는다(정보 계층 전용).
#   근거를 갖춘 값이 아니라 "이 정도면 사람이 한 번 더 봐야 한다"는 출발점이다.
#   `scripts/measure_price_gap.py`로 실제 물건 30~100건의 분포를 재고 나서
#   docs/decisions.md에 기록한 뒤 고친다.
#
# 왜 이 언저리에서 출발하나(추정 근거, 출처 아님): 공시가격 현실화율이 시세의
# 60~70%대라고 알려져 있고 우리는 거기에 140%를 곱하므로, 정상이라면 공시 기준값과
# 실거래가가 비슷해진다. 크게 벌어지면 둘 중 하나가 이상한 것이다.
TRADE_INFLATED_GAP_PCT = 50  # 실거래가가 공시 기준보다 이만큼 이상 높으면 '부풀림 의심'
TRADE_DEPRESSED_GAP_PCT = -30  # 실거래가가 공시 기준보다 이만큼 이상 낮으면 '시세 하락 가능성'


@dataclass(frozen=True)
class PriceCandidate:
    """시세 후보 1건. **숫자만 들고 다니지 않는다** — 출처·기준일이 항상 붙는다."""

    price_won: int
    source: str  # SOURCE_*
    source_name: str  # 사람이 읽는 출처명
    as_of: str  # 기준일 또는 조회 기간
    sample_count: int | None = None  # 실거래가일 때 표본 수
    detail: str = ""  # 매칭 방법 등 부가 설명


@dataclass(frozen=True)
class ResolvedPrice:
    """채택 결과."""

    price_won: int | None
    source: str | None
    as_of: str | None
    sample_count: int | None
    gap_pct: int | None  # (실거래가 - 공시기준) / 공시기준 × 100
    gap_direction: str | None  # 'trade_inflated' | 'trade_depressed' | None
    candidates: list[PriceCandidate] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    @property
    def alternatives(self) -> list[PriceCandidate]:
        """채택되지 않은 후보들 (근거 공개용)."""
        if self.source is None:
            return list(self.candidates)
        picked = False
        out: list[PriceCandidate] = []
        for c in self.candidates:
            if not picked and c.source == self.source and c.price_won == self.price_won:
                picked = True
                continue
            out.append(c)
        return out

    @property
    def manual_and_auto_both_present(self) -> bool:
        sources = {c.source for c in self.candidates}
        return SOURCE_MANUAL in sources and bool(sources - {SOURCE_MANUAL})


def compute_gap_pct(trade_won: int, public_won: int) -> int | None:
    """실거래가가 공시 기준보다 몇 % 높은가. 기준이 0 이하면 계산하지 않는다."""
    if public_won <= 0:
        return None
    return round((trade_won - public_won) / public_won * 100)


def resolve(candidates: list[PriceCandidate]) -> ResolvedPrice:
    """후보 목록 → 채택값 + 괴리. 후보가 없으면 전부 `None`(추정하지 않는다)."""
    usable = [c for c in candidates if c.price_won and c.price_won > 0]
    if not usable:
        return ResolvedPrice(
            price_won=None,
            source=None,
            as_of=None,
            sample_count=None,
            gap_pct=None,
            gap_direction=None,
            candidates=list(candidates),
            notes=[],
        )

    # 낮은 쪽. 같은 값이면 안정적인 순서를 위해 소스 이름으로 가른다.
    picked = min(usable, key=lambda c: (c.price_won, c.source))

    gap_pct: int | None = None
    direction: str | None = None
    trade = next((c for c in usable if c.source == SOURCE_ACTUAL_TRADE), None)
    public = None
    for key in PUBLIC_SOURCES:  # 공시가격을 기준시가보다 먼저 본다
        public = next((c for c in usable if c.source == key), None)
        if public is not None:
            break
    if trade is not None and public is not None:
        gap_pct = compute_gap_pct(trade.price_won, public.price_won)
        if gap_pct is not None:
            if gap_pct >= TRADE_INFLATED_GAP_PCT:
                direction = "trade_inflated"
            elif gap_pct <= TRADE_DEPRESSED_GAP_PCT:
                direction = "trade_depressed"

    return ResolvedPrice(
        price_won=picked.price_won,
        source=picked.source,
        as_of=picked.as_of,
        sample_count=picked.sample_count,
        gap_pct=gap_pct,
        gap_direction=direction,
        candidates=list(candidates),
        notes=[],
    )


def gap_message(resolved: ResolvedPrice) -> str | None:
    """괴리를 사용자 언어 한 줄로. 판정 문구가 아니라 **정보**다."""
    if resolved.gap_pct is None:
        return None
    if resolved.gap_direction == "trade_inflated":
        return (
            f"실제 거래된 값이 정부가 매긴 공시 기준보다 {resolved.gap_pct}% 높아요. "
            "신축 빌라에서 값을 부풀려 신고한 뒤 그 값을 근거로 보증금을 높게 받는 수법이 "
            "있어요 — 중개사에게 이 가격이 어떻게 정해졌는지 꼭 물어보세요."
        )
    if resolved.gap_direction == "trade_depressed":
        return (
            f"정부가 매긴 공시 기준이 실제 거래값보다 높아요(실거래가가 {abs(resolved.gap_pct)}% 낮음). "
            "최근 시세가 내려가고 있을 수 있어요 — 계약 시점의 시세를 한 번 더 확인하세요."
        )
    return (
        f"실제 거래값과 정부 공시 기준의 차이는 {resolved.gap_pct}% 예요 "
        "(둘이 크게 다르지 않아요)."
    )


def log_decision(resolved: ResolvedPrice) -> None:
    """채택 과정을 사람이 읽을 수 있게 남긴다.

    ⚠ 주소·이름·번지를 찍지 않는다 — 각 후보가 이미 자기 안에 법정동코드까지만 담고 있다.
    """
    for c in resolved.candidates:
        parts = []
        if c.as_of:  # 사용자 입력값에는 기준일이 없다 — "( 기준"으로 새지 않게
            parts.append(f"{c.as_of} 기준")
        if c.sample_count:
            parts.append(f"표본 {c.sample_count}건")
        if c.detail:
            parts.append(c.detail)
        suffix = f" ({' · '.join(parts)})" if parts else ""
        _log.info(
            f"[시세] 후보 — {SOURCE_LABELS.get(c.source, c.source)}: "
            f"{c.price_won:,}원{suffix}"
        )
    if resolved.price_won is None:
        _log.info("[시세] 채택: 없음 — 전세가율은 '확인 필요'로 남습니다")
        return
    label = SOURCE_LABELS.get(resolved.source, resolved.source)
    picked_note = "낮은 쪽" if len(resolved.candidates) > 1 else "유일한 후보"
    _log.info(f"[시세] 채택: {label} {resolved.price_won:,}원 ({picked_note})")
    if resolved.gap_pct is not None:
        mark = {
            "trade_inflated": " ⚠ 부풀림 의심",
            "trade_depressed": " ⚠ 시세 하락 가능성",
        }.get(resolved.gap_direction or "", "")
        sign = "+" if resolved.gap_pct >= 0 else ""
        _log.info(f"[시세] 괴리: 실거래가가 공시 기준 대비 {sign}{resolved.gap_pct}%{mark}")
