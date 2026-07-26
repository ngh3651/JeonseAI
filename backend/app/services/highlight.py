"""IE 결과 ↔ OCR 좌표 매칭 — 사진 위에 무엇을 어디에 표시할지 정한다.

⚠ **표시 전용이다.** 여기서 나온 어떤 값도 위험 등급·점수·근거 카드를 바꾸지 않는다.
  규칙 엔진은 IE 결과만 보고 이미 판정을 끝냈고, 이 모듈은 그 판정 결과 중 "사진에서
  가리킬 수 있는 것"만 골라 좌표를 붙인다.

설계 원칙 (지시서 + risk-scoring 규칙의 보수적 편향과 같은 방향):
1. **부분 매칭 금지.** 앵커가 하나라도 안 맞으면 좌표 없음으로 둔다.
   틀린 위치에 칠하는 것보다 안 칠하는 것이 낫다.
2. **말소된 항목에는 절대 좌표를 내보내지 않는다.** 사용자가 "이미 없어진 빚"을
   현재 위험으로 오해하는 것이 이 기능의 최악의 오류다.
3. **실패는 조용히 넘어가되 로그에는 이유를 남긴다.** 아침에 형광펜이 안 보일 때
   (a)OCR 실패 (b)매칭 실패 (c)앱 렌더 실패 중 무엇인지 로그만으로 가려야 한다.
4. **로그에 개인정보를 남기지 않는다.** 실명은 `김○○`으로 마스킹하고 좌표·개수만 남긴다.

매칭 대상은 **IE 결과가 기준**이다(OCR이 본 것 전부가 아니라). 규칙 엔진이 판정에 쓴
항목만 표시해야 리포트 내용과 사진 표시가 어긋나지 않는다. 예를 들어 갑구에 이름이
5명 보여도 IE의 `current_owners`가 2명이면 **현재 소유자 2명만** 칠한다 — 이미 지분을
넘긴 옛 소유자를 칠하면 사용자가 그 사람을 임대인으로 오인할 수 있다.
"""

from __future__ import annotations

import logging

from dataclasses import dataclass

from ..schemas.contract import Highlight, HighlightBox
from ..schemas.internal import MoneyEntry, RegistryExtract
from .ocr import OcrResult
from .ocr_layout import OcrPage, RegistryItem, build_items, check_document

_log = logging.getLogger("jeonseai")

# 등기목적 앵커 — 항목 종류별로 등기부에 반드시 쓰이는 말
_PURPOSE_KEYWORDS = {
    "mortgage": "근저당권설정",
    "jeonse": "전세권설정",
}

_OWNER_BODY = (
    "계약서의 임대인 이름과 상대방 신분증이 이 이름과 같은지 확인하세요. "
    "다르면 계약을 진행하지 마세요."
)


def mask_name(name: str) -> str:
    """로그용 이름 마스킹 — `소유자D` → `김○○`, `주식회사하나은행` → `주식○○○○○○○`."""
    name = (name or "").strip()
    if len(name) <= 1:
        return name or "(이름없음)"
    return name[0] + "○" * (len(name) - 1)


def _normalize(
    box: tuple[float, float, float, float], page: OcrPage, pad_ratio: float = 0.0
) -> HighlightBox | None:
    """픽셀 bbox → 0~1 정규화. 원본 크기는 Pillow가 읽은 값(ocr.py)만 쓴다."""
    if page.width <= 0 or page.height <= 0:
        return None
    x0, y0, x1, y1 = box
    pad_x = (x1 - x0) * pad_ratio
    pad_y = (y1 - y0) * pad_ratio
    x0, y0 = max(0.0, x0 - pad_x), max(0.0, y0 - pad_y)
    x1 = min(float(page.width), x1 + pad_x)
    y1 = min(float(page.height), y1 + pad_y)
    if x1 <= x0 or y1 <= y0:
        return None
    return HighlightBox(
        x=round(x0 / page.width, 6),
        y=round(y0 / page.height, 6),
        w=round((x1 - x0) / page.width, 6),
        h=round((y1 - y0) / page.height, 6),
    )


def _active_rights_items(items: list[RegistryItem], section: str) -> list[RegistryItem]:
    """해당 구역에서 **말소되지 않은** 항목만. 말소 행 자체도 대상에서 뺀다."""
    return [
        it
        for it in items
        if it.section == section and not it.canceled and not it.is_cancel_record
    ]


# ══════════════════════════════════════════════════════════════════════════════
# 소유자 이름
# ══════════════════════════════════════════════════════════════════════════════


