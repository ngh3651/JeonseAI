"""서버 시작 전 준비 — 클라우드(Railway)에서 컨테이너가 뜰 때마다 한 번 돈다 (2026-10-21).

하는 일 (전부 **이미 돼 있으면 건너뛴다** = 몇 번 돌려도 같다):
1. 폴더 만들기 — `DATA_DIR`(기록 DB) · `PRICE_DB_DIR`(시세 DB) · `PRECEDENT_INDEX_DIR`(판례 인덱스)
2. 시세 DB가 없고 `PRICE_DB_URLS`가 있으면 내려받기
   - 쉼표로 구분한 주소 목록. 파일 이름이 `official_price.sqlite(.gz)` / `tax_base.sqlite(.gz)`여야 한다
   - 3번까지 다시 시도, 크기를 로그로 남기고, **임시 파일에 받은 뒤 이름을 바꿔** 반쯤 받은 파일이 남지 않게 한다
3. 판례 인덱스가 없고 `BUILD_PRECEDENT_INDEX=1`이고 Upstage 키가 있으면 인덱스 만들기
   - ⚠ 임베딩 크레딧을 **한 번** 쓴다(판례 161건). 볼륨에 남으므로 다음 시작부터는 건너뛴다

⚠ **절대 서버 시작을 막지 않는다.** 무엇이 실패해도 경고만 남기고 종료 코드 0으로 끝난다 —
  시세 DB가 없어도 분석은 된다(시세는 '확인 필요'로 남는다). 판례가 없어도 리포트는 나온다.
⚠ 키 값·주소의 쿼리 문자열(토큰이 들어 있을 수 있다)은 로그에 찍지 않는다.

실행: `python scripts/prepare_runtime.py` (Dockerfile의 시작 명령이 uvicorn 앞에서 부른다)
"""

from __future__ import annotations

import gzip
import os
import shutil
import sys
import time
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

from app import settings  # noqa: E402

PRICE_DB_FILENAMES = ("official_price.sqlite", "tax_base.sqlite")
RETRIES = 3
CHUNK = 1024 * 1024
DOWNLOAD_TIMEOUT_SECONDS = 60


def log(msg: str) -> None:
    print(f"[준비] {msg}", flush=True)


def _safe_url(url: str) -> str:
    """로그용 — 쿼리 문자열(서명 토큰 등)을 뗀다."""
    parts = urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}{parts.path}"


def _target_name(url: str) -> str | None:
    """주소의 파일 이름 → 저장할 DB 이름. 모르는 이름이면 None."""
    name = Path(urlsplit(url).path).name
    if name.endswith(".gz"):
        name = name[: -len(".gz")]
    return name if name in PRICE_DB_FILENAMES else None


def _human(n: int) -> str:
    return f"{n / 1024 / 1024:,.1f}MB"


def download(url: str, dest: Path, *, opener=urllib.request.urlopen) -> bool:
    """`url` → `dest`. `.gz`면 풀면서 받는다. 성공하면 True. 예외를 밖으로 내지 않는다."""
    gz = urlsplit(url).path.endswith(".gz")
    tmp = dest.with_name(dest.name + ".part")
    for attempt in range(1, RETRIES + 1):
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            t0 = time.perf_counter()
            with opener(url, timeout=DOWNLOAD_TIMEOUT_SECONDS) as resp, open(tmp, "wb") as out:
                stream = gzip.GzipFile(fileobj=resp) if gz else resp
                shutil.copyfileobj(stream, out, CHUNK)
            size = tmp.stat().st_size
            if size == 0:
                raise OSError("빈 파일")
            with open(tmp, "rb") as f:
                if f.read(16) != b"SQLite format 3\x00":
                    raise OSError("SQLite 파일이 아님")
            os.replace(tmp, dest)  # 원자적 교체 — 반쯤 받은 파일이 DB 이름으로 남지 않는다
            log(f"내려받기 완료: {dest.name} {_human(size)} ({time.perf_counter() - t0:.0f}초)")
            return True
        except Exception as e:  # noqa: BLE001 — 준비 단계는 서버 시작을 막지 않는다
            log(f"⚠ 내려받기 실패 {attempt}/{RETRIES}: {_safe_url(url)} ({type(e).__name__}: {e})")
            try:
                tmp.unlink(missing_ok=True)
            except OSError:
                pass
            if attempt < RETRIES:
                time.sleep(2 * attempt)
    return False


