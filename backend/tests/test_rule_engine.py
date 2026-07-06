"""규칙 엔진 봉인 테스트 (E-1b).

핵심 봉인 대상(승인된 계획의 보수적 편향 강제):
1. 누락·미상 입력 → 절대 '양호' 없음
2. 금액 파싱 실패 시 0 치환 금지 (None 유지)
3. worst-of 종합 + insurance '확인 필요'는 종합 계산 제외 (표시는 유지)
4. gaugeProgress는 종합 등급 구간 안
"""

import json
from pathlib import Path

import pytest

from app.schemas.internal import Grade, RegistryExtract, parse_amount
from app.services import thresholds as T
from app.services import fallback_texts, rule_engine

FIXTURES = Path(__file__).parent / "fixtures" / "registry"
FIXTURE_NAMES = [
    "clean_house",
    "mortgage_heavy",
    "trust_seizure",
    "canceled_only",
    "messy_amounts",
    "missing_sections",
    "real_snapshot",
]


def load_fixture(name: str) -> dict:
    return json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))


def run_fixture(name: str):
    data = load_fixture(name)
    extract = RegistryExtract.from_raw(data["registry"])
    return rule_engine.evaluate(
        extract,
        deposit=data["inputs"]["deposit"],
        market_price=data["inputs"].get("market_price"),
        blacklist_entries=data.get("blacklist"),
    )


def evidence(verdict, evidence_id: str):
    return next(e for e in verdict.evidences if e.id == evidence_id)


# ── 금액 파싱: 실패는 None, 0 치환 금지 ──────────────────────────────────────


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        (120_000_000, 120_000_000),
        ("120,000,000", 120_000_000),
        ("금120,000,000원", 120_000_000),
        ("1억 2,000만원", 120_000_000),
        ("3억", 300_000_000),
        ("일억이천만원", None),  # 한글 수사 — 해석 불가
        ("불명", None),
        ("", None),
        (None, None),
        (-1, None),
        (True, None),
    ],
)
def test_parse_amount(raw, expected):
    assert parse_amount(raw) == expected


def test_parse_amount_failure_is_none_not_zero():
    """실패를 0으로 치환하면 '빚 없음'이 되어 위험 축소 — 반드시 None이어야 한다."""
    result = parse_amount("읽을수없는금액")
    assert result is None
    assert result != 0


# ── 픽스처별 판정 ────────────────────────────────────────────────────────────


def test_clean_house_overall_good():
    v = run_fixture("clean_house")
    assert v.grade is Grade.GOOD
    assert evidence(v, "jeonse_ratio").grade is Grade.GOOD
    assert evidence(v, "senior_debt").grade is Grade.GOOD
    assert evidence(v, "ownership").grade is Grade.GOOD
    assert evidence(v, "blacklist").grade is Grade.GOOD
    assert v.senior_debt_amount == 0


def test_insurance_caution_excluded_from_overall_but_still_shown():
    """insurance '확인 필요'는 종합 강등 계산에서 제외하되, 카드로는 항상 존재해야 한다."""
    v = run_fixture("clean_house")
    ins = evidence(v, "insurance")
    assert ins.grade is Grade.CAUTION  # 등기부만으론 양호 불가(구조적)
    assert v.grade is Grade.GOOD  # 그래도 종합은 양호
    assert len(v.evidences) == 5  # 표시에서 숨기지 않는다


def test_insurance_never_good_in_any_fixture():
    for name in FIXTURE_NAMES:
        v = run_fixture(name)
        assert evidence(v, "insurance").grade is not Grade.GOOD, name


def test_mortgage_heavy_danger():
    v = run_fixture("mortgage_heavy")
    senior = evidence(v, "senior_debt")
    assert senior.grade is Grade.DANGER
    assert v.grade is Grade.DANGER
    assert v.senior_debt_amount == 180_000_000
    # 60%·90% 두 기준 모두 초과했는지 facts로 추적 가능해야 한다(설명 가능성)
    assert senior.facts["senior_ratio_pct"] > T.SENIOR_DEBT_RATIO_DANGER_PCT
    assert senior.facts["combined_ratio_pct"] > T.COMBINED_RATIO_DANGER_PCT


