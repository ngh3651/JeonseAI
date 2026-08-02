"""공시가격·기준시가 **원본 파일 구조 탐지** CLI (개발 도구 — 외부 호출 없음).

파일이 도착했을 때 **가장 먼저** 실행하는 도구다. 컬럼 이름을 추측해서 코드에 박지
않기 위해, 실제 파일을 열어 무엇이 들어 있는지 사람에게 보여주고
`backend/data/price_sources.json` 초안을 만들어 준다.

사용법:
    python scripts/inspect_price_source.py <파일.csv|파일.zip> [--source official_price|tax_base]
                                            [--sample 2000] [--member 이름] [--write]

    # 1) 뭐가 들었는지 본다
    python scripts/inspect_price_source.py data/price/raw/공동주택공시가격.zip

    # 2) 확인했으면 매핑 초안을 써 넣는다 (verified 는 사람이 직접 true 로)
    python scripts/inspect_price_source.py data/price/raw/공동주택공시가격.zip \
        --source official_price --write

⚠ **전체 파일을 메모리에 올리지 않는다.** 공시가격은 1,500만 행을 넘길 수 있다.
  앞부분 표본만 읽어 컬럼을 보고, 행 수는 스트리밍으로 센다.
⚠ 개인정보를 출력하지 않는다 — 값 예시는 컬럼당 5개까지만 보여준다(주소·번지 포함
  가능성이 있으므로 이 출력을 그대로 문서·커밋에 붙여넣지 말 것).
"""

from __future__ import annotations

import argparse
import io
import re
import sys
import zipfile
from collections import Counter
from pathlib import Path
from statistics import median

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.services import price_sources as PS  # noqa: E402

# 시도해 볼 인코딩 — cp949 우선(정부 공개 CSV의 압도적 다수).
ENCODING_CANDIDATES = ("cp949", "utf-8-sig", "utf-8", "euc-kr", "utf-16")
DELIMITER_CANDIDATES = (",", "\t", "|", ";")

_HANGUL = re.compile(r"[가-힣]")
_NUM = re.compile(r"^-?\d+$")
_FLOAT = re.compile(r"^-?\d+\.\d+$")


# ── 파일 열기 (ZIP 안이어도 스트리밍) ────────────────────────────────────────


def list_members(path: Path) -> list[str]:
    if path.suffix.lower() != ".zip":
        return [path.name]
    with zipfile.ZipFile(path) as zf:
        return [i.filename for i in zf.infolist() if not i.is_dir()]


def open_binary(path: Path, member: str | None):
    """(이름, 바이너리 스트림, 압축 해제 크기) — 컨텍스트 매니저처럼 쓰지 않고 직접 닫는다."""
    if path.suffix.lower() != ".zip":
        return path.name, path.open("rb"), path.stat().st_size
    zf = zipfile.ZipFile(path)
    infos = [i for i in zf.infolist() if not i.is_dir()]
    if member:
        picked = next((i for i in infos if i.filename == member), None)
        if picked is None:
            raise SystemExit(f"[중단] zip 안에 {member!r} 가 없습니다. --member 로 골라 주세요.")
    else:
        data_like = [i for i in infos if i.filename.lower().endswith((".csv", ".txt", ".dat"))]
        pool = data_like or infos
        picked = max(pool, key=lambda i: i.file_size)
    return picked.filename, zf.open(picked, "r"), picked.file_size


# ── 인코딩·구분자 판별 ───────────────────────────────────────────────────────


def detect_encoding(head: bytes) -> tuple[str, str]:
    """(인코딩, 판단 근거). 실패하면 SystemExit."""
    reasons: list[str] = []
    for enc in ENCODING_CANDIDATES:
        try:
            text = head.decode(enc)
        except (UnicodeDecodeError, LookupError):
            reasons.append(f"{enc}: 디코드 실패")
            continue
        hangul = len(_HANGUL.findall(text))
        if hangul == 0 and enc in ("cp949", "euc-kr"):
            reasons.append(f"{enc}: 디코드는 됐지만 한글 0자 — 아닐 가능성")
            continue
        return enc, f"{enc} 로 디코드 성공 (표본에서 한글 {hangul}자 확인) / " + " · ".join(reasons)
    raise SystemExit(
        "[중단] 인코딩을 판별하지 못했습니다.\n  " + "\n  ".join(reasons)
        + "\n  → 파일을 메모장으로 열어 인코딩을 확인한 뒤 price_sources.json 의 file_encoding 에 직접 적으세요."
    )