def _match_owner(
    name: str, items: list[RegistryItem], pages: dict[int, OcrPage]
) -> tuple[int, tuple[float, float, float, float]] | str:
    """이름 문자열이 갑구의 유효 항목에서 발견되면 (page_index, bbox), 아니면 실패 사유."""
    target = name.strip()
    if not target:
        return "이름이 비어 있음"

    hits = [
        (it, hit)
        for it in _active_rights_items(items, "갑구")
        for hit in it.names
        if hit.name == target
    ]
    if not hits:
        # 왜 못 찾았는지를 갈라서 남긴다 — 아침 진단의 핵심
        anywhere = [hit for it in items for hit in it.names if hit.name == target]
        if not anywhere:
            return "이름 word 미검출 (갑구·을구 어디에도 없음)"
        where = ", ".join(f"{h.page_index}:L{h.line_index}" for h in anywhere[:3])
        return f"갑구 유효 항목 밖에서만 발견됨 ({where}) — 말소되었거나 을구 채무자 표기"

    # 같은 이름이 여러 번 나오면 **가장 마지막(최신) 등기**를 쓴다.
    # 갑구는 위에서 아래로 시간순이라, 아래쪽이 현재 지분을 만든 등기다.
    hits.sort(key=lambda pair: (pair[1].page_index, pair[1].box[1]))
    _, hit = hits[-1]
    if hit.page_index not in pages:
        return f"좌표가 있는 페이지({hit.page_index})의 OCR 결과가 없음"
    return hit.page_index, hit.box


# ══════════════════════════════════════════════════════════════════════════════
# 금액 항목 (근저당권 · 전세권)
# ══════════════════════════════════════════════════════════════════════════════


def _match_money_entry(
    entry: MoneyEntry, kind: str, items: list[RegistryItem], pages: dict[int, OcrPage]
) -> tuple[int, tuple[float, float, float, float]] | str:
    """순위번호 + 등기목적 + 금액이 **같은 줄**에 다 있어야 좌표를 준다.

    셋 중 하나라도 없으면 실패다. 금액만 보고 칠하면 같은 금액을 가진 다른 항목
    (말소분 포함)을 칠할 수 있어 순위번호를 반드시 함께 본다.
    """
    rank = str(getattr(entry, "rank_number", "") or "").strip()
    amount = entry.amount
    keyword = _PURPOSE_KEYWORDS[kind]

    if amount is None:
        return "금액 미상 — 앵커로 쓸 금액 문자열이 없음"
    if not rank:
        return "순위번호 없음 — 같은 금액의 다른 항목과 구분할 수 없음"

    amount_text = f"{amount:,}"
    candidates = [it for it in _active_rights_items(items, "을구") if it.rank == rank]
    if not candidates:
        canceled = [it for it in items if it.section == "을구" and it.rank == rank and it.canceled]
        if canceled:
            return (
                f"OCR에서는 을구 순위{rank}가 말소로 확인됨 — 표시하지 않음"
                f" (근거: {canceled[0].cancel_evidence})"
            )
        return f"을구 순위{rank} 항목을 사진에서 찾지 못함"

    item = candidates[0]
    if keyword not in item.purpose:
        return f"을구 순위{rank}의 등기목적에 '{keyword}'이 없음 (읽힌 값 '{item.purpose[:20]}')"

    # 순위번호와 같은 줄에서 금액 word를 찾는다
    for page_index, _, line in item.lines:
        if page_index != item.rank_page_index or line.index != item.rank_line_index:
            continue
        money_words = [w for w in line.words if amount_text in w.text]
        if not money_words and item.rank_box:
            return (
                f"앵커 '{amount_text}'이 순위번호와 같은 줄({page_index}:L{line.index})에 없음"
            )
        if money_words and item.rank_box:
            boxes = [item.rank_box] + [w.box for w in money_words]
            if page_index not in pages:
                return f"좌표가 있는 페이지({page_index})의 OCR 결과가 없음"
            return page_index, (
                min(b[0] for b in boxes),
                min(b[1] for b in boxes),
                max(b[2] for b in boxes),
                max(b[3] for b in boxes),
            )
    return f"을구 순위{rank}의 순위번호 줄을 찾지 못함"


# ══════════════════════════════════════════════════════════════════════════════
# 조립
# ══════════════════════════════════════════════════════════════════════════════


@dataclass
class HighlightResult:
    """하이라이트 + 사용자에게 보여줄 한 줄 안내(있을 때만)."""

    highlights: list[Highlight]
    notice: str | None = None


