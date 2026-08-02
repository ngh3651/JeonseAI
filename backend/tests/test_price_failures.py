"""**실패 주입** 테스트 — 고장난 경우를 일부러 만든다 (2026-08-03 Phase 5-3).

정상 경로는 `test_official_price.py`·`test_price_resolver.py`가 본다.
이 파일이 묻는 것은 하나다: **조용히 이상한 값이 나오는 경로가 있는가?**

각 케이스는 둘 중 하나여야 한다.
  ⑴ 명확히 실패한다 (안내 문구 + 값 없음)
  ⑵ 보수적으로 실패한다 (값을 채우지 않고 '확인 필요'로 남긴다)
**절대 안 되는 것**: 에러 없이 틀린 숫자가 나오는 것.
"""

from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

import pytest

from app.services import market_price as MP
from app.services import official_price as OP
from app.services import price_lookup as PL
from app.services import price_resolver as R
from app.services import price_sources as PS

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import build_price_db as BUILD  # noqa: E402

from tests.test_official_price import OFFICIAL_COLUMNS, build, write_config  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "price"

HEADER = "법정동코드,시도,시군구,읍면동,본번,부번,동명,호명,전용면적,공시가격,공시기준일"
GOOD = "1168010100,서울특별시,강남구,합성동,1234,0,101,501,84.88,620000000,20250101"
ADDR = "[집합건물] 서울특별시 강남구 합성동 1234 제101동 제5층 제501호"


def make_csv(tmp_path: Path, *lines: str, name: str = "x.csv") -> Path:
    p = tmp_path / name
    p.write_text("\n".join([HEADER, *lines]) + "\n", encoding="utf-8")
    return p


# ── 원본 CSV가 망가진 경우 ───────────────────────────────────────────────────


def test_컬럼_이름이_하나_다르면_멈춘다(tmp_path, monkeypatch, capsys):
    write_config(
        tmp_path,
        monkeypatch,
        official_price={"columns": {**OFFICIAL_COLUMNS, "area_sqm": "면적"}},
    )
    csv = make_csv(tmp_path, GOOD)
    assert build(PS.SOURCE_OFFICIAL_PRICE, csv) == 2
    out = capsys.readouterr().out
    assert "찾지 못했습니다" in out
    assert "area_sqm" in out  # 어느 필드가 문제인지 말해 준다
    # DB가 만들어지지 않았어야 한다 — 반쪽짜리 DB가 남으면 다음 조회가 조용히 틀린다
    assert not OP.db_path(PS.SOURCE_OFFICIAL_PRICE).exists()


def test_칸_수가_모자란_행은_버리고_나머지는_살린다(tmp_path, monkeypatch):
    write_config(tmp_path, monkeypatch)
    csv = make_csv(tmp_path, GOOD, "1168010100,서울특별시")
    assert build(PS.SOURCE_OFFICIAL_PRICE, csv) == 0
    conn = sqlite3.connect(OP.db_path(PS.SOURCE_OFFICIAL_PRICE))
    assert conn.execute(f"SELECT COUNT(*) FROM {OP.TABLE_NAME}").fetchone()[0] == 1
    conn.close()


@pytest.mark.parametrize(
    "price",
    ["", "0", "-500000", "미정", "N/A", "  "],
)
def test_가격이_이상한_행은_담지_않는다(tmp_path, monkeypatch, price):
    write_config(tmp_path, monkeypatch)
    csv = make_csv(
        tmp_path,
        f"1168010100,서울특별시,강남구,합성동,1234,0,101,501,84.88,{price},20250101",
    )
    # 모든 행이 걸러져 DB가 비면 **종료 코드 1로 크게 실패한다**(조용한 빈 DB 금지).
    assert build(PS.SOURCE_OFFICIAL_PRICE, csv) == 1
    conn = sqlite3.connect(OP.db_path(PS.SOURCE_OFFICIAL_PRICE))
    assert conn.execute(f"SELECT COUNT(*) FROM {OP.TABLE_NAME}").fetchone()[0] == 0
    conn.close()
    # 그래도 조회는 터지지 않고 '못 찾았다'로 끝난다 — 0원짜리 시세가 나오지 않는다
    r, _ = OP.lookup(PS.SOURCE_OFFICIAL_PRICE, address=ADDR, area_sqm=84.88)
    assert r is None


