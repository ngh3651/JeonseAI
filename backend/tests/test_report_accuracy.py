"""리포트가 **틀린 말을 하지 않게** — 받는 순서 · 숫자 뜻 · 법의 사실 (2026-11-01 규혁 실기기 피드백).

시연 샘플(신길동 274-1 제3층 제301호)에서 나온 세 가지를 막는다:
  ① 을구 1번 근저당이 말소(2번은 그 말소 기록)되고 3·4번만 살아 있는데 리포트가 '3순위·4순위 근저당'이라고 했다.
  ② 판례 공통점이 "이 집도 3억 6,000만원 선순위 근저당이 있어요" — 빚은 2건 합계 4억 1,200만원이다.
  ③ 준비된 문구가 "이 빚을 **진** 쪽이 먼저 돈을 받아가고" — 먼저 받는 쪽은 돈을 **빌려준** 곳이다.
"""

from __future__ import annotations

import json
from types import SimpleNamespace as NS

import pytest

from app.schemas.internal import Grade, RegistryExtract
from app.services import (
    debt_order,
    evidence_view,
    explanation,
    fact_ledger,
    fallback_texts,
    house_signals,
    mark_plans,
    registry_facts,
    report_builder,
    rule_engine,
    text_guard,
)
from app.services.precedent import explainer
from app.services.precedent.models import PrecedentChunk, PrecedentDoc, RetrievedPrecedent

# ── 시연 샘플과 같은 모양의 등기부 ────────────────────────────────────────────


def sample_registry() -> dict:
    return {
        "address": "서울특별시 영등포구 신길동 274-1 제3층 제301호",
        "exclusive_area_sqm": 49.85,
        "current_owners": [{"name": "김가상", "share": "단독소유"}],
        "ownership_changes": [
            {"rank_number": "1", "purpose": "소유권보존", "receipt_date": "2019-11-05", "is_canceled": False},
            {"rank_number": "2", "purpose": "소유권이전", "receipt_date": "2022-04-15", "cause": "매매",
             "holder": "김가상", "is_canceled": False},
        ],
        "provisional_seizures": [], "provisional_dispositions": [], "seizures": [],
        "auction_commencements": [], "trust_registrations": [],
        "mortgages": [
            {"rank_number": "1", "max_claim_amount": 3_900_000_000, "mortgagee": "주식회사가상저축은행",
             "receipt_date": "2019-11-05", "is_canceled": True},
            {"rank_number": "3", "max_claim_amount": 360_000_000, "mortgagee": "주식회사가상은행",
             "receipt_date": "2022-04-15", "is_canceled": False},
            {"rank_number": "4", "max_claim_amount": 52_000_000, "mortgagee": "이가상",
             "receipt_date": "2023-08-22", "is_canceled": False},
        ],
        "jeonse_rights": [], "lease_registrations": [],
    }


def sample_extract() -> RegistryExtract:
    return RegistryExtract.from_raw(sample_registry())


def sample_verdict():
    return rule_engine.evaluate(sample_extract(), deposit=100_000_000, market_price=400_000_000, blacklist_entries=[])


LOSS = NS(status="ok", expectedSale=301_480_000, expectedReturn=50_000_000, expectedLoss=50_000_000, ratePct=75.4,
          priorityAmount=50_000_000, priorityLimit=50_000_000, priorityCap=150_000_000)


def sample_ledger() -> fact_ledger.Ledger:
    v = sample_verdict()
    return fact_ledger.for_verdict(v, registry_facts.build(sample_extract()), LOSS)


# ══════════════════════════════════════════════════════════════════════════════
# ① 받는 순서
# ══════════════════════════════════════════════════════════════════════════════


def test_순위번호를_못_읽으면_접수일_그것도_안_되면_번호를_붙이지_않는다():
    assert debt_order.orders([{"rank_number": "3"}, {"rank_number": "4"}]) == [1, 2]
    assert debt_order.orders([{"rank_number": "4"}, {"rank_number": "3-1"}]) == [2, 1]
    # 순위번호 하나를 못 읽음 → 접수일 순
    assert debt_order.orders([
        {"rank_number": "", "receipt_date": "2023-08-22"}, {"rank_number": "3", "receipt_date": "2022-04-15"},
    ]) == [2, 1]
    # 순위번호도 없고 접수일이 같다 → 모른다(지어내지 않는다)
    assert debt_order.orders([
        {"receipt_date": "2022-04-15"}, {"receipt_date": "2022-04-15"},
    ]) == [None, None]
    assert debt_order.label("근저당", None) == "근저당"
    assert debt_order.registry_ref("을구", "3") == "을구 3번"
    assert debt_order.registry_ref("을구", "") is None


