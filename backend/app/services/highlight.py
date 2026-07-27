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
from .formatting import format_won
from .ocr import OcrResult
from .ocr_layout import OcrPage, RegistryItem, build_items, check_document

_log = logging.getLogger("jeonseai")

# 등기목적 앵커 — 항목 종류별로 등기부에 반드시 쓰이는 말
_PURPOSE_KEYWORDS = {
    "mortgage": "근저당권설정",
    "jeonse": "전세권설정",
}

# 문구 원칙 (2026-07-27 페르소나 리뷰 반영):
# - 사용자가 **직접 할 수 있는 행동**으로 끝낸다. "은행에서 확인하세요" 같은, 남의 대출
#   잔액을 은행이 알려줄 리 없는 지시는 "이 앱은 현실을 모른다"로 읽혀 경고 전체를 무시하게 한다.
# - 어려운 말은 **쉬운 말 먼저, 괄호에 원래 말**.
# - 법적 단정("전원 동의가 필요합니다") 대신 권고형 — 판정이 아닌 조언 계층이며,
#   권위 출처 없이 단정하면 앱 전체 신뢰가 흔들린다(risk-scoring 3절 톤과도 일치).
_OWNER_BODY = (
    "계약서에 적힌 집주인(임대인) 이름, 그리고 계약 자리에 나온 사람의 신분증이 "
    "이 이름과 같은지 확인하세요. 하나라도 다르면 그날은 서명하지 마세요.\n"
    "대리인이 나왔다면 집주인의 위임장과 인감증명서를 함께 보여 달라고 하세요."
)

# 집주인이 법인일 때는 위 문구를 그대로 쓰면 **틀린 지시**가 된다.
# 계약 자리에 나오는 사람은 대표이사·직원이고, 그 사람 신분증에 '주식회사○○'이
# 적혀 있을 리가 없다. 그대로 따르면 정상 계약을 이상하다고 판단하거나,
# 반대로 확인 자체를 포기한다(2026-07-27 실호출: 소유자가 '법인A'인데
# 개인용 문구가 나갔다).
#
# 법인 여부는 **OCR이 읽은 등록번호 뒤 7자리**로 가른다 — 마스킹(`○○○○○○-○******`)이면
# 개인, 숫자(`121111-0173575`)면 법인이다(docs/ocr-highlight-findings.md §2.8).
# IE의 `current_owners`에는 이름·지분만 있어 법인 여부를 알 수 없다.
#
# ⚠ 고정 템플릿이다. LLM을 개입시키지 않는다(결정 ④). 표시 계층이라 등급·점수와 무관하다.
_OWNER_BODY_CORP = (
    "집주인이 사람이 아니라 회사(법인)예요. 계약 자리에 나오는 사람은 대표이사나 직원이라, "
    "그 사람 신분증에 이 이름이 적혀 있지 않은 것이 정상이에요.\n"
    "회사의 등기부(법인 등기사항전부증명서)를 보여 달라고 해서, 나온 사람이 거기 적힌 "
    "대표이사와 같은 사람인지 확인하세요.\n"
    "대표이사가 아닌 사람이 나왔다면 회사의 법인인감증명서와 위임장을 함께 보여 달라고 하고, "
    "계약서에 찍는 도장이 그 법인인감과 같은지도 확인하세요."
)
_OWNER_SOURCE = "등기부 갑구 — 이 앱이 사진에서 직접 찾은 위치"