def test_기준일을_어디서도_못_구하면_담지_않는다(tmp_path, monkeypatch, capsys):
    """'언제 기준 시세인가'가 없으면 근거를 밝힐 수 없다 — 값이 있어도 버린다."""
    write_config(tmp_path, monkeypatch, official_price={"as_of": None})
    csv = make_csv(
        tmp_path,
        "1168010100,서울특별시,강남구,합성동,1234,0,101,501,84.88,620000000,",
    )
    # columns.as_of 매핑은 있으므로 빌드는 시작되지만, 행의 값이 비어 전부 버려진다.
    assert build(PS.SOURCE_OFFICIAL_PRICE, csv) == 1
    assert "기준일 없음" in capsys.readouterr().out


def test_행의_기준일만_비면_소스_기준일로_메운다(tmp_path, monkeypatch):
    write_config(tmp_path, monkeypatch)  # as_of = '2025-01-01'
    csv = make_csv(
        tmp_path,
        "1168010100,서울특별시,강남구,합성동,1234,0,101,501,84.88,620000000,",
    )
    assert build(PS.SOURCE_OFFICIAL_PRICE, csv) == 0
    r, _ = OP.lookup(PS.SOURCE_OFFICIAL_PRICE, address=ADDR, area_sqm=84.88)
    assert r is not None and r.as_of == "2025-01-01"


def test_법정동코드가_없고_지역명도_못_찾으면_버린다(tmp_path, monkeypatch, capsys):
    write_config(tmp_path, monkeypatch)
    csv = make_csv(
        tmp_path,
        ",없는시도,없는구,없는동,1234,0,101,501,84.88,620000000,20250101",
    )
    assert build(PS.SOURCE_OFFICIAL_PRICE, csv) == 1  # 전부 버려져 빈 DB → 크게 실패
    assert "법정동코드 확정 실패" in capsys.readouterr().out
    conn = sqlite3.connect(OP.db_path(PS.SOURCE_OFFICIAL_PRICE))
    assert conn.execute(f"SELECT COUNT(*) FROM {OP.TABLE_NAME}").fetchone()[0] == 0
    conn.close()


# ── 설정이 망가진 경우 ───────────────────────────────────────────────────────


def test_모르는_가격_단위는_멈춘다(tmp_path, monkeypatch, capsys):
    write_config(tmp_path, monkeypatch, official_price={"price_unit": "억원"})
    csv = make_csv(tmp_path, GOOD)
    assert build(PS.SOURCE_OFFICIAL_PRICE, csv) == 2
    assert "price_unit" in capsys.readouterr().out


def test_단가_설정인데_공유면적_컬럼이_없으면_멈춘다(tmp_path, monkeypatch):
    """(전용+공유)를 곱해야 총액이 되는데 공유면적을 모르면 값이 낮게 나온다."""
    write_config(tmp_path, monkeypatch, official_price={"price_is_total": False})
    cfg = PS.load(PS.SOURCE_OFFICIAL_PRICE)
    assert any("area_common_sqm" in m for m in cfg.missing_items())
    with pytest.raises(PS.PriceSourceNotReady):
        cfg.require_ready()


def test_설정_JSON이_깨지면_안내와_함께_실패한다(tmp_path, monkeypatch):
    path = tmp_path / "price_sources.json"
    path.write_text("{ 이건 JSON이 아니다 ", encoding="utf-8")
    monkeypatch.setattr(PS, "CONFIG_PATH", path)
    with pytest.raises(PS.PriceSourceNotReady) as e:
        PS.load(PS.SOURCE_OFFICIAL_PRICE)
    assert "JSON" in str(e.value)