def test_말소된_1번이_있어도_살아_있는_첫_빚이_1순위다():
    v = sample_verdict()
    senior = next(e for e in v.evidences if e.id == "senior_debt")
    assert [m["order"] for m in senior.facts["mortgages"]] == [1, 2]
    assert [m["rank_number"] for m in senior.facts["mortgages"]] == ["3", "4"]  # 등기부 칸 번호는 그대로 남긴다

    view = evidence_view.build(senior, v, registry_facts.build(sample_extract()), LOSS)
    labels = [p.label for p in view["points"]]
    assert "1순위 근저당" in labels and "2순위 근저당" in labels
    assert not any(lab.startswith(("3순위", "4순위")) for lab in labels)
    queue = view["visual"].items
    assert [i["label"] for i in queue] == ["가상은행", "이○○", "내 보증금"]


def test_전세권도_같은_줄에서_순위번호_순서로_선다():
    raw = sample_registry()
    raw["mortgages"] = [{"rank_number": "2", "max_claim_amount": 100_000_000, "mortgagee": "가상은행",
                         "receipt_date": "2021-01-01", "is_canceled": False}]
    raw["jeonse_rights"] = [{"rank_number": "1", "deposit_amount": 50_000_000, "holder": "박가상",
                             "receipt_date": "2020-01-01", "is_canceled": False}]
    extract = RegistryExtract.from_raw(raw)
    v = rule_engine.evaluate(extract, deposit=100_000_000, market_price=400_000_000, blacklist_entries=[])
    senior = next(e for e in v.evidences if e.id == "senior_debt")
    view = evidence_view.build(senior, v, registry_facts.build(extract), LOSS)
    assert [i["label"] for i in view["visual"].items] == ["전세권", "가상은행", "내 보증금"]  # 전엔 전세권이 맨 뒤였다
    rows = [p.label for p in view["points"]]
    assert rows[:2] == ["1순위 전세권", "2순위 근저당"]
    assert view["points"][0].sub == "2020.1.1 · 박○○"  # 사람 이름은 가린다


def test_등기_항목_사실과_사진에서_보기도_같은_순서를_쓴다():
    facts = registry_facts.build(sample_extract())
    assert [(f.kind, f.order) for f in facts if f.kind == "근저당"] == [("근저당", 1), ("근저당", 2)]

    entry = sample_extract().mortgages[1]  # 을구 3번
    shown, _plan = mark_plans.ranked("mortgage", entry, 360_000_000, "3", section="을구", order=1)
    assert shown[0] == "1순위" and shown[-1] == "을구 3번"
    rows = mark_plans.fact_rows("mortgage", shown)
    assert ["받는 순서", "1순위"] in rows and ["등기부 번호", "을구 3번"] in rows
    # 갑구 항목엔 받는 순서가 없다(빚 줄이 아니다) — 칸 번호만
    seized, _ = mark_plans.ranked("provisional_seizure", {"receipt_date": "2024-01-02"}, 10_000_000, "5", section="갑구")
    assert not any(x.endswith("순위") for x in seized) and seized[-1] == "갑구 5번"


def test_이_집_신호와_AI_재료에_등기부_칸_번호를_순위로_싣지_않는다():
    v = sample_verdict()
    signals = house_signals.build(sample_extract(), v)
    joined = " ".join(signals)
    assert "4순위" not in joined and "3순위" not in joined
    assert "2순위 근저당 5,200만원은 은행이 아니라 개인" in joined
    # 근저당 금액은 빌린 돈이 아니라 채권최고액 — 이름을 붙이고, 집주인이 빌렸다고 단정하지 않는다
    assert "의 근저당(채권최고액 3억 6,000만원)이 잡혔어요" in joined and "빌렸어요" not in joined

    material = explanation._verdict_for_prompt(v, sample_ledger())
    senior = next(e for e in material["근거"] if e["id"] == "senior_debt")["수치사실"]
    first = senior["mortgages"][0]
    assert "rank_number" not in first and first["받는_순서"] == "1순위" and first["등기부_칸"] == "을구 3번"
    sheet = material["이_집_숫자표"]
    assert sheet["먼저_갚을_빚_합계"] == "4억 1,200만원 (2건)"
    assert sheet["먼저_갚을_빚_한_건씩"][0].startswith("1순위 근저당 3억 6,000만원")


