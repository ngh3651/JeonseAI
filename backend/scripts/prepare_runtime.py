"""서버 시작 준비 — 클라우드(Railway)에서 컨테이너가 뜰 때마다 한 번 돈다 (2026-10-21 · 10-22 리뷰 반영).

하는 일 (전부 **이미 돼 있으면 건너뛴다** = 몇 번 돌려도 같다):
1. 폴더 만들기 — `DATA_DIR`(기록 DB) · `PRICE_DB_DIR`(시세 DB) · `PRECEDENT_INDEX_DIR`(판례 인덱스)
2. 시세 DB가 없고 `PRICE_DB_URLS`가 있으면 내려받기
   - 쉼표로 구분한 주소 목록. 파일 이름이 `official_price.sqlite(.gz)` / `tax_base.sqlite(.gz)`여야 한다
   - 3번까지 다시 시도하고, **임시 파일에 받은 뒤 이름을 바꿔** 반쯤 받은 파일이 DB 이름으로 남지 않게 한다
   - **다 받았는지 확인한다**: 받은 바이트 수 = `Content-Length`(있을 때), 그리고 SQLite 머리말의
     쪽 크기 × 쪽 수 = 파일 크기. 어긋나면 지우고 다시 받는다(끊긴 다운로드를 완성본으로 믿지 않는다)
3. 판례 인덱스가 없고 `BUILD_PRECEDENT_INDEX=1`이고 Upstage 키가 있으면 인덱스 만들기
   - ⚠ 임베딩 크레딧을 **한 번** 쓴다(판례 161건). 볼륨에 남으므로 다음 시작부터는 건너뛴다
   - "다 만들었다"의 표시는 적재가 **맨 마지막에** 쓰는 `meta.json`이다(중간에 끊기면 없다)

**어떻게 도나 (2026-10-22)**: 서버가 **먼저** 뜨고, 이 준비는 서버 안의 뒤쪽 스레드에서 돈다
(`app/main.py` 시작 시 `start_background()`). 수백 MB를 받는 동안에도 헬스체크가 통과하고, 진행 상황은
`GET /`의 `priceDb`·`precedentIndex`로 보인다. 같은 볼륨에서 **한 번에 하나만** 돌도록 파일 잠금을 건다.

⚠ **절대 서버를 막지 않는다.** 무엇이 실패해도 경고만 남긴다 — 시세 DB가 없어도 분석은 된다
  (시세는 '확인 필요'로 남는다). 판례가 없어도 리포트는 나온다.
⚠ 키 값·주소(쿼리 문자열에 토큰이 들어 있을 수 있다)·예외 메시지는 로그에 찍지 않는다 — **예외 종류만**.

직접 실행: `python scripts/prepare_runtime.py` (끝날 때까지 기다린다)
"""

from __future__ import annotations

import gzip
import os
import shutil
import sys
import threading
import time
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:  # noqa: BLE001 — 서버 안에서 import될 때 stdout을 바꿀 수 없는 환경도 있다
        pass

from app import settings  # noqa: E402

PRICE_DB_FILENAMES = ("official_price.sqlite", "tax_base.sqlite")
#: 판례 인덱스 "완성" 표시 — `ingest.ingest()`가 docs·chunks를 다 쓴 **뒤에** 마지막으로 쓴다.
PRECEDENT_DONE_MARKER = "meta.json"
RETRIES = 3
CHUNK = 1024 * 1024
DOWNLOAD_TIMEOUT_SECONDS = 60
LOCK_NAME = ".prepare.lock"
#: 잠금 파일이 이보다 오래됐으면 지난번 실행이 죽은 것으로 보고 넘겨받는다.
STALE_LOCK_SECONDS = 3 * 3600

_SQLITE_MAGIC = b"SQLite format 3\x00"


def log(msg: str) -> None:
    print(f"[준비] {msg}", flush=True)


def _target_name(url: str) -> str | None:
    """주소의 파일 이름 → 저장할 DB 이름. 모르는 이름이면 None."""
    name = Path(urlsplit(url).path).name
    if name.endswith(".gz"):
        name = name[: -len(".gz")]
    return name if name in PRICE_DB_FILENAMES else None


def _human(n: int) -> str:
    return f"{n / 1024 / 1024:,.1f}MB"


class IncompleteDownload(OSError):
    """받은 파일이 완성본이 아니다 (크기 불일치·SQLite 아님)."""


def check_sqlite_complete(path: Path) -> None:
    """SQLite 머리말로 **파일이 끝까지 있는지** 확인한다. 아니면 `IncompleteDownload`.

    머리말 16~17바이트 = 쪽 크기(1이면 65536), 28~31바이트 = 쪽 수. 정상 파일은 쪽 크기 × 쪽 수가
    파일 크기와 같다. 끊긴 다운로드는 머리말은 멀쩡해도 파일이 짧다 — 그걸 여기서 잡는다.
    """
    size = path.stat().st_size
    with open(path, "rb") as f:
        header = f.read(100)
    if len(header) < 100 or header[:16] != _SQLITE_MAGIC:
        raise IncompleteDownload("SQLite 파일이 아님")
    page_size = int.from_bytes(header[16:18], "big")
    if page_size == 1:
        page_size = 65536
    page_count = int.from_bytes(header[28:32], "big")
    if page_count and page_size * page_count != size:
        raise IncompleteDownload("SQLite 크기 불일치")


