"""법정동코드 로더 테스트 (STEP 1).

기대값은 전부 `backend/data/lawd_codes.txt` 에서 **실제로 확인한 값**이다
(2026-07-29 스냅샷). 기억이나 추측으로 적은 숫자가 없다.

⚠ 이 테스트는 판정과 무관하다 — 위험 등급·임계값에 닿지 않는다.
"""

from __future__ import annotations

import logging

import pytest

from app.services import lawd_code
from app.services.lawd_code import LawdCodeError, lawd_candidates, lawd_codes

pytestmark = pytest.mark.skipif(
    not lawd_code.LAWD_CODE_FILE.exists(),
    reason="backend/data/lawd_codes.txt 없음 (code.go.kr 전체자료 필요)",
)


# ── 기본 매칭 ────────────────────────────────────────────────────────────────


def test_서울_양천구는_11470을_후보에_담는다():
    """실측: 1147000000 서울특별시 양천구 존재."""
    codes = lawd_codes("서울특별시 양천구 합성동 1234 합성아파트 제101동 제1층 제101호")
    assert "11470" in codes
    assert codes[0] == "11470"  # 다른 후보가 앞설 이유가 없다


def test_광역시가_아닌_시의_구는_구코드가_시코드보다_앞선다():
    """함정 1 — 실측: 4111000000 경기도 수원시 / 4111100000 경기도 수원시 장안구 (둘 다 존재).

    실거래가 API가 받는 것은 구 단위(41111)다. 둘 다 후보에 담되 구가 먼저여야 한다.
    """
    codes = lawd_codes("경기도 수원시 장안구 정자동 123-4")
    assert "41111" in codes
    assert "41110" in codes
    assert codes.index("41111") < codes.index("41110")


def test_구가_없는_시는_시코드가_나온다():
    """장안구를 빼면 41111은 걸리지 않는다 (접두 일치라 과잉 매칭이 없다)."""
    codes = lawd_codes("경기도 수원시 정자동 123-4")
    assert "41110" in codes
    assert "41111" not in codes


def test_세종특별자치시는_시군구_행으로_처리된다():
    """실측: 3611000000 세종특별자치시 존재 — 시도 행이 아니라 시군구 행이다.

    법정동명이 **한 토큰**이라 1토큰 접두 일치가 되어야 잡힌다.
    """
    assert "36110" in lawd_codes("세종특별자치시 어진동 500")


# ── 시도 명칭 변경 (양방향 후보) ─────────────────────────────────────────────


def test_강원도_춘천시는_구코드와_신코드를_둘_다_후보로_준다():
    """실측: 4211000000 강원도 춘천시 폐지 / 5111000000 강원특별자치도 춘천시 존재."""
    codes = lawd_codes("강원도 춘천시 효자동 1")
    assert "42110" in codes
    assert "51110" in codes


def test_신구_표기가_같은_후보_집합을_만든다():
    """옛 표기로 들어와도 새 표기로 들어와도 시도해 볼 코드 집합은 같아야 한다."""
    old = set(lawd_codes("강원도 춘천시 효자동 1"))
    new = set(lawd_codes("강원특별자치도 춘천시 효자동 1"))
    assert old == new
    assert {"42110", "51110"} <= old


def test_존재_행이_폐지_행보다_앞선다():
    """✅ 2026-07-29 실호출로 확정된 순서.

    춘천 아파트매매 2026-06: 42110(폐지) → 0건 / 51110(존재) → 225건.
    개편 전 거래도 현행 코드로 조회된다 — API가 과거분까지 새 코드로 옮겨 놓았다.
    """
    codes = lawd_codes("강원도 춘천시 효자동 1")
    assert codes.index("51110") < codes.index("42110")  # 존재 → 폐지


def test_제주도_옛표기도_신코드를_후보로_준다():
    """실측: 4911000000 제주도 제주시 폐지 / 5011000000 제주특별자치도 제주시 존재."""
    codes = lawd_codes("제주도 제주시 이도이동 1")
    assert "49110" in codes
    assert "50110" in codes


def test_전북_옛표기도_신코드를_후보로_준다():
    """전라북도(45) ↔ 전북특별자치도(52)."""
    codes = lawd_codes("전라북도 전주시 완산구 중앙동1가 1")
    assert any(c.startswith("45") for c in codes)
    assert any(c.startswith("52") for c in codes)


# ── 광주·전남 2:1 통합 ──────────────────────────────────────────────────────


def test_광주광역시_서구는_구계열과_통합계열을_둘_다_준다():
    """실측: 2914000000 광주광역시 서구 폐지 / 1224000000 전남광주통합특별시 서구 존재."""
    codes = lawd_codes("광주광역시 서구 화정동 1")
    assert "29140" in codes
    assert "12240" in codes
    assert codes.index("12240") < codes.index("29140")  # 존재 먼저


def test_전라남도_목포시도_통합계열을_후보로_준다():
    """실측: 4611000000 전라남도 목포시 폐지 / 1211000000 전남광주통합특별시 목포시 존재."""
    codes = lawd_codes("전라남도 목포시 용당동 1")
    assert "46110" in codes
    assert "12110" in codes


