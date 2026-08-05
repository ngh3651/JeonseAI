"""판정(RuleVerdict) → 결정적(비-LLM) 기본 설명 문구.

역할 두 가지:
1. E-1 단계 리포트의 설명 본문 (LLM 연동 전).
2. E-2 이후 Solar Pro 호출이 실패했을 때의 폴백 — 리포트는 항상 완성된다.

가드레일: 이 모듈은 판정 값(등급·수치)을 절대 만들지 않는다. RuleVerdict를 읽어
문장만 만든다. 문구는 기존 앱 더미(페르소나 리뷰를 거친 문구)를 기반으로 한다.
"""

from __future__ import annotations

from ..schemas.internal import EvidenceVerdict, Grade, RuleVerdict
from . import terms
from .formatting import format_won, round_half_up
from .rule_engine import BLACKLIST_PENDING_LABEL

HEADLINES: dict[Grade, str] = {
    Grade.DANGER: "보증금을 지키기 어려운 신호가 보여요",
    Grade.CAUTION: "확인할 게 몇 가지 있어요 — 지금 결정은 잠시 미루세요",
    Grade.GOOD: "큰 위험 신호는 보이지 않았어요 — 그래도 직접 확인은 필요해요",
}

NEXT_ACTIONS: dict[Grade, str] = {
    # 상담처 전화번호는 Phase F에서 공식 홈페이지로 확인 후 병기
    Grade.DANGER: "계약 전에 HUG(주택도시보증공사) 안심전세포털·대한법률구조공단 등에서 전문가 상담부터 받으세요",
    Grade.CAUTION: "보류하고, 아래 질문을 중개사에게 확인한 뒤 결정하세요",
    Grade.GOOD: "계약 직전 최신 등기부등본으로 한 번 더 확인하고, 보증보험 가입을 알아보세요",
}

# 근거 카드 고정 라벨([설명] title / [UI] termSubtitle·actionLabel 기본값)
TITLES: dict[str, tuple[str, str]] = {
    "jeonse_ratio": ("보증금이 집값에 비해 높지 않나요?", "전세가율"),
    "senior_debt": ("나보다 먼저 돈 받아갈 빚이 있나요?", "선순위 채권 · 근저당권"),
    "ownership": ("집 소유권에 이상 신호가 있나요?", "신탁등기 · 압류 · 가압류"),
    "insurance": ("보증보험에 가입할 수 있나요?", "전세보증금 반환보증 (HUG 등)"),
    "blacklist": ("집주인이 위험 명단에 있나요?", "악성임대인 공개 명단"),
}

# 2026-08-05: 근거 id별 고정 `TERM_GLOSSARY`를 없앴다. 용어는 이제 `data/terms.json`
# 한 곳에 모여 있고, **문장에 실제로 등장한 용어만** `terms.attach()`가 붙인다.
# 예전 방식은 id에 미리 매어 둔 탓에 LLM이 쓴 다른 용어('대항력' 등)에는 툴팁이
# 붙지 않았고, 반대로 문장에 없는 용어가 담길 수도 있었다(계약 §2.2 전제 위반).

# 홈 카드 3번째 줄(topRiskSummary)용 짧은 라벨
_RISK_SHORT = {
    "jeonse_ratio": "전세가율 높음",
    "senior_debt": "먼저 갚을 빚 신호",
    "ownership": "소유권 이상",
    "insurance": "보증보험 확인 필요",
    "blacklist": "임대인 명단 확인",
}


def _risk_label(e: EvidenceVerdict, verdict: RuleVerdict) -> str:
    """홈 카드 요약 줄의 근거별 짧은 라벨 — 위험 매물도 숫자를 병기해 매물끼리
    비교 가능하게 한다(서연 리뷰). 숫자에 라벨을 함께 붙여 초보(지수)도 의미를 안다."""
    if e.id == "jeonse_ratio":
        pct = e.facts.get("jeonse_ratio_pct")
        if pct is not None:
            return f"전세가율 {round_half_up(pct)}%(높음)"
        return _RISK_SHORT["jeonse_ratio"]  # 시세 미입력 등으로 %를 알 수 없을 때
    if e.id == "senior_debt":
        n = (e.facts.get("mortgage_count") or 0) + (e.facts.get("lease_registration_count") or 0)
        return f"{_RISK_SHORT['senior_debt']} {n}건" if n else _RISK_SHORT["senior_debt"]
    return _RISK_SHORT[e.id]


