"""공시가격·기준시가 원본 CSV → **SQLite 변환** CLI (개발 도구 — 외부 호출 없음).

사용법:
    python scripts/build_price_db.py --source official_price data/price/raw/공동주택.zip
    python scripts/build_price_db.py --source tax_base data/price/raw/기준시가.csv --region 서울
    python scripts/build_price_db.py --source official_price <파일> --limit 100000   # 시험용

⚠ **전체를 메모리에 올리지 않는다.** 한 줄씩 읽어 batch 단위로 넣는다.
  공시가격은 1,500만 행을 넘길 수 있어, 전체 로드는 시작조차 못 한다.
⚠ 컬럼 이름은 이 파일에 하나도 없다 — 전부 `backend/data/price_sources.json` 에서 온다.
⚠ 매핑이 준비되지 않았으면 **조용히 넘어가지 않고** 무엇을 하면 되는지 알려주고 멈춘다.

변환이 끝나면 **자기검증**을 한다: 무작위 10건을 원본 파일에서 다시 읽어
DB 값과 대조한다(레코드 번호를 함께 저장해 두기 때문에 정확히 같은 줄을 볼 수 있다).

────────────────────────────────────────────────────────────────────────
[2026-08-05] `line.split(구분자)` → **`csv.reader`** 로 교체

예전에는 한 줄을 구분자로 그냥 쪼갰다. 그런데 실제 파일 두 개 모두 **값 안에
쉼표가 들어 있다**:
  · 공시가격  0.91% (300만 행 중 27,249건) — 단지명 '상원주택(101,102동)'
  · 기준시가  1.25% (249만 행 중 31,193건) — 상가건물호주소 '"24,25"'
이 행들은 칸이 통째로 밀려 **가격 자리에 면적이, 면적 자리에 가격이** 들어갔다.
(inspect 표본에서 전용면적 최댓값이 1,479,000㎡로 찍힌 것이 그 증거다.)

더 나빴던 것은 두 가지다:
  ⑴ **자기검증이 못 잡았다.** 원본을 같은 파서로 다시 읽어 대조하므로 똑같이
     틀린 값이 나와 '일치'가 된다. 그래서 파서 교체는 검증 자체를 되살리는 일이다.
  ⑵ **밀린 행이 우선 채택됐다.** 밀린 가격은 25원·59원처럼 극단적으로 작은데
     `official_price` 는 후보 중 **최저가**를 고르므로 정상 행을 제친다.

`csv` 모듈은 C 구현이라 스트리밍 성능도 그대로다. 따옴표 해제는 이제 csv 가
전담하므로 `.strip('"')` 를 따로 하지 않는다(값에 든 정당한 따옴표를 지우지 않게).
────────────────────────────────────────────────────────────────────────
"""

from __future__ import annotations

import argparse
import csv
import io
import sqlite3
import sys
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.services import lawd_code, official_price as OP  # noqa: E402
from app.services import price_normalize as N  # noqa: E402
from app.services import price_sources as PS  # noqa: E402

BATCH = 50_000
SAMPLE_CHECK = 10


# ── 원본 스트리밍 ────────────────────────────────────────────────────────────


def open_text(path: Path, member: str | None, encoding: str):
    """(이름, 텍스트 스트림, close 함수). ZIP 안이어도 압축을 풀지 않고 흘려 읽는다."""
    if path.suffix.lower() != ".zip":
        raw = path.open("rb")
        return path.name, io.TextIOWrapper(raw, encoding=encoding, newline=""), raw.close
    zf = zipfile.ZipFile(path)
    infos = [i for i in zf.infolist() if not i.is_dir()]
    if member:
        picked = next((i for i in infos if i.filename == member), None)
        if picked is None:
            raise SystemExit(f"[중단] zip 안에 {member!r} 가 없습니다.")
    else:
        data_like = [i for i in infos if i.filename.lower().endswith((".csv", ".txt", ".dat"))]
        picked = max(data_like or infos, key=lambda i: i.file_size)
    raw = zf.open(picked, "r")

    def _close():
        raw.close()
        zf.close()

    return picked.filename, io.TextIOWrapper(raw, encoding=encoding, newline=""), _close


def open_records(path: Path, member: str | None, cfg: PS.PriceSourceConfig):
    """(이름, csv.reader, close) — 따옴표·이스케이프를 표준 CSV 규칙으로 해석한다.

    ⚠ `open_text` 가 `newline=""` 로 열기 때문에 값 안에 줄바꿈이 있어도 csv 가
      한 레코드로 묶어 준다. 그래서 이후 번호는 **물리적 줄 번호가 아니라
      레코드 번호**다 — 쓰는 쪽과 검증하는 쪽이 같은 정의를 쓰므로 일관된다.
    """
    name, stream, close = open_text(path, member, cfg.file_encoding)
    reader = csv.reader(stream, delimiter=cfg.delimiter or ",")
    return name, reader, close