def prepare_price_db(*, opener=urllib.request.urlopen) -> None:
    price_dir = settings.price_db_dir()
    missing = [n for n in PRICE_DB_FILENAMES if not (price_dir / n).is_file()]
    if not missing:
        log(f"시세 DB 있음 — 건너뜀 ({', '.join(PRICE_DB_FILENAMES)})")
        return
    urls = [u.strip() for u in settings.env_str("PRICE_DB_URLS").split(",") if u.strip()]
    if not urls:
        log(
            f"⚠ 시세 DB 없음({', '.join(missing)}) + PRICE_DB_URLS 미설정 — 시세 자동 조회는"
            " 실거래가(MOLIT)만 씁니다. 분석은 그대로 됩니다"
        )
        return
    for url in urls:
        name = _target_name(url)
        if name is None:
            log(f"⚠ 모르는 파일 이름이라 건너뜀: {_safe_url(url)} (official_price/tax_base.sqlite[.gz])")
            continue
        if name not in missing:
            continue
        log(f"시세 DB 내려받는 중: {name} ← {_safe_url(url)}")
        download(url, price_dir / name, opener=opener)


def prepare_precedent_index(*, ingest_fn=None) -> None:
    index_dir = settings.precedent_index_dir()
    if (index_dir / "docs.jsonl").is_file():
        log("판례 인덱스 있음 — 건너뜀")
        return
    if not settings.env_flag("BUILD_PRECEDENT_INDEX"):
        log("판례 인덱스 없음 — BUILD_PRECEDENT_INDEX=1이 아니라 만들지 않음 (판례 화면은 빈 목록)")
        return
    if not settings.env_str("UPSTAGE_API_KEY"):
        log("⚠ 판례 인덱스를 만들려면 UPSTAGE_API_KEY가 필요합니다 — 건너뜀")
        return
    log("판례 인덱스 만드는 중 — ⚠ Upstage 임베딩 크레딧을 한 번 씁니다(볼륨에 남아 다음부터는 건너뜀)")
    try:
        if ingest_fn is None:
            from app.services.precedent.embedding import get_backend
            from app.services.precedent.ingest import ingest

            def ingest_fn() -> dict:
                return ingest(index_dir=index_dir, backend=get_backend("upstage"), verbose=False)

        meta = ingest_fn()
        log(f"판례 인덱스 완료 — 문서 {meta.get('doc_count', '?')}건")
    except Exception as e:  # noqa: BLE001 — 판례가 없어도 서버는 뜬다
        log(f"⚠ 판례 인덱스 만들기 실패 — 판례 화면은 빈 목록 ({type(e).__name__}: {str(e)[:120]})")


def writable(path: Path) -> bool:
    """폴더에 실제로 쓸 수 있는가 — 볼륨이 root 소유로 붙으면 폴더는 있어도 못 쓴다."""
    probe = path / ".write-test"
    try:
        probe.write_bytes(b"ok")
        probe.unlink()
        return True
    except OSError:
        return False


def main() -> int:
    for label, path in (
        ("기록 DB", settings.data_dir()),
        ("시세 DB", settings.price_db_dir()),
        ("판례 인덱스", settings.precedent_index_dir()),
    ):
        try:
            path.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            log(f"⚠ {label} 폴더를 만들지 못함: {path} ({type(e).__name__})")
        if writable(path):
            log(f"{label} 폴더: {path}")
        else:
            log(
                f"⚠ {label} 폴더에 쓸 수 없음: {path} — Railway라면 Variables에"
                " RAILWAY_RUN_UID=0 을 넣으세요(볼륨이 root 소유로 붙습니다). 기록이 저장되지 않습니다"
            )
    for step in (prepare_price_db, prepare_precedent_index):
        try:
            step()
        except Exception as e:  # noqa: BLE001 — 마지막 방어선
            log(f"⚠ {step.__name__} 예기치 못한 실패 — 무시하고 서버를 시작합니다 ({type(e).__name__})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
