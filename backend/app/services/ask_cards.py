"""리포트 4장 '중개사에게 물어볼 질문' (2026-10-29 규혁 확정안).

한 줄: **이 집 등기부에서 뽑은 질문 + 이 집 숫자로 계산한 합격선 + 말을 글로 받게 하는 대본.**

누가 무엇을 하나 (판정 불개입 — CLAUDE.md §2-1):
- **고르기 = 규칙.** 등기부 사실(riskFacts·riskTags·ownerFacts·주소)로 질문을 고른다. 최대 4개.
  밀린 세금은 어느 집이든 넣는다(집주인이 계약 때 보여 줘야 하는 서류 — 주택임대차보호법 제3조의7).
- **합격선 = 규칙 계산.** 2장 손실 계산과 **같은 함수**(`loss_estimate.estimate`, 대법원 매각통계)를 쓴다.
  여유 = 예상 낙찰가 − 먼저 갚을 빚 − 내 보증금. 판정 등급과 무관한 참고 정보다.
- **좋은 답·핑계·받아치기·특약 = 정해 둔 문구**(`data/ask_cards.json`). AI가 쓰지 않는다.
- **why(왜 물어봐야 하나)만 AI가 이 집 숫자로 다시 쓸 수 있다**(`polish=True`). 입력에 없는 숫자·판정 말투가 섞이면
  버리고 정해 둔 문장을 쓴다(판례 설명과 같은 검사 — `text_guard.check`).

고르기 기준 중 '산 지 몇 달'(RECENT_MONTHS)은 **질문을 보여 줄지 정하는 값일 뿐 판정이 아니다**
(시세 괴리 잠정값과 같은 취급 — decisions.md 2026-08-03 · 2026-10-29).
"""

from __future__ import annotations

import json
import logging
import re
import time
from datetime import date
from pathlib import Path


from ..schemas.contract import AskCard, AskCards, AskPass, Report
from . import loss_estimate, text_guard
from .formatting import format_won, round_half_up
from .patterns import TAG_AUCTION, TAG_LEASE, TAG_PENDING, TAG_SEIZURE, TAG_TRUST, tags_from_report
from .price_normalize import is_whole_building
from .registry_facts import norm_date

_log = logging.getLogger("jeonseai")
_PATH = Path(__file__).resolve().parents[2] / "data" / "ask_cards.json"

#: 화면에 내는 질문 수 상한 (2026-10-29 규혁: "4개로 가자, 반드시 4개는 아니고")
MAX_CARDS = 4
#: '산 지 얼마 안 된 집' 질문을 붙이는 기간(개월). **판정 아님 — 질문 고르기 전용 잠정값.**
RECENT_MONTHS = 6
_PH = re.compile(r"\{([^{}]+)\}")

_cfg_cache: dict | None = None


def _cfg() -> dict:
    global _cfg_cache
    if _cfg_cache is None:
        _cfg_cache = json.loads(_PATH.read_text(encoding="utf-8"))
    return _cfg_cache


def _fill(text: str, values: dict[str, str]) -> str:
    return _PH.sub(lambda m: values.get(m.group(1), m.group(0)), text or "")


def _dot(iso: str | None) -> str | None:
    """'2026-08-12' → '2026.8.12'"""
    d = norm_date(iso)
    if not d:
        return None
    y, m, dd = d.split("-")
    return f"{int(y)}.{int(m)}.{int(dd)}"


def _months_between(a: str, b: str) -> int | None:
    try:
        da, db = date.fromisoformat(a), date.fromisoformat(b)
    except ValueError:
        return None
    months = (db.year - da.year) * 12 + (db.month - da.month)
    if db.day < da.day:
        months -= 1
    return months