def test_설정_파일이_통째로_없으면_안내한다(tmp_path, monkeypatch):
    monkeypatch.setattr(PS, "CONFIG_PATH", tmp_path / "없는파일.json")
    with pytest.raises(PS.PriceSourceNotReady) as e:
        PS.load(PS.SOURCE_OFFICIAL_PRICE)
    assert "없습니다" in str(e.value)


# ── DB가 망가진 경우 ─────────────────────────────────────────────────────────


def test_DB_스키마_버전이_다르면_price_status가_알아챈다(tmp_path, monkeypatch):
    write_config(tmp_path, monkeypatch)
    assert build(PS.SOURCE_OFFICIAL_PRICE, make_csv(tmp_path, GOOD)) == 0
    conn = sqlite3.connect(OP.db_path(PS.SOURCE_OFFICIAL_PRICE))
    conn.execute(
        f"UPDATE {OP.META_TABLE} SET value='999' WHERE key='schema_version'"
    )
    conn.commit()
    conn.close()
    assert OP.db_meta(PS.SOURCE_OFFICIAL_PRICE)["schema_version"] != str(OP.SCHEMA_VERSION)


def test_테이블이_통째로_없으면_안내와_함께_실패한다(tmp_path, monkeypatch):
    write_config(tmp_path, monkeypatch)
    assert build(PS.SOURCE_OFFICIAL_PRICE, make_csv(tmp_path, GOOD)) == 0
    conn = sqlite3.connect(OP.db_path(PS.SOURCE_OFFICIAL_PRICE))
    conn.execute(f"DROP TABLE {OP.TABLE_NAME}")
    conn.commit()
    conn.close()
    r, notes = OP.lookup(PS.SOURCE_OFFICIAL_PRICE, address=ADDR, area_sqm=84.88)
    assert r is None
    assert any("데이터베이스를 읽지 못했습니다" in n for n in notes)


def test_DB가_빈_파일이어도_리포트_경로는_살아남는다(tmp_path, monkeypatch):
    write_config(tmp_path, monkeypatch)
    OP.db_path(PS.SOURCE_OFFICIAL_PRICE).parent.mkdir(parents=True, exist_ok=True)
    OP.db_path(PS.SOURCE_OFFICIAL_PRICE).write_bytes(b"")
    r, notes = OP.lookup(PS.SOURCE_OFFICIAL_PRICE, address=ADDR, area_sqm=84.88)
    # 빈 파일은 sqlite가 '빈 DB'로 열어 주므로 테이블이 없다는 오류가 난다
    assert r is None
    assert notes


# ── 실거래가 API가 이상한 경우 ───────────────────────────────────────────────


def test_HTTP200인데_본문이_에러면_시세를_채우지_않는다(monkeypatch):
    """공공 API는 200으로 에러를 준다 — 200만 보고 넘기면 엉뚱한 값이 흐른다."""
    xml = (
        "<response><header><resultCode>30</resultCode>"
        "<resultMsg>SERVICE KEY IS NOT REGISTERED ERROR</resultMsg></header></response>"
    )
    with pytest.raises(MP.MarketPriceError) as e:
        MP._parse_items(xml, "apt")
    assert "30" in e.value.detail


def test_실거래가가_예외를_내도_리포트_경로가_살아남는다(monkeypatch):
    def boom(*a, **k):
        raise MP.MarketPriceError(502, "실거래가 서버에 연결하지 못했어요")

    monkeypatch.setattr(MP, "lookup_market_price", boom)
    monkeypatch.setattr(PL, "_official_candidates", lambda *a, **k: ([], []))
    resolved = PL.collect(address=ADDR, area_sqm=84.88, manual_price_won=300_000_000)
    assert resolved.price_won == 300_000_000
    assert any("연결하지 못했어요" in n for n in resolved.notes)