def detect_delimiter(first_line: str) -> tuple[str, str]:
    counts = {d: first_line.count(d) for d in DELIMITER_CANDIDATES}
    best = max(counts, key=lambda d: counts[d])
    if counts[best] == 0:
        raise SystemExit(
            "[중단] 구분자를 찾지 못했습니다(쉼표·탭·파이프·세미콜론 모두 0개).\n"
            "  → 고정폭(fixed-width) 파일일 수 있습니다. 레이아웃참고자료를 확인하세요."
        )
    shown = {",": "쉼표", "\t": "탭", "|": "파이프", ";": "세미콜론"}
    detail = " · ".join(f"{shown[d]} {counts[d]}개" for d in DELIMITER_CANDIDATES)
    return best, f"첫 줄에서 {shown[best]}가 가장 많음 ({detail})"


def looks_like_header(cells: list[str]) -> tuple[bool, str]:
    """헤더처럼 보이나 — 숫자만인 칸이 거의 없고 중복이 없으면 헤더."""
    numeric = sum(1 for c in cells if _NUM.match(c.strip()) or _FLOAT.match(c.strip()))
    dup = len(cells) - len(set(c.strip() for c in cells))
    is_header = numeric <= len(cells) * 0.2 and dup == 0
    return is_header, f"{len(cells)}칸 중 숫자만인 칸 {numeric}개 · 중복 이름 {dup}개"


# ── 표본 읽기 ────────────────────────────────────────────────────────────────


def read_sample(path: Path, member: str | None, limit: int):
    name, raw, size = open_binary(path, member)
    try:
        head = raw.read(1 << 16)
        encoding, enc_reason = detect_encoding(head)
        raw.close()
    except Exception:
        raw.close()
        raise

    name, raw, size = open_binary(path, member)
    try:
        stream = io.TextIOWrapper(raw, encoding=encoding, newline="")
        first = stream.readline().rstrip("\r\n")
        delimiter, delim_reason = detect_delimiter(first)
        header_cells = first.split(delimiter)
        is_header, header_reason = looks_like_header(header_cells)

        columns = (
            [c.strip().strip('"') for c in header_cells]
            if is_header
            else [f"col{i + 1}" for i in range(len(header_cells))]
        )
        rows: list[list[str]] = []
        if not is_header:
            rows.append([c.strip().strip('"') for c in header_cells])
        for _ in range(limit):
            line = stream.readline()
            if not line:
                break
            cells = [c.strip().strip('"') for c in line.rstrip("\r\n").split(delimiter)]
            if len(cells) == 1 and not cells[0]:
                continue
            rows.append(cells)
    finally:
        raw.close()

    return {
        "member": name,
        "size": size,
        "encoding": encoding,
        "encoding_reason": enc_reason,
        "delimiter": delimiter,
        "delimiter_reason": delim_reason,
        "has_header": is_header,
        "header_reason": header_reason,
        "columns": columns,
        "rows": rows,
    }


def count_rows(path: Path, member: str | None, encoding: str) -> int:
    """전체 행 수 — **스트리밍으로 줄바꿈만 센다**(메모리 상수)."""
    _, raw, _ = open_binary(path, member)
    total = 0
    try:
        while True:
            chunk = raw.read(1 << 22)  # 4MB
            if not chunk:
                break
            total += chunk.count(b"\n")
    finally:
        raw.close()
    return total


# ── 컬럼 프로파일 ────────────────────────────────────────────────────────────