def _card(key: str, t: dict, values: dict[str, str], *, facts: list[str], why: str,
          pass_line: AskPass, ask_key: str = "ask", card_id: str | None = None) -> AskCard:
    return AskCard(
        id=card_id or key,
        title=_fill(t["title"], values),
        legal=bool(t.get("legal", False)),
        facts=[f for f in facts if f],
        why=why,
        ask=_fill(t.get(ask_key) or t["ask"], values),
        okReply=_fill(t["okReply"], values),
        badReply=_fill(t["badReply"], values),
        counter=_fill(t["counter"], values),
        passLine=pass_line,
        docs=list(t.get("docs", [])),
        clause=_fill(t["clause"], values),
        stopSub=_fill(t["stopSub"], values),
    )


def build(report: Report) -> AskCards:
    """리포트 → 4장 질문 묶음. 예외를 던지지 않는 것이 목표지만, 문구 파일이 깨지면 그대로 올린다(배포 전 테스트가 잡는다)."""
    cfg = _cfg()
    T = cfg["cards"]
    tags = tags_from_report(report)
    if TAG_AUCTION in tags:
        return AskCards(cards=[], stop=cfg["stop"])

    W = format_won
    dep = int(report.deposit or 0)
    debt = int(report.seniorDebtAmount or 0)
    # 합격선은 최우선변제를 **빼고** 본다 — 조건이 붙는 돈에 기대 '빚을 둬도 된다'고 하지 않게(2026-10-31)
    est = loss_estimate.estimate(report, priority=False)
    priced = est.status == "ok" and est.expectedSale is not None
    sale = int(est.expectedSale or 0)
    lost = int(est.expectedLoss or 0) if est.status in ("ok", "debt_exceeds") else 0
    cushion = sale - debt - dep if priced else None  # 숨은 빚이 들어갈 자리 (음수면 이미 모자람)
    cushion_clear = sale - dep if priced else None  # 근저당을 말소했을 때
    of = report.ownerFacts
    facts_by: dict[str, list] = {}
    for f in report.riskFacts or []:
        facts_by.setdefault(f.kind, []).append(f)

    values = {
        "모자람": W(lost),
        "근저당합계": W(debt),
        "소유자수": str(of.ownerCount if of else 0),
    }
    leads: list[AskCard] = []
    others: list[AskCard] = []

    # ── 처리 중인 등기 신청 — 잔금 당일 빈틈 (2026-10-31). 무엇인지 모르면 돈을 보내면 안 돼서 맨 앞 ──
    if TAG_PENDING in tags:
        fs = [f"{_dot(report.registryViewedAt) or '이 등기부를 뗀 날'} · 신청사건 처리중"]
        leads.append(_card("pending", T["pending"], values, facts=fs, why=T["pending"]["why"],
                           pass_line=AskPass(text="무슨 신청인지 확인 · 잔금 전에",
                                             sub="처리가 끝난 등기부로 다시 대조하세요")))

    # ── 임차권등기 — 전 세입자가 보증금을 못 받고 나간 기록 ──
    leases = facts_by.get("임차권등기", [])
    if leases or TAG_LEASE in tags:
        fs = [" · ".join(x for x in (_dot(f.receiptDate), "임차권등기" + (f" {W(f.amount)}" if f.amount else "")) if x)
              for f in leases[:2]] or ["임차권등기 기록이 있어요"]
        leads.append(_card("lease", T["lease"], values, facts=fs, why=T["lease"]["why"],
                           pass_line=AskPass(text="임차권등기 말소 · 잔금 전에")))

    # ── 압류·가압류·가처분 ──
    seized = [f for k in ("압류", "가압류", "가처분") for f in facts_by.get(k, [])]
    if seized or TAG_SEIZURE in tags:
        kinds = list(dict.fromkeys(f.kind for f in seized)) or ["압류·가압류"]
        v = {**values, "압류종류": "·".join(kinds)}
        fs = [" · ".join(x for x in (_dot(f.receiptDate), f.kind + (f" {W(f.amount)}" if f.amount else "")) if x)
              for f in seized[:2]]
        leads.append(_card("seizure", T["seizure"], v, facts=fs, why=T["seizure"]["why"],
                           pass_line=AskPass(text="잔금 전 말소 · 특약에 글로")))

    # ── 근저당 — 잔금 날 말소할지, 그대로 둘지 ──
    mortgages = facts_by.get("근저당", [])
    same_day = bool(of and of.latestTransferDate and any(
        norm_date(m.receiptDate) == of.latestTransferDate for m in mortgages))
    if mortgages or debt > 0:
        fs: list[str] = []
        if same_day:
            fs.append(f"{_dot(of.latestTransferDate)} · 집주인이 이 집을 삼")
        fs += [" · ".join(x for x in (_dot(m.receiptDate), "근저당" + (f" {W(m.amount)}" if m.amount else "")) if x)
               for m in mortgages[:2]]
        keep = priced and lost == 0
        if keep:
            t = T["debtKeep"]
            card = _card("debtKeep", t, values, card_id="debt", facts=fs, why=t["why"],
                         pass_line=AskPass(text="대출 더 안 받기 · 특약에 글로",
                                           sub="지금 빚이면 경매 때도 보증금이 다 돌아오는 계산이에요"))
            others.append(card)
        else:
            t = T["debtClear"]
            why = ("집을 산 같은 날 대출이 잡혔어요. 전세금으로 이 대출을 갚으려는 걸 수 있어요." if same_day else t["why"])
            if lost > 0:
                why += f" 안 갚고 두면 경매 때 보증금 {W(lost)}이 모자라요."
            v = dict(values)
            if lost == 0:
                v["모자람"] = "그 빚만큼"
            card = _card("debtClear", t, v, card_id="debt", facts=fs, why=why,
                         pass_line=AskPass(text="잔금 날 말소 · 특약에 글로",
                                           sub=(f"안 되면 경매 때 {W(lost)}을 못 받는 계산이에요" if lost > 0 else None),
                                           tone="danger" if lost > 0 else "plain"))
            if lost == 0:
                card.stopSub = "이 빚이 남으면 경매 때 그 빚부터 빠져요"
            leads.append(card)

    # ── 단독·다가구 — 먼저 들어온 세입자 보증금 ──
    if is_whole_building(report.propertyAddress or report.address or ""):
        if priced and cushion is not None and cushion > 0:
            pl = AskPass(text=f"합계 {W(cushion)} 이하", sub="이만큼까지는 경매 때도 내 보증금이 다 돌아오는 계산이에요")
        elif priced:
            pl = AskPass(text="빚부터 정리돼야 해요", sub=f"지금도 경매 때 {W(lost)}이 모자라요", tone="danger")
        else:
            pl = AskPass(text="확정일자 부여현황으로 합계 확인", sub="건물 시세를 넣으면 한도를 계산해요")
        fs = ["단독·다가구 건물 · 여러 세대가 한 등기부"]
        if debt > 0:
            fs.append(f"먼저 갚을 빚 {W(debt)}")
        leads.append(_card("tenants", T["tenants"], values, facts=fs, why=T["tenants"]["why"], pass_line=pl))

    # ── 신탁 ──
    trusts = facts_by.get("신탁", [])
    if trusts or TAG_TRUST in tags:
        fs = [" · ".join(x for x in (_dot(f.receiptDate), "신탁") if x) for f in trusts[:1]] or ["신탁 기록이 있어요"]
        leads.append(_card("trust", T["trust"], values, facts=fs, why=T["trust"]["why"],
                           pass_line=AskPass(text="신탁회사 임대 동의서 원본")))

    # ── 산 지(지은 지) 얼마 안 된 집 ──
    viewed = norm_date(report.registryViewedAt) or norm_date(report.analyzedAt)
    if of and of.latestTransferDate and viewed and (of.latestCause in ("매매", "보존")):
        months = _months_between(of.latestTransferDate, viewed)
        if months is not None and 0 <= months <= RECENT_MONTHS:
            label = f"{months}개월" if months >= 1 else "한 달이 안"
            v = {**values, "개월": label}
            t = dict(T["recent"])
            if of.latestCause == "보존":
                t["title"] = "지은 지 {개월} 된 집"
            fs = [f"{_dot(of.latestTransferDate)} · " + ("새 건물로 처음 등기됨" if of.latestCause == "보존" else "매매로 집주인이 바뀜"),
                  f"{_dot(viewed)} · 이 등기부를 뗀 날"]
            leads.append(_card("recent", t, v, facts=fs, why=T["recent"]["why"],
                               pass_line=AskPass(text="특약 2줄: 잔금 다음 날까지 새 담보 금지 · 팔거나 대출 늘리면 미리 알림")))

    # ── 공동 소유 ──
    if of and of.ownerCount >= 2:
        others.append(_card("owners", T["owners"], values, facts=[f"지금 소유자 {of.ownerCount}명"],
                            why=T["owners"]["why"], pass_line=AskPass(text="소유자 모두 서명 · 또는 위임장")))

    # ── 밀린 세금 (어느 집이든) ──
    t = T["tax"]
    corporate = bool(of and of.corporate)
    why = (t["whyCorporate"] + " " if corporate else "") + t["why"]
    if priced and cushion is not None and cushion > 0:
        pl = AskPass(big="0원", text=f"많아도 {W(cushion)} 이하", sub="이만큼까지는 경매 때도 보증금이 다 돌아오는 계산이에요")
        why += f" 이 집 여유는 {W(cushion)}이에요."
    elif priced and debt > 0 and cushion_clear is not None and cushion_clear > 0:
        pl = AskPass(big="0원", text=f"빚을 말소하면 {W(cushion_clear)}까지", sub="근저당을 말소했을 때 보증금이 다 돌아오는 한도예요")
        why += f" 근저당을 말소하면 이 집 여유는 {W(cushion_clear)}이에요."
    elif priced:
        pl = AskPass(big="0원", text="밀린 세금이 없어야 해요")
    else:
        pl = AskPass(big="0원", text="밀린 세금이 없어야 해요", sub="시세를 넣으면 이 집 한도를 계산해요")
    n_seize = len(facts_by.get("압류", []))
    tax_facts = [f"압류 {n_seize}건 · 세금은 납세증명서로 확인"]
    if corporate:
        tax_facts.insert(0, "집주인이 회사(법인)")
    tax = _card("tax", t, values, facts=tax_facts, why=why, pass_line=pl,
                ask_key="askCorporate" if corporate else "ask")

    # ── 보증보험 (자리가 남으면) ──
    if report.marketPrice:
        pct = round_half_up(dep / report.marketPrice * 100)
        ins_facts = [f"보증금 {W(dep)} · 시세 {W(report.marketPrice)} ({pct}%)"]
    else:
        ins_facts = [f"보증금 {W(dep)}"]
    insurance = _card("insurance", T["insurance"], values, facts=ins_facts, why=T["insurance"]["why"],
                      pass_line=AskPass(text="특약: 보증보험이 안 되면 계약 해제 · 계약금 전액 반환"))

    if leads:
        ordered = [leads[0], tax, *leads[1:], *others, insurance]
    else:
        ordered = [tax, *others, insurance]
    cards = ordered[:MAX_CARDS]

    share = [cfg["shareIntro"], ""]
    share += [f"{i}. {c.title} — {', '.join(c.docs)}" for i, c in enumerate(cards, 1)]
    share += ["", cfg["shareOutro"]]
    _log.info(f"[4장 질문] {len(cards)}개 · " + ", ".join(c.id for c in cards))
    return AskCards(cards=cards, shareText="\n".join(share))


