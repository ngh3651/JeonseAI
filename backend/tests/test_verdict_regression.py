"""판정 회귀 봉인 — **표시 기능을 아무리 늘려도 등급은 단 한 건도 달라지지 않는다.**

왜 이 파일이 따로 있나 (2026-07-28):
이 프로젝트의 불변 원칙은 "위험 판단 = 규칙 엔진, LLM은 설명만"이다(CLAUDE.md 3절).
그런데 OCR 하이라이트·읽기 가이드·LLM 구조화 경로처럼 **판정 옆에서 자라는 기능**이
늘수록, 어느 날 누군가 "OCR이 압류를 하나 더 찾았으니 등급도 올리자"는 한 줄을
넣기 쉬워진다. 그 한 줄은 리뷰에서 좋아 보이기까지 한다.

이 파일은 그 한 줄이 들어온 순간 **빨간불이 켜지게** 하는 장치다.
아래 표는 2026-07-28 `feat/reading-guide` 착수 시점(기점 커밋 5ffcd35)의 실측값이다.

⚠ **이 표를 고쳐서 테스트를 통과시키지 말 것.**
   등급이 달라졌다면 그것은 판정 로직이 바뀐 것이고, 그때 필요한 것은
   ⑴ 권위 출처 확보 → ⑵ `docs/decisions.md` 기록 → ⑶ 코드 반영 → ⑷ 이 표 갱신
   순서다(risk-scoring 규칙 1절). 순서를 건너뛰고 표만 고치면 규칙이 무너진다.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.schemas.internal import RegistryExtract
from app.services import highlight, ocr, report_builder, rule_engine

FIXTURES = Path(__file__).parent / "fixtures" / "registry"

# 픽스처 → (종합등급, 게이지, 선순위채권합계, {근거 id: 등급})
GOLDEN: dict[str, tuple[str, float, int, dict[str, str]]] = {
    "canceled_only": ("양호", 0.8, 0, {
        "jeonse_ratio": "양호", "senior_debt": "양호", "ownership": "양호",
        "insurance": "확인 필요", "blacklist": "확인 필요"}),
    "clean_house": ("양호", 0.8, 0, {
        "jeonse_ratio": "양호", "senior_debt": "양호", "ownership": "양호",
        "insurance": "확인 필요", "blacklist": "확인 필요"}),
    "messy_amounts": ("확인 필요", 0.7, 120_000_000, {
        "jeonse_ratio": "양호", "senior_debt": "확인 필요", "ownership": "양호",
        "insurance": "확인 필요", "blacklist": "확인 필요"}),
    "missing_sections": ("확인 필요", 0.5, 0, {
        "jeonse_ratio": "확인 필요", "senior_debt": "확인 필요", "ownership": "확인 필요",
        "insurance": "확인 필요", "blacklist": "확인 필요"}),
    "mortgage_heavy": ("위험", 0.35, 180_000_000, {
        "jeonse_ratio": "양호", "senior_debt": "위험", "ownership": "양호",
        "insurance": "확인 필요", "blacklist": "확인 필요"}),
    "real_snapshot": ("양호", 0.8, 0, {
        "jeonse_ratio": "양호", "senior_debt": "양호", "ownership": "양호",
        "insurance": "확인 필요", "blacklist": "확인 필요"}),
    "trust_seizure": ("위험", 0.35, 0, {
        "jeonse_ratio": "양호", "senior_debt": "양호", "ownership": "위험",
        "insurance": "위험", "blacklist": "확인 필요"}),
}


def load(name: str) -> dict:
    return json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))


def test_모든_픽스처가_회귀표에_들어_있다():
    """픽스처를 새로 추가하면 이 표에도 넣어야 한다 — 조용히 빠지면 봉인이 뚫린다."""
    on_disk = {p.stem for p in FIXTURES.glob("*.json")}
    assert on_disk == set(GOLDEN), f"회귀표에 없는 픽스처: {on_disk - set(GOLDEN)}"


@pytest.mark.parametrize("name", sorted(GOLDEN))
def test_등급이_기점_커밋과_같다(name: str):
    data = load(name)
    extract = RegistryExtract.from_raw(data["registry"])
    verdict = rule_engine.evaluate(
        extract,
        deposit=data["inputs"]["deposit"],
        market_price=data["inputs"].get("market_price"),
    )
    grade, gauge, senior, evidences = GOLDEN[name]
    assert verdict.grade.value == grade
    assert verdict.gauge_progress == gauge
    assert verdict.senior_debt_amount == senior
    assert {e.id: e.grade.value for e in verdict.evidences} == evidences


@pytest.mark.parametrize("name", sorted(GOLDEN))
def test_리포트_조립을_거쳐도_등급이_같다(name: str):
    """`build_report`는 설명 생성을 지나므로, LLM 경로가 판정을 건드리지 않는지도 함께 본다.

    (conftest가 API 키를 비워 두어 LLM은 폴백으로 흐른다 — 실호출 없음.)
    """
    data = load(name)
    extract = RegistryExtract.from_raw(data["registry"])
    report = report_builder.build_report(
        extract,
        deposit=data["inputs"]["deposit"],
        market_price=data["inputs"].get("market_price"),
        alias=None,
    )
    grade, gauge, senior, evidences = GOLDEN[name]
    assert report.grade == grade
    assert report.gaugeProgress == gauge
    assert report.seniorDebtAmount == senior
    assert {e.id: e.grade for e in report.evidences} == evidences


@pytest.mark.parametrize("name", sorted(GOLDEN))
def test_하이라이트를_붙여도_등급이_같다(name: str):
    """표시(하이라이트)가 판정에 새는 통로가 없는지 — 좌표가 있든 없든 등급이 같아야 한다.

    OCR 결과가 없을 때와, 있을 때(합성 페이지)의 리포트를 같은 입력으로 만들어 비교한다.
    표시 개수는 달라지지만 **판정 필드는 한 글자도 달라지면 안 된다.**
    """
    from tests.test_highlight import eul_gu_page, gap_gu_page

    data = load(name)
    extract = RegistryExtract.from_raw(data["registry"])
    kwargs = dict(
        deposit=data["inputs"]["deposit"],
        market_price=data["inputs"].get("market_price"),
        alias=None,
    )
    bare = report_builder.build_report(extract, **kwargs)

    result = highlight.build_highlights(
        extract, ocr.OcrResult(pages=[gap_gu_page(0), eul_gu_page()], elapsed=1.0)
    )
    with_marks = report_builder._build(
        extract,
        **kwargs,
        highlights=result.highlights,
        highlight_notice=result.notice,
        checked_notes=result.checked_notes,
        registry_viewed_at=result.viewed_at,
    )[0]

    for field in ("grade", "gaugeProgress", "deposit", "marketPrice", "seniorDebtAmount"):
        assert getattr(bare, field) == getattr(with_marks, field), f"{field}가 표시 때문에 바뀌었다"
    assert [(e.id, e.grade) for e in bare.evidences] == [
        (e.id, e.grade) for e in with_marks.evidences
    ]