_MORTGAGE_BODY = (
    "집이 경매로 넘어가면, 이 돈을 빌려준 곳이 내 보증금보다 먼저 돈을 가져갑니다. "
    "그만큼 내가 못 받을 수 있어요.\n"
    "등기부에 적힌 이 금액은 실제 빚보다 크게 잡아 둔 한도(채권최고액)예요. "
    "지금 남은 빚이 얼마인지는 중개사에게 '집주인 대출 잔액 확인서(부채증명원)'를 요청해 확인하세요."
)
_JEONSE_BODY = (
    "나보다 먼저 들어온 세입자가 이 집에 권리를 걸어 둔 것입니다. "
    "집이 경매로 넘어가면 그 사람이 내 보증금보다 먼저 돈을 가져갑니다.\n"
    "이 전세권이 언제 없어지는지 중개사에게 확인하고, 없어진 뒤에 계약하는 것이 안전합니다."
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
) -> tuple[int, tuple[float, float, float, float], str] | str:
    """이름이 갑구의 유효 항목에서 발견되면 (page_index, bbox, 개인/법인), 아니면 실패 사유.

    세 번째 값(`kind`)은 **OCR이 읽은 등록번호 형태**에서 온다 — 문구를 개인용/법인용으로
    가르는 유일한 근거다(IE는 소유자의 등록번호를 주지 않는다).
    """
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
    return hit.page_index, hit.box, hit.kind


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
    """하이라이트 + 사용자에게 보여줄 안내."""

    highlights: list[Highlight]
    notice: str | None = None
    # 등기부 꼬리말의 열람일시 `YYYY.MM.DD` — **표시 전용**. 판정에 쓰지 않는다.
    # 등기부는 열람 시점의 스냅샷이라, 그 뒤에 잡힌 근저당은 이 서류에 없다.
    viewed_at: str | None = None
    # **"무엇을 찾아봤고 무엇을 왜 표시하지 않았는지"** 요약. 표시 전용이다.
    #
    # 왜 필요한가 (2026-07-27 페르소나 2인 공통 지적, 이번 리뷰 최다 지적):
    # 이 등기부는 근저당이 전부 말소돼 이름에만 형광펜이 칠해진다. 그런데 화면이
    # 그 사실을 **한 마디도 하지 않으면** 두 페르소나 모두 "AI가 을구를 안 봤나 보다,
    # 그럼 이 판정도 못 믿겠다"로 읽었다. 즉 **침묵이 신뢰를 깎는다.**
    # 반대로 "근저당 2건은 모두 말소된 것으로 확인해 표시하지 않았어요" 한 줄이 들어가면
    # 같은 화면이 "을구를 읽었고, 읽은 결과 뺐구나"라는 **가장 강한 신뢰 장치**가 된다.
    checked_notes: list[str] = None  # type: ignore[assignment]

    def __post_init__(self) -> None:
        if self.checked_notes is None:
            self.checked_notes = []


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
        # 표시를 못 하더라도 "언제 뗀 서류인가"는 알려준다 — 표시와 무관한 사실이다.
        return HighlightResult([], notice=check.notice, viewed_at=check.viewed_at)

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
        f"이 집은 {owner_count}명이 함께 가진 집이에요(공동명의). "
        f"계약서에 {owner_count}명 모두의 서명이나 도장이 있는 것이 가장 안전합니다. "
        "한 명만 나온다면 나머지 사람의 위임장과 인감증명서를 보여 달라고 하세요."
        if owner_count > 1
        else None
    )

    for i, name in enumerate(owner_names):
        matched = _match_owner(name, items, pages)
        if isinstance(matched, str):
            failures.append(f"갑구 소유자 {mask_name(name)} — {matched}")
            continue
        page_index, box, owner_kind = matched
        norm = _normalize(box, pages[page_index], pad_ratio=0.08)
        if norm is None:
            failures.append(f"갑구 소유자 {mask_name(name)} — 원본 크기를 몰라 정규화 실패")
            continue
        is_corp = owner_kind == "법인"
        if is_corp:
            _log.info(
                f"[매칭] 갑구 소유자 {mask_name(name)} — 등록번호 형태가 법인 → 법인용 문구 사용"
            )
        highlights.append(
            Highlight(
                id=f"owner-{i}",
                page=page_index,
                kind="owner",
                badge=len(highlights) + 1,
                box=norm,
                title=f"집주인 이름 · {name}",
                body=_OWNER_BODY_CORP if is_corp else _OWNER_BODY,
                caution=shared_note,
                source=_OWNER_SOURCE,
            )
        )

    for kind, entries, label in (
        ("mortgage", active_mortgages, "집에 잡힌 빚 (근저당권)"),
        ("jeonse", active_jeonse, "다른 사람의 전세권"),
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
            amount_text = format_won(entry.amount) if entry.amount is not None else "금액 미상"
            highlights.append(
                Highlight(
                    id=f"{kind}-{i}",
                    page=page_index,
                    kind=kind,
                    badge=len(highlights) + 1,
                    box=norm,
                    title=f"{label} · {amount_text}",
                    body=_MORTGAGE_BODY if kind == "mortgage" else _JEONSE_BODY,
                    caution=None,
                    source="등기부 을구 — 이 앱이 사진에서 직접 찾은 위치",
                )
            )

    _log.info(
        f"[매칭] 대상 항목 {total_targets}건 → 좌표 확보 {len(highlights)}건 / 실패 {len(failures)}건"
    )
    for reason in failures:
        _log.info(f"[매칭] ✗ 실패: {reason}")

    notes = _build_checked_notes(
        extract=extract,
        items=items,
        highlights=highlights,
        money_allowed=money_allowed,
        owner_names=owner_names,
    )
    if highlights:
        pages_used = sorted({h.page for h in highlights})
        _log.info(
            f"[응답] 좌표 {len(highlights)}건을 정규화하여 계약에 포함 (사진 {pages_used})"
        )
    if notice:
        _log.info(f"[응답] 사용자 안내: {notice}")
    for note in notes:
        _log.info(f"[응답] 찾아본 것: {note}")
    return HighlightResult(
        highlights,
        notice=notice,
        checked_notes=notes,
        viewed_at=check.viewed_at,
    )


def _build_checked_notes(
    *,
    extract: RegistryExtract,
    items: list[RegistryItem],
    highlights: list[Highlight],
    money_allowed: bool,
    owner_names: list[str],
) -> list[str]:
    """**"무엇을 찾아봤고 무엇을 왜 표시하지 않았는지"** 를 사용자 말로 정리한다.

    이 함수가 하는 일은 설명뿐이다 — 판정을 만들지도, 바꾸지도 않는다.
    (2026-07-27 페르소나 2인 + 디자인 리뷰가 공통으로 지적한 최우선 항목:
     "표시가 없는 것"과 "안 본 것"이 화면에서 구분되지 않아 신뢰가 깎인다.)
    """
    notes: list[str] = []

    # ① 집주인 이름
    owner_marks = [h for h in highlights if h.kind == "owner"]
    if owner_marks:
        shared = " (공동명의)" if len(owner_names) > 1 else ""
        notes.append(f"집주인 이름 {len(owner_marks)}곳{shared} — 사진에서 찾아 표시했어요")
    elif owner_names:
        notes.append(
            f"집주인 이름 {len(owner_names)}명은 리포트에 반영됐지만, 사진에서 위치를 찾지 못했어요"
        )
    else:
        notes.append("집주인 이름을 등기부에서 읽지 못했어요 — 리포트의 근거 카드를 확인하세요")

    # ② 근저당(집에 잡힌 빚) — **말소를 왜 뺐는지가 이 목록의 핵심**이다
    canceled_mortgages = [
        it for it in items if it.section == "을구" and it.canceled and "근저당" in it.purpose
    ]
    active_mortgages = [m for m in extract.mortgages if m.is_active]
    money_marks = [h for h in highlights if h.kind in ("mortgage", "jeonse")]
    if canceled_mortgages:
        notes.append(
            f"집에 잡힌 빚(근저당) {len(canceled_mortgages)}건은 **모두 말소된 것으로 확인**해 "
            "표시하지 않았어요 — 이미 정리된 빚이에요"
        )
    if not money_allowed and (active_mortgages or extract.jeonse_rights):
        notes.append("빚 표시는 이번엔 생략했어요 — 위 안내를 확인해 주세요")
    elif active_mortgages and money_marks:
        notes.append(f"지금 남아 있는 빚 {len(money_marks)}건을 표시했어요")
    elif active_mortgages and not money_marks:
        notes.append(
            f"지금 남아 있는 빚 {len(active_mortgages)}건은 리포트에 반영됐지만, "
            "사진에서 위치를 찾지 못했어요 — 리포트의 근거 카드에서 확인하세요"
        )
    elif not active_mortgages and not canceled_mortgages:
        notes.append("지금 남아 있는 빚(근저당)은 없었어요")
    elif not active_mortgages:
        notes.append("지금 남아 있는 빚(근저당)은 없어요")

    # ③ 압류·가압류·신탁 등
    signal_fields = (
        extract.seizures + extract.provisional_seizures + extract.provisional_dispositions
        + extract.auction_commencements + extract.trust_registrations
    )
    active_signals = [e for e in signal_fields if e.is_active]
    if active_signals:
        notes.append(
            f"압류·가압류·신탁 같은 표시가 {len(active_signals)}건 있어요 — 리포트의 근거 카드를 꼭 보세요"
        )
    else:
        notes.append("압류·가압류·신탁 같은 표시는 없었어요")

    notes.append("표시가 적다는 건 확인할 게 적다는 뜻이에요. 못 읽었다는 뜻이 아니에요.")

    # [진단] checkedNotes 생성 결과 요약 — 개수/참·거짓만 (이름·번호 금지).
    # ③의 '없었어요'가 조건 분기인지 하드코딩인지, [1]의 압류·가압류 건수와 나란히 놓고 본다:
    # 압류·가압류가 있는데 여기 '문구: 없음'이면 사실과 다른 문장이 화면에 나가는 것이다.
    _attempted = len(owner_names) + (
        len(active_mortgages) + len([j for j in extract.jeonse_rights if j.is_active])
        if money_allowed
        else 0
    )
    _placed = len(owner_marks) + len(money_marks)
    _log.info(
        f"[찾아본것] {len(notes)}줄"
        f" | 말소제외 {len(canceled_mortgages)}건"
        f" | 위치못찾음 {max(0, _attempted - _placed)}건"
        f" | 압류·가압류 문구: {'있음' if active_signals else '없음'}"
    )
    return notes
