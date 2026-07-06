"""표시용 유틸 테스트 — short_address(주소 축약)는 표시 전용, 판정에 미사용."""

import pytest

from app.services.formatting import short_address


@pytest.mark.parametrize(
    ("full", "expected"),
    [
        (
            "서울특별시 양천구 신정동 1234 행복아파트 제101동 제5층 제501호",
            "신정동 1234 행복아파트 제101동 제5층 제501호",
        ),
        # 지번 + 도로명 병기: 앞(지번) 부분만 쓰고 '동'부터
        (
            "서울특별시 양천구 신정동 1234 아파트 제501호, 서울특별시 양천구 행복로 100",
            "신정동 1234 아파트 제501호",
        ),
        # 도로명뿐인 주소: '로/길'부터
        ("서울특별시 양천구 행복로 100", "행복로 100"),
        # 읍·면 단위
        ("경기도 양평군 양평읍 백안리 123-4", "양평읍 백안리 123-4"),
        # 매칭 실패(플레이스홀더 등) → 원본 그대로
        ("주소 미확인 (등기부 원본 확인 필요)", "주소 미확인 (등기부 원본 확인 필요)"),
        ("", ""),
    ],
)
def test_short_address(full, expected):
    assert short_address(full) == expected