def _content_length(resp) -> int | None:
    try:
        raw = resp.headers.get("Content-Length") if getattr(resp, "headers", None) else None
        return int(raw) if raw is not None else None
    except (TypeError, ValueError):
        return None


class _Counter:
    """원본(압축된 그대로) 바이트 수를 센다 — `Content-Length`와 견주기 위해."""

    def __init__(self, raw) -> None:
        self._raw = raw
        self.count = 0

    def read(self, n: int = -1) -> bytes:
        data = self._raw.read(n)
        self.count += len(data)
        return data

    def readinto(self, buf) -> int:  # gzip.GzipFile이 쓸 수 있다
        data = self.read(len(buf))
        buf[: len(data)] = data
        return len(data)


def download(url: str, dest: Path, *, opener=urllib.request.urlopen) -> bool:
    """`url` → `dest`. `.gz`면 풀면서 받는다. 완성본을 받으면 True. 예외를 밖으로 내지 않는다."""
    gz = urlsplit(url).path.endswith(".gz")
    tmp = dest.with_name(dest.name + ".part")
    for attempt in range(1, RETRIES + 1):
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            t0 = time.perf_counter()
            with opener(url, timeout=DOWNLOAD_TIMEOUT_SECONDS) as resp, open(tmp, "wb") as out:
                expected = _content_length(resp)
                counter = _Counter(resp)
                stream = gzip.GzipFile(fileobj=counter) if gz else counter
                shutil.copyfileobj(stream, out, CHUNK)
            if expected is not None and counter.count != expected:
                raise IncompleteDownload("받은 크기가 Content-Length와 다름")
            check_sqlite_complete(tmp)
            os.replace(tmp, dest)  # 원자적 교체 — 반쯤 받은 파일이 DB 이름으로 남지 않는다
            log(f"내려받기 완료: {dest.name} {_human(dest.stat().st_size)} ({time.perf_counter() - t0:.0f}초)")
            return True
        except Exception as e:  # noqa: BLE001 — 준비 단계는 서버를 막지 않는다
            # ⚠ 주소·예외 메시지에는 토큰이 섞일 수 있다 → 예외 종류만 남긴다
            log(f"⚠ {dest.name} 내려받기 실패 {attempt}/{RETRIES} ({type(e).__name__})")
            try:
                tmp.unlink(missing_ok=True)
            except OSError:
                pass
            if attempt < RETRIES:
                time.sleep(2 * attempt)
    return False


def _source_marker(price_dir: Path, name: str) -> Path:
    return price_dir / f"{name}.source"


def _url_fingerprint(url: str) -> str:
    """주소의 지문(해시) — 주소 자체는 토큰이 섞일 수 있어 파일에 남기지 않는다."""
    import hashlib

    return hashlib.sha256(url.encode("utf-8")).hexdigest()[:16]


def prepare_price_db(*, opener=urllib.request.urlopen) -> None:
    """시세 DB 준비 — 없으면 받고, **`PRICE_DB_URLS`의 주소가 바뀌었으면 새로 받는다**(2026-10-24).

    예전엔 파일이 있으면 무조건 건너뛰어, 2026년분 DB를 새 주소로 올려도 서버는 옛 파일을 계속 썼다.
    이제 받은 주소의 지문을 `<이름>.source`에 남기고, 지문이 다르면 다시 받는다(임시 파일에 받은 뒤 바꿔 끼우므로
    받는 동안에도 옛 DB로 조회된다). 지문 기록이 없는 옛 파일은 지금 주소에서 받은 것으로 보고 기록만 남긴다.
    """
    price_dir = settings.price_db_dir()
    urls = [u.strip() for u in settings.env_str("PRICE_DB_URLS").split(",") if u.strip()]
    missing = [n for n in PRICE_DB_FILENAMES if not (price_dir / n).is_file()]
    if not urls:
        if missing:
            log(
                f"⚠ 시세 DB 없음({', '.join(missing)}) + PRICE_DB_URLS 미설정 — 시세 자동 조회는"
                " 실거래가(MOLIT)만 씁니다. 분석은 그대로 됩니다"
            )
        else:
            log(f"시세 DB 있음 — 건너뜀 ({', '.join(PRICE_DB_FILENAMES)})")
        return
    for i, url in enumerate(urls, 1):
        name = _target_name(url)
        if name is None:
            log(f"⚠ PRICE_DB_URLS {i}번째 주소의 파일 이름을 모름 — 건너뜀 (official_price/tax_base.sqlite[.gz])")
            continue
        dest = price_dir / name
        marker = _source_marker(price_dir, name)
        fp = _url_fingerprint(url)
        if dest.is_file():
            try:
                recorded = marker.read_text(encoding="utf-8").strip()
            except OSError:
                recorded = ""
            if not recorded:
                _write_marker(marker, fp)  # 지문 없던 옛 파일 — 지금 주소에서 받은 것으로 기록만
                log(f"시세 DB 있음 — 건너뜀 ({name})")
                continue
            if recorded == fp:
                log(f"시세 DB 있음 — 건너뜀 ({name})")
                continue
            log(f"시세 DB 주소가 바뀜 → 새로 받는 중: {name} (PRICE_DB_URLS {i}번째)")
        else:
            log(f"시세 DB 내려받는 중: {name} (PRICE_DB_URLS {i}번째)")
        if download(url, dest, opener=opener):
            _write_marker(marker, fp)