def profile(columns: list[str], rows: list[list[str]]) -> list[dict]:
    out = []
    for i, col in enumerate(columns):
        vals = [r[i].strip() for r in rows if i < len(r) and r[i].strip()]
        kinds = Counter(
            "int" if _NUM.match(v) else "float" if _FLOAT.match(v) else "text" for v in vals
        )
        kind = kinds.most_common(1)[0][0] if kinds else "empty"
        nums: list[float] = []
        if kind in ("int", "float"):
            for v in vals[:5000]:
                try:
                    nums.append(float(v))
                except ValueError:
                    pass
        widths = Counter(len(v) for v in vals[:5000])
        out.append(
            {
                "index": i,
                "name": col,
                "kind": kind,
                "filled": len(vals),
                "samples": vals[:5],
                "min": min(nums) if nums else None,
                "max": max(nums) if nums else None,
                "median": median(nums) if nums else None,
                "common_width": widths.most_common(1)[0][0] if widths else None,
                "distinct_in_sample": len(set(vals[:5000])),
            }
        )
    return out


# ── 필드 후보 제안 ───────────────────────────────────────────────────────────

# (정규 필드, 이름에 들어가면 가점되는 키워드, 값 조건 함수, 사람이 읽을 설명)
_NAME_HINTS: dict[str, tuple[str, ...]] = {
    "bjd_cd": ("법정동코드", "법정동_코드", "bjdcd", "법정동번호", "행정동코드"),
    "sido": ("시도", "시·도", "광역"),
    "sigungu": ("시군구", "시·군·구", "시군구명"),
    "umd": ("읍면동", "법정동명", "동명", "읍면동명", "리명"),
    "jibun_full": ("지번", "번지주소", "지번주소"),
    "jibun_bon": ("본번", "번지"),
    "jibun_bu": ("부번", "호"),
    "dong_nm": ("동명칭", "단지동", "건물동", "동주소", "동번호"),
    "ho_nm": ("호명칭", "호수", "호주소", "호번호"),
    "area_sqm": ("전용면적", "전용", "공급면적", "면적"),
    "area_common_sqm": ("공유면적", "공용면적", "공유", "공용"),
    "price": ("공시가격", "기준시가", "고시가격", "가격", "금액", "공시"),
    "as_of": ("고시일자", "기준일", "공시기준일", "일자", "기준년월"),
}


def _score(field: str, col: dict) -> tuple[int, list[str]]:
    name = col["name"].replace(" ", "")
    reasons: list[str] = []
    score = 0
    for rank, kw in enumerate(_NAME_HINTS.get(field, ())):
        if kw in name:
            bonus = 40 - rank * 3
            score += bonus
            reasons.append(f"이름에 '{kw}' 포함(+{bonus})")
            break

    kind, med, width = col["kind"], col["median"], col["common_width"]
    if field == "bjd_cd":
        if kind == "int" and width == 10:
            score += 40
            reasons.append("값이 10자리 정수(+40) — 법정동코드 자릿수")
        elif kind == "int" and width in (5, 8):
            score += 15
            reasons.append(f"값이 {width}자리 정수(+15)")
    elif field in ("area_sqm", "area_common_sqm"):
        if kind == "float" and med is not None and 5 <= med <= 400:
            score += 35
            reasons.append(f"값이 소수이고 중앙값 {med:.2f}(+35) — ㎡ 범위")
        elif kind == "float":
            score += 10
            reasons.append("값이 소수(+10)")
    elif field == "price":
        if kind == "int" and med is not None and med >= 1_000:
            score += 35
            reasons.append(f"값이 큰 정수, 중앙값 {med:,.0f}(+35)")
    elif field == "as_of":
        if kind == "int" and width in (6, 8):
            score += 30
            reasons.append(f"값이 {width}자리 정수(+30) — 날짜 형태")
        elif kind == "text" and med is None and col["samples"] and "-" in col["samples"][0]:
            score += 20
            reasons.append("값에 '-' 포함(+20) — 날짜 형태")
    elif field in ("sido", "sigungu", "umd"):
        if kind == "text" and col["samples"] and _HANGUL.search(col["samples"][0]):
            score += 20
            reasons.append("값이 한글 텍스트(+20)")
        if field == "sido" and col["distinct_in_sample"] <= 20:
            score += 15
            reasons.append(f"표본 내 고유값 {col['distinct_in_sample']}개(+15) — 시도 수준")
    elif field in ("jibun_bon", "jibun_bu", "jibun_full"):
        if kind in ("int", "text"):
            score += 10
            reasons.append("정수/문자 값(+10)")
    elif field in ("dong_nm", "ho_nm"):
        if kind in ("int", "text"):
            score += 10
            reasons.append("정수/문자 값(+10)")
    return score, reasons


