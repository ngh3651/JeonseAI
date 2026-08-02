"""공시가격·기준시가 조회 테스트 (2026-08-03).

════════════════════════════════════════════════════════════════════════════
⚠⚠ 이 테스트가 **검증하지 못하는 것** — 반드시 먼저 읽을 것 ⚠⚠

픽스처 CSV(`tests/fixtures/price/*.csv`)는 **실제 파일이 아니라 우리가 예상한
구조를 흉내 낸 합성 데이터**다. 2026-08-03 현재 공공데이터포털 점검 중이라
실제 파일을 한 번도 본 적이 없다.

따라서 이 테스트가 초록이어도 다음은 **전혀 보장되지 않는다**:
  · 실제 공시가격 CSV의 컬럼 이름이 이 픽스처와 같은지
  · 가격 컬럼이 원/천원/만원 중 무엇인지
  · 기준시가 '고시가격'이 호별 총액인지 ㎡당 단가인지
  · 지번이 한 칸인지 본번/부번 두 칸인지
  · 동·호 표기가 '101'인지 '0101'인지 '제101동'인지

이 테스트가 실제로 검증하는 것은 **로직뿐**이다 — 매핑대로 읽었을 때 단위 환산·
지번 매칭·동호 좁히기·최저가 채택·명확한 실패가 의도대로 도는가.
실제 파일이 도착하면 `scripts/inspect_price_source.py`로 구조를 확인하고
`data/price_sources.json`을 고쳐야 하며, **그 확인은 사람만 할 수 있다.**
════════════════════════════════════════════════════════════════════════════
"""

from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

import pytest

from app.services import official_price as OP
from app.services import price_normalize as N
from app.services import price_sources as PS

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import build_price_db as BUILD  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "price"

# 픽스처 CSV 의 컬럼 이름 — 실제 파일이 아니라 **우리 가정**이다(위 경고 참조).
OFFICIAL_COLUMNS = {
    "bjd_cd": "법정동코드",
    "sido": "시도",
    "sigungu": "시군구",
    "umd": "읍면동",
    "jibun_bon": "본번",
    "jibun_bu": "부번",
    "dong_nm": "동명",
    "ho_nm": "호명",
    "area_sqm": "전용면적",
    "price": "공시가격",
    "as_of": "공시기준일",
}
TAX_COLUMNS = {
    "bjd_cd": "법정동코드",
    "jibun_bon": "번지",
    "jibun_bu": "호",
    "dong_nm": "상가건물동주소",
    "ho_nm": "상가건물호주소",
    "area_sqm": "전용면적",
    "area_common_sqm": "공유면적",
    "price": "고시가격",
    "as_of": "고시일자",
}


# ── 도우미 ───────────────────────────────────────────────────────────────────


def write_config(tmp_path: Path, monkeypatch, **overrides) -> Path:
    """임시 매핑 설정을 만들고 모듈이 그것을 읽게 한다 (커밋된 설정은 건드리지 않는다)."""
    base = {
        "schema_version": 1,
        "sources": {
            PS.SOURCE_OFFICIAL_PRICE: {
                "label": "테스트 공시가격",
                "source_name": "테스트 공시가격",
                "as_of": "2025-01-01",
                "verified": True,
                "file_encoding": "utf-8",
                "delimiter": ",",
                "has_header": True,
                "price_unit": "won",
                "price_is_total": True,
                "columns": dict(OFFICIAL_COLUMNS),
            },
            PS.SOURCE_TAX_BASE: {
                "label": "테스트 기준시가",
                "source_name": "테스트 기준시가",
                "as_of": "2026-01-01",
                "verified": True,
                "file_encoding": "utf-8",
                "delimiter": ",",
                "has_header": True,
                "price_unit": "won",
                "price_is_total": False,
                "columns": dict(TAX_COLUMNS),
            },
        },
    }
    for source_key, patch in overrides.items():
        node = base["sources"][source_key]
        for k, v in patch.items():
            if k == "columns":
                node["columns"] = v
            else:
                node[k] = v
    path = tmp_path / "price_sources.json"
    path.write_text(json.dumps(base, ensure_ascii=False, indent=2), encoding="utf-8")
    monkeypatch.setattr(PS, "CONFIG_PATH", path)
    monkeypatch.setattr(OP, "PRICE_DIR", tmp_path)
    return path


def build(source_key: str, csv_path: Path, *extra: str) -> int:
    argv = ["build_price_db.py", str(csv_path), "--source", source_key, *extra]
    old = sys.argv
    sys.argv = argv
    try:
        return BUILD.main()
    finally:
        sys.argv = old