def top_risk_summary(verdict: RuleVerdict) -> str:
    """홈 카드 3번째 줄 — 매물끼리 비교 가능해야 한다 (서연 리뷰 2026-07-07·2026-07-08 반영).

    순서: 위험(DANGER) → 주의(CAUTION, 매물 고유) → 시세 미입력 안내 → 전부 양호 수치.
    시세 미입력이 실제 위험 신호(빚 등)를 덮지 않도록 CAUTION을 시세 안내보다 먼저 본다.
    서비스 쪽 사정으로 생긴 '확인 필요'(보험 구조적 한계·명단 미구축)와, 시세가 없어
    판정 불가한 전세가율은 이 줄에서 제외한다(매물 고유 위험이 아니거나 '높음' 단정 불가).
    """
    dangers = [e for e in verdict.evidences if e.grade is Grade.DANGER]
    if dangers:
        return " · ".join(_risk_label(e, verdict) for e in dangers[:2])

    market_missing = verdict.market_price is None
    cautions = []
    for e in verdict.evidences:
        if e.grade is not Grade.CAUTION:
            continue
        if e.id == "insurance":  # 등기부만으론 확인 불가(구조적) — 매물 고유 위험 아님
            continue
        if e.id == "blacklist" and e.status_label == BLACKLIST_PENDING_LABEL:  # 명단 미구축
            continue
        if e.id == "jeonse_ratio" and market_missing:  # 시세 없으면 '높음'이 아니라 '미상'
            continue
        cautions.append(e)
    if cautions:
        summary = " · ".join(_risk_label(e, verdict) for e in cautions[:2])
        return f"{summary} · 시세 입력 필요" if market_missing else summary
    if market_missing:
        # E3(2026-07-09): 다른 카드 요약과 톤 통일 — 상태 토큰(시세 미입력)을 앞세운다.
        # 2026-08-03: 자동 조회 실패도 이 자리에 온다 — 사용자가 안 넣은 것처럼 말하지 않는다.
        return "시세를 못 구했어요 · 직접 넣으면 결과가 더 정확해져요"
    # 전부 양호 + 시세 있음 — 매물 고유 수치로 홈에서 줄 세워 비교 가능하게
    senior = next((e for e in verdict.evidences if e.id == "senior_debt"), None)
    debt_count = 0
    if senior is not None:
        debt_count = (
            (senior.facts.get("mortgage_count") or 0)
            + (senior.facts.get("jeonse_right_count") or 0)
            + (senior.facts.get("lease_registration_count") or 0)
        )
    pct = round_half_up(verdict.deposit / verdict.market_price * 100)
    return f"전세가율 {pct}% · 먼저 갚을 빚 {debt_count}건"


#: 시세를 결정적 문구에서 부를 이름 (2026-08-05).
#: 폴백 문구도 LLM 프롬프트와 **같은 문제**를 갖고 있었다 — 2026-08-03 자동조회가 붙은
#: 뒤에도 "입력하신 시세"라고 못 박아, 공시가격에서 온 값에도 그렇게 말했다.
_PRICE_CALL = {
    "manual": "입력하신 시세",
    "actual_trade": "국토교통부 실거래가",
    "official_price": "공시가격으로 계산한 집값",
    "tax_base": "국세청 기준시가",
}


def price_call(verdict: RuleVerdict) -> str:
    """이 리포트에서 시세를 뭐라고 부를지. 출처를 모르면 중립적으로 '시세'."""
    prov = verdict.price_provenance
    if prov is not None and prov.source:
        return _PRICE_CALL.get(prov.source, "확인된 시세")
    return "시세"


