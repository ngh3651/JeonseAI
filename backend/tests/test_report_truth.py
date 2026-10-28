"""리포트가 **이 집의 실제 상황**을 말하는가 (2026-10-29 QA).

① 등급과 반대 방향 말투 — 위험인데 안심시키는 AI 문장은 그 칸만 버린다(맨 윗줄을 고정하지는 않는다).
② 사진 때문에 '확인 필요'로 올린 카드 — 그 **이유**를 말하고, 수치를 '높음'이라 하지 않는다.
③ 판례·질문·'눈에 띈 위험'은 카드 문장 속 글자가 아니라 **규칙 엔진이 센 건수**로 고른다.
④ 소유권·보증보험 문구는 실제로 걸린 신호 종류를 말한다(경매만 있는 집을 '압류'라 하지 않는다).
"""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from app.schemas.internal import Grade, RegistryExtract
from app.services import explanation, fallback_texts, patterns, questions, report_builder, rule_engine, text_guard

FIXTURES = Path(__file__).parent / "fixtures" / "registry"


def load(name: str) -> dict:
    return json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))


def build(name: str, *, pages_incomplete_reason: str | None = None, mutate=None, **kw):
    data = copy.deepcopy(load(name))
    if mutate:
        mutate(data["registry"])
    extract = RegistryExtract.from_raw(data["registry"])
    if pages_incomplete_reason:
        extract.pages_incomplete = True
        extract.pages_incomplete_reason = pages_incomplete_reason
    inputs = {**data["inputs"], **kw}
    report = report_builder.build_report(
        extract, deposit=inputs["deposit"], market_price=inputs["market_price"], alias="테스트"
    )
    verdict = rule_engine.evaluate(
        extract, deposit=inputs["deposit"], market_price=inputs["market_price"]
    )
    return report, verdict


def ev(report, eid):
    return next(e for e in report.evidences if e.id == eid)


# ══════════════════════════════════════════════════════════════════════════════
# ① 등급과 반대 방향
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.parametrize(
    "text",
    [
        "이 집은 대체로 괜찮은 편이에요",
        "계약해도 무난해 보여요",
        "빚이 조금 있지만 걱정할 수준은 아니에요",
        "근저당 2건은 흔한 일이라 크게 신경 쓰지 않아도 돼요.",
        "빚이 시세의 90%로 낮은 편이에요.",
        "큰 위험 신호는 보이지 않았어요",
        "이 정도면 계약해도 될 것 같아요",
    ],
)
def test_danger_text_that_reassures_is_dropped(text):
    assert text_guard.check(text, max_len=600, allowed={90.0, 2.0}, grade="위험") is not None


@pytest.mark.parametrize(
    "text, grade",
    [
        ("큰 위험 신호는 보이지 않았어요 — 그래도 직접 확인은 필요해요", "양호"),
        ("집주인에게 이 빚이 괜찮은지 꼭 물어보세요.", "위험"),
        ("지금 보이는 쪽에서는 압류 같은 표시가 보이지 않았어요. 빠진 쪽을 더 올려 주세요.", "확인 필요"),
        ("보증금을 지키기 어려운 신호가 보여요", "위험"),
        ("집값이 내려가면 보증금을 다 돌려받기 어려울 수 있어요.", "양호"),
    ],
)
def test_same_direction_text_passes(text, grade):
    assert text_guard.check(text, max_len=600, allowed=set(), grade=grade) is None


@pytest.mark.parametrize("text", ["압류가 걸려 있어 경매 위험이 커요.", "이 집은 피하세요."])
def test_good_card_that_alarms_is_dropped(text):
    assert text_guard.check(text, max_len=600, allowed=set(), grade="양호") is not None


def test_reassuring_ai_headline_on_danger_report_falls_back_only_that_field(monkeypatch):
    data = load("mortgage_heavy")
    extract = RegistryExtract.from_raw(data["registry"])
    verdict = rule_engine.evaluate(
        extract, deposit=data["inputs"]["deposit"], market_price=data["inputs"]["market_price"]
    )
    assert verdict.grade is Grade.DANGER
    monkeypatch.setenv("UPSTAGE_API_KEY", "test-key")
    content = json.dumps(
        {
            "headline": "이 집은 대체로 괜찮은 편이에요",
            "evidences": [
                {"id": e.id, "easy_explanation": f"{e.id} 항목을 쉬운 말로 설명해요."}
                for e in verdict.evidences
            ],
        },
        ensure_ascii=False,
    )
    monkeypatch.setattr(explanation, "_call_solar", lambda m, k: content)
    result = explanation.generate(verdict)
    # 맨 윗줄만 준비된 문장으로, 나머지 AI 문장은 그대로 쓴다
    assert result.texts["headline"] == fallback_texts.HEADLINES[Grade.DANGER]
    assert result.source == "AI 생성(일부 폴백)"
    assert result.texts["evidences"]["ownership"]["easy_explanation"] == "ownership 항목을 쉬운 말로 설명해요."


# ══════════════════════════════════════════════════════════════════════════════
# ② 사진 때문에 올린 카드 — 이유를 말한다
# ══════════════════════════════════════════════════════════════════════════════