# ══════════════════════════════════════════════════════════════════════════════
# why 다듬기 (AI) — 이 집 숫자로만, 검사 통과분만
# ══════════════════════════════════════════════════════════════════════════════

_POLISH_CACHE: dict[tuple[str, str], dict[str, str]] = {}
_POLISH_MAX_LEN = 150

_POLISH_PROMPT = """당신은 전세 계약 앱에서 '중개사에게 물어볼 질문' 카드의 "왜 물어봐야 하나" 문장을 쓰는 역할입니다.
읽는 사람은 부동산을 처음 해 보는 사회초년생입니다.

입력: 질문 카드 목록. 카드마다 제목, '이_집에서_본_것'(등기부 사실), '기본_문장'(우리가 쓴 문장)이 있습니다.

할 일: 카드마다 기본_문장을 **이 집 사실이 드러나게** 2~3문장(80~130자)으로 다시 쓰세요.
1. 숫자(금액·날짜·건수·개월)는 입력에 있는 것만 쓰세요. 입력에 없는 숫자를 쓰면 그 카드는 버려집니다.
2. 집이 위험하다/안전하다, 계약해도 된다/안 된다 같은 판정을 하지 마세요. "괜찮아요" "걱정 마세요" 금지.
3. "~해요" 말투로 쓰세요. 쉬운 말을 먼저 쓰고, 꼭 필요한 용어만 쓰세요.
4. 기본_문장의 뜻을 바꾸지 마세요. 질문 자체나 특약을 새로 만들지 마세요.

다음 JSON으로만 답하세요: {"cards": [{"id": "카드 id 그대로", "why": "..."}]}"""