def build_highlights(extract: RegistryExtract, ocr: OcrResult) -> HighlightResult:
    """IE 결과 + OCR 좌표 → 계약의 `highlights`. 실패해도 예외를 던지지 않는다."""
    if not ocr.pages:
        _log.info("[매칭] 건너뜀 — OCR 결과 없음 (좌표 없이 리포트 완성)")
        return HighlightResult([])

    items = build_items(ocr.pages)
    pages = {p.index: p for p in ocr.pages}

    # ── 사진 묶음 점검: 같은 등기부인가 / 순서가 맞나 / 빠진 쪽은 없나 ──────
    check = check_document(ocr.pages)
    for reason in check.reasons:
        _log.info(f"[사진점검] {reason}")
    if not check.ok_to_highlight_any:
        _log.info("[매칭] 중단 — 사진 묶음 점검 실패로 아무것도 표시하지 않음")
        return HighlightResult([], notice=check.notice)

    canceled_items = [it for it in items if it.canceled]
    if canceled_items:
        reasons = "; ".join(f"{it.section} 순위{it.rank} ← {it.cancel_evidence}" for it in canceled_items)
        _log.info(f"[매칭] — 말소 항목 {len(canceled_items)}건은 대상에서 제외 ({reasons})")

    # 말소 근거 행이 있는데 **대상 항목을 못 찾았다면**, 무언가 말소됐는데 무엇인지 모른다는
    # 뜻이다. 이 상태로 금액을 칠하면 말소된 항목을 칠할 수 있다 → 금액 표시를 통째로 보류.
    unbound = [it for it in items if it.is_cancel_record and not it.cancel_bound]
    money_allowed = check.ok_to_highlight_money
    notice = check.notice
    if unbound:
        money_allowed = False
        detail = "; ".join(f"{it.location} '{it.purpose[:24]}'" for it in unbound)
        _log.info(
            f"[매칭] ⚠ 말소 근거 행 {len(unbound)}건이 대상 항목을 못 찾음 → 금액 표시 전체 보류 ({detail})"
        )
        notice = notice or "말소된 항목을 정확히 가려내지 못해 빚 표시는 생략했어요."

    # ── 대상 수집 (IE 기준) ────────────────────────────────────────────────
    owner_names = [o.name.strip() for o in extract.current_owners if o.name and o.name.strip()]
    active_mortgages = [m for m in extract.mortgages if m.is_active] if money_allowed else []
    active_jeonse = [j for j in extract.jeonse_rights if j.is_active] if money_allowed else []
    total_targets = len(owner_names) + len(active_mortgages) + len(active_jeonse)

    highlights: list[Highlight] = []
    failures: list[str] = []
    owner_count = len(owner_names)
    shared_note = (
        f"이 집은 {owner_count}명 공동명의입니다. 계약하려면 {owner_count}명 전원의 동의가 필요합니다."
        if owner_count > 1
        else None
    )

    for i, name in enumerate(owner_names):
        matched = _match_owner(name, items, pages)
        if isinstance(matched, str):
            failures.append(f"갑구 소유자 {mask_name(name)} — {matched}")
            continue
        page_index, box = matched
        norm = _normalize(box, pages[page_index], pad_ratio=0.08)
        if norm is None:
            failures.append(f"갑구 소유자 {mask_name(name)} — 원본 크기를 몰라 정규화 실패")
            continue
        highlights.append(
            Highlight(
                id=f"owner-{i}",
                page=page_index,
                kind="owner",
                badge=len(highlights) + 1,
                box=norm,
                title=f"소유자 이름 · {name}",
                body=_OWNER_BODY,
                caution=shared_note,
            )
        )

    for kind, entries, label in (
        ("mortgage", active_mortgages, "근저당권"),
        ("jeonse", active_jeonse, "전세권"),
    ):
        for i, entry in enumerate(entries):
            rank = str(getattr(entry, "rank_number", "") or "").strip() or "?"
            matched = _match_money_entry(entry, kind, items, pages)
            if isinstance(matched, str):
                failures.append(f"을구 순위{rank} {label} — {matched}")
                continue
            page_index, box = matched
            norm = _normalize(box, pages[page_index], pad_ratio=0.05)
            if norm is None:
                failures.append(f"을구 순위{rank} {label} — 원본 크기를 몰라 정규화 실패")
                continue
            amount_text = f"{entry.amount:,}원" if entry.amount is not None else "금액 미상"
            highlights.append(
                Highlight(
                    id=f"{kind}-{i}",
                    page=page_index,
                    kind=kind,
                    badge=len(highlights) + 1,
                    box=norm,
                    title=f"{label} · {amount_text}",
                    body=(
                        "집이 경매로 넘어가면 이 금액이 내 보증금보다 먼저 돌려받습니다. "
                        "계약 전에 이 빚이 실제로 얼마 남았는지 은행에서 확인하세요."
                    ),
                    caution=None,
                )
            )

    _log.info(
        f"[매칭] 대상 항목 {total_targets}건 → 좌표 확보 {len(highlights)}건 / 실패 {len(failures)}건"
    )
    for reason in failures:
        _log.info(f"[매칭] ✗ 실패: {reason}")
    if highlights:
        pages_used = sorted({h.page for h in highlights})
        _log.info(
            f"[응답] 좌표 {len(highlights)}건을 정규화하여 계약에 포함 (사진 {pages_used})"
        )
    if notice:
        _log.info(f"[응답] 사용자 안내: {notice}")
    return HighlightResult(highlights, notice=notice)
