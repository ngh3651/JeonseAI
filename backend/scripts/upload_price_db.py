"""시세 DB를 GitHub 릴리스에 올리고, Railway에 넣을 `PRICE_DB_URLS` 한 줄을 알려 준다 (2026-10-24).

왜: 서버(Railway)에는 시세 DB가 없다(`GET /`의 `priceDb:false`) → 시세 자동 조회가 실거래가만 쓰고 자주 실패한다.
DB는 git에 넣기엔 크다. 그래서 **압축(.gz)해서 GitHub 릴리스 파일로 올리고**, 서버는 시작할 때
`PRICE_DB_URLS`의 주소에서 내려받는다(`scripts/prepare_runtime.py` — 이미 있는 기능).

쓰는 법 (규혁 PC, 한 줄):

    cd backend && python scripts/upload_price_db.py

필요한 것: `backend/data/price/official_price.sqlite`·`tax_base.sqlite`(이미 PC에 있음),
GitHub CLI `gh`(없으면 `winget install --id GitHub.cli` → `gh auth login` 한 번).
끝나면 화면에 나온 `PRICE_DB_URLS=...` 값을 Railway Variables에 넣고 **Deploy**를 누른다.

⚠ 시세 DB는 공개 데이터(국토부 공시가격·국세청 기준시가)로 만든 것이라 공개 저장소의 릴리스에 올려도 된다.
⚠ 파일 하나가 GitHub 한도(2GB)를 넘으면 멈추고 알려 준다.
"""

from __future__ import annotations

import argparse
import gzip
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8")  # 윈도 콘솔에서 한글·✅가 깨지지 않게
    except Exception:  # noqa: BLE001
        pass

BACKEND = Path(__file__).resolve().parents[1]
REPO = "ngh3651/JeonseAI"
FILES = ("official_price.sqlite", "tax_base.sqlite")
GITHUB_ASSET_LIMIT = 2 * 1024**3  # GitHub 릴리스 파일 하나의 한도
KST = timezone(timedelta(hours=9))


def compress(src: Path, out_dir: Path) -> Path:
    """`src` → `out_dir/<이름>.gz` (이미 있고 원본보다 새로우면 다시 만들지 않는다)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    dest = out_dir / (src.name + ".gz")
    if dest.exists() and dest.stat().st_mtime >= src.stat().st_mtime:
        return dest
    tmp = dest.with_name(dest.name + ".part")
    with open(src, "rb") as fin, gzip.open(tmp, "wb", compresslevel=6) as fout:
        shutil.copyfileobj(fin, fout, 4 * 1024 * 1024)
    tmp.replace(dest)
    return dest


def download_urls(tag: str, names: list[str]) -> str:
    """서버가 내려받을 주소 목록 — `PRICE_DB_URLS` 값 그대로."""
    return ",".join(f"https://github.com/{REPO}/releases/download/{tag}/{n}" for n in names)


def _gh(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["gh", *args], capture_output=True, text=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--price-dir", default=str(BACKEND / "data" / "price"))
    ap.add_argument("--tag", default="price-db-" + datetime.now(KST).strftime("%Y%m%d"))
    args = ap.parse_args()

    price_dir = Path(args.price_dir)
    missing = [n for n in FILES if not (price_dir / n).is_file()]
    if missing:
        print(f"[중단] 시세 DB가 없어요: {', '.join(missing)} ({price_dir})")
        print("       만들기: python scripts/build_price_db.py --source official_price <원본>")
        return 1
    if shutil.which("gh") is None:
        print("[중단] GitHub CLI(gh)가 없어요 → winget install --id GitHub.cli  그다음  gh auth login")
        return 1
    if _gh("auth", "status").returncode != 0:
        print("[중단] gh 로그인이 안 돼 있어요 → gh auth login")
        return 1

    out_dir = BACKEND / "out" / "price_upload"  # out/은 git에 안 올라간다
    assets: list[Path] = []
    for name in FILES:
        src = price_dir / name
        print(f"압축 중: {name} ({src.stat().st_size / 1024**2:,.0f}MB) — 몇 분 걸릴 수 있어요")
        gz = compress(src, out_dir)
        size = gz.stat().st_size
        print(f"  → {gz.name} {size / 1024**2:,.0f}MB")
        if size > GITHUB_ASSET_LIMIT:
            print(f"[중단] {gz.name}이 GitHub 한도(2GB)를 넘어요 — 채팅에 알려 주세요")
            return 1
        assets.append(gz)

    if _gh("release", "view", args.tag, "-R", REPO).returncode != 0:
        print(f"릴리스 만드는 중: {args.tag}")
        r = _gh(
            "release", "create", args.tag, "-R", REPO,
            "--title", f"시세 DB {args.tag[-8:]}",
            "--notes", "서버 시작 때 PRICE_DB_URLS로 내려받는 시세 DB(공시가격·기준시가). 앱 설치 파일 아님.",
            "--latest=false",
        )
        if r.returncode != 0:
            print(f"[중단] 릴리스를 못 만들었어요: {r.stderr.strip()[:300]}")
            return 1
    for gz in assets:
        print(f"올리는 중: {gz.name} (크기에 따라 몇 분)")
        r = _gh("release", "upload", args.tag, str(gz), "--clobber", "-R", REPO)
        if r.returncode != 0:
            print(f"[중단] 올리기 실패: {r.stderr.strip()[:300]}")
            return 1

    print("\n✅ 끝. Railway → jeonseai 서비스 → Variables에 아래 한 줄을 넣고 Deploy를 누르세요:\n")
    print(f"PRICE_DB_URLS={download_urls(args.tag, [g.name for g in assets])}")
    print("\n배포 뒤 몇 분 지나면 서버 상태(GET /)의 priceDb가 true가 됩니다.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