def test_통합_신표기는_역방향으로_옛_계열을_찾아준다():
    """2:1 통합의 역방향(12 → 29 또는 46)은 표에 적힌 쌍만 쓰고, 실제 선택은
    법정동명 전체 접두 일치가 가른다.

    '전남광주통합특별시 목포시' → '전라남도 목포시'는 실재하고
    '광주광역시 목포시'는 없으므로, 잘못된 쪽은 자연히 탈락한다.
    """
    codes = lawd_codes("전남광주통합특별시 목포시 용당동 1")
    assert "12110" in codes
    assert "46110" in codes
    assert not any(c.startswith("29") for c in codes)  # 광주광역시 계열은 안 붙는다


def test_접미사가_같은_다른_지역을_잘못_잇지_않는다():
    """'광주광역시 서구'와 '대구광역시 서구'는 접미사가 같다.

    시도를 무시하고 구 이름만 보면 섞인다. 시도 토큰까지 포함한 접두 일치라 안 섞인다.
    """
    codes = lawd_codes("대구광역시 서구 내당동 1")
    assert not any(c.startswith("29") for c in codes)
    assert not any(c.startswith("12") for c in codes)


# ── 같은 이름이 여러 코드인 경우 ────────────────────────────────────────────


def test_같은_이름의_폐지구가_현행_시코드를_밀어내지_않는다():
    """실측: '경기도 부천시 원미구'가 41192(존재)·41195(폐지) 둘 다이고,
    상위 '경기도 부천시'는 41190(존재)이다.

    최장 일치 하나만 취했다면 폐지 구(41195)가 뽑혀 현행 코드를 잃었을 것이다.
    """
    codes = lawd_codes("경기도 부천시 원미구 중동 1")
    assert "41190" in codes  # 현행 시 코드가 살아 있다
    assert "41192" in codes
    assert "41195" in codes
    # 존재 행들이 폐지 행보다 앞선다
    assert codes.index("41192") < codes.index("41195")
    assert codes.index("41190") < codes.index("41195")


# ── 실패 처리 ────────────────────────────────────────────────────────────────


def test_매칭_불가_문자열은_빈_목록():
    assert lawd_codes("어디에도 없는 주소 문자열") == []


def test_시도_없이_구만_있으면_빈_목록():
    """'중구'·'남구'·'동구'는 전국에 여러 개다 — 시도 없이는 특정할 수 없다."""
    assert lawd_codes("양천구 합성동 1234") == []


def test_빈_주소는_빈_목록():
    assert lawd_codes("") == []
    assert lawd_codes("   ") == []


def test_매칭_실패는_경고를_남기되_상세주소는_찍지_않는다(caplog):
    """실패가 조용하면 안 된다. 단 로그에 개인정보(번지·이름)를 남기지 않는다."""
    with caplog.at_level(logging.WARNING, logger="jeonseai"):
        lawd_codes("없는시도 없는구 상세번지 9999 홍길동아파트 101동")
    messages = [r.message for r in caplog.records]
    assert any("법정동코드 매칭 실패" in m for m in messages)
    joined = " ".join(messages)
    assert "9999" not in joined  # 번지 안 찍힘
    assert "홍길동아파트" not in joined  # 건물명 안 찍힘
    assert "없는시도 없는구" in joined  # 시도+시군구까지만


# ── 주소 앞부분 파싱 ────────────────────────────────────────────────────────


def test_지번_도로명_병기는_콤마_앞만_본다():
    """등기부는 '지번, 도로명'을 병기하기도 한다 (formatting.short_address와 같은 관례)."""
    assert "11470" in lawd_codes("서울특별시 양천구 합성동 1234, 합성로 100")


def test_대괄호_표기를_떼어낸다():
    """OCR 헤더에서 오는 '[집합건물] ...' 형태."""
    assert "11470" in lawd_codes("[집합건물] 서울특별시 양천구 합성동 1234")


# ── 후보 메타데이터 ─────────────────────────────────────────────────────────


def test_후보에_이름과_존재여부가_함께_온다():
    """어느 코드가 통했는지 로그로 남기려면 코드만으로는 부족하다."""
    candidates = lawd_candidates("경기도 수원시 장안구 정자동 123-4")
    top = candidates[0]
    assert top.lawd_cd == "41111"
    assert top.name == "경기도 수원시 장안구"
    assert top.active is True
    assert top.matched_tokens == 3


# ── 파일 누락 ────────────────────────────────────────────────────────────────


def test_파일이_없으면_안내와_함께_실패한다(monkeypatch, tmp_path):
    """코드를 직접 만들어 채우지 않는다 — 어디서 받는지 알려주고 멈춘다."""
    monkeypatch.setattr(lawd_code, "LAWD_CODE_FILE", tmp_path / "없음.txt")
    lawd_code._load_rows.cache_clear()
    try:
        with pytest.raises(LawdCodeError) as exc:
            lawd_code._load_rows()
        assert "code.go.kr" in str(exc.value)
        assert "backend/data/lawd_codes.txt" in str(exc.value)
    finally:
        lawd_code._load_rows.cache_clear()


def test_한글이_깨지지_않는다():
    """인코딩(cp949)이 맞는지 — 깨지면 이름 비교가 전부 무너진다."""
    rows = lawd_code._load_rows()
    names = {r.name for r in rows}
    assert "서울특별시 양천구" in names
    assert "경기도 수원시 장안구" in names
    assert "강원특별자치도 춘천시" in names
    assert not any("�" in r.name for r in rows)
