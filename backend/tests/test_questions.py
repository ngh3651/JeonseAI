"""질문 생성기(E-2) 테스트 — 템플릿 선택·조건부 변형·빈칸 렌더링.

(LLM 미개입 — data/questions.json 기반. 실 API 호출 없음)
"""

import json
from pathlib import Path

from app.schemas.internal import RegistryExtract
from app.services import questions, report_builder
from app.services.formatting import format_won

FIXTURES = Path(__file__).parent / "fixtures" / "registry"


def report_for(name: str, *, market_price: int | None = "fixture"):
    data = json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))
    extract = RegistryExtract.from_raw(data["registry"])
    market = data["inputs"].get("market_price") if market_price == "fixture" else market_price
    return report_builder.build_report(
        extract,
        deposit=data["inputs"]["deposit"],
        market_price=market,
        alias=None,
        use_llm=False,  # 질문 생성기는 LLM과 무관 — 결정적 경로로 리포트 생성
    )


def labels(groups):
    return [g.riskLabel for g in groups]


def test_base_group_always_present_and_last():
    report = report_for("clean_house")
    groups = questions.build_question_groups(report)
    assert labels(groups)[-1] == "어떤 집이든 꼭"
    assert len(groups[-1].items) >= 2


def test_danger_variant_included_when_grade_danger():
    """선순위 '위험' 케이스 — 기본 질문 + evidenceGrade:위험 변형 질문이 함께 나온다."""
    report = report_for("mortgage_heavy")
    groups = questions.build_question_groups(report)
    senior = next(g for g in groups if "선순위 채권" in g.riskLabel)
    assert len(senior.items) == 2  # 무조건 1건 + 위험 변형 1건
    variant = senior.items[1]
    assert format_won(180_000_000) in variant.question  # {선순위채권합계} 치환
    assert format_won(120_000_000) in variant.question  # {보증금} 치환
    assert "{" not in variant.question  # 빈칸 잔여 없음


def test_variant_absent_when_grade_caution():
    """선순위 '확인 필요' 케이스 — 위험 변형은 나오지 않는다 (숫자만 바뀐 동일 질문 방지)."""
    report = report_for("messy_amounts")
    groups = questions.build_question_groups(report)
    senior = next(g for g in groups if "선순위 채권" in g.riskLabel)
    assert len(senior.items) == 1


def test_market_price_condition_switches_jeonse_questions():
    """시세 미입력 → '시세 자료' 질문, 시세 입력+주의 → '전세가율' 질문."""
    # 시세 미입력: jeonse_ratio가 '확인 필요'가 되어 전세가율 그룹 등장
    report = report_for("clean_house", market_price=None)
    groups = questions.build_question_groups(report)
    jeonse = next(g for g in groups if g.riskLabel == "전세가율")
    assert len(jeonse.items) == 1
    assert "실거래가" in jeonse.items[0].question  # marketPriceProvided:false 항목
    # {전세가율} 빈칸을 쓰는 true-변형은 시세가 없으면 렌더 불가 → 자동 제외됨을 겸사 확인


def test_jeonse_group_hidden_when_grade_good():
    """전세가율 '양호'면 전세가율 그룹 자체가 나오지 않는다 (패턴 파생 규칙)."""
    report = report_for("clean_house")  # 전세가율 50% → 양호
    groups = questions.build_question_groups(report)
    assert "전세가율" not in labels(groups)


def test_trust_group_on_trust_case():
    report = report_for("trust_seizure")
    groups = questions.build_question_groups(report)
    assert "신탁등기" in labels(groups)
    trust = next(g for g in groups if g.riskLabel == "신탁등기")
    assert any("신탁원부" in i.question for i in trust.items)


def test_broken_config_still_returns_base_group(tmp_path, monkeypatch):
    """questions.json이 깨져도 기본 그룹은 나간다 (계약 §3.6 — 빈 배열 금지)."""
    bad = tmp_path / "questions.json"
    bad.write_text("{ 이건 JSON이 아님", encoding="utf-8")
    monkeypatch.setattr(questions, "_QUESTIONS_PATH", bad)
    report = report_for("clean_house")
    groups = questions.build_question_groups(report)
    assert labels(groups) == ["어떤 집이든 꼭"]