def test_trust_seizure_ownership_and_insurance_danger():
    v = run_fixture("trust_seizure")
    assert evidence(v, "ownership").grade is Grade.DANGER
    assert evidence(v, "insurance").grade is Grade.DANGER  # 결격 신호 → 종합에도 반영
    assert evidence(v, "jeonse_ratio").grade is Grade.GOOD  # 전세가율 40%
    assert v.grade is Grade.DANGER  # worst-of


def test_canceled_only_zero_debt_and_good():
    v = run_fixture("canceled_only")
    assert v.senior_debt_amount == 0  # 말소 채권은 합산 제외
    assert evidence(v, "senior_debt").grade is Grade.GOOD
    assert v.grade is Grade.GOOD


def test_messy_amounts_caution_no_zero_substitution():
    v = run_fixture("messy_amounts")
    senior = evidence(v, "senior_debt")
    assert senior.grade is Grade.CAUTION  # 금액 미상 → 양호 금지
    assert senior.facts["unknown_amount_count"] == 2
    assert v.senior_debt_amount == 120_000_000  # 파싱된 금액만 합산(미상은 0으로 넣지 않음)
    assert v.grade is Grade.CAUTION


def test_missing_sections_never_good():
    """페이지 누락 시 을구 없음을 '근저당 없음'으로 판정하지 않는다 — 전 항목 양호 금지."""
    v = run_fixture("missing_sections")
    for ev in v.evidences:
        assert ev.grade is not Grade.GOOD, ev.id
    assert v.grade is not Grade.GOOD
    assert v.doc_flags  # 무엇이 누락됐는지 추적 가능해야 한다


def test_unknown_cancellation_counts_as_active():
    """is_canceled 누락(None)은 말소로 단정하지 않고 유효로 취급한다."""
    extract = RegistryExtract.from_raw(
        {
            "address": "서울 ○○구",
            "current_owners": [{"name": "테스트"}],
            "ownership_changes": [],
            "provisional_seizures": [],
            "provisional_dispositions": [],
            "seizures": [],
            "auction_commencements": [],
            "trust_registrations": [{"trustee": "○○신탁"}],  # is_canceled 없음
            "mortgages": [],
            "jeonse_rights": [],
            "lease_registrations": [],
        }
    )
    v = rule_engine.evaluate(extract, deposit=100, market_price=1000, blacklist_entries=[{"name": "x"}])
    assert evidence(v, "ownership").grade is Grade.DANGER


def test_lease_registration_is_danger_signal():
    extract = RegistryExtract.from_raw(
        {
            "address": "서울 ○○구",
            "current_owners": [{"name": "테스트"}],
            "ownership_changes": [],
            "provisional_seizures": [],
            "provisional_dispositions": [],
            "seizures": [],
            "auction_commencements": [],
            "trust_registrations": [],
            "mortgages": [],
            "jeonse_rights": [],
            "lease_registrations": [{"is_canceled": False}],
        }
    )
    v = rule_engine.evaluate(extract, deposit=100, market_price=1000, blacklist_entries=[{"name": "x"}])
    assert evidence(v, "senior_debt").grade is Grade.DANGER


def test_no_market_price_caps_jeonse_ratio():
    v_data = load_fixture("clean_house")
    extract = RegistryExtract.from_raw(v_data["registry"])
    v = rule_engine.evaluate(extract, deposit=200_000_000, market_price=None, blacklist_entries=v_data["blacklist"])
    jeonse = evidence(v, "jeonse_ratio")
    assert jeonse.grade is Grade.CAUTION  # 시세 없음 → 양호 단정 금지
    assert jeonse.action_label == "시세 입력하기"


def test_blacklist_states():
    data = load_fixture("clean_house")
    extract = RegistryExtract.from_raw(data["registry"])
    # ① 명단 미구축 → '명단 대조 아직 안 됨'(확인 필요) — 카드는 표시하되 종합 계산 임시 제외
    v = rule_engine.evaluate(extract, deposit=1, market_price=None, blacklist_entries=[])
    pending = evidence(v, "blacklist")
    assert pending.grade is Grade.CAUTION
    assert pending.status_label == rule_engine.BLACKLIST_PENDING_LABEL
    # ② 이름 일치 → 동명이인 가능성: 위험 단정 대신 확인 필요 + 직접 확인 유도 (종합 계산 포함)
    v = rule_engine.evaluate(
        extract, deposit=1, market_price=None, blacklist_entries=[{"name": "홍소유"}]
    )
    matched = evidence(v, "blacklist")
    assert matched.grade is Grade.CAUTION
    assert matched.facts["matched"] == ["홍소유"]
    assert v.grade is Grade.CAUTION  # 일치 상태는 종합에 반영된다


