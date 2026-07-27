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
from .formatting import eun_neun

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
        # **실패도 말한다.** 예전에는 빈 목록이라, 두 번째 경로가 429·타임아웃·스키마
        # 위반·키 없음 중 무엇으로 빠졌든 화면 결과가 전부 똑같이 '무음'이었다.
        # 그러면 교차검증 문장이 있다가 없다가 하는 이유를 아무도 알 수 없다.
        return [
            "이번엔 한 가지 방법으로만 읽었어요 — 두 번째 확인은 하지 못했어요 "
            "(분석 결과에는 영향이 없어요)"
        ]

    agreed = check.agreed
    if agreed:
        detail = ", ".join(f"{c.label} {c.ie_count}건" for c in agreed[:3])
        more = f" 외 {len(agreed) - 3}종" if len(agreed) > 3 else ""
        notes.append(f"서류 내용을 2가지 방법으로 교차 확인했어요 — {detail}{more} 일치")
    elif not check.disagreed:
        notes.append("서류 내용을 2가지 방법으로 교차 확인했어요 — 두 방법 모두 특별한 항목을 찾지 못했어요")

    for c in check.disagreed:
        missed = (unplaced or {}).get(c.field, 0)
        # ⚠ 꼬리를 **"표시하지 않았어요"** 로 통일한다. 앱은 그 표식이 든 문장만
        #   화면에 그리므로(`kUnmarkedNoteMarkers`), 예전의 "조심스럽게 줄였어요"는
        #   **하필 우리가 덜 찾은 쪽(더 위험한 방향)의 불일치를 침묵시켰다.**
        tail = (
            f" 그중 {missed}건은 위치를 짚지 못해 사진에 표시하지 않았어요"
            if missed
            else " 개수가 달라 사진에는 확실한 것만 표시하고 나머지는 표시하지 않았어요"
        )
        # 판정을 어느 쪽 기준으로 했는지 **반드시 말한다.** 숫자 두 개만 던지면
        # "그래서 뭘 믿어야 하지"로 남는다(페르소나 2인 공통 지적).
        #
        # ⚠ **"더 엄격한 쪽으로 계산했다"고 쓰면 거짓말이 된다.** 판정은 언제나
        #   서류 전체를 읽는 방법(IE) 기준이고, 그쪽이 **더 적게** 잡는 경우가 실제로 있다.
        #   그때는 적게 잡았다는 사실을 그대로 말하고 사용자가 직접 확인하게 한다
        #   (판정을 바꾸는 것은 CLAUDE.md 3절이 금지한다 — 대신 침묵하지 않는다).
        if c.ie_count >= c.llm_count:
            verdict_line = f"위험 계산은 더 많이 잡은 {c.ie_count}건 기준으로 했어요."
        else:
            verdict_line = (
                f"위험 계산은 {c.ie_count}건 기준으로 했지만 다른 방법에서는 {c.llm_count}건이"
                " 보였어요 — 등기부 원본을 꼭 한 번 더 확인하세요."
            )
        notes.append(
            f"{eun_neun(c.label)} AI가 서로 다른 두 방법으로 읽었더니 개수가 달랐어요"
            f"({c.ie_count}건 / {c.llm_count}건). {verdict_line}{tail}"
        )
    return notes