@pytest.fixture
def official_db(tmp_path, monkeypatch):
    write_config(tmp_path, monkeypatch)
    assert build(PS.SOURCE_OFFICIAL_PRICE, FIXTURES / "official_price_sample.csv") == 0
    return tmp_path


@pytest.fixture
def tax_db(tmp_path, monkeypatch):
    write_config(tmp_path, monkeypatch)
    assert build(PS.SOURCE_TAX_BASE, FIXTURES / "tax_base_sample.csv") == 0
    return tmp_path


# ── 정규화 순수 함수 ─────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "bon,bu,expected",
    [("1234", "0", "1234"), ("1234", "5", "1234-5"), ("0555", "0012", "555-12"),
     ("1234", "", "1234"), ("", "5", ""), ("1234-5", None, "1234-5")],
)
def test_지번_정규화(bon, bu, expected):
    assert N.normalize_jibun(bon, bu) == expected


def test_지번_정규화는_실거래가_모듈과_같은_결과를_낸다():
    from app.services.market_price import normalize_jibun as mp_norm

    for raw in ("1234", "727-6", "1234-0", "0555-0012"):
        assert N.normalize_jibun_text(raw) == mp_norm(raw)


@pytest.mark.parametrize(
    "raw,expected",
    [("제101동", "101"), ("101동", "101"), ("0101", "101"), ("101", "101"),
     ("A", "A"), ("가동", "가"), ("", "")],
)
def test_동호_표기_정규화(raw, expected):
    assert N.normalize_unit(raw) == expected


def test_주소에서_동과_호를_뽑는다():
    addr = "서울특별시 강남구 합성동 1234 합성아파트 제101동 제5층 제501호"
    assert N.extract_dong(addr) == "101"
    assert N.extract_ho(addr) == "501"


def test_읍면동을_건물_동으로_오인하지_않는다():
    # '합성동'은 읍면동이다. '제'도 없고 숫자·영문도 아니므로 건물 동으로 잡히면 안 된다.
    assert N.extract_dong("서울특별시 강남구 합성동 1234") == ""


def test_호가_여러_번_나오면_마지막_것을_쓴다():
    addr = "[집합건물] 서울특별시 강남구 합성동 1234 제101동 제5층 제501호"
    assert N.extract_ho(addr) == "501"


@pytest.mark.parametrize(
    "raw,expected",
    [("20250101", "2025-01-01"), ("2025-01-01", "2025-01-01"),
     ("2025.1.1", "2025-01-01"), ("202501", "2025-01-01"), ("", ""), ("몰라", "")],
)
def test_기준일_정규화(raw, expected):
    assert N.normalize_as_of(raw) == expected


@pytest.mark.parametrize(
    "raw,expected",
    [("84.88", 84.88), ("1,234.5", 1234.5), ("84.88㎡", 84.88), ("", None), ("미정", None)],
)
def test_숫자_파싱은_못_읽으면_0이_아니라_None(raw, expected):
    assert N.parse_float(raw) == expected


# ── 단독·다가구 판별 (Phase 2 안전망의 근거) ────────────────────────────────


@pytest.mark.parametrize(
    "address,expected",
    [
        ("[집합건물] 서울특별시 강남구 합성동 1234 제101동 제5층 제501호", False),
        ("[건물] 서울특별시 강남구 합성동 1234", True),
        ("[토지] 서울특별시 강남구 합성동 1234", True),
        ("서울특별시 강남구 합성동 1234 합성아파트 제101동 제5층 제501호", False),
        ("서울특별시 강남구 합성동 1234", True),  # 호수 표기 없음 → 통건물 의심
        ("[집합건물] 서울특별시 강남구 합성동 1234", False),  # 대괄호가 호수보다 강한 신호
    ],
)
def test_통건물_등기_판별(address, expected):
    assert N.is_whole_building(address) is expected


# ── 매핑이 없을 때: 조용히 실패하지 않는다 ──────────────────────────────────


def test_매핑이_비어_있으면_무엇을_하라고_알려주며_실패한다(tmp_path, monkeypatch):
    path = tmp_path / "price_sources.json"
    path.write_text(
        json.dumps({"sources": {PS.SOURCE_OFFICIAL_PRICE: {"label": "미설정"}}}),
        encoding="utf-8",
    )
    monkeypatch.setattr(PS, "CONFIG_PATH", path)
    cfg = PS.load(PS.SOURCE_OFFICIAL_PRICE)
    assert not cfg.ready
    with pytest.raises(PS.PriceSourceNotReady) as e:
        cfg.require_ready()
    assert "inspect_price_source.py" in str(e.value)