def _write_marker(marker: Path, fp: str) -> None:
    try:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(fp, encoding="utf-8")
    except OSError:
        pass

def precedent_index_ready(index_dir: Path | None = None) -> bool:
    """판례 인덱스가 **끝까지** 만들어졌는가 — 적재가 마지막에 쓰는 `meta.json`으로 판단한다."""
    return ((index_dir or settings.precedent_index_dir()) / PRECEDENT_DONE_MARKER).is_file()


def prepare_precedent_index(*, ingest_fn=None) -> None:
    index_dir = settings.precedent_index_dir()
    if precedent_index_ready(index_dir):
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
        _refresh_precedent_service()
    except Exception as e:  # noqa: BLE001 — 판례가 없어도 서버는 뜬다
        log(f"⚠ 판례 인덱스 만들기 실패 — 판례 화면은 빈 목록 ({type(e).__name__})")


def _refresh_precedent_service() -> None:
    """서버 안에서 돌았다면, 빈 인덱스로 미리 만들어진 판례 검색기를 버려 새 인덱스를 읽게 한다."""
    try:
        from app.services.precedent import service

        service._service = None
    except Exception:  # noqa: BLE001
        pass


def writable(path: Path) -> bool:
    """폴더에 실제로 쓸 수 있는가 — 볼륨이 root 소유로 붙으면 폴더는 있어도 못 쓴다."""
    probe = path / f".write-test-{os.getpid()}"
    try:
        probe.write_bytes(b"ok")
        probe.unlink()
        return True
    except OSError:
        return False


# ── 한 번에 하나만 ─────────────────────────────────────────────────────────────


def _acquire_lock(lock: Path) -> bool:
    """파일 하나를 '만들 때만' 성공하는 방식(O_EXCL)으로 잠근다. 오래된 잠금은 넘겨받는다."""
    try:
        lock.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        return True  # 잠금 파일을 둘 곳이 없으면(쓰기 불가) 그냥 진행한다 — 각 단계가 알아서 실패를 삼킨다
    for _ in range(2):
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, str(os.getpid()).encode())
            os.close(fd)
            return True
        except FileExistsError:
            try:
                if time.time() - lock.stat().st_mtime > STALE_LOCK_SECONDS:
                    lock.unlink()
                    continue
            except OSError:
                pass
            return False
        except OSError:
            return True
    return False


def run() -> int:
    """준비 전체를 한 번 돈다. 다른 준비가 이미 돌고 있으면 건너뛴다. 늘 0을 돌려준다."""
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

    lock = settings.data_dir() / LOCK_NAME
    if not _acquire_lock(lock):
        log("다른 준비가 이미 돌고 있음 — 건너뜀")
        return 0
    try:
        for step in (prepare_price_db, prepare_precedent_index):
            try:
                step()
            except Exception as e:  # noqa: BLE001 — 마지막 방어선
                log(f"⚠ {step.__name__} 예기치 못한 실패 — 무시하고 계속 ({type(e).__name__})")
    finally:
        try:
            lock.unlink(missing_ok=True)
        except OSError:
            pass
    return 0


# ── 서버 안에서 뒤쪽 스레드로 ───────────────────────────────────────────────────

_thread: threading.Thread | None = None
_thread_lock = threading.Lock()


def start_background() -> threading.Thread | None:
    """서버 시작 때 부른다 — 준비를 데몬 스레드로 띄우고 바로 돌아온다. 이미 돌고 있으면 그대로 둔다."""
    global _thread
    with _thread_lock:
        if _thread is not None and _thread.is_alive():
            return _thread
        _thread = threading.Thread(target=_run_quietly, name="prepare-runtime", daemon=True)
        _thread.start()
        return _thread


def _run_quietly() -> None:
    try:
        run()
    except Exception as e:  # noqa: BLE001 — 스레드가 죽으며 서버 로그를 더럽히지 않게
        log(f"⚠ 준비 스레드 예기치 못한 실패 ({type(e).__name__})")


def main() -> int:
    return run()


if __name__ == "__main__":
    sys.exit(main())
