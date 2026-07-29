"""추출 스키마 계약 — **배타 조건이 조용히 사라지지 않게** 못 박는다.

왜 이 파일이 생겼나 (2026-07-28):
`seizures`(압류)와 `provisional_seizures`(가압류)의 description에 배타 조건이 없어서,
IE가 가압류 3건을 **양쪽에 동시에** 넣었다(실측 run 20260728_225552_594, 5회 반복 고정).
설명에 "'가압류'는 제외한다" 한 줄을 넣자 중복이 사라졌다
(`docs/ie-schema-probe-2026-07-28.md`).

문제는 이 조건이 **주석도 코드도 아닌 문자열 안에** 산다는 것이다. 리팩터·문구 정리 중에
지워져도 테스트는 전부 통과하고, 그 사실은 **다음 실호출에서야** 드러난다(크레딧을 쓰고서).
그래서 여기서 문자열을 직접 검사한다.

⚠ 이 파일은 판정을 검사하지 않는다. 등급 봉인은 `test_verdict_regression.py`가 한다.
  description은 **추출 지시**일 뿐 임계값·가중치가 아니다.
"""

from __future__ import annotations

import pytest

from app.schemas.registry_schema import REGISTRY_JSON_SCHEMA, build_response_format

#: 서로 배타적이어야 하는 필드 쌍 — 한 이름이 다른 이름의 **부분 문자열**이라 위험하다.
#: (가압류 ⊃ 압류, 가처분 ⊃ 처분). 새로 그런 쌍이 생기면 여기 추가한다.
EXCLUSIVE_PAIRS = (
    ("seizures", "압류", "provisional_seizures", "가압류"),
)


def _desc(field: str) -> str:
    return REGISTRY_JSON_SCHEMA["properties"][field]["description"]


@pytest.mark.parametrize(("narrow", "_nl", "broad", "broad_label"), EXCLUSIVE_PAIRS)
def test_배타_조건이_description에_남아_있다(narrow, _nl, broad, broad_label):
    """좁은 쪽(압류) 설명이 넓은 쪽(가압류)을 **명시적으로 배제**하는가."""
    desc = _desc(narrow)
    assert broad_label in desc, (
        f"{narrow} 설명에 '{broad_label}' 배제 문구가 없다 — "
        f"IE가 '{broad_label}'을 여기에도 넣는다 (2026-07-28 실측)"
    )
    assert "제외" in desc or "넣지 않는다" in desc, (
        f"{narrow} 설명에 배제 표현('제외'/'넣지 않는다')이 없다: {desc!r}"
    )
    assert broad in desc, (
        f"{narrow} 설명이 '{broad_label}'을 어디에 넣어야 하는지({broad}) 안 알려준다 — "
        "배제만 하면 모델이 항목을 통째로 버릴 수 있다"
    )


@pytest.mark.parametrize(("narrow", "narrow_label", "broad", "_bl"), EXCLUSIVE_PAIRS)
def test_넓은_쪽도_좁은_쪽을_배제한다(narrow, narrow_label, broad, _bl):
    """양방향이어야 한다 — 한쪽만 막으면 반대 방향 중복이 남는다."""
    desc = _desc(broad)
    assert narrow_label in desc, f"{broad} 설명에 '{narrow_label}' 언급이 없다"
    assert "넣지 않는다" in desc or "제외" in desc, (
        f"{broad} 설명에 배제 표현이 없다: {desc!r}"
    )


def test_배타_조건이_실제_전송_페이로드까지_간다():
    """description은 `build_response_format()`을 통해 나간다 — 중간에서 잘리면 소용없다.

    스키마 상수만 검사하면 '상수는 맞는데 전송은 다른' 상태를 못 잡는다.
    """
    payload = build_response_format()
    blob = str(payload)
    assert "'가압류'는 제외한다" in blob, "배타 조건이 실제 전송 페이로드에 없다"
    for field in ("seizures", "provisional_seizures"):
        assert field in blob, f"{field}가 전송 페이로드에 없다"