def test_XML이_깨져도_예외로_명확히_실패한다():
    with pytest.raises(MP.MarketPriceError) as e:
        MP._parse_items("<response><header", "apt")
    assert "해석하지 못했어요" in e.value.detail


# ── 두 소스가 크게 어긋나는 경우 ─────────────────────────────────────────────


def test_두_소스가_100배_차이나도_낮은_쪽을_쓰고_괴리를_밝힌다():
    trade = R.PriceCandidate(
        10_000_000_000, R.SOURCE_ACTUAL_TRADE, "실거래가", "2026-02~2026-07", 3
    )
    public = R.PriceCandidate(100_000_000, R.SOURCE_OFFICIAL_PRICE, "공시가격", "2025-01-01")
    resolved = R.resolve([trade, public])
    assert resolved.price_won == 100_000_000  # 낮은 쪽
    assert resolved.gap_pct == 9900
    assert resolved.gap_direction == "trade_inflated"
    # 사용자에게는 "부풀림 의심"이라고 말한다
    assert "부풀" in R.gap_message(resolved)


def test_공시_기준이_0이면_괴리를_계산하지_않고_나눗셈도_하지_않는다():
    trade = R.PriceCandidate(1_000_000_000, R.SOURCE_ACTUAL_TRADE, "실거래가", "")
    public = R.PriceCandidate(0, R.SOURCE_OFFICIAL_PRICE, "공시가격", "")
    resolved = R.resolve([trade, public])
    assert resolved.price_won == 1_000_000_000  # 0은 후보에서 빠진다
    assert resolved.gap_pct is None


# ── 조용한 오염 방지 ─────────────────────────────────────────────────────────


def test_같은_지번_다른_동호는_섞이지_않는다(tmp_path, monkeypatch):
    write_config(tmp_path, monkeypatch)
    csv = make_csv(
        tmp_path,
        "1168010100,서울특별시,강남구,합성동,1234,0,101,501,84.88,620000000,20250101",
        "1168010100,서울특별시,강남구,합성동,1234,0,102,501,84.88,100000000,20250101",
    )
    assert build(PS.SOURCE_OFFICIAL_PRICE, csv) == 0
    # 101동 501호를 물었으면 102동의 1억이 아니라 101동의 6.2억이 나와야 한다
    r, _ = OP.lookup(PS.SOURCE_OFFICIAL_PRICE, address=ADDR, area_sqm=84.88)
    assert r.base_price_won == 620_000_000
    assert r.match_method == "dong_ho"
    assert r.matched_count == 1


def test_면적이_전혀_다르면_지번이_같아도_채우지_않는다(tmp_path, monkeypatch):
    write_config(tmp_path, monkeypatch)
    csv = make_csv(
        tmp_path,
        "1168010100,서울특별시,강남구,합성동,1234,0,201,301,29.76,200000000,20250101",
        "1168010100,서울특별시,강남구,합성동,1234,0,202,302,29.76,210000000,20250101",
    )
    assert build(PS.SOURCE_OFFICIAL_PRICE, csv) == 0
    r, notes = OP.lookup(
        PS.SOURCE_OFFICIAL_PRICE,
        address="[집합건물] 서울특별시 강남구 합성동 1234",
        area_sqm=114.756,
    )
    assert r is None
    assert any("특정하지 못해" in n for n in notes)


def test_자동조회값이_사용자_입력을_조용히_덮어쓰지_않는다():
    """사용자 값이 채택되지 않았더라도 **후보 목록에 그대로 남아** 화면에 보인다."""
    resolved = R.resolve([
        R.PriceCandidate(900_000_000, R.SOURCE_MANUAL, "직접 입력", ""),
        R.PriceCandidate(600_000_000, R.SOURCE_OFFICIAL_PRICE, "공시가격", "2025-01-01"),
    ])
    assert resolved.source == R.SOURCE_OFFICIAL_PRICE
    assert [a.source for a in resolved.alternatives] == [R.SOURCE_MANUAL]
    assert resolved.alternatives[0].price_won == 900_000_000