def test_커밋된_설정은_기본적으로_미설정_상태다():
    """실제 파일을 아직 못 봤으므로 verified=false 여야 한다. 자동으로 켜지면 안 된다."""
    for key in PS.ALL_SOURCES:
        cfg = PS.load(key)
        assert cfg.verified is False
        assert not cfg.ready


def test_조회는_매핑_미설정을_예외가_아니라_안내_문구로_돌려준다(tmp_path, monkeypatch):
    monkeypatch.setattr(OP, "PRICE_DIR", tmp_path)
    result, notes = OP.lookup(
        PS.SOURCE_OFFICIAL_PRICE, address="서울특별시 강남구 합성동 1234", area_sqm=84.88
    )
    assert result is None
    assert notes and "inspect_price_source.py" in notes[0]


def test_DB가_없으면_빌드_방법을_알려준다(tmp_path, monkeypatch):
    write_config(tmp_path, monkeypatch)
    result, notes = OP.lookup(
        PS.SOURCE_OFFICIAL_PRICE, address="서울특별시 강남구 합성동 1234", area_sqm=84.88
    )
    assert result is None
    assert any("build_price_db.py" in n for n in notes)


def test_모르는_정규_필드명은_설정_로딩에서_막힌다(tmp_path, monkeypatch):
    path = tmp_path / "price_sources.json"
    path.write_text(
        json.dumps({"sources": {PS.SOURCE_TAX_BASE: {"columns": {"없는필드": "X"}}}}),
        encoding="utf-8",
    )
    monkeypatch.setattr(PS, "CONFIG_PATH", path)
    with pytest.raises(PS.PriceSourceNotReady) as e:
        PS.load(PS.SOURCE_TAX_BASE)
    assert "없는필드" in str(e.value)


# ── 빌드 ─────────────────────────────────────────────────────────────────────


def test_빌드는_못_쓰는_행을_조용히_담지_않는다(official_db):
    conn = sqlite3.connect(OP.db_path(PS.SOURCE_OFFICIAL_PRICE))
    n = conn.execute(f"SELECT COUNT(*) FROM {OP.TABLE_NAME}").fetchone()[0]
    conn.close()
    # 픽스처 15행 중 5행은 면적·가격·지번이 없거나 음수/문자라 버려진다.
    assert n == 10


def test_빌드_메타에_기준일과_행수가_남는다(official_db):
    meta = OP.db_meta(PS.SOURCE_OFFICIAL_PRICE)
    assert meta["row_count"] == "10"
    assert meta["as_of"] == "2025-01-01"
    assert meta["schema_version"] == str(OP.SCHEMA_VERSION)


def test_지역_필터가_다른_시도를_걸러낸다(tmp_path, monkeypatch):
    write_config(tmp_path, monkeypatch)
    assert build(
        PS.SOURCE_OFFICIAL_PRICE, FIXTURES / "official_price_sample.csv", "--region", "서울"
    ) == 0
    conn = sqlite3.connect(OP.db_path(PS.SOURCE_OFFICIAL_PRICE))
    codes = {r[0] for r in conn.execute(f"SELECT DISTINCT lawd_cd FROM {OP.TABLE_NAME}")}
    conn.close()
    assert codes == {"11680"}


def test_설정에_적힌_컬럼이_파일에_없으면_멈춘다(tmp_path, monkeypatch, capsys):
    write_config(
        tmp_path,
        monkeypatch,
        official_price={"columns": {**OFFICIAL_COLUMNS, "price": "존재하지않는가격컬럼"}},
    )
    assert build(PS.SOURCE_OFFICIAL_PRICE, FIXTURES / "official_price_sample.csv") == 2
    assert "찾지 못했습니다" in capsys.readouterr().out


def test_인코딩이_다르면_조용히_깨지지_않고_멈춘다(tmp_path, monkeypatch, capsys):
    # utf-8 픽스처를 cp949 로 저장해 두고, 설정은 utf-8 이라고 우긴다.
    src = (FIXTURES / "official_price_sample.csv").read_text(encoding="utf-8")
    bad = tmp_path / "cp949.csv"
    bad.write_bytes(src.encode("cp949"))
    write_config(tmp_path, monkeypatch)
    assert build(PS.SOURCE_OFFICIAL_PRICE, bad) == 2
    out = capsys.readouterr().out
    assert "읽지 못했습니다" in out or "찾지 못했습니다" in out