# ══════════════════════════════════════════════════════════════════════════════
# ② 숫자 뜻
# ══════════════════════════════════════════════════════════════════════════════

BAD = [
    "이 집도 3억 6,000만원 선순위 근저당이 있어요.",  # 실기기에서 나온 그 문장
    "보증금은 4억원이에요.",  # 시세를 보증금 자리에
    "3순위 근저당 3억 6,000만원이 있어요.",  # 등기부 칸 번호를 순위로
    "내 보증금까지 더하면 103%가 돼요.",  # 빚 비율을 합친 비율 자리에
    "경매로 팔리면 4억원에 팔려요.",  # 시세를 낙찰가 자리에
    "이 집도 3억 6,000만원\n선순위 근저당이 있어요.",  # 말풍선처럼 문장 가운데서 줄을 바꿔도
    # 2026-11-01 머지 뒤 검토에서 나온 것
    "이 집 빚은 3억 6,000만원이에요.",  # 맨 '빚'도 합계 자리 — 한 건만 쓰면 빚이 그것뿐인 것처럼 읽힌다
    "선순위 근저당 3억 6,000만원이 있어요.",  # '선순위'가 앞에 있어도
    "보증금 1억원을 모두 돌려받을 수 있어요.",  # 계산은 5,000만원 — 부풀리기
    "경매로 가면 보증금 1억원을 모두 돌려받아요.",
    "근저당 3억 6,000만원은 시세의 25%예요.",  # 25%는 전세가율이다
    "3순위인 근저당이 있어요.",
    "근저당이 3순위예요.",
    "빚 4억원이 시세 4억원보다 많아요.",  # 고쳐 쓰라는 사유를 잘못 읽고 쓴 문장
    "앞선 빚 3억 6,000만원이 있어요.",
    "최우선변제로 5,500만원을 먼저 받아요.",
]
GOOD = [
    "이 집도 4억 1,200만원 선순위 빚이 있어요.",
    "이 집도 3억 6,000만원과 5,200만원 선순위 근저당이 있어요.",
    "1순위 근저당 3억 6,000만원은 가상은행이 먼저 받아가요.",
    "내 보증금 1억원 중 5,000만원은 돌려받아요.",
    "보증금 중 5,000만원은 최우선변제로 먼저 받아요.",
    "내 보증금은 3순위예요.",
    "집값의 103%가 이미 빚이에요. 내 보증금까지 더하면 128%가 돼요.",
    "보증금은 시세의 25%예요. 전세가율 기준 80%보다 낮아요.",
    "경매로 팔리면 3억 148만원쯤에 팔려요.",
    "빚이 시세의 60%를 넘으면 위험 신호로 봐요.",
    "빚이 4억 1,200만원이라 시세 4억원보다 많아요.",
    "5,000만원은 못 돌려받을 수 있어요.",
    "개인이 빌려준 5,200만원도 있어요.",
    "선순위 근저당 3억 6,000만원 외에 개인 근저당 5,200만원이 더 있어요.",  # 한 문장에 두 건 다
    "**경매로 가면 반만 돌아와요** 경매로 팔리면 3억 148만원쯤에 팔리는데, 빚 4억 1,200만원이 먼저라 내 보증금 1억원 중 최우선변제 5,000만원만 돌려받아요.",
    # 2026-11-01 머지 뒤 검토 — 맞는 문장인데 걸리던 것
    "빚 4억 1,200만원이 시세 4억원보다 많아요.",  # 뒤에 오는 '시세'는 견주는 대상이다
    "먼저 갚을 빚은 3억 6,000만원(1순위)과 5,200만원(2순위)이에요.",
    "보증금 1억원을 돌려받으려면 집이 5억 1,200만원 넘게 팔려야 해요.",  # 조건·문턱 금액
    "보증금이 1억 5,000만원 이하여야 최우선변제를 받아요.",
    "최우선변제는 낙찰가의 50%까지만 받아요.",
    "1순위 근저당 3억 6,000만원은 시세의 90%예요.",  # 빚 한 건 ÷ 시세
    "근저당 1건만 따져도 시세의 90%예요.",
    "보증보험에 가입하면 보증금 1억원을 모두 돌려받을 수 있어요.",  # 조건 마디 — 이 집 경매 계산이 아니다
    "경매로 가면 보증금 1억원을 모두 돌려받기는 어려워요.",
    "보증금에서 5,000만원을 빼면 나머지는 못 받을 수 있어요.",
    "보증금 1억원을 다 돌려받으려면 집이 5억 1,200만원 이상에 팔려야 해요.",  # '다 돌려받으려면'은 조건이다
    "보증금 1억원을 모두 돌려받을 수 있는지 계약 전에 확인하세요.",  # 물음 — 돌려받는다고 말한 게 아니다
    "선순위 빚은 1순위 3억 6,000만원, 2순위 5,200만원으로 모두 4억 1,200만원이에요.",
    "경매로 팔리면 1순위인 은행이 3억 6,000만원을 먼저 받아가요.",
    "보증금 1억원에 빚 4억 1,200만원을 더하면 시세의 128%예요.",
    "빚에 보증금까지 얹으면 128%예요.",
    "3억 148만원에 낙찰되면 빚 4억 1,200만원도 다 못 갚아요.",
    "이 집 시세 4억원보다 빚이 1,200만원 더 많아요.",  # 차이 금액
]


