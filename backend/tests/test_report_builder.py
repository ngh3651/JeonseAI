"""report_builder 계약 준수 테스트 (E-1c).

Report(계약 §2.1)의 [판정] 필드가 RuleVerdict에서만 왔는지, 형태가 계약과 맞는지 봉인.
(실 API 호출 없음 — 픽스처의 registry로 build_report만 검증)
"""

import json
from pathlib import Path

from app.schemas.internal import RegistryExtract
from app.services import report_builder, rule_engine
from app.services.formatting import short_address

FIXTURES = Path(__file__).parent / "fixtures" / "registry"
ALL_EVIDENCE_IDS = {"jeonse_ratio", "senior_debt", "ownership", "insurance", "blacklist"}


def load(name: str) -> dict:
    return json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))


def test_build_report_contract_shape_and_verdict_parity():
    data = load("clean_house")
    extract = RegistryExtract.from_raw(data["registry"])
    deposit = data["inputs"]["deposit"]
    market = data["inputs"]["market_price"]

    report = report_builder.build_report(
        extract, deposit=deposit, market_price=market, alias="테스트 매물"
    )
    verdict = rule_engine.evaluate(extract, deposit=deposit, market_price=market)

    # 계약 형태
    assert report.grade in ("위험", "확인 필요", "양호")
    assert 0.0 <= report.gaugeProgress <= 1.0
    assert {e.id for e in report.evidences} == ALL_EVIDENCE_IDS  # 5종 전부, 숨김 없음
    assert report.alias == "테스트 매물"
    assert report.analyzedAt  # ISO 문자열

    # [판정] 필드 패리티 — Report의 판정 값은 RuleVerdict와 정확히 일치해야 한다
    assert report.grade == verdict.grade.value
    assert report.gaugeProgress == verdict.gauge_progress
    assert report.deposit == verdict.deposit
    assert report.marketPrice == verdict.market_price
    assert report.seniorDebtAmount == verdict.senior_debt_amount
    verdict_by_id = {e.id: e for e in verdict.evidences}
    for ev in report.evidences:
        assert ev.grade == verdict_by_id[ev.id].grade.value
        assert ev.detailText == verdict_by_id[ev.id].detail_text
        assert ev.sourceText == verdict_by_id[ev.id].source_text


def test_build_report_alias_falls_back_to_short_address():
    data = load("clean_house")
    extract = RegistryExtract.from_raw(data["registry"])
    report = report_builder.build_report(
        extract, deposit=data["inputs"]["deposit"], market_price=None, alias=None
    )
    # 별칭 미입력 → 표제부 주소의 축약형 (계약 §3.1 해석 범위 — 표시용 축약)
    assert report.alias == short_address(report.address)
    assert report.address  # 전체 주소는 address 필드에 그대로 유지


def test_alias_fallback_uses_dong_start():
    """실주소 형태에서 별칭이 '○○동'부터 시작하는지 — 홈 카드 제목 길이 문제 방지."""
    data = load("clean_house")
    raw = dict(data["registry"])
    raw["address"] = "서울특별시 양천구 신정동 1234 행복아파트 제101동 제5층 제501호, 서울특별시 양천구 행복로 100"
    extract = RegistryExtract.from_raw(raw)
    report = report_builder.build_report(
        extract, deposit=100, market_price=None, alias=None
    )
    assert report.alias == "신정동 1234 행복아파트 제101동 제5층 제501호"
    assert report.address.startswith("서울특별시")  # 전체 주소는 유지


def test_build_report_orders_danger_first():
    data = load("mortgage_heavy")
    extract = RegistryExtract.from_raw(data["registry"])
    report = report_builder.build_report(
        extract,
        deposit=data["inputs"]["deposit"],
        market_price=data["inputs"]["market_price"],
        alias=None,
    )
    assert report.evidences[0].id == "senior_debt"  # 위험 카드가 맨 위 (결론 먼저)
    assert report.evidences[0].grade == "위험"
