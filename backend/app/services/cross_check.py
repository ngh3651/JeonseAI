"""두 추출 경로의 **불일치를 사용자에게 말해주는** 계층.

지금까지 두 경로가 어긋나면 조용히 표시만 보류하고 끝났다. 그것이 신뢰를 깎는다는 것이
2026-07-27 페르소나 2인의 공통 지적이었다("AI가 을구를 안 봤나 보다") — 침묵이 문제다.

두 경로란:
- **문서 판독** = Upstage Information Extract. 사진을 통째로 보고 필드를 뽑는다. 좌표는 없다.
- **사진 판독** = Document OCR로 글자·좌표를 얻고, 그 줄·칸 텍스트를 국내 LLM에 넘겨
  두 번째로 구조화한 것. 위치를 알지만 사진 품질에 약하다.

⚠ **판정은 문서 판독(IE) 기준을 유지한다.** 사진 판독이 항목을 더 찾아도 등급은 바뀌지
  않는다. 불일치는 ⑴ 사용자 고지 ⑵ 표시 보류 판단에만 쓴다. 이 경계는
  `tests/test_cross_check.py`가 못 박는다.

실측 근거 (2026-07-28, 왜 이게 필요한가):
IE는 `seizures`와 `provisional_seizures`에 **같은 순위번호(2,4,7,8,9)를 중복 배정**했다.
같은 문서를 5회 다시 넣어도 배열 길이는 고정이었으므로 흔들림이 아니라 **구조적 한계**다.
등기목적 텍스트를 읽는 두 번째 경로만이 압류/가압류를 가른다.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field

from ..schemas.internal import RegistryExtract

_log = logging.getLogger("jeonseai")

# 사용자에게 이름으로 부를 수 있는 항목만 비교한다.
# (`ownership_changes`처럼 개수 자체가 사용자에게 의미 없는 것은 뺀다 — 숫자가 어긋났다고
#  알려도 무엇을 하라는 말인지 알 수 없어 불안만 남는다.)
_COMPARED: tuple[tuple[str, str], ...] = (
    ("mortgages", "빚(근저당)"),
    ("jeonse_rights", "전세권"),
    ("lease_registrations", "임차권등기"),
    ("provisional_seizures", "가압류"),
    ("seizures", "압류"),
    ("auction_commencements", "경매개시결정"),
    ("trust_registrations", "신탁등기"),
    ("current_owners", "집주인"),
)


@dataclass(frozen=True)
class FieldComparison:
    """항목 종류 1개에 대한 두 경로의 개수 대조."""

    field: str
    label: str
    ie_count: int
    llm_count: int

    @property
    def agrees(self) -> bool:
        return self.ie_count == self.llm_count

    @property
    def both_empty(self) -> bool:
        return self.ie_count == 0 and self.llm_count == 0


@dataclass
class CrossCheck:
    """교차검증 결과. `ran=False`면 두 번째 경로가 없었다는 뜻이다."""

    ran: bool = False
    provider: str | None = None
    comparisons: list[FieldComparison] = field(default_factory=list)
    error: str | None = None

    @property
    def agreed(self) -> list[FieldComparison]:
        return [c for c in self.comparisons if c.agrees and not c.both_empty]

    @property
    def disagreed(self) -> list[FieldComparison]:
        return [c for c in self.comparisons if not c.agrees]


def _active_count(extract: RegistryExtract, field_name: str) -> int:
    """말소되지 않은 항목 수. `current_owners`는 말소 개념이 없어 그대로 센다."""
    items = getattr(extract, field_name, []) or []
    if field_name == "current_owners":
        return len(items)
    return len([x for x in items if getattr(x, "is_active", True)])


def compare(
    ie: RegistryExtract, llm_extract: RegistryExtract | None, *, provider: str | None = None,
    error: str | None = None,
) -> CrossCheck:
    """문서 판독(IE) ↔ 사진 판독(LLM) 개수 대조. **판정을 만들지 않는다.**"""
    if llm_extract is None:
        return CrossCheck(ran=False, provider=provider, error=error)
    comparisons = [
        FieldComparison(
            field=name,
            label=label,
            ie_count=_active_count(ie, name),
            llm_count=_active_count(llm_extract, name),
        )
        for name, label in _COMPARED
    ]
    check = CrossCheck(ran=True, provider=provider, comparisons=comparisons)
    _log.info(
        f"[교차검증:{provider}] 일치 {len(check.agreed)}종 / 불일치 {len(check.disagreed)}종"
        + (
            " | 불일치 상세: "
            + ", ".join(f"{c.field} IE {c.ie_count} vs LLM {c.llm_count}" for c in check.disagreed)
            if check.disagreed
            else ""
        )
    )
    return check


def to_notes(check: CrossCheck, *, unplaced: dict[str, int] | None = None) -> list[str]:
    """교차검증 결과 → `checkedNotes` 문장.

    `unplaced`는 "리포트에는 있는데 사진에서 위치를 못 짚은" 종류별 개수다
    (`highlight.py`가 센다). 두 숫자를 한 문장에 담아야 사용자가 "왜 개수가 다르지?"를
    스스로 풀 수 있다.
    """
    notes: list[str] = []
    if not check.ran:
        return notes

    agreed = check.agreed
    if agreed:
        detail = ", ".join(f"{c.label} {c.ie_count}건" for c in agreed[:3])
        more = f" 외 {len(agreed) - 3}종" if len(agreed) > 3 else ""
        notes.append(f"서류 내용을 2가지 방법으로 교차 확인했어요 — {detail}{more} 일치")
    elif not check.disagreed:
        notes.append("서류 내용을 2가지 방법으로 교차 확인했어요 — 두 방법 모두 특별한 항목을 찾지 못했어요")

    for c in check.disagreed:
        missed = (unplaced or {}).get(c.field, 0)
        tail = (
            f" {missed}건은 위치를 짚지 못해 사진에 표시하지 않았어요"
            if missed
            else " 개수가 달라 사진 표시는 조심스럽게 줄였어요"
        )
        notes.append(
            f"{c.label}은(는) 문서 판독에서 {c.ie_count}건, 사진 판독에서 {c.llm_count}건이"
            f" 확인됐어요.{tail} (리포트의 근거 카드에는 전부 반영돼 있어요)"
        )
    return notes