# ── 행 정규화 ────────────────────────────────────────────────────────────────


@dataclass
class SkipStats:
    no_price: int = 0
    no_area: int = 0
    no_jibun: int = 0
    no_lawd: int = 0
    bad_price: int = 0
    short_row: int = 0
    no_as_of: int = 0
    region_filtered: int = 0
    # 버리지는 않지만 **조용히 넘어가면 안 되는** 것 — 총액 계산이 과소평가된다.
    common_area_missing: int = 0

    def total(self) -> int:
        return (
            self.no_price
            + self.no_area
            + self.no_jibun
            + self.no_lawd
            + self.bad_price
            + self.short_row
            + self.no_as_of
        )

    def lines(self) -> list[str]:
        rows = [
            ("칸 수 부족", self.short_row),
            ("가격 없음", self.no_price),
            ("가격이 0 이하 또는 숫자 아님", self.bad_price),
            ("전용면적 없음", self.no_area),
            ("지번 없음", self.no_jibun),
            ("법정동코드 확정 실패", self.no_lawd),
            ("기준일 없음 (행에도 설정에도 없음)", self.no_as_of),
        ]
        return [f"    · {label}: {n:,}건" for label, n in rows if n]

    def warnings(self) -> list[str]:
        out = []
        if self.common_area_missing:
            out.append(
                f"    ⚠ 공유면적이 빈 행 {self.common_area_missing:,}건 — 전용면적만으로 "
                "총액을 계산했습니다(실제보다 낮게 나옵니다). "
                "가격이 낮으면 전세가율이 높아져 경고 쪽으로 기울므로 미탐은 아니지만, "
                "이 건수가 크면 컬럼 매핑을 다시 확인하세요."
            )
        return out


class LawdResolver:
    """시도+시군구 텍스트 → LAWD_CD(5자리). 결과를 캐시한다.

    법정동코드 컬럼이 있으면 그 앞 5자리를 쓰고, 없을 때만 이름으로 찾는다.
    이름으로도 못 찾으면 **그 행을 버린다** — 지역을 모르면 조회 키를 만들 수 없고,
    비슷한 코드를 찍어 넣으면 다른 동네 시세를 붙이는 사고가 된다.
    """

    def __init__(self) -> None:
        self._cache: dict[str, str] = {}

    def resolve(self, bjd_cd: str, sido: str, sigungu: str) -> str:
        if bjd_cd and len(bjd_cd) >= 5 and bjd_cd[:5].isdigit():
            return bjd_cd[:5]
        key = f"{sido} {sigungu}".strip()
        if not key:
            return ""
        if key in self._cache:
            return self._cache[key]
        try:
            codes = lawd_code.lawd_codes(key)
        except lawd_code.LawdCodeError:
            codes = []
        value = codes[0] if codes else ""
        self._cache[key] = value
        return value


def normalize_row(
    cfg: PS.PriceSourceConfig,
    idx: dict[str, int],
    cells: list[str],
    line_no: int,
    resolver: LawdResolver,
    multiplier: int,
    stats: SkipStats,
) -> tuple | None:
    """CSV 한 줄 → DB 한 행(tuple). 못 쓰는 줄은 `None` + 사유 카운트."""

    def get(field: str) -> str:
        i = idx.get(field)
        if i is None or i >= len(cells):
            return ""
        # 따옴표 해제는 csv.reader 가 이미 했다 — 여기서 또 벗기면 값에 든
        # 정당한 따옴표까지 지운다(2026-08-05 파서 교체).
        return cells[i].strip()

    if len(cells) < 2:
        stats.short_row += 1
        return None

    bjd_cd = get("bjd_cd")
    lawd_cd = resolver.resolve(bjd_cd, get("sido"), get("sigungu"))
    if not lawd_cd:
        stats.no_lawd += 1
        return None

    if idx.get("jibun_full") is not None:
        jibun = N.normalize_jibun_text(get("jibun_full"))
    else:
        jibun = N.normalize_jibun(get("jibun_bon"), get("jibun_bu"))
    if not jibun:
        stats.no_jibun += 1
        return None

    area = N.parse_float(get("area_sqm"))
    if area is None or area <= 0:
        stats.no_area += 1
        return None
    area_common = N.parse_float(get("area_common_sqm"))

    raw_price = N.parse_float(get("price"))
    if raw_price is None:
        stats.no_price += 1
        return None
    price_won = raw_price * multiplier
    if cfg.price_is_total is False:
        # ㎡당 단가 → 호별 총액. 국세청 산식은 (전용 + 공유)면적을 곱한다.
        if area_common is None:
            stats.common_area_missing += 1
        total_area = area + (area_common or 0.0)
        price_won = price_won * total_area
    price_won = int(round(price_won))
    if price_won <= 0:
        stats.bad_price += 1
        return None

    # 기준일 없는 값은 쓰지 않는다 — "언제 기준 시세인가"가 없으면 사용자에게
    # 근거를 밝힐 수 없고, 낡은 값을 오늘 시세로 쓰게 된다(설계 원칙 4).
    as_of = N.normalize_as_of(get("as_of")) or (cfg.as_of or "")
    if not as_of:
        stats.no_as_of += 1
        return None

    return (
        lawd_cd,
        bjd_cd or None,
        get("umd") or None,
        jibun,
        N.normalize_unit(get("dong_nm")) or None,
        N.normalize_unit(get("ho_nm")) or None,
        area,
        area_common,
        price_won,
        as_of,
        line_no,
    )


