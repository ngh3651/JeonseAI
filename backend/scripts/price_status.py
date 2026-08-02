"""시세 자동조회 **준비 상태 점검** CLI (개발 도구 — 외부 호출 없음).

데이터를 넣고 **가장 먼저** 실행하는 도구다. 지금 어디까지 됐고 다음에 무엇을
하면 되는지를 한 화면에 보여준다.

    python scripts/price_status.py

⚠ 네트워크를 쓰지 않는다(키가 '있는지'만 본다 — 유효한지는 확인하지 않는다).
⚠ 개인정보를 출력하지 않는다. 키 값도 찍지 않는다.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from dotenv import load_dotenv  # noqa: E402

from app.services import lawd_code, official_price as OP  # noqa: E402
from app.services import price_sources as PS  # noqa: E402

BACKEND = Path(__file__).resolve().parents[1]

OK = "✅"
NO = "❌"
WARN = "⚠️ "

RAW_PATTERNS = ("*.csv", "*.zip", "*.txt")


def find_raw(keywords: tuple[str, ...]) -> list[Path]:
    """data/price/raw/ 에서 키워드가 이름에 든 파일을 찾는다."""
    if not OP.RAW_DIR.exists():
        return []
    hits: list[Path] = []
    for pat in RAW_PATTERNS:
        for p in sorted(OP.RAW_DIR.glob(pat)):
            name = p.name.replace(" ", "")
            if any(k in name for k in keywords) or not keywords:
                hits.append(p)
    return hits


def section(title: str) -> None:
    print()
    print("─" * 74)
    print(f" {title}")
    print("─" * 74)


def line(mark: str, label: str, detail: str = "") -> None:
    print(f"  {mark} {label}" + (f" — {detail}" if detail else ""))


def todo(*lines: str) -> None:
    for ln in lines:
        print(f"       → {ln}")


def check_molit_key() -> bool:
    load_dotenv(dotenv_path=BACKEND / ".env")
    key = (os.environ.get("MOLIT_API_KEY") or "").strip()
    if key:
        line(OK, "국토부 실거래가 API 키 (MOLIT_API_KEY)", f"설정됨 ({len(key)}자)")
        return True
    line(NO, "국토부 실거래가 API 키 (MOLIT_API_KEY)", "없음")
    todo(
        "https://www.data.go.kr 에서 '국토교통부_아파트 매매 실거래가' 활용 신청",
        "발급된 키를 backend/.env 에 MOLIT_API_KEY=... 로 추가",
        "키가 없어도 공시가격·기준시가 조회는 동작합니다 (실거래가만 빠짐)",
    )
    return False


def check_lawd() -> bool:
    path = lawd_code.LAWD_CODE_FILE
    if not path.exists():
        line(NO, "법정동코드 파일", f"없음 ({path})")
        todo(
            "https://www.code.go.kr → 법정동코드 → '법정동코드 전체자료' 내려받기",
            f"압축을 풀어 {path} 로 저장 (인코딩 cp949 그대로)",
        )
        return False
    try:
        rows = lawd_code._load_rows()
    except lawd_code.LawdCodeError as e:
        line(NO, "법정동코드 파일", f"읽지 못함 — {e}")
        return False
    size = path.stat().st_size / (1 << 20)
    line(OK, "법정동코드 파일", f"{size:,.1f} MB · 시군구 행 {len(rows):,}개")
    return True


def check_source(key: str, keywords: tuple[str, ...], label: str) -> bool:
    section(label)

    raws = find_raw(keywords)
    if raws:
        for p in raws:
            line(OK, "원본 파일", f"{p.name} ({p.stat().st_size / (1 << 20):,.1f} MB)")
    else:
        line(NO, "원본 파일", f"{OP.RAW_DIR} 에서 못 찾음")
        todo(
            f"파일을 {OP.RAW_DIR} 에 둔다 (CSV 또는 ZIP 그대로)",
            "이름에 위 키워드가 없어도 됩니다 — 아래 명령에 경로를 직접 주면 됩니다",
        )

    try:
        cfg = PS.load(key)
    except PS.PriceSourceNotReady as e:
        line(NO, "컬럼 매핑", str(e).splitlines()[0])
        return False

    missing = cfg.missing_items()
    if missing:
        line(NO, "컬럼 매핑", f"미설정 {len(missing)}건")
        for m in missing:
            print(f"       · {m}")
        example = raws[0] if raws else Path("<원본파일>")
        todo(
            f"python scripts/inspect_price_source.py {example} --source {key} --write",
            "출력된 제안을 검토하고 backend/data/price_sources.json 을 고친다",
            "price_unit · price_is_total · as_of 를 채우고 verified 를 true 로",
        )
    else:
        line(OK, "컬럼 매핑", f"준비됨 (기준일 {cfg.as_of or '행별 컬럼'}, 단위 {cfg.price_unit})")

    db = OP.db_path(key)
    meta = OP.db_meta(key)
    if meta:
        line(
            OK,
            "SQLite",
            f"{db.name} · {int(meta.get('row_count', 0)):,}행 · "
            f"{db.stat().st_size / (1 << 20):,.1f} MB · 기준일 {meta.get('as_of') or '?'}"
            + (f" · 지역필터 {meta['region_filter']}" if meta.get("region_filter") else ""),
        )
        if meta.get("schema_version") != str(OP.SCHEMA_VERSION):
            line(WARN, "SQLite 스키마 버전", f"{meta.get('schema_version')} ≠ {OP.SCHEMA_VERSION} — 다시 빌드하세요")
            return False
        return True

    if db.exists():
        line(WARN, "SQLite", f"{db.name} 은 있는데 메타를 읽지 못했습니다 — 손상 가능성")
        todo(f"python scripts/build_price_db.py --source {key} <원본파일>  (다시 빌드)")
        return False

    line(NO, "SQLite", f"없음 ({db})")
    if not missing:
        example = raws[0] if raws else Path("<원본파일>")
        todo(f"python scripts/build_price_db.py --source {key} {example}")
    return False


def main() -> int:
    print("═" * 74)
    print(" 시세 자동조회 — 준비 상태")
    print("═" * 74)

    section("① 국토부 실거래가 (거래가 있는 집만 — 커버리지 낮음)")
    key_ok = check_molit_key()
    lawd_ok = check_lawd()

    op_ok = check_source(
        PS.SOURCE_OFFICIAL_PRICE,
        ("공동주택", "공시가격", "apt", "official"),
        "② 국토교통부 공동주택 공시가격 (아파트·연립·다세대)",
    )
    tb_ok = check_source(
        PS.SOURCE_TAX_BASE,
        ("기준시가", "오피스텔", "offi", "tax"),
        "③ 국세청 오피스텔 기준시가 (오피스텔)",
    )

    section("종합")
    line(OK if (key_ok and lawd_ok) else NO, "실거래가 조회", "가능" if (key_ok and lawd_ok) else "불가")
    line(OK if op_ok else NO, "공시가격 조회", "가능" if op_ok else "불가")
    line(OK if tb_ok else NO, "기준시가 조회", "가능" if tb_ok else "불가")
    print()
    if op_ok or tb_ok or (key_ok and lawd_ok):
        print("  한 가지라도 가능하면 analyze 흐름에서 시세 자동조회가 동작합니다.")
        print("  전부 불가여도 리포트는 그대로 완성됩니다 — 전세가율만 '확인 필요'로 남습니다.")
    else:
        print("  지금은 자동조회가 전혀 되지 않습니다. 사용자가 시세를 직접 넣어야 합니다.")
        print("  (리포트는 그래도 완성됩니다 — 전세가율·선순위 비율이 '확인 필요'가 될 뿐입니다)")
    print()
    print("  단독·다가구는 어느 소스로도 전세가율을 내지 않습니다 —")
    print("  등기부가 1개라 앞순위 세입자 보증금 합계를 알 수 없기 때문입니다(의도된 한계).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