def test_blacklist_pending_excluded_from_overall_but_shown():
    """명단 미구축의 '확인 필요'는 종합 강등 계산에서 임시 제외 — 임시 조치, 명단 도착 시 원복.
    (decisions.md 2026-07-06)"""
    data = load_fixture("clean_house")
    extract = RegistryExtract.from_raw(data["registry"])
    v = rule_engine.evaluate(
        extract,
        deposit=data["inputs"]["deposit"],
        market_price=data["inputs"]["market_price"],
        blacklist_entries=[],  # 명단 미구축 상태
    )
    assert evidence(v, "blacklist").grade is Grade.CAUTION  # 카드는 그대로 표시
    assert v.grade is Grade.GOOD  # 그래도 종합은 양호 (임시 제외)


def test_ratio_boundary_compared_on_raw_value_not_rounded():
    """경계 구간(예: 90.2%)이 반올림(90%)으로 '초과'에서 빠지면 미탐 — 원값 비교 봉인.
    (rule-auditor 2026-07-06 지적 반영)"""
    data = load_fixture("clean_house")
    extract = RegistryExtract.from_raw(data["registry"])
    # 전세가율 180,400,000 / 200,000,000 = 90.2% → 반올림하면 90이지만 판정은 '위험'이어야 한다
    v = rule_engine.evaluate(
        extract, deposit=180_400_000, market_price=200_000_000, blacklist_entries=[{"name": "x"}]
    )
    assert evidence(v, "jeonse_ratio").grade is Grade.DANGER

    # 선순위채권 120,400,000 / 200,000,000 = 60.2% → 반올림 60이지만 '위험'
    raw = dict(data["registry"])
    raw["mortgages"] = [{"max_claim_amount": 120_400_000, "is_canceled": False}]
    extract2 = RegistryExtract.from_raw(raw)
    v2 = rule_engine.evaluate(
        extract2, deposit=10_000_000, market_price=200_000_000, blacklist_entries=[{"name": "x"}]
    )
    assert evidence(v2, "senior_debt").grade is Grade.DANGER


# ── 종합 파생·게이지 ─────────────────────────────────────────────────────────


def test_gauge_within_band_for_all_fixtures():
    for name in FIXTURE_NAMES:
        v = run_fixture(name)
        lo, hi = T.GAUGE_BANDS[v.grade]
        assert lo <= v.gauge_progress <= hi, name


def test_real_snapshot_runs_and_is_conservative():
    """실추출 스냅샷 — 근저당 2건 전부 말소된 실물. 합계 0, 위험으로 과장하지 않아야 한다."""
    data = load_fixture("real_snapshot")
    extract = RegistryExtract.from_raw(data["registry"])
    # 명단 미구축 상태를 고정 주입해 데이터 파일 변화와 무관하게 결정적으로 검증
    v = rule_engine.evaluate(
        extract,
        deposit=data["inputs"]["deposit"],
        market_price=data["inputs"]["market_price"],
        blacklist_entries=[],
    )
    assert v.senior_debt_amount == 0
    assert evidence(v, "senior_debt").grade is Grade.GOOD
    assert evidence(v, "ownership").grade is Grade.GOOD
    assert v.grade is Grade.GOOD  # 명단 미구축 임시 제외 후: 깨끗한 실물 → 양호
    assert v.address  # 표제부 주소가 실제로 추출됨


def test_fallback_texts_cover_all_evidences():
    """폴백 문구는 어떤 판정에서도 빈 문자열 없이 완성돼야 한다(리포트 항상 완성 원칙)."""
    for name in FIXTURE_NAMES:
        v = run_fixture(name)
        texts = fallback_texts.build(v)
        assert texts["headline"] and texts["next_action"] and texts["top_risk_summary"]
        assert set(texts["evidences"].keys()) == {e.id for e in v.evidences}
        for body in texts["evidences"].values():
            assert body["title"] and body["easy_explanation"]