# ── DB ───────────────────────────────────────────────────────────────────────


def create_db(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode = OFF")
    conn.execute("PRAGMA synchronous = OFF")
    conn.execute("PRAGMA cache_size = -64000")  # 64MB
    conn.execute(
        f"""
        CREATE TABLE {OP.TABLE_NAME} (
            id              INTEGER PRIMARY KEY,
            lawd_cd         TEXT NOT NULL,
            bjd_cd          TEXT,
            umd             TEXT,
            jibun           TEXT NOT NULL,
            dong_nm         TEXT,
            ho_nm           TEXT,
            area_sqm        REAL,
            area_common_sqm REAL,
            price_won       INTEGER NOT NULL,
            as_of           TEXT NOT NULL,
            src_line        INTEGER NOT NULL
        )
        """
    )
    conn.execute(f"CREATE TABLE {OP.META_TABLE} (key TEXT PRIMARY KEY, value TEXT)")
    return conn


def build_indexes(conn: sqlite3.Connection) -> None:
    # 조회는 항상 (시군구코드, 지번)으로 들어온다 — 이 복합 인덱스가 없으면 전수 스캔이다.
    conn.execute(
        f"CREATE INDEX idx_price_lookup ON {OP.TABLE_NAME} (lawd_cd, jibun)"
    )
    conn.commit()


def write_meta(conn: sqlite3.Connection, meta: dict[str, str]) -> None:
    conn.executemany(
        f"INSERT OR REPLACE INTO {OP.META_TABLE} (key, value) VALUES (?, ?)",
        list(meta.items()),
    )
    conn.commit()


# ── 자기검증 ─────────────────────────────────────────────────────────────────


def self_check(
    conn: sqlite3.Connection,
    path: Path,
    member: str | None,
    cfg: PS.PriceSourceConfig,
    idx: dict[str, int],
    multiplier: int,
) -> tuple[int, int, list[str]]:
    """무작위 N건을 **원본 파일에서 다시 읽어** DB 값과 대조한다.

    ⚠ 이 검증은 파서가 옳다는 것을 증명하지 못한다 — 쓸 때와 **같은 파서**로 다시
      읽기 때문이다. 실제로 2026-08-05 이전에는 쉼표가 든 행을 양쪽에서 똑같이
      잘못 쪼개 '일치 10/10'이 나왔다. 그래서 이 검증의 값어치는 파서가 표준
      규칙(csv)을 따를 때 비로소 생긴다.
    """
    rows = conn.execute(
        f"SELECT * FROM {OP.TABLE_NAME} ORDER BY RANDOM() LIMIT {SAMPLE_CHECK}"
    ).fetchall()
    if not rows:
        return 0, 0, ["DB가 비어 있어 검증할 수 없습니다"]
    wanted = {r[11]: r for r in rows}  # src_line(레코드 번호) → row (컬럼 순서는 CREATE TABLE 그대로)

    _, reader, close = open_records(path, member, cfg)
    found: dict[int, list[str]] = {}
    try:
        for rec_no, cells in enumerate(reader, start=1):
            if rec_no in wanted:
                found[rec_no] = [c.strip() for c in cells]
                if len(found) == len(wanted):
                    break
    finally:
        close()

    resolver = LawdResolver()
    stats = SkipStats()
    ok = 0
    problems: list[str] = []
    for line_no, db_row in wanted.items():
        cells = found.get(line_no)
        if cells is None:
            problems.append(f"원본 {line_no}번째 줄을 다시 찾지 못했습니다")
            continue
        rebuilt = normalize_row(cfg, idx, cells, line_no, resolver, multiplier, stats)
        if rebuilt is None:
            problems.append(f"원본 {line_no}번째 줄이 이번엔 걸러졌습니다 (재현 불가)")
            continue
        db_tuple = tuple(db_row)[1:]  # id 제외
        if _same(rebuilt, db_tuple):
            ok += 1
        else:
            problems.append(
                f"원본 {line_no}번째 줄 불일치\n"
                f"      DB : {db_tuple}\n"
                f"      원본: {rebuilt}"
            )
    return ok, len(wanted), problems


def _same(a: tuple, b: tuple) -> bool:
    if len(a) != len(b):
        return False
    for x, y in zip(a, b):
        if isinstance(x, float) or isinstance(y, float):
            if x is None or y is None:
                if x is not y:
                    return False
                continue
            if abs(float(x) - float(y)) > 1e-6:
                return False
        elif x != y:
            return False
    return True


# ── 본체 ─────────────────────────────────────────────────────────────────────


def main() -> int:
    ap = argparse.ArgumentParser(description="공시가격·기준시가 CSV → SQLite")
    ap.add_argument("path", help="원본 CSV 또는 ZIP")
    ap.add_argument("--source", required=True, choices=PS.ALL_SOURCES)
    ap.add_argument("--member", help="zip 안에서 읽을 파일 이름")
    ap.add_argument(
        "--region",
        action="append",
        default=[],
        help="지역 필터 — 시도/시군구 이름 조각 또는 코드 앞자리(예: --region 서울 --region 경기). "
        "여러 번 줄 수 있고, 하나라도 걸리면 담는다. 없으면 전국.",
    )
    ap.add_argument("--limit", type=int, default=0, help="이 행 수만 처리 (0=전체, 시험용)")
    args = ap.parse_args()

    path = Path(args.path)
    if not path.exists():
        print(f"[중단] 파일이 없습니다: {path}")
        return 2

    try:
        cfg = PS.load(args.source)
        cfg.require_ready()
    except PS.PriceSourceNotReady as e:
        print("[중단]", e)
        return 2

    multiplier = cfg.price_multiplier()

    # 헤더 → 정규 필드 인덱스
    name, reader, close = open_records(path, args.member, cfg)
    try:
        header = [c.strip() for c in next(reader, [])]
        if not header:
            print("[중단] 파일이 비어 있거나 첫 줄을 읽지 못했습니다.")
            return 2
        if not cfg.has_header:
            header = [f"col{i + 1}" for i in range(len(header))]
    except UnicodeDecodeError as e:
        # 조용히 깨진 글자로 진행하지 않는다 — 인코딩이 틀리면 컬럼 이름부터 어긋난다.
        print(
            f"[중단] 파일을 {cfg.file_encoding} 로 읽지 못했습니다 ({e}).\n"
            f"  → python scripts/inspect_price_source.py {path} 로 인코딩을 다시 판별하고\n"
            f"    price_sources.json 의 file_encoding 을 고치세요."
        )
        return 2
    finally:
        close()

    idx: dict[str, int] = {}
    missing_cols: list[str] = []
    for field, col in cfg.columns.items():
        if not col:
            continue
        if col in header:
            idx[field] = header.index(col)
        elif not cfg.has_header and col.startswith("col") and col[3:].isdigit():
            idx[field] = int(col[3:]) - 1
        else:
            missing_cols.append(f"{field} → '{col}'")
    if missing_cols:
        print("[중단] 설정에 적힌 컬럼을 파일에서 찾지 못했습니다:")
        for m in missing_cols:
            print("   ·", m)
        print("\n  파일의 실제 컬럼:")
        print("   ", header)
        print(
            f"\n  → python scripts/inspect_price_source.py {path} --source {args.source} --write "
            "로 다시 초안을 만드세요."
        )
        return 2

    db = OP.db_path(args.source)
    print(f"원본   : {path}  ({name})")
    print(f"인코딩 : {cfg.file_encoding} · 구분자 {cfg.delimiter!r} · 헤더 {cfg.has_header}")
    print(f"가격   : 단위 {cfg.price_unit}(×{multiplier:,}) · 총액여부 {cfg.price_is_total}")
    print(f"기준일 : {cfg.as_of or '(행별 컬럼 사용)'}")
    print(f"출력   : {db}")
    if args.region:
        print(f"지역   : {', '.join(args.region)} 만 담습니다")
    print()

    conn = create_db(db)
    resolver = LawdResolver()
    stats = SkipStats()
    inserted = 0
    read = 0
    t0 = time.perf_counter()
    buf: list[tuple] = []

    region_keys = [r.strip() for r in args.region if r.strip()]
    region_fields = [f for f in ("sido", "sigungu", "umd") if f in idx]

    def region_ok(cells: list[str], lawd_prefix_source: str) -> bool:
        if not region_keys:
            return True
        for key in region_keys:
            if key.isdigit() and lawd_prefix_source.startswith(key):
                return True
            for f in region_fields:
                i = idx[f]
                if i < len(cells) and key in cells[i]:
                    return True
        return False

    name, reader, close = open_records(path, args.member, cfg)
    try:
        start_line = 2 if cfg.has_header else 1
        for line_no, raw_cells in enumerate(reader, start=1):
            if line_no < start_line:
                continue
            if not raw_cells or (len(raw_cells) == 1 and not raw_cells[0].strip()):
                continue  # 빈 줄
            cells = [c.strip() for c in raw_cells]
            read += 1

            bjd = cells[idx["bjd_cd"]] if "bjd_cd" in idx and idx["bjd_cd"] < len(cells) else ""
            if not region_ok(cells, bjd):
                stats.region_filtered += 1
            else:
                row = normalize_row(cfg, idx, cells, line_no, resolver, multiplier, stats)
                if row is not None:
                    buf.append(row)
                    if len(buf) >= BATCH:
                        conn.executemany(
                            f"INSERT INTO {OP.TABLE_NAME} (lawd_cd, bjd_cd, umd, jibun, dong_nm,"
                            f" ho_nm, area_sqm, area_common_sqm, price_won, as_of, src_line)"
                            f" VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                            buf,
                        )
                        inserted += len(buf)
                        buf.clear()
                        el = time.perf_counter() - t0
                        print(
                            f"  ... 읽음 {read:,} / 담음 {inserted:,} / 버림 {stats.total():,}"
                            f" / 지역제외 {stats.region_filtered:,}  ({el:.0f}초)",
                            flush=True,
                        )
            if args.limit and read >= args.limit:
                break
    finally:
        close()

    if buf:
        conn.executemany(
            f"INSERT INTO {OP.TABLE_NAME} (lawd_cd, bjd_cd, umd, jibun, dong_nm,"
            f" ho_nm, area_sqm, area_common_sqm, price_won, as_of, src_line)"
            f" VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            buf,
        )
        inserted += len(buf)
    conn.commit()

    print("\n인덱스 만드는 중 ...")
    build_indexes(conn)
    elapsed = time.perf_counter() - t0

    as_of_row = conn.execute(
        f"SELECT as_of, COUNT(*) c FROM {OP.TABLE_NAME} GROUP BY as_of ORDER BY c DESC LIMIT 1"
    ).fetchone()
    write_meta(
        conn,
        {
            "schema_version": str(OP.SCHEMA_VERSION),
            "source_key": args.source,
            "source_name": cfg.source_name,
            "source_file": path.name,
            "member": name,
            "row_count": str(inserted),
            "as_of": (as_of_row[0] if as_of_row else (cfg.as_of or "")),
            "region_filter": ",".join(region_keys),
            "price_unit": cfg.price_unit or "",
            "price_is_total": str(cfg.price_is_total),
            "built_seconds": f"{elapsed:.1f}",
        },
    )

    size_mb = db.stat().st_size / (1 << 20)
    print("═" * 78)
    print("변환 결과")
    print("═" * 78)
    print(f"  읽은 줄     : {read:,}")
    print(f"  담은 행     : {inserted:,}")
    print(f"  지역 제외   : {stats.region_filtered:,}")
    print(f"  버린 행     : {stats.total():,}")
    for line in stats.lines():
        print(line)
    for line in stats.warnings():
        print(line)
    print(f"  DB 크기     : {size_mb:,.1f} MB")
    print(f"  소요        : {elapsed:.1f}초")
    print(f"  기준일      : {as_of_row[0] if as_of_row else '(없음)'}")
    print()

    print("자기검증 — 무작위 10건을 원본에서 다시 읽어 대조")
    ok, total, problems = self_check(conn, path, args.member, cfg, idx, multiplier)
    print(f"  일치 {ok}/{total}")
    for p in problems:
        print("    ❌", p)
    conn.close()

    if problems:
        print("\n⚠ 검증에 실패한 건이 있습니다. DB를 그대로 쓰지 마세요.")
        return 1
    print("\n✅ 검증 통과. 다음: python scripts/price_status.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