def polish(report: Report, bundle: AskCards, *, call=None) -> AskCards:
    """why를 AI가 이 집 숫자로 다시 쓴다. 키가 없거나 실패하면 그대로 돌려준다(화면은 늘 완성된다)."""
    if not bundle.cards:
        return bundle
    key = (report.id, report.analyzedAt)
    cached = _POLISH_CACHE.get(key)
    if cached is None:
        cached = _polish_call(report, bundle, call=call)
        if cached is not None:
            _POLISH_CACHE[key] = cached
    for c in bundle.cards:
        new = (cached or {}).get(c.id)
        if new:
            c.why, c.whyByAi = new, True
    return bundle


def _polish_call(report: Report, bundle: AskCards, *, call=None) -> dict[str, str] | None:
    from .explanation import _load_api_key
    from .llm import solar_models

    material = [{"id": c.id, "제목": c.title, "이_집에서_본_것": c.facts, "기본_문장": c.why} for c in bundle.cards]
    allowed = text_guard.collect_allowed(material)
    started = time.monotonic()
    try:
        if call is None:
            api_key = _load_api_key()
            if not api_key:
                return None

            def call(messages):  # noqa: E306
                # 모델·추론 설정은 solar_models가 고른다 — 끝난 모델이면 다음 모델로 바꿔 다시(2026-10-31)
                resp, _model = solar_models.post_chat(
                    {"messages": messages, "temperature": 0.4, "max_tokens": 1500,
                     "response_format": {"type": "json_object"}},
                    api_key=api_key,
                    timeout=45,
                )
                resp.raise_for_status()
                return resp.json()["choices"][0]["message"]["content"]

        raw = call([
            {"role": "system", "content": _POLISH_PROMPT},
            {"role": "user", "content": json.dumps({"카드": material}, ensure_ascii=False)},
        ])
        data = json.loads(raw)
    except Exception as e:  # 호출·파싱 실패 — 정해 둔 문장 그대로
        _log.info(f"[4장 질문] why 다듬기 실패 → 정해 둔 문장 ({type(e).__name__})")
        return None
    ids = {c.id for c in bundle.cards}
    out: dict[str, str] = {}
    drops: list[str] = []
    for item in (data.get("cards") or []) if isinstance(data, dict) else []:
        cid = str(item.get("id") or "")
        why = re.sub(r"\s+", " ", str(item.get("why") or "")).strip()
        if cid not in ids or not why:
            continue
        reason = text_guard.check(why, max_len=_POLISH_MAX_LEN, allowed=allowed, grade=report.grade)
        if reason:
            drops.append(f"{cid}:{reason}")
            continue
        out[cid] = why
    _log.info(f"[4장 질문] why 다듬기 {len(out)}/{len(ids)} 통과 ({time.monotonic() - started:.1f}초)"
              + (f" · 버림 {drops}" if drops else ""))
    return out
