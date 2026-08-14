"""홈 화면 예시 리포트 (2026-08-14 D13).

시연 영상에서 홈 화면에는 **방금 찍은 실제 분석(위험)**과 **예시 한 건**이 나란히
놓인다. 그 대비가 성립하려면 예시는 깨끗한 매물이어야 하고, 무엇보다 **손으로 적은
값이 아니라 규칙 엔진이 실제로 내린 판정**이어야 한다 — 예시만 다른 경로에서 나오면
기준이 바뀔 때 조용히 어긋난다(실제로 예전 예시의 출처 문구가 그렇게 낡아 있었다).
"""

from __future__ import annotations

from app import dummy_data
from app.services import rule_engine, store
from app.schemas.internal import Grade, RegistryExtract

#: 판정에 실제로 쓰이는(=worst-of 풀에 들어가는) 근거 카드.
#: `insurance`와 `blacklist`는 구조적으로 제외된다 — 아래 테스트가 그 이유를 못 박는다.
JUDGING_IDS = ("jeonse_ratio", "senior_debt", "ownership")


def test_예시는_한_건뿐이다():
    """여럿이면 시연에서 어느 것이 방금 찍은 분석인지 흐려진다."""
    assert dummy_data.EXAMPLE_IDS == {"dummy-example"}
    assert len(dummy_data.get_history()) == 1


def test_예시_종합_등급은_양호다():
    (report,) = dummy_data.get_history()

    assert report.grade == "양호", (
        "예시가 '위험'·'확인 필요'로 뜨면 실제 촬영 분석(위험)과 대비가 사라진다"
    )
    assert report.seniorDebtAmount == 0
    assert report.marketPrice == dummy_data._EXAMPLE_MARKET_PRICE


def test_판정에_쓰이는_근거_카드는_전부_양호다():
    (report,) = dummy_data.get_history()
    by_id = {e.id: e for e in report.evidences}

    for eid in JUDGING_IDS:
        assert by_id[eid].grade == "양호", f"{eid}가 양호가 아니면 종합도 양호가 될 수 없다"


def test_보증보험은_구조적으로_양호가_될_수_없다():
    """**이 카드는 어떤 입력으로도 '양호'가 되지 않는다.**

    등기부만으로는 보증보험 가입 가능을 단정할 수 없어서다(`_judge_insurance`).
    그래서 규칙 엔진은 이 '확인 필요'를 **worst-of 계산에서 제외**한다(위험일 때만 반영) —
    카드는 화면에 남고 종합 등급은 양호가 된다. 예시를 만들 때 이 카드를 양호로
    보이게 하려면 판정 로직을 고쳐야 하는데, 그것은 보수적 편향을 거스르는 일이다.
    """
    (report,) = dummy_data.get_history()
    insurance = next(e for e in report.evidences if e.id == "insurance")

    assert insurance.grade == "확인 필요"
    assert report.grade == "양호", "보증보험 '확인 필요'는 종합 등급을 끌어내리지 않는다"


def test_악성임대인_카드는_명단_미구축_상태다():
    """명단 데이터가 0건이라 '명단 대조 아직 안 됨'이다.

    이 상태는 매물의 위험이 아니라 **우리 데이터 준비 상태**라, 규칙 엔진이 worst-of에서
    빼고(2026-07-06) 앱은 카드 자체를 하단 한계 고지로 내린다(2026-08-14 D6).
    명단이 채워지면 라벨이 바뀌어 저절로 카드로 돌아온다.
    """
    (report,) = dummy_data.get_history()
    blacklist = next(e for e in report.evidences if e.id == "blacklist")

    assert blacklist.statusLabel == rule_engine.BLACKLIST_PENDING_LABEL
    assert report.grade == "양호"


def test_예시는_규칙_엔진이_만든_그대로다():
    """같은 등기부·같은 입력을 규칙 엔진에 직접 넣으면 같은 판정이 나와야 한다.

    예시를 손으로 적기 시작하면 이 등식이 깨지고, 기준이 바뀌어도 예시만 옛 값으로
    남는다. 그때 심사위원이 보는 것은 **우리가 지금 쓰지 않는 기준**이다.
    """
    (report,) = dummy_data.get_history()
    verdict = rule_engine.evaluate(
        RegistryExtract.from_raw(dummy_data._EXAMPLE_REGISTRY),
        deposit=dummy_data._EXAMPLE_DEPOSIT,
        market_price=dummy_data._EXAMPLE_MARKET_PRICE,
    )

    assert verdict.grade is Grade.GOOD
    assert report.grade == verdict.grade.value
    assert report.gaugeProgress == verdict.gauge_progress
    assert report.seniorDebtAmount == verdict.senior_debt_amount
    assert {(e.id, e.grade) for e in report.evidences} == {
        (e.id, e.grade.value) for e in verdict.evidences
    }


def test_예시_등기부는_문서_신뢰도_게이트를_통과한다():
    """배열 키가 하나라도 비면 `doc_incomplete`가 켜져 **모든 양호가 확인 필요로 내려간다.**
    예시가 조용히 '확인 필요'로 바뀌는 가장 흔한 경로라 따로 못 박는다."""
    extract = RegistryExtract.from_raw(dummy_data._EXAMPLE_REGISTRY)

    assert extract.missing_fields == []
    assert extract.doc_incomplete is False


def test_예시는_삭제할_수_없는_id다():
    """계약 §3.4 — 예시 리포트는 조회만 허용(삭제 시도 403)."""
    assert store.EXAMPLE_IDS == dummy_data.EXAMPLE_IDS
    assert store.get("dummy-example") is not None