def test_cp949_파일도_설정만_맞으면_그대로_읽힌다(tmp_path, monkeypatch):
    src = (FIXTURES / "official_price_sample.csv").read_text(encoding="utf-8")
    cp = tmp_path / "cp949.csv"
    cp.write_bytes(src.encode("cp949"))
    write_config(tmp_path, monkeypatch, official_price={"file_encoding": "cp949"})
    assert build(PS.SOURCE_OFFICIAL_PRICE, cp) == 0
    conn = sqlite3.connect(OP.db_path(PS.SOURCE_OFFICIAL_PRICE))
    n = conn.execute(f"SELECT COUNT(*) FROM {OP.TABLE_NAME}").fetchone()[0]
    conn.close()
    assert n == 10


# ── 조회 ─────────────────────────────────────────────────────────────────────

ADDR_101_501 = "[집합건물] 서울특별시 강남구 합성동 1234 합성아파트 제101동 제5층 제501호"
ADDR_NO_DONG = "[집합건물] 서울특별시 강남구 합성동 1234 합성아파트 제5층 제501호"


def test_동호와_면적이_모두_맞으면_그_행을_쓴다(official_db):
    r, notes = OP.lookup(PS.SOURCE_OFFICIAL_PRICE, address=ADDR_101_501, area_sqm=84.88)
    assert r is not None
    assert r.match_method == "dong_ho"
    assert r.matched_count == 1
    assert r.base_price_won == 620_000_000
    assert r.price_won == int(round(620_000_000 * 1.40))  # 공시가격 × 140%
    assert r.as_of == "2025-01-01"
    assert r.lawd_cd == "11680"
    assert r.area_basis == "exclusive"
    assert r.area_mismatch is False


def test_동을_모르면_호만으로_좁히고_여러_건이면_낮은_쪽을_쓴다(official_db):
    r, _ = OP.lookup(PS.SOURCE_OFFICIAL_PRICE, address=ADDR_NO_DONG, area_sqm=84.88)
    assert r is not None
    assert r.match_method == "ho"
    assert r.matched_count == 2  # 101동 501호(6.2억) · 102동 501호(6.1억)
    assert r.base_price_won == 610_000_000  # 낮은 쪽 — 미탐 방향으로 틀리지 않기 위해


def test_동호는_맞는데_면적이_어긋나면_플래그를_세운다(official_db):
    r, _ = OP.lookup(PS.SOURCE_OFFICIAL_PRICE, address=ADDR_101_501, area_sqm=59.82)
    assert r is not None
    assert r.match_method == "dong_ho"
    assert r.area_mismatch is True


def test_지번이_없으면_None이고_추정하지_않는다(official_db):
    r, notes = OP.lookup(
        PS.SOURCE_OFFICIAL_PRICE,
        address="[집합건물] 서울특별시 강남구 합성동 9999 제101동 제5층 제501호",
        area_sqm=84.88,
    )
    assert r is None
    assert any("찾지 못했습니다" in n for n in notes)


def test_지번에_한_건뿐이고_면적을_모르면_그_한_건을_쓴다(official_db):
    r, _ = OP.lookup(
        PS.SOURCE_OFFICIAL_PRICE, address="서울특별시 강남구 합성동 777", area_sqm=None
    )
    assert r is not None
    assert r.match_method == "jibun_single"
    assert r.base_price_won == 380_000_000


def test_좁힐_근거가_하나도_없으면_채우지_않는다(official_db):
    # 지번에 5건이 있는데 동·호도 없고 면적도 안 맞으면 → 아무것도 고르지 않는다.
    r, notes = OP.lookup(
        PS.SOURCE_OFFICIAL_PRICE, address="서울특별시 강남구 합성동 1234", area_sqm=999.0
    )
    assert r is None
    assert any("특정하지 못해" in n for n in notes)


def test_부번이_있는_지번도_매칭된다(official_db):
    r, _ = OP.lookup(
        PS.SOURCE_OFFICIAL_PRICE,
        address="[집합건물] 서울특별시 강남구 합성동 1234-5 합성빌라 제2층 제201호",
        area_sqm=55.56,
    )
    assert r is not None
    assert r.base_price_won == 215_000_000


