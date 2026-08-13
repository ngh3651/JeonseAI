"""말소가 **확인된** 권리를 판정 계산에서 빼는 계층 (2026-08-14, D10).

## 왜 만들었나 — 결정을 뒤집었다

2026-07-27 결정 ③은 "OCR 말소 판정으로 등급을 바꾸지 않는다"였다. 그때의 근거는
"OCR 해석으로 위험을 낮추면 미탐이 난다"였고, 방향 자체는 지금도 옳다.

그런데 실기기 실행에서 **반대 방향의 사실 오류**가 드러났다. 선순위채권 합계
27억 8,000만원 안에 을구 순위1의 채권최고액 13억 8,000만원이 들어 있었는데,
그 근저당은 등기부에 취소선이 그어진 **말소분**이었다. 우리 OCR 레이아웃은 이미
`page_4.jpg:L6-7 의 '1번근저당권설정등기말소'`를 근거로 말소로 판정해 하이라이트에서
빼고 있었다 — 즉 **앱은 말소라는 것을 알고 있으면서 계산에서는 세고 있었다.**

없는 빚을 13억 8,000만원 세는 것은 보수적 편향이 아니라 사실 오류다. 보수적 편향은
"모를 때 위험 쪽으로"이지 "아는데도 틀리게"가 아니다. 등기부 원본과 대조하면 바로
드러나는 종류의 오류이기도 하다.

## 그래서 이 모듈은 무엇을 하는가

`RegistryExtract`의 항목 중 **OCR이 말소를 명확히 결합해 확인한 것**에만
`is_canceled = True`를 찍는다. 그 뒤는 지금까지와 똑같다 — `rule_engine`은 원래부터
`is_active`(= `is_canceled is not True`)인 항목만 센다. **규칙은 한 줄도 바뀌지 않는다.**
바뀌는 것은 규칙에 들어가는 **사실**이다.

## 안전 조건 — 넷 다 통과할 때만 뺀다

1. **결합된 말소만.** `ocr_layout`의 `cancel_bound`/`canceled` 계산을 그대로 쓴다.
   'N번○○등기말소' 행이 같은 구역의 N번 항목을 실제로 찾아냈을 때만 그 항목이
   `canceled`가 된다. 근거 문자열(`cancel_evidence`)이 없으면 빼지 않는다.
2. **미결 말소가 있으면 그 구역은 통째로 손대지 않는다.** 말소 근거 행은 있는데 대상
   항목을 특정하지 못한 상태(`is_cancel_record and not cancel_bound`)는 "무언가 말소됐는데
   무엇인지 모른다"는 **사실**이다. 이때 무엇이든 빼면 살아 있는 권리를 뺄 수 있다.
   구역을 못 읽은 미결('미상')은 **모든 구역**을 막는다.
3. **사진 묶음 점검을 통과해야 한다.** 쪽이 빠졌거나 순서가 어긋났거나 다른 등기부가
   섞였으면(`check_document`) 말소 판정 자체가 어긋날 수 있다 — 빼지 않는다.
4. **하나로 특정될 때만.** 말소된 OCR 항목과 IE 항목을 잇는 짝이 **정확히 하나**여야
   한다. 둘 이상이 후보면 어느 것이 말소분인지 가릴 수 없으므로 빼지 않는다.

어느 하나라도 애매하면 **종전대로 센다.** 빼지 못해 과다 계산되는 쪽은 경고가 남는
방향이고, 잘못 빼는 쪽은 위험이 사라지는 방향이다 — 두 실수의 무게가 다르다.

## 무엇을 열쇠로 잇는가 — 금액 우선, 순위번호는 차선

처음에는 (구역, 순위번호)로 이으려 했다. **실측에서 그 방법이 실패했다.**
2026-08-13 실제 등기부(`out/runs/20260813_234910_034`)에서 IE는 13억 8,000만원짜리
근저당의 순위번호를 **4번**으로 줬는데, OCR로 읽은 등기부에서 그 근저당은 **을구 1번**이고
말소된 것은 바로 그 1번이었다(을구 2번 행 `1번근저당권설정등기말소`). 순위번호만 믿었다면
말소분을 못 뺐을 뿐 아니라, 반대로 **살아 있는 4번을 뺄 뻔했다.**

그래서 금액이 있는 종류(근저당·전세권·임차권등기·가압류)는 **금액**으로 잇는다.
등기부의 금액 표기(`금1,380,000,000원`)는 IE도 OCR도 같은 글자를 읽으므로 순위번호보다
훨씬 안정적이다. 대신 같은 금액이 유효분에도 있으면(실측 사례: 을구 3번과 4번이 둘 다
5억) **어느 쪽이 말소분인지 가릴 수 없으므로 빼지 않는다.**

금액이 없는 종류(압류·경매개시결정·신탁등기)만 순위번호로 잇는다. 이 종류는 갑구에
있고, 실측에서 IE의 갑구 순위번호는 OCR과 일치했다.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field

from ..schemas.internal import MoneyEntry, RegistryEntry, RegistryExtract, parse_amount
from . import highlight, ocr, ocr_layout
from .formatting import format_won
from .ocr_layout import RIGHTS_SECTIONS, UNKNOWN_SECTION, RegistryItem

_log = logging.getLogger("jeonseai")


@dataclass(frozen=True)
class Exclusion:
    """계산에서 뺀 권리 1건 — 로그·고지에 그대로 쓸 수 있는 형태."""

    section: str  # 갑구 | 을구
    rank: str  # 순위번호
    label: str  # 사람이 읽는 이름 ('근저당', '압류' …)
    ie_field: str  # RegistryExtract 속성 이름
    amount: int | None  # 금액이 있는 종류만. 없으면 None
    evidence: str  # "page_4.jpg:L6-7 '1번근저당권설정등기말소'"

    def describe(self) -> str:
        money = f" {format_won(self.amount)}" if self.amount is not None else ""
        return f"{self.section} 순위{self.rank} {self.label}{money} (근거: {self.evidence})"


@dataclass
class CancellationResult:
    """이번 분석에서 말소 제외가 무엇을 했는가."""

    excluded: list[Exclusion] = field(default_factory=list)
    #: 제외를 아예 적용하지 못한 사유. None이면 적용했다(뺄 것이 0건일 수도 있다).
    skipped_reason: str | None = None
    #: 안전 조건 2에 걸려 손대지 않은 구역들
    blocked_sections: tuple[str, ...] = ()
    senior_before: int = 0
    senior_after: int = 0

    @property
    def applied(self) -> bool:
        return self.skipped_reason is None

    @property
    def count(self) -> int:
        return len(self.excluded)

    @property
    def mortgage_count(self) -> int:
        """근저당만 센 개수 — 화면 문구가 '빚'만 말하기 때문에 따로 둔다."""
        return sum(1 for e in self.excluded if e.ie_field == "mortgages")


#: `_RANKED_RULES`의 kind → 사람이 읽는 짧은 이름. 로그 한 줄에 들어갈 길이여야 한다.
_LABELS = {
    "mortgage": "근저당",
    "jeonse": "전세권",
    "lease_registration": "임차권등기",
    "provisional_seizure": "가압류",
    "seizure": "압류",
    "auction": "경매개시결정",
    "trust": "신탁등기",
}


def senior_debt_total(extract: RegistryExtract) -> int:
    """`rule_engine._judge_senior_debt`가 세는 것과 **같은 합계**.

    (유효한 근저당 + 전세권의 금액 중 파싱된 것만. 미상은 0으로 치환하지 않는다.)
    여기서 다시 계산하는 이유는 로그에 "얼마에서 얼마로 줄었는지"를 찍기 위해서다 —
    판정에 쓰이지 않는다.
    """
    entries: list[MoneyEntry] = [
        *(m for m in extract.mortgages if m.is_active),
        *(j for j in extract.jeonse_rights if j.is_active),
    ]
    return sum(e.amount for e in entries if e.amount is not None)


#: 등기목적으로 종류를 가릴 때의 **우선순위**. `highlight._RANKED_RULES`의 선언 순서를
#: 그대로 쓰지 않는 이유는 하나다 — `강제경매개시결정(2번가압류의본압류로의이행)` 같은
#: 문구는 압류 규칙(`(?<!가)압류`)에도 걸린다. 경매를 먼저 보게 해 한 항목이 정확히
#: 한 종류로만 분류되게 한다.
_CLASSIFY_ORDER = (
    "mortgage",
    "jeonse",
    "lease_registration",
    "auction",
    "trust",
    "provisional_seizure",
    "seizure",
)


def _classify(item: RegistryItem):
    """말소된 OCR 항목이 **어느 종류의 권리인가**. 못 가리면 None."""
    by_kind = {r.kind: r for r in highlight._RANKED_RULES}
    for kind in _CLASSIFY_ORDER:
        rule = by_kind.get(kind)
        if rule is not None and rule.purpose.search(item.purpose):
            return rule
    return None


def _section_matches(item_section: str, rule_section: str) -> bool:
    """구역이 같은가. 구역 머리를 못 읽은 '미상'은 어느 권리 구역과도 같다고 본다."""
    return item_section == rule_section or item_section == UNKNOWN_SECTION


def _ocr_amount(item: RegistryItem) -> int | None:
    """OCR 항목이 말하는 **금액 하나**. 하나로 못 좁히면 None.

    등기부의 금액은 `금1,380,000,000원`처럼 늘 `금`으로 시작한다. 이 접두사로 거르지
    않으면 공동담보 목록의 주소 조각(`20,205호(중동)`)이 금액으로 잡힌다(실측).
    """
    amounts = {
        parsed
        for m in item.moneys
        if m.text.strip().startswith("금") and (parsed := parse_amount(m.text)) is not None
    }
    return amounts.pop() if len(amounts) == 1 else None


def _entry_amount(entry: RegistryEntry, rule) -> int | None:
    """IE 항목의 금액 — `highlight._entry_amount`와 같은 규칙(0 치환 금지)."""
    if not rule.amount_attr:
        return None
    return highlight._entry_amount(entry, rule.amount_attr)


def _pick_target(rule, item: RegistryItem, items: list[RegistryItem], extract: RegistryExtract):
    """말소된 OCR 항목 ↔ IE 항목의 짝. (IE 항목|None, 금액|None)

    **정확히 하나로 좁혀질 때만** 항목을 돌려준다. 자세한 근거는 모듈 docstring
    "무엇을 열쇠로 잇는가" 절 참고.
    """
    candidates = [e for e in getattr(extract, rule.ie_field, []) if e.is_active]
    if not candidates:
        return None, None

    # 같은 종류의 **살아 있는** OCR 항목 — 열쇠가 겹치는지 보는 데 쓴다.
    siblings = [
        it
        for it in items
        if it is not item
        and not it.canceled
        and not it.is_cancel_record
        and _section_matches(it.section, rule.section)
        and _classify(it) is rule
    ]

    amount = _ocr_amount(item)
    if rule.amount_attr and amount is not None:
        if any(_ocr_amount(s) == amount for s in siblings):
            # 같은 금액이 유효분에도 있다 → 어느 쪽이 말소분인지 가릴 수 없다(실측 사례).
            return None, None
        matches = [e for e in candidates if _entry_amount(e, rule) == amount]
        return (matches[0], amount) if len(matches) == 1 else (None, None)

    # 금액이 없는 종류(압류·경매개시결정·신탁등기) — 순위번호로 잇는다.
    if not item.rank:
        return None, None
    if any(s.rank == item.rank for s in siblings):
        return None, None
    matches = [
        e for e in candidates if str(getattr(e, "rank_number", "") or "").strip() == item.rank
    ]
    return (matches[0], None) if len(matches) == 1 else (None, None)


def _blocked_sections(items: list[RegistryItem]) -> tuple[str, ...]:
    """미결 말소(대상 항목을 못 찾은 말소 근거 행)가 막는 구역 목록."""
    blocked: set[str] = set()
    for it in items:
        if it.is_cancel_record and not it.cancel_bound:
            if it.section in RIGHTS_SECTIONS:
                blocked.add(it.section)
            else:
                # 구역을 못 읽은 미결 말소 — 어느 구역 것인지 모르므로 전부 막는다.
                blocked.update(RIGHTS_SECTIONS)
    return tuple(sorted(blocked))


def apply_confirmed_cancellations(
    extract: RegistryExtract,
    ocr_result: "ocr.OcrResult",
    *,
    check: "ocr_layout.DocumentCheck | None",
) -> CancellationResult:
    """말소가 확인된 항목에 `is_canceled=True`를 찍는다. **extract를 제자리에서 고친다.**

    돌려주는 값은 로그·고지용이다. 판정은 이 뒤에 `rule_engine`이 평소대로 한다.
    """
    result = CancellationResult(
        senior_before=senior_debt_total(extract),
        senior_after=senior_debt_total(extract),
    )

    # ── 안전 조건 3: 사진 묶음을 믿을 수 있는가 ────────────────────────────────
    if not ocr_result.pages:
        result.skipped_reason = "OCR 결과 없음"
        return result
    if check is None:
        result.skipped_reason = "사진 묶음 점검 결과 없음"
        return result
    if not (check.ok_to_highlight_any and check.ok_to_highlight_money):
        # 쪽 누락·순서 어긋남·다른 등기부 섞임. 빠진 쪽에 말소 행이 있을 수도,
        # 우리가 이은 순서가 틀렸을 수도 있다 — 어느 쪽이든 말소 판정을 믿을 수 없다.
        reasons = "; ".join(check.reasons) or "사유 미상"
        result.skipped_reason = f"사진 묶음 점검 미통과 ({reasons})"
        return result

    # 항목은 페이지를 걸쳐 이어지므로 **문서 순서**로 읽어야 말소 판정이 맞는다
    # (`highlight.build_highlights`와 똑같은 전처리를 쓴다 — 두 곳이 다른 순서로 읽으면
    #  "표시는 뺐는데 계산은 셌다" 같은 어긋남이 정확히 이 자리에서 다시 생긴다).
    ordered_pages, _, _ = highlight._apply_page_order(ocr_result.pages, check.page_order)
    items = ocr_layout.build_items(ordered_pages)

    # ── 안전 조건 2: 미결 말소가 막는 구역 ────────────────────────────────────
    result.blocked_sections = _blocked_sections(items)
    if result.blocked_sections:
        _log.info(
            f"[판정] 말소 미결로 제외 보류 — {', '.join(result.blocked_sections)}는"
            " 종전대로 계산합니다 (말소 근거 행이 대상 항목을 특정하지 못함)"
        )

    # ── 안전 조건 1: 근거가 결합된 말소만 ─────────────────────────────────────
    for item in items:
        if not (item.canceled and item.cancel_evidence):
            continue
        rule = _classify(item)
        if rule is None:
            continue  # 등기목적을 우리 규칙 어느 것으로도 못 읽었다
        if rule.section in result.blocked_sections:
            continue
        if not _section_matches(item.section, rule.section):
            continue

        # ── 안전 조건 4: 짝이 정확히 하나일 때만 ──────────────────────────────
        target, amount = _pick_target(rule, item, items, extract)
        if target is None:
            continue

        target.is_canceled = True
        result.excluded.append(
            Exclusion(
                section=rule.section,
                rank=item.rank or "?",  # OCR이 읽은 **등기부의** 순위번호 (IE 값이 아니다)
                label=_LABELS.get(rule.kind, rule.kind),
                ie_field=rule.ie_field,
                amount=amount,
                # `cancel_evidence`는 "…:L6-7 의 '…'" 형태다. 로그 한 줄로 읽히게
                # 조사만 뺀다(값 자체는 손대지 않는다).
                evidence=(item.cancel_evidence or "").replace(" 의 '", " '"),
            )
        )

    result.senior_after = senior_debt_total(extract)
    _log_result(result)
    return result


def _log_result(result: CancellationResult) -> None:
    """제안서에 그대로 캡처할 두 줄. 근거 없이는 한 건도 찍히지 않는다."""
    for ex in result.excluded:
        _log.info(f"[판정] 말소 확인으로 계산에서 제외 — {ex.describe()}")
    if result.excluded and result.senior_before != result.senior_after:
        _log.info(
            f"[판정] 선순위채권 합계 {format_won(result.senior_before)}"
            f" → {format_won(result.senior_after)} (말소 {result.mortgage_count}건 제외)"
        )