def suggest(cols: list[dict]) -> dict[str, list[tuple[int, dict, list[str]]]]:
    out: dict[str, list[tuple[int, dict, list[str]]]] = {}
    for field in PS.CANONICAL_FIELDS:
        ranked = []
        for col in cols:
            s, reasons = _score(field, col)
            if s > 0:
                ranked.append((s, col, reasons))
        ranked.sort(key=lambda t: -t[0])
        out[field] = ranked[:3]
    return out


# ── 가격 단위·총액 여부 추정 ────────────────────────────────────────────────


def estimate_price_semantics(price_col: dict | None, area_cols: list[dict]) -> list[str]:
    """가격 컬럼의 단위(원/천원/만원)와 총액 여부를 **근거와 함께** 추정한다.

    ⚠ 결론을 자동으로 설정에 쓰지 않는다. 사람이 읽고 고르게 한다.
    """
    lines: list[str] = []
    if price_col is None or price_col["median"] is None:
        return ["가격 후보 컬럼을 찾지 못해 단위를 추정할 수 없습니다."]

    med = price_col["median"]
    lines.append(f"가격 컬럼 '{price_col['name']}' 중앙값 = {med:,.0f}")
    lines.append(f"  범위: {price_col['min']:,.0f} ~ {price_col['max']:,.0f}")

    area_med = None
    if area_cols:
        area_med = sum(c["median"] or 0 for c in area_cols)
        lines.append(
            "  면적 합(전용" + ("+공유" if len(area_cols) > 1 else "") + ") 중앙값 = "
            f"{area_med:,.2f}㎡"
        )

    lines.append("")
    lines.append("  단위별로 '호별 총액'이 얼마가 되는지:")
    for unit, mult in PS.PRICE_UNIT_MULTIPLIER.items():
        total_won = med * mult
        line = f"    · price_unit={unit:<13} 총액으로 보면 {_eok(total_won)}"
        if area_med:
            line += f" / ㎡단가로 보면 {_eok(total_won * area_med)}"
        lines.append(line)

    lines.append("")
    lines.append("  판단 기준 (사람이 고른다):")
    lines.append("    공동주택 공시가격 호별 총액은 보통 수천만원 ~ 수십억원 범위다.")
    lines.append("    오피스텔 기준시가도 호별 총액은 수천만원 ~ 수억원 범위다.")
    lines.append("    위 표에서 **현실적인 금액이 나오는 조합**을 골라")
    lines.append("    price_unit 과 price_is_total 에 적고 verified 를 true 로 바꾼다.")
    return lines


def _eok(won: float) -> str:
    if won >= 100_000_000:
        return f"{won / 100_000_000:.2f}억원"
    if won >= 10_000:
        return f"{won / 10_000:,.0f}만원"
    return f"{won:,.0f}원"


# ── 출력 ─────────────────────────────────────────────────────────────────────