@pytest.mark.parametrize("text", BAD)
def test_숫자를_다른_자리에_쓰면_걸린다(text):
    assert fact_ledger.check(text, sample_ledger()) is not None


@pytest.mark.parametrize("text", GOOD)
def test_제자리에_쓴_숫자는_막지_않는다(text):
    assert fact_ledger.check(text, sample_ledger()) is None


def _clean_ledger() -> fact_ledger.Ledger:
    """빚 없는 아파트 — 보증금 2억 8,000만원 · 시세 4억원(전세가율 70%) · 경매로 가도 다 돌려받는 계산."""
    raw = {**sample_registry(), "mortgages": []}
    extract = RegistryExtract.from_raw(raw)
    v = rule_engine.evaluate(extract, deposit=280_000_000, market_price=400_000_000, blacklist_entries=[])
    loss = NS(status="ok", expectedSale=328_000_000, expectedReturn=280_000_000, expectedLoss=0, ratePct=82.0,
              priorityAmount=0, priorityLimit=None, priorityCap=None)
    return fact_ledger.for_verdict(v, registry_facts.build(extract), loss)


@pytest.mark.parametrize("text", [
    "보증금 2억 8,000만원은 시세 4억원의 70%예요.",
    "전세가율이 70%로 주의 기준 80%보다 낮아요.",
    "경매로 가도 3억 2,800만원쯤에 팔려 보증금 2억 8,000만원을 모두 돌려받는 계산이에요.",
    "시세가 3억 5,000만원 아래로 떨어지면 전세가율이 80%를 넘어요.",  # 문턱
    "보증금이 시세의 80%(3억 2,000만원)를 넘으면 보증보험 가입이 어려울 수 있어요.",
])
def test_빚_없는_집의_맞는_문장(text):
    assert fact_ledger.check(text, _clean_ledger()) is None


@pytest.mark.parametrize("text", ["보증금 3억원은 시세의 70%예요.", "전세가율이 75%예요.", "경매로 가면 3억원에 팔려요."])
def test_빚_없는_집의_틀린_문장(text):
    assert fact_ledger.check(text, _clean_ledger()) is not None


def test_판례_이야기_문장은_이_집_장부와_견주지_않는다():
    text = "판례 속 집은 보증금 5억원이었어요.\n이 집도 4억 1,200만원 선순위 빚이 있어요."
    assert fact_ledger.check(text, sample_ledger(), skip_precedent=True) is None
    # 판례 문장이어도 '이 집'을 말하면 견준다
    bad = "이 집도 판례처럼 3억 6,000만원 선순위 근저당이 있어요."
    assert fact_ledger.check(bad, sample_ledger(), skip_precedent=True) is not None
    # 한 문장에 판례 집과 이 집을 견주면 판례 쪽 마디의 숫자는 판례의 숫자다
    both = "판례 속 집은 보증금 2억원이었고, 이 집은 보증금 1억원이에요."
    assert fact_ledger.check(both, sample_ledger(), skip_precedent=True) is None
    assert fact_ledger.check("판례 속 집은 보증금 2억원이었고, 이 집은 보증금 3억원이에요.", sample_ledger(),
                             skip_precedent=True) is not None
    # '그 집'·'당시'도 판례 이야기다
    assert fact_ledger.check("판례 속 집처럼 빚이 많았어요. 그 집은 보증금 2억원이었어요.", sample_ledger(),
                             skip_precedent=True) is None