def test_폐지된_시군구코드에_있는_데이터도_찾는다(tmp_path, monkeypatch):
    """실거래가와 같은 이유 — 과거 자료는 옛 코드로 남아 있을 수 있다.

    '경기도 부천시 원미구'는 41192(존재)와 41195(폐지)가 함께 있다.
    존재 코드에 데이터가 없으면 폐지 코드까지 내려가야 한다.
    """
    csv = tmp_path / "old_code.csv"
    csv.write_text(
        "법정동코드,시도,시군구,읍면동,본번,부번,동명,호명,전용면적,공시가격,공시기준일\n"
        "4119500000,경기도,부천시,합성동,1234,0,101,501,84.88,300000000,20250101\n",
        encoding="utf-8",
    )
    write_config(tmp_path, monkeypatch)
    assert build(PS.SOURCE_OFFICIAL_PRICE, csv) == 0
    r, _ = OP.lookup(
        PS.SOURCE_OFFICIAL_PRICE,
        address="[집합건물] 경기도 부천시 원미구 합성동 1234 제101동 제5층 제501호",
        area_sqm=84.88,
    )
    assert r is not None
    assert r.lawd_cd == "41195"


# ── 가격 단위 · 총액 여부 ────────────────────────────────────────────────────


def test_만원_단위_설정이면_원으로_환산한다(tmp_path, monkeypatch):
    csv = tmp_path / "man.csv"
    csv.write_text(
        "법정동코드,시도,시군구,읍면동,본번,부번,동명,호명,전용면적,공시가격,공시기준일\n"
        "1168010100,서울특별시,강남구,합성동,1234,0,101,501,84.88,62000,20250101\n",
        encoding="utf-8",
    )
    write_config(tmp_path, monkeypatch, official_price={"price_unit": "man_won"})
    assert build(PS.SOURCE_OFFICIAL_PRICE, csv) == 0
    r, _ = OP.lookup(PS.SOURCE_OFFICIAL_PRICE, address=ADDR_101_501, area_sqm=84.88)
    assert r.base_price_won == 620_000_000


def test_기준시가는_단가면_전용과_공유를_더해_총액으로_바꾼다(tax_db):
    r, _ = OP.lookup(
        PS.SOURCE_TAX_BASE,
        address="[집합건물] 서울특별시 강남구 합성동 555 제A동 제3층 제301호",
        area_sqm=28.50,
    )
    assert r is not None
    # 3,150,000원/㎡ × (28.50 + 14.20)㎡ = 134,505,000원
    assert r.base_price_won == 134_505_000
    assert r.multiplier == 1.0  # 기준시가에는 환산 배수를 곱하지 않는다
    assert r.price_won == 134_505_000
    assert r.area_basis == "exclusive_plus_common"


def test_기준시가_기준일은_행의_고시일자를_쓴다(tax_db):
    r, _ = OP.lookup(
        PS.SOURCE_TAX_BASE,
        address="[집합건물] 서울특별시 강남구 합성동 555 제A동 제3층 제301호",
        area_sqm=28.50,
    )
    assert r.as_of == "2026-01-01"


# ── 손상·이상 상황 ───────────────────────────────────────────────────────────


def test_DB가_손상되면_조용히_None이_아니라_안내와_함께_실패한다(official_db, monkeypatch):
    OP.db_path(PS.SOURCE_OFFICIAL_PRICE).write_bytes("이건 sqlite 파일이 아니다".encode() * 100)
    r, notes = OP.lookup(PS.SOURCE_OFFICIAL_PRICE, address=ADDR_101_501, area_sqm=84.88)
    assert r is None
    assert any("데이터베이스를 읽지 못했습니다" in n for n in notes)


def test_주소를_해석하지_못하면_조회하지_않고_이유를_남긴다(official_db):
    r, notes = OP.lookup(PS.SOURCE_OFFICIAL_PRICE, address="주소 미확인", area_sqm=84.88)
    assert r is None
    assert any("읽지 못해" in n for n in notes)


def test_두_소스를_한꺼번에_조회한다(tmp_path, monkeypatch):
    write_config(tmp_path, monkeypatch)
    assert build(PS.SOURCE_OFFICIAL_PRICE, FIXTURES / "official_price_sample.csv") == 0
    assert build(PS.SOURCE_TAX_BASE, FIXTURES / "tax_base_sample.csv") == 0
    results, _ = OP.lookup_all(address=ADDR_101_501, area_sqm=84.88)
    assert [r.source_key for r in results] == [PS.SOURCE_OFFICIAL_PRICE]


# ── HUG 참고 계산 ────────────────────────────────────────────────────────────


def test_HUG_인정한도는_140퍼센트와_90퍼센트를_따로_곱한다():
    from app.services import thresholds as T

    assert T.PUBLIC_PRICE_TO_HOUSE_PRICE_RATIO == 1.40
    assert T.HUG_COLLATERAL_RECOGNITION_RATIO == 0.90
    assert OP.hug_recognized_limit(100_000_000) == 126_000_000
