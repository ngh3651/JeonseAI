"""깨끗한 등기부 견본 — 규칙 엔진이 '양호'를 내는 기준 입력 (테스트 전용).

예전(2026-08-14 D13 ~ 2026-10-29)에는 이 견본을 규칙 엔진에 통과시킨 리포트('성산동 행복아파트',
`dummy-example`)를 서버가 **모든 기기의 기록 목록 끝**에 붙였다. 2026-10-29에 그 예시를 없앴고
(규혁 결정 — 내 것이 아닌 집이 목록에 섞였다), 견본은 여기 테스트에만 남는다.
다른 테스트(판례·챗봇)도 '깨끗한 리포트 한 건'이 필요할 때 [build_clean_report]를 쓴다.

이 파일이 못 박는 것: 빚도 압류도 신탁도 없는 등기부 + 전세가율 48%면 **규칙 엔진이 실제로** '양호'를 낸다.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app.schemas.contract import Report
from app.schemas.internal import Grade, RegistryExtract
from app.services import report_builder, rule_engine

#: 깨끗한 매물의 등기부 — 빚도 압류도 신탁도 없는 집.
#: ⚠ 이름·주소는 지어낸 값이다(실제 등기부의 값을 옮겨 적지 않는다).
#: ⚠ 주소에 **동·호수가 있어야** 한다. 없으면 단독·다가구로 보여 전세가율 판정이
#:   보류되고(`price_normalize.is_whole_building`), 종합 등급이 거기 붙들린다.
CLEAN_REGISTRY: dict = {
    **{key: [] for key in RegistryExtract.LIST_KEYS},
    "address": "서울특별시 마포구 성산동 100-1 행복아파트 제102동 제501호",
    "exclusive_area_sqm": 59.9,
    "current_owners": [{"name": "홍길동", "share": "단독소유"}],
    "ownership_changes": [
        {"rank_number": "2", "receipt_date": "2019-03-14", "cause": "매매", "is_canceled": False}
    ],
}

#: 보증금 2억 4,000만원 / 시세 5억원 = 전세가율 48% — HUG 90%·부동산원 80% 기준 모두 아래라 '양호'.
CLEAN_DEPOSIT = 240_000_000
CLEAN_MARKET_PRICE = 500_000_000


def build_clean_report() -> Report:
    """깨끗한 등기부를 **실제 규칙 엔진에 통과시킨** 리포트 (Solar 안 부름 — 폴백 문구)."""
    return report_builder.build_report(
        RegistryExtract.from_raw(CLEAN_REGISTRY),
        deposit=CLEAN_DEPOSIT,
        market_price=CLEAN_MARKET_PRICE,
        alias="성산동 행복아파트",
        report_id="clean-sample",
        analyzed_at=datetime.now(timezone(timedelta(hours=9))) - timedelta(hours=3),
        use_llm=False,
    )


#: 판정에 실제로 쓰이는(=worst-of 풀에 들어가는) 근거 카드.
#: `insurance`와 `blacklist`는 구조적으로 제외된다 — 아래 테스트가 그 이유를 못 박는다.
JUDGING_IDS = ("jeonse_ratio", "senior_debt", "ownership")


def test_견본_종합_등급은_양호다():
    report = build_clean_report()

    assert report.grade == "양호", (
        "깨끗한 등기부인데 '위험'·'확인 필요'로 뜨면 규칙 엔진의 양호 경로가 깨진 것이다"
    )
    assert report.seniorDebtAmount == 0
    assert report.marketPrice == CLEAN_MARKET_PRICE


def test_판정에_쓰이는_근거_카드는_전부_양호다():
    report = build_clean_report()
    by_id = {e.id: e for e in report.evidences}

    for eid in JUDGING_IDS:
        assert by_id[eid].grade == "양호", f"{eid}가 양호가 아니면 종합도 양호가 될 수 없다"


def test_보증보험은_구조적으로_양호가_될_수_없다():
    """**이 카드는 어떤 입력으로도 '양호'가 되지 않는다.**

    등기부만으로는 보증보험 가입 가능을 단정할 수 없어서다(`_judge_insurance`).
    그래서 규칙 엔진은 이 '확인 필요'를 **worst-of 계산에서 제외**한다(위험일 때만 반영) —
    카드는 화면에 남고 종합 등급은 양호가 된다. 견본에서 이 카드를 양호로
    보이게 하려면 판정 로직을 고쳐야 하는데, 그것은 보수적 편향을 거스르는 일이다.
    """
    report = build_clean_report()
    insurance = next(e for e in report.evidences if e.id == "insurance")

    assert insurance.grade == "확인 필요"
    assert report.grade == "양호", "보증보험 '확인 필요'는 종합 등급을 끌어내리지 않는다"


def test_악성임대인_카드는_명단_미구축_상태다():
    """명단 데이터가 0건이라 '명단 대조 아직 안 됨'이다.

    이 상태는 매물의 위험이 아니라 **우리 데이터 준비 상태**라, 규칙 엔진이 worst-of에서
    빼고(2026-07-06) 앱은 카드 자체를 하단 한계 고지로 내린다(2026-08-14 D6).
    명단이 채워지면 라벨이 바뀌어 저절로 카드로 돌아온다.
    """
    report = build_clean_report()
    blacklist = next(e for e in report.evidences if e.id == "blacklist")

    assert blacklist.statusLabel == rule_engine.BLACKLIST_PENDING_LABEL
    assert report.grade == "양호"


def test_견본은_규칙_엔진이_만든_그대로다():
    """같은 등기부·같은 입력을 규칙 엔진에 직접 넣으면 같은 판정이 나와야 한다.

    견본 리포트를 손으로 적기 시작하면 이 등식이 깨지고, 기준이 바뀌어도 견본만 옛 값으로
    남는다. 그때 심사위원이 보는 것은 **우리가 지금 쓰지 않는 기준**이다.
    """
    report = build_clean_report()
    verdict = rule_engine.evaluate(
        RegistryExtract.from_raw(CLEAN_REGISTRY),
        deposit=CLEAN_DEPOSIT,
        market_price=CLEAN_MARKET_PRICE,
    )

    assert verdict.grade is Grade.GOOD
    assert report.grade == verdict.grade.value
    assert report.gaugeProgress == verdict.gauge_progress
    assert report.seniorDebtAmount == verdict.senior_debt_amount
    assert {(e.id, e.grade) for e in report.evidences} == {
        (e.id, e.grade.value) for e in verdict.evidences
    }


def test_견본_등기부는_문서_신뢰도_게이트를_통과한다():
    """배열 키가 하나라도 비면 `doc_incomplete`가 켜져 **모든 양호가 확인 필요로 내려간다.**
    견본이 조용히 '확인 필요'로 바뀌는 가장 흔한 경로라 따로 못 박는다."""
    extract = RegistryExtract.from_raw(CLEAN_REGISTRY)

    assert extract.missing_fields == []
    assert extract.doc_incomplete is False