def test_경매로_한_푼도_못_받는_집에서_모두_돌려받는다고_하면_걸린다():
    v = sample_verdict()
    zero = NS(status="debt_exceeds", expectedSale=301_480_000, expectedReturn=0, expectedLoss=100_000_000,
              ratePct=75.4, priorityAmount=0, priorityLimit=None, priorityCap=None)
    led = fact_ledger.for_verdict(v, registry_facts.build(sample_extract()), zero)
    why = fact_ledger.check("보증금 1억원을 모두 돌려받을 수 있어요.", led)
    assert why is not None and "0원" in why
    assert fact_ledger.check("보증금 1억원을 모두 돌려받기는 어려워요.", led) is None


def test_걸린_이유는_AI가_고칠_수_있게_정답을_알려_준다():
    why = fact_ledger.check(BAD[0], sample_ledger())
    assert "합계 4억 1,200만원" in why and "1순위 근저당" in why


def test_우리_준비된_문구는_숫자_뜻_검사를_지난다():
    """검사가 너무 빡빡하면 맞는 문장까지 버린다 — 우리 문구로 오탐이 없는지 본다."""
    v = sample_verdict()
    led = sample_ledger()
    texts = fallback_texts.build(v)
    for eid, body in texts["evidences"].items():
        assert fact_ledger.check(body["easy_explanation"], led) is None, eid
        assert text_guard.legal_fact_hit(body["easy_explanation"]) is None, eid
    for ev in v.evidences:
        assert fact_ledger.check(ev.detail_text, led) is None, ev.id


# ══════════════════════════════════════════════════════════════════════════════
# ③ 법의 사실
# ══════════════════════════════════════════════════════════════════════════════


def test_빚을_진_쪽이_먼저_받는다는_말은_걸린다():
    assert text_guard.legal_fact_hit("집이 경매로 넘어가면 이 빚을 진 쪽이 먼저 돈을 받아가고") is not None
    assert text_guard.legal_fact_hit("집주인이 갚지 못하면 은행이 먼저 받아가요.") is None
    assert text_guard.legal_fact_hit("빚을 진 사람이 먼저 받는 게 아니라 빌려준 곳이 먼저 받아요.") is None
    assert text_guard.legal_fact_hit("빚을 진 사람이 먼저 받는 게 **아니라** 빌려준 곳이 먼저 받아요.") is None
    assert text_guard.banned_hit("이 집은 **안전**합니다") is not None  # 별표가 말을 갈라도
    # 집주인·임대인은 경매로 팔린 돈 이야기일 때만 — 계약금 이야기는 맞는 말
    assert text_guard.legal_fact_hit("경매가 되면 집주인이 먼저 돈을 받아가요.") is not None
    assert text_guard.legal_fact_hit("임대인이 먼저 받는 계약금을 확인하세요.") is None


def test_대항력은_다음_날_0시():
    assert text_guard.legal_fact_hit("전입신고를 한 그날 바로 대항력이 생겨요.") is not None
    assert text_guard.legal_fact_hit("전입신고를 하면 바로 다음 날 0시에 대항력이 생겨요.") is None
    assert text_guard.legal_fact_hit("전입신고를 해도 대항력이 바로 생기는 건 아니에요.") is None
    assert text_guard.legal_fact_hit("입주하자마자 대항력이 생겨요.") is not None
    # 같은 날 말이 '대항력이 생긴다'에 붙지 않으면 맞는 말
    assert text_guard.legal_fact_hit("잔금 당일 근저당이 잡히면 대항력보다 빨라요.") is None
    assert text_guard.legal_fact_hit("이사 당일 근저당이 잡히면 대항력이 생기기 전이라 위험해요.") is None


def test_채권최고액은_실제_빚이_아니다():
    assert text_guard.legal_fact_hit("채권최고액은 실제 빌린 돈이에요.") is not None
    assert text_guard.legal_fact_hit("채권최고액은 실제로 빌린 돈보다 많게 잡아요.") is None


def test_준비된_빚_문구는_빌려준_곳이_먼저_받는다고_말한다():
    texts = fallback_texts.build(sample_verdict())
    body = texts["evidences"]["senior_debt"]["easy_explanation"]
    assert "빌려준 곳이 먼저" in body and "빚을 진" not in body


