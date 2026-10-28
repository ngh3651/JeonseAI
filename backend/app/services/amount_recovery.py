"""못 읽은 빚 금액을 **같은 사진의 글자(OCR)**로 다시 읽는다 (2026-10-29 QA).

## 왜 만들었나
판정 재료는 Information Extract(IE)다. IE가 근저당·전세권·임차권등기 항목은 찾았는데 **금액 칸만 비워**
돌려주면(읽을 수 없으면 생략하라고 시켰다 — `llm/prompts.py` 4번), 그 빚은 '금액 미상'이 되고 리포트는
"금액을 못 읽은 빚 1건 — 원본으로 확인해 주세요"로 남는다. 규혁 결정: **못 읽은 빚이 없게 만든다**
(1순위), 그래도 못 읽으면 **그 쪽을 다시 찍게** 한다(2순위).

## 무엇을 하나
1. IE가 금액을 비운 **살아 있는** 항목마다, OCR 표에서 **같은 구역(을구) · 같은 순위번호 · 같은 등기목적**
   항목을 찾는다(형광펜 매칭과 같은 앵커).
2. 그 항목의 글자에서 금액을 읽는다 — 콤마 금액('금120,000,000원')과 한글 수사('금일억이천만원정').
3. **서로 다른 금액이 딱 하나**일 때만 채운다. 둘 이상이면(변경등기 등) 어느 것인지 모르니 채우지 않는다.
4. 그래도 못 읽은 항목은 그 항목이 있는 쪽(못 찾았으면 을구가 보인 쪽)을 '다시 찍기' 대상으로 돌려준다.

## 안전 조건 (보수적 편향)
- 금액을 **지어내지 않는다.** 같은 문서의 같은 항목 줄에 적힌 글자만 쓴다.
- 말소된 항목·말소 행은 건드리지 않는다. 사진 묶음 점검이 금액 표시를 막은 경우(쪽 누락 등)에도 —
  그때는 OCR 항목 경계를 믿기 어렵다 — **채우지 않는다**(다시 찍기만 권한다).
- 채운 금액은 리포트의 '찾아본 것'에 한 줄로 밝힌다 — 사용자가 원본과 맞춰 볼 수 있게.
- 판정 규칙은 한 줄도 바뀌지 않는다. 바뀌는 것은 규칙에 들어가는 **사실**(빈 금액)뿐이다(`cancellation.py`와 같은 방식).
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field

from ..schemas.internal import MoneyEntry, RegistryExtract, parse_amount
from .formatting import format_won
from .ocr_layout import DocumentCheck, RegistryItem, build_items

_log = logging.getLogger("jeonseai")

#: (IE 배열, OCR 구역, 등기목적 패턴, 사람이 읽는 이름)
_KINDS = (
    ("mortgages", "을구", re.compile(r"근저당권설정"), "근저당"),
    ("jeonse_rights", "을구", re.compile(r"전세권설정"), "전세권"),
)

#: 한 항목 줄에 적힌 금액 — 콤마 금액 또는 '금…원' 꼴(한글 수사 포함)
_AMOUNT_TEXT = re.compile(r"금\s*[0-9,일이삼사오육칠팔구십백천만억조\s]+원|\d{1,3}(?:,\d{3})+")


@dataclass
class RecoveryResult:
    filled: int = 0
    notes: list[str] = field(default_factory=list)  # 리포트 '찾아본 것'에 붙일 문장
    #: 그래도 못 읽은 빚이 있는 쪽 — **업로드 순서** 인덱스(앱의 사진 순서). 다시 찍기 대상
    unread_pages: list[int] = field(default_factory=list)
    still_unknown: int = 0


def _rank_of(entry: MoneyEntry) -> str:
    raw = entry.model_dump().get("rank_number")
    return str(raw).strip() if raw is not None else ""


def _amounts_in(item: RegistryItem) -> set[int]:
    texts = [m.text for m in item.moneys]
    for _, _, line in item.lines:
        joined = "".join(w.text for w in line.words)
        texts.extend(m.group(0) for m in _AMOUNT_TEXT.finditer(joined))
    out: set[int] = set()
    for t in texts:
        n = parse_amount(t)
        if n:  # 0원은 금액으로 보지 않는다
            out.add(n)
    return out


def recover_missing_amounts(
    extract: RegistryExtract,
    ocr_pages: list,
    *,
    check: DocumentCheck | None,
) -> RecoveryResult:
    """IE가 금액을 비운 살아 있는 빚 → OCR 글자로 채운다. `extract`를 **제자리에서** 고친다."""
    result = RecoveryResult()
    missing = [
        (kind, entry)
        for kind in _KINDS
        for entry in getattr(extract, kind[0])
        if isinstance(entry, MoneyEntry) and entry.is_active and entry.amount is None
    ]
    if not missing:
        return result
    if not ocr_pages:
        result.still_unknown = len(missing)
        return result

    # 문서 순서로 세워 항목을 잇는다(쪽을 넘는 항목) — 형광펜 매칭과 같은 정렬. 업로드 인덱스로 되돌릴 표도 만든다.
    from .highlight import _apply_page_order  # 순환 import 회피 — highlight가 이 모듈을 부르지 않는다

    order = check.page_order if check is not None else None
    ordered, to_upload, _ = _apply_page_order(list(ocr_pages), order)
    items = build_items(ordered)
    # 쪽이 빠졌으면 항목 경계(어디까지가 그 순위의 줄인가)를 믿기 어렵다 — 채우지 않고 다시 찍기만
    may_fill = check is None or check.ok_to_highlight_money

    eul_pages = sorted(
        {to_upload.get(pi, pi) for it in items if it.section == "을구" for pi in it.page_indexes}
    )
    unread: set[int] = set()
    for (attr, section, purpose, label), entry in missing:
        rank = _rank_of(entry)
        candidates = [
            it
            for it in items
            if it.section == section
            and not it.canceled
            and not it.is_cancel_record
            and rank
            and it.rank == rank
            and purpose.search(it.purpose)
        ]
        if len(candidates) == 1 and may_fill:
            amounts = _amounts_in(candidates[0])
            if len(amounts) == 1:
                value = amounts.pop()
                entry.amount = value
                entry.amount_unknown = False
                result.filled += 1
                result.notes.append(
                    f"을구 순위 {rank} {label} 금액은 사진 글자로 다시 읽었어요({format_won(value)}) — 원본과 한 번 맞춰 보세요"
                )
                _log.info(f"[금액] 을구 순위{rank} {label} — IE 빈 금액을 OCR 글자로 채움 ({value:,}원)")
                continue
            _log.info(
                f"[금액] 을구 순위{rank} {label} — OCR 금액 후보 {len(amounts)}개라 채우지 않음"
            )
        else:
            _log.info(
                f"[금액] 을구 순위{rank or '?'} {label} — OCR 항목 {len(candidates)}개"
                f"{'' if may_fill else ' · 쪽 누락으로 채우지 않음'}"
            )
        result.still_unknown += 1
        if len(candidates) == 1:
            unread.update(to_upload.get(pi, pi) for pi in candidates[0].page_indexes)
        else:
            unread.update(eul_pages)
    result.unread_pages = sorted(unread)
    return result