def easy_explanation(ev: EvidenceVerdict, verdict: RuleVerdict) -> str:
    """근거 카드 펼침 1단의 쉬운 설명 — 판정 결과별 결정적 템플릿."""
    f = ev.facts
    if ev.id == "jeonse_ratio":
        if f.get("jeonse_ratio_pct") is None:
            return (
                "시세를 알 수 없어 아직 계산할 수 없어요. "
                "국토부 실거래가·KB시세에서 확인한 금액을 넣으면 바로 알려드릴게요."
            )
        pct = f["jeonse_ratio_pct"]
        call = price_call(verdict)
        if ev.grade is Grade.DANGER:
            return (
                f"보증금이 {call}의 {pct}%에 달해요(전세가율). 집값이 조금만 내려가도 "
                "집을 팔아 보증금을 다 돌려주기 어려운 수준이에요."
            )
        if ev.grade is Grade.CAUTION:
            return (
                f"보증금이 {call}의 {pct}%를 차지해요(전세가율). "
                "시세가 내려가면 보증금을 다 돌려받기 어려울 수 있어요."
            )
        return f"보증금이 {call}의 {pct}% 수준이에요. 일반적인 범위지만, 시세 근거는 직접 확인하세요."
    if ev.id == "senior_debt":
        if f.get("lease_registration_count"):
            return (
                "이 집에는 임차권등기가 남아 있어요. 과거에 보증금을 제때 돌려받지 못한 "
                "세입자가 있었다는 뜻이라, 같은 일이 반복될 위험을 꼭 확인해야 해요."
            )
        if ev.grade is Grade.DANGER:
            # 2026-08-05: **수치를 넣는다.** 예전 문구는 "크게 잡혀 있어요"라고만 해
            # 1억 8,000만원·시세의 90%를 말하지 않았다. LLM 문장이 좋아지면서 폴백과의
            # 격차가 벌어졌는데, 정작 폴백이 나가는 때는 **Solar가 죽었을 때**다 —
            # 그때 위험 매물이 숫자 없이 나가면 안 된다.
            # 값은 전부 facts에서 온다(결정적 템플릿 유지 — 새로 계산하지 않는다).
            total = f.get("senior_debt_total") or 0
            count = f.get("mortgage_count") or 0
            ratio = f.get("senior_ratio_pct")
            combined = f.get("combined_ratio_pct")
            head = f"이 집에는 나보다 먼저 갚아야 할 빚(선순위 채권)이 {format_won(total)} 있어요"
            if count:
                head += f" — 근저당 {count}건이에요"
            body = ""
            if ratio is not None:
                body = f" 이 빚만으로 {price_call(verdict)}의 {ratio}%예요."
                if combined is not None:
                    body += f" 내 보증금까지 더하면 {combined}%가 돼요."
            return (
                f"{head}.{body} 집이 경매로 넘어가면 이 빚을 진 쪽이 먼저 돈을 받아가고, "
                "남는 금액에서 보증금을 돌려받게 돼요."
            )
        if f.get("unknown_amount_count"):
            return (
                "등기부등본에서 빚 항목을 찾았지만 금액을 정확히 읽지 못했어요. "
                "등기부등본 '을구'에 적힌 빚 금액(채권최고액)을 원본에서 직접 확인해 주세요."
            )
        if ev.grade is Grade.CAUTION:
            return (
                "등기부등본에 먼저 갚아야 할 빚이 있어요. 시세를 입력하면 "
                "이 빚이 과한 수준인지 비율로 알려드릴 수 있어요."
            )
        return "등기부등본에서 큰 빚은 보이지 않았어요. 다만 계약 직전에는 최신 등기부등본으로 다시 확인하세요."
    if ev.id == "ownership":
        signals = f.get("signals") or {}
        if ev.grade is Grade.DANGER:
            if signals.get("신탁등기"):
                return (
                    "신탁등기가 설정되어 있어요. 집주인 마음대로 전세 계약을 "
                    "맺지 못할 수 있어서, 신탁회사의 동의가 있었는지 꼭 확인해야 해요."
                )
            return (
                "이 집엔 압류·가압류(집을 팔거나 세놓지 못하게 묶인 표시)가 걸려 있어요. "
                "집주인이 재산 분쟁 중일 수 있고, 경매로 넘어갈 위험 신호라 계약 전 전문가 확인이 필요해요."
            )
        if ev.grade is Grade.CAUTION:
            return "갑구(소유권) 정보를 온전히 확인하지 못했어요. 등기부등본 원본으로 다시 확인해 주세요."
        return (
            "압류·가압류·신탁 같은 이상 신호는 보이지 않았어요. "
            "다만 계약 직전 최신 등기부등본으로 한 번 더 확인하세요."
        )
    if ev.id == "insurance":
        if ev.grade is Grade.DANGER:
            return (
                "경매·압류 등으로 보증보험 가입이 거절될 수 있는 신호가 있어요. "
                "가입이 안 되는 집은 보증금을 지킬 안전장치가 사라져요."
            )
        return (
            "등기부등본만으로는 가입 가능 여부를 단정할 수 없어요. "
            "가입 요건은 보증기관에서 직접 확인이 필요해요."
        )
    if ev.id == "blacklist":
        if ev.facts.get("matched"):
            return (
                "공개 명단에서 같은 이름이 발견됐어요. 동명이인일 수 있으니 "
                "안심전세포털에서 직접 확인하고, 중개사에게도 꼭 물어보세요."
            )
        if ev.grade is Grade.CAUTION:
            return (
                "아직 명단 대조를 완료하지 못했어요. HUG(주택도시보증공사) 안심전세포털의 "
                "공개 명단에서 집주인 이름을 직접 확인해 주세요."
            )
        return (
            "공개 명단에서 발견되지 않았어요. 다만 명단에 없다고 "
            "안전이 보장되는 건 아니에요 — 아래 질문으로 직접 확인하세요."
        )
    return "자세한 내용은 상세 수치를 확인해 주세요."


def action_label(ev: EvidenceVerdict) -> str | None:
    if ev.action_label:
        return ev.action_label
    if ev.grade is Grade.GOOD and ev.id in ("jeonse_ratio", "ownership"):
        return None
    return "중개사에게 물어볼 질문 보기"


def build(verdict: RuleVerdict) -> dict:
    """리포트에 필요한 [설명]·[UI] 텍스트 일체 (E-2에서 LLM 성공 시 이 값 대신 사용)."""
    return {
        "headline": HEADLINES[verdict.grade],
        "next_action": NEXT_ACTIONS[verdict.grade],
        "top_risk_summary": top_risk_summary(verdict),
        "evidences": {
            ev.id: {
                "title": TITLES[ev.id][0],
                "term_subtitle": TITLES[ev.id][1],
                "easy_explanation": easy_explanation(ev, verdict),
                "term_glossary": terms.attach(easy_explanation(ev, verdict)),
                "action_label": action_label(ev),
            }
            for ev in verdict.evidences
        },
    }