def test_capped_cards_say_the_photo_reason_not_high_numbers():
    report, verdict = build("clean_house", pages_incomplete_reason="1·5쪽이 빠졌어요")
    jr = ev(report, "jeonse_ratio")
    assert jr.grade == "확인 필요"
    assert "1·5쪽이 빠졌어요" in jr.easyExplanation
    assert "높" not in jr.easyExplanation  # 이 집 비율은 기준 아래 — '높다'고 하지 않는다
    assert "1·5쪽이 빠졌어요" in (jr.detailText or "")
    sd = ev(report, "senior_debt")
    assert "먼저 갚아야 할 빚이 있어요" not in sd.easyExplanation
    assert "1·5쪽이 빠졌어요" in sd.easyExplanation
    # 홈 요약 줄: '(높음)' 없이 사진 다시 확인
    assert report.topRiskSummary.startswith("사진 다시 확인 필요")
    assert "높음" not in report.topRiskSummary
    # 사진 때문인 카드는 판례 태그가 아니다
    assert report.riskTags == []
    assert all(e.facts.get("capped_reason") for e in verdict.evidences if e.id in ("jeonse_ratio", "ownership"))


def test_incomplete_reason_from_builder_matches_retake_card_words():
    reason = report_builder._incomplete_reason([1, 5], [1], [2, 3, 4], unnumbered=False)
    assert reason == "1·5쪽이 빠졌어요 · 3쪽이 잘 안 읽혔어요"
    assert report_builder._incomplete_reason([], [0], [], unnumbered=False) == "1쪽이 잘 안 읽혔어요"


def test_real_caution_still_says_its_own_reason():
    # 시세 없음 — 사진이 아니라 정말 비율을 못 따지는 경우는 그대로
    report, _ = build("clean_house", market_price=None)
    assert "시세를 알 수 없어" in ev(report, "jeonse_ratio").easyExplanation


# ══════════════════════════════════════════════════════════════════════════════
# ③ 실제 문제 태그 — 판례·질문·'눈에 띈 위험'
# ══════════════════════════════════════════════════════════════════════════════


def test_risk_tags_follow_counts():
    report, _ = build("trust_seizure")
    assert set(report.riskTags) >= {"신탁등기", "압류·가압류", "보증보험"}
    assert "경매" not in report.riskTags
    clean, _ = build("clean_house")
    assert clean.riskTags == []  # 보증보험 구조적 '확인 필요'는 문제 태그가 아니다


def test_legacy_report_without_tags_does_not_read_none_sentence():
    report, _ = build("clean_house", pages_incomplete_reason="1쪽이 빠졌어요")
    legacy = report.model_copy(update={"riskTags": None})
    # 소유권 카드 상세엔 "신탁등기·압류·…경매개시결정은 없었어요"가 있다 — 글자가 아니라 건수를 본다
    assert "없었어요" in (ev(legacy, "ownership").detailText or "")
    assert patterns.tags_from_report(legacy) == []
    danger, _ = build("trust_seizure")
    assert set(patterns.tags_from_report(danger.model_copy(update={"riskTags": None}))) == set(danger.riskTags)


def _seizure_only(reg):
    reg["trust_registrations"] = []


def _auction_only(reg):
    reg["trust_registrations"] = []
    reg["seizures"] = []
    reg["auction_commencements"] = [
        {"rank_number": "7", "purpose": "임의경매개시결정", "receipt_date": "2026-01-02", "is_canceled": False}
    ]


def test_questions_follow_the_real_problem():
    report, _ = build("trust_seizure", mutate=_seizure_only)
    labels = [g.riskLabel for g in questions.build_question_groups(report)]
    assert "압류·가압류" in labels
    assert "신탁등기" not in labels  # 압류만 있는 집에 '신탁원부 보여 주세요'를 묻지 않는다
    auction, _ = build("trust_seizure", mutate=_auction_only)
    labels = [g.riskLabel for g in questions.build_question_groups(auction)]
    assert "경매" in labels and "신탁등기" not in labels
    clean, _ = build("clean_house")
    labels = [g.riskLabel for g in questions.build_question_groups(clean)]
    assert "보증보험" not in labels  # 구조적 '확인 필요'만으로 '가입 거절된 적 있나요'를 묻지 않는다
    assert "어떤 집이든 꼭" in labels


def test_price_unknown_still_asks_for_price_material():
    report, _ = build("clean_house", market_price=None)
    labels = [g.riskLabel for g in questions.build_question_groups(report)]
    assert "전세가율" in labels


# ══════════════════════════════════════════════════════════════════════════════
# ④ 신호 종류에 맞는 문구
# ══════════════════════════════════════════════════════════════════════════════


def test_auction_only_text_says_auction_not_seizure():
    report, _ = build("trust_seizure", mutate=_auction_only)
    text = ev(report, "ownership").easyExplanation
    assert "경매개시결정" in text
    assert "압류" not in text
    ins = ev(report, "insurance").easyExplanation
    assert ins.startswith("경매개시결정 때문에")