def test_챗봇도_법의_사실과_반대면_고쳐_쓰게_한다():
    hit = text_guard.check_chat_reply("경매가 되면 빚을 진 쪽이 먼저 받아가요.", allowed={0.0})
    assert hit is not None and hit[0].startswith("사실과반대")


# ══════════════════════════════════════════════════════════════════════════════
# 고쳐 쓰기 — AI 문장을 고정 문구로 바꾸지 않고 한 번 더 기회를 준다
# ══════════════════════════════════════════════════════════════════════════════


@pytest.fixture
def solar_key(monkeypatch):
    monkeypatch.setenv("UPSTAGE_API_KEY", "test-key")


def _payload(v, senior_text: str) -> str:
    return json.dumps({
        "headline": "먼저 갚을 빚이 집값보다 커요",
        "evidences": [
            {"id": e.id, "easy_explanation": senior_text if e.id == "senior_debt" else f"**{e.id} 이야기** 이 집 이야기예요."}
            for e in v.evidences
        ],
    }, ensure_ascii=False)


def test_설명이_숫자_뜻에_걸리면_한_번_고쳐_쓰게_하고_통과하면_AI_글을_쓴다(monkeypatch, solar_key):
    v = sample_verdict()
    calls: list[str] = []
    answers = iter([
        _payload(v, "**빚이 집값보다 커요** 이 집에는 3억 6,000만원 선순위 근저당이 있어요."),
        json.dumps({"evidences": [{"id": "senior_debt",
                                   "easy_explanation": "**빚이 집값보다 커요** 먼저 갚을 빚이 4억 1,200만원이에요."}]},
                   ensure_ascii=False),
    ])

    def mock(messages, key):
        calls.append(messages[-1]["content"])
        return next(answers)

    monkeypatch.setattr(explanation, "_call_solar", mock)
    result = explanation.generate(v, ledger=sample_ledger())
    assert len(calls) == 2
    assert "합계 4억 1,200만원" in calls[1]  # 왜 걸렸는지 AI에게 알려 준다
    assert "4억 1,200만원" in result.texts["evidences"]["senior_debt"]["easy_explanation"]
    assert result.evidence_sources["senior_debt"] != explanation.FALLBACK_SOURCE_LABEL


def test_고쳐_쓴_글도_틀리면_준비된_문구(monkeypatch, solar_key):
    v = sample_verdict()
    bad = _payload(v, "**빚이 집값보다 커요** 이 집에는 3억 6,000만원 선순위 근저당이 있어요.")
    monkeypatch.setattr(explanation, "_call_solar", lambda m, k: bad)
    result = explanation.generate(v, ledger=sample_ledger())
    assert result.evidence_sources["senior_debt"] == explanation.FALLBACK_SOURCE_LABEL
    assert "3억 6,000만원 선순위" not in result.texts["evidences"]["senior_debt"]["easy_explanation"]


def _match() -> RetrievedPrecedent:
    doc = PrecedentDoc(
        case_id="c1", case_no="99다59306", court="대법원", decided="2000-01-01",
        holding="선순위 저당권이 있는 집이 경매로 넘어가면 후순위 임차인은 낙찰자에게 임차권을 주장할 수 없다.",
        risk_tags=["선순위 채권"], source_url="https://www.law.go.kr/", verified=True, source_verified=True,
    )
    chunk = PrecedentChunk(chunk_id="c1#0", case_id="c1", section="판결요지", text=doc.holding, risk_tags=doc.risk_tags)
    return RetrievedPrecedent(doc=doc, chunk=chunk, vector_score=0.9, keyword_score=0.9, hybrid_score=0.9,
                              matched_tags=["선순위 채권"])