def main() -> int:
    ap = argparse.ArgumentParser(description="공시가격·기준시가 원본 구조 탐지")
    ap.add_argument("path", help="CSV 또는 ZIP 경로")
    ap.add_argument("--source", choices=PS.ALL_SOURCES, help="--write 할 때 어느 소스인지")
    ap.add_argument("--member", help="zip 안에서 읽을 파일 이름")
    ap.add_argument("--sample", type=int, default=2000, help="표본 행 수 (기본 2000)")
    ap.add_argument("--no-count", action="store_true", help="전체 행 수 세기를 건너뛴다")
    ap.add_argument("--write", action="store_true", help="price_sources.json 에 초안을 써 넣는다")
    args = ap.parse_args()

    path = Path(args.path)
    if not path.exists():
        print(f"[중단] 파일이 없습니다: {path}")
        return 2

    if path.suffix.lower() == ".zip":
        print("═" * 78)
        print("ZIP 내용")
        print("═" * 78)
        for m in list_members(path):
            print(f"  · {m}")
        print()

    info = read_sample(path, args.member, args.sample)

    print("═" * 78)
    print("파일 개요")
    print("═" * 78)
    print(f"  경로       : {path}")
    print(f"  대상       : {info['member']}")
    print(f"  크기       : {info['size'] / (1 << 20):,.1f} MB (압축 해제 기준)")
    print(f"  인코딩     : {info['encoding']}")
    print(f"      근거   : {info['encoding_reason']}")
    print(f"  구분자     : {info['delimiter']!r}")
    print(f"      근거   : {info['delimiter_reason']}")
    print(f"  헤더       : {'있음' if info['has_header'] else '없음(col1.. 로 이름 붙임)'}")
    print(f"      근거   : {info['header_reason']}")
    print(f"  컬럼 수    : {len(info['columns'])}")
    print(f"  표본 행 수 : {len(info['rows'])}")
    if not args.no_count:
        total = count_rows(path, args.member, info["encoding"])
        print(f"  전체 행 수 : {total:,} (줄바꿈 기준, 헤더 포함)")
    print()

    cols = profile(info["columns"], info["rows"])

    print("═" * 78)
    print("컬럼 전체 (값 예시 5개)")
    print("═" * 78)
    for c in cols:
        stat = ""
        if c["median"] is not None:
            stat = f"  [min {c['min']:,.4g} / 중앙 {c['median']:,.4g} / max {c['max']:,.4g}]"
        print(f"  [{c['index']:>3}] {c['name']}   ({c['kind']}, 채워짐 {c['filled']}){stat}")
        print(f"        예시: {c['samples']}")
    print()

    ranked = suggest(cols)
    print("═" * 78)
    print("우리가 필요한 필드 → 후보 컬럼 제안 (근거 포함)")
    print("═" * 78)
    draft_columns: dict[str, str | None] = {}
    for field in PS.CANONICAL_FIELDS:
        cands = ranked[field]
        if not cands:
            print(f"  {field:<16} → (후보 없음)")
            draft_columns[field] = None
            continue
        top_score, top_col, top_reasons = cands[0]
        draft_columns[field] = top_col["name"]
        print(f"  {field:<16} → '{top_col['name']}'  (점수 {top_score})")
        print(f"      근거: {' · '.join(top_reasons)}")
        for s, col, reasons in cands[1:]:
            print(f"      대안: '{col['name']}' (점수 {s}) — {' · '.join(reasons)}")
    print()

    price_col = ranked["price"][0][1] if ranked["price"] else None
    area_cols = [ranked[f][0][1] for f in ("area_sqm", "area_common_sqm") if ranked[f]]
    print("═" * 78)
    print("가격 단위·총액 여부 추정 (자동 확정하지 않는다)")
    print("═" * 78)
    for line in estimate_price_semantics(price_col, area_cols):
        print("  " + line)
    print()

    if args.write:
        if not args.source:
            print("[중단] --write 하려면 --source official_price|tax_base 를 함께 주세요.")
            return 2
        saved = PS.write_draft(
            args.source,
            {
                "file_encoding": info["encoding"],
                "delimiter": info["delimiter"],
                "has_header": info["has_header"],
                "columns": draft_columns,
            },
        )
        print("═" * 78)
        print(f"초안을 저장했습니다: {saved}")
        print("═" * 78)
        print("  아직 쓸 수 없습니다. 사람이 다음 3가지를 채워야 합니다:")
        print("    ① price_unit      (won / thousand_won / man_won)")
        print("    ② price_is_total  (호별 총액이면 true, ㎡당 단가면 false)")
        print("    ③ as_of           (기준일 'YYYY-MM-DD')")
        print("  그리고 columns 를 위 제안과 대조해 확인한 뒤 verified 를 true 로 바꾸세요.")
        print("  확인이 끝나면:  python scripts/price_status.py")
    else:
        print("(설정 파일에 쓰려면 --source <키> --write 를 붙여 다시 실행하세요)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