def test_판례_공통점도_한_번_고쳐_쓰게_한다(monkeypatch, solar_key):
    led = sample_ledger()
    summary = {"먼저_갚을_빚_표기": "4억 1,200만원", "이_집_숫자표": fact_ledger.sheet(led, [])}
    first = {"cases": [{"case_id": "c1", "easy_summary": "판례 속 집은 선순위 저당권이 있었고 경매로 넘어갔어요. 법원은 후순위 임차인이 권리를 주장할 수 없다고 봤어요.",
                        "common_point": "이 집도 3억 6,000만원 선순위 근저당이 있어요.", "advice": "계약 전에 빚을 확인하세요."}]}
    fixed = {"cases": [{"case_id": "c1", "easy_summary": first["cases"][0]["easy_summary"],
                        "common_point": "이 집도 4억 1,200만원 선순위 빚이 있어요.", "advice": "계약 전에 빚을 확인하세요."}]}
    answers = iter([json.dumps(first, ensure_ascii=False), json.dumps(fixed, ensure_ascii=False)])
    monkeypatch.setattr(explainer, "_call_solar", lambda m, k: next(answers))
    out, source = explainer.explain_matches([_match()], summary, led)
    assert out["c1"].common_point == "이 집도 4억 1,200만원 선순위 빚이 있어요."
    assert source != "폴백"


def test_리포트_전체에서_N순위는_살아_있는_빚_수를_넘지_않는다():
    """여러 등기부 모양으로 리포트를 만들어 '순위' 글자를 전부 훑는다 — 등기부 칸 번호가 새지 않게."""
    import re

    shapes = []
    a = sample_registry()
    shapes.append(a)
    b = sample_registry()
    b["mortgages"].append({"rank_number": "7", "max_claim_amount": 30_000_000, "mortgagee": "가상캐피탈",
                           "receipt_date": "2024-02-02", "is_canceled": False})
    shapes.append(b)
    c = sample_registry()
    c["jeonse_rights"] = [{"rank_number": "5", "deposit_amount": 80_000_000, "holder": "가상", "receipt_date": "2023-01-01",
                           "is_canceled": False}]
    shapes.append(c)
    for raw in shapes:
        extract = RegistryExtract.from_raw(raw)
        report = report_builder.build_report(extract, deposit=100_000_000, market_price=400_000_000, alias=None,
                                             use_llm=False)
        live = sum(1 for m in raw["mortgages"] if not m["is_canceled"]) + len(raw["jeonse_rights"])
        for ev in report.evidences:
            for p in ev.points:
                for m in re.finditer(r"(\d+)순위", f"{p.label} {p.value} {p.sub or ''}"):
                    assert 1 <= int(m.group(1)) <= live, (p.label, live)
        assert report.grade == Grade.DANGER.value


def test_고쳐_쓰기는_짧게_기다린다(monkeypatch, solar_key):
    """고쳐 쓰기 호출은 기다림 상한을 짧게(앱 분석 대기 180초를 넘기지 않게) — 첫 호출은 그대로."""
    seen: list[float | None] = []

    class _Provider:
        name, model = "solar", "solar-pro2"

        def chat(self, system, user, *, max_tokens, temperature, timeout=None):
            seen.append(timeout)
            raise explanation.LlmError("끊김")

    monkeypatch.setattr(explanation.llm, "explain_provider", lambda: _Provider())
    explanation._repair({}, explanation.ExplanationPayload.model_construct(headline="", evidences=[]),
                        {"headline": "x"}, "key", "solar")
    assert seen == [explanation.REPAIR_TIMEOUT_SECONDS]
    assert explanation._CALL_TIMEOUT.get() is None  # 끝나면 되돌린다

    sent: list[float] = []

    def post_chat(payload, *, api_key, timeout, post=None):
        sent.append(timeout)
        raise explainer.requests.exceptions.ReadTimeout("끊김")

    monkeypatch.setattr(explainer.solar_models, "post_chat", post_chat)
    explainer._repair_cases({"판례_후보": []}, [], "key")
    with pytest.raises(explainer.requests.exceptions.ReadTimeout):
        explainer._call_solar([], "key")
    assert sent == [explainer._REPAIR_TIMEOUT, explainer._REQUEST_TIMEOUT]


def test_챗봇_답_길이는_900자까지_넘으면_몇_자인지_알려_준다():
    """solar-pro4는 답이 더 자세하다 — 700자 목록 답은 통과, 넘으면 고쳐 쓸 목표를 숫자로(2026-11-02)."""
    ok = "· 이 앱은 등기부의 빚과 압류를 찾아요.\n" * 30  # 약 690자
    assert len(ok) < text_guard.CHAT_MAX_LEN
    assert text_guard.check_chat_reply(ok, allowed={0.0}) is None
    hit = text_guard.check_chat_reply("가" * 950, allowed={0.0})
    assert hit is not None and hit[0] == "길이" and "950자" in hit[1] and "700자" in hit[1]
