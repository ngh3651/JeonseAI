"""같은 사진 = 같은 결과 — 분석 결과 캐시 (2026-10-22, P1-1).

왜 있나: 같은 사진을 다시 보내면 지금까지는 IE·OCR을 처음부터 다시 불렀다 — 크레딧을 두 번 쓰고, IE의 작은
흔들림 때문에 결과가 미세하게 달라질 수도 있었다. 흔한 경우는 둘이다:
  · 분석은 서버에서 끝났는데 앱이 기다리다 끊겨(3분) 사용자가 '다시 시도'를 누른 경우
  · 갤러리에서 같은 사진을 다시 골라 다시 분석한 경우
같은 입력이면 **같은 리포트를 그대로** 돌려준다(크레딧 0원, 몇 밀리초).

키 = 올라온 JPEG 묶음의 SHA-256(**순서 포함** — 하이라이트·가림 상자의 쪽 번호가 업로드 순서라서) + 보증금 + 시세 입력
+ **서버 코드 버전**(`code_version()` — 배포로 규칙이 바뀌면 키도 바뀐다. 옛 판정을 24시간 돌려주지 않게)
+ **시세 DB 준비 여부**(`price_db_ready()` — 배포 직후 시세 DB를 내려받기 전에 만든 '시세 없음' 리포트가
  DB가 뜬 뒤에도 24시간 나가지 않게. DB를 끝내 안 올려도 캐시는 그대로 돈다).
별칭은 키에 넣지 않는다 — 판정과 무관하다. 별칭만 바꿔 다시 보내면 같은 리포트에 새 별칭을 붙여 돌려준다.
**같은 기기 안에서만** 찾는다(기록이 기기별이라 다른 기기의 리포트는 돌려줄 수 없다).
기간은 `ANALYSIS_CACHE_HOURS`(기본 24시간, 0이면 끈다).

저장: 기록 DB(`app.db`)의 `analysis_cache` 표 — (기기 id, 키, 리포트 id, 저장 시각)만. 사진·이름은 담지 않는다.
리포트 본문은 기록 표에 이미 있다 — 여기에는 "이 키면 이 리포트"라는 **쪽지**만 남긴다. 그래서 사용자가 그 리포트를
지우면 캐시도 자연히 빗나간다(쪽지가 가리키는 리포트가 없으면 다시 분석한다).
연결은 이 모듈이 따로 연다(`store.db_path()` — 같은 파일). `store.py`의 표 정의는 건드리지 않는다.

⚠ 대조(compare)에는 쓰지 않는다 — 대조는 "지금 다시 뗀 서류"를 새로 읽는 것이 목적이다.
⚠ 분석 횟수 상한(429)은 캐시보다 **먼저** 센다 — 같은 사진을 끝없이 보내 서버를 붙잡는 것을 막는다.
"""

from __future__ import annotations

import hashlib
import logging
import sqlite3
import threading
from contextlib import closing
from datetime import datetime, timedelta, timezone

from .. import settings
from ..schemas.contract import Report
from . import official_price, store

_log = logging.getLogger("jeonseai")

#: 키를 만드는 법이 바뀌면 올린다 — 옛 쪽지가 새 계산과 섞이지 않게.
KEY_VERSION = "v1"

#: Railway 밖(로컬·테스트)에서 쓰는 코드 버전 — 배포 커밋을 모르면 이 고정 문자열이다.
LOCAL_CODE_VERSION = "local"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS analysis_cache (
    device_id  TEXT NOT NULL,
    cache_key  TEXT NOT NULL,
    report_id  TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (device_id, cache_key)
)
"""

_lock = threading.Lock()


def hours() -> int:
    """캐시를 쓰는 기간(시간). 0 이하면 캐시를 끈다."""
    return settings.env_int("ANALYSIS_CACHE_HOURS", 24)


def _now() -> datetime:
    return datetime.now(timezone.utc)  # 테스트가 바꿔 끼운다(시간이 지난 것처럼)


def _iso(when: datetime) -> str:
    return when.isoformat(timespec="milliseconds")  # store.py와 같은 형식 — 문자열 비교가 시간 순서다


def code_version() -> str:
    """지금 서버 코드의 버전 — 키에 넣어 **새로 배포하면 캐시가 저절로 빗나가게** 한다.

    규칙(판정)을 고쳐 배포했는데 같은 사진에 24시간 동안 옛 리포트를 돌려주면 안 된다.
    Railway는 배포마다 그 커밋 해시를 `RAILWAY_GIT_COMMIT_SHA`로 넣어 준다(헬스체크 `version`과 같은 값).
    없으면(로컬·테스트) 고정 문자열 — 로컬에서 코드를 고친 뒤 옛 결과가 보이면 `ANALYSIS_CACHE_HOURS=0`으로 끈다.
    """
    return settings.env_str("RAILWAY_GIT_COMMIT_SHA") or LOCAL_CODE_VERSION


def price_db_ready() -> bool:
    """시세 DB(공시가격 + 오피스텔 기준시가)가 **둘 다** 있는가 — 헬스체크 `priceDb`와 같은 판단.

    서버는 바로 뜨고 시세 DB는 뒤에서 내려받는다(처음 몇 분은 없다). 내려받기는 다 받은 뒤 이름을 바꾸므로
    파일이 있으면 다 받은 것이다(`prepare_runtime.py`). 확인하다 실패하면 '없음'으로 본다.
    """
    try:
        return all(official_price.db_path(key).is_file() for key in official_price.DB_FILENAMES)
    except Exception:  # noqa: BLE001
        return False


def make_key(images: list[tuple[str, bytes]], *, deposit: int, market_price: int | None) -> str:
    """사진 묶음(순서 포함) + 보증금 + 시세 입력 + 서버 코드 버전 + 시세 DB 준비 여부 → 64자리 키.

    파일 이름은 넣지 않는다(앱이 늘 page_N.jpg로 보낸다).
    """
    h = hashlib.sha256()
    h.update(f"{KEY_VERSION}|code={code_version()}|pricedb={int(price_db_ready())}|{len(images)}|".encode())
    for _, data in images:
        h.update(hashlib.sha256(data).digest())
    price = "" if market_price is None else str(int(market_price))
    h.update(f"|deposit={int(deposit)}|price={price}".encode())
    return h.hexdigest()


def _execute(sql: str, params: tuple = ()) -> list[tuple]:
    path = store.db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with _lock, closing(sqlite3.connect(path, timeout=10)) as conn, conn:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute(_SCHEMA)
        return conn.execute(sql, params).fetchall()


def _forget(key: str, device_id: str) -> None:
    _execute("DELETE FROM analysis_cache WHERE device_id = ? AND cache_key = ?", (device_id, key))


def lookup(key: str, *, device_id: str) -> Report | None:
    """이 기기에서 같은 키로 만든 **기간 안의** 리포트. 없거나 지워졌거나 기간이 지났으면 None.

    예외를 밖으로 던지지 않는다 — 캐시가 깨져도 분석은 처음부터 하면 된다.
    """
    ttl = hours()
    if ttl <= 0:
        return None
    try:
        rows = _execute(
            "SELECT report_id, created_at FROM analysis_cache WHERE device_id = ? AND cache_key = ?",
            (device_id, key),
        )
        if not rows:
            return None
        report_id, created_at = rows[0]
        try:
            age = _now() - datetime.fromisoformat(created_at)
        except ValueError:
            age = timedelta(hours=ttl + 1)  # 읽을 수 없는 시각 = 지난 것으로
        if age > timedelta(hours=ttl):
            _forget(key, device_id)
            return None
        report = store.get(report_id, device_id=device_id)
        if report is None:  # 사용자가 지웠거나 그때 저장이 실패했다 → 쪽지만 치운다
            _forget(key, device_id)
            return None
    except Exception:  # noqa: BLE001
        _log.error("[캐시] ⚠ 캐시를 읽지 못함 — 처음부터 분석합니다", exc_info=True)
        return None
    minutes = int(age.total_seconds() // 60)
    _log.info(
        f"[캐시] 적중 — 같은 사진·같은 입력이라 {minutes}분 전 분석({report.id})을 그대로 보냅니다"
        f" (IE·OCR 호출 0회, 크레딧 0원, 키 {key[:12]}…)"
    )
    return report


def is_complete(report: Report) -> bool:
    """모든 쪽을 읽은 결과인가 — **덜 된 결과는 캐시하지 않는다.**

    OCR이 한 쪽이라도 실패하면(가림 상자가 그 쪽을 통째로 덮는다 = 그 쪽 글자를 못 읽었다) 형광펜·가림이 빠진
    리포트다. 이걸 24시간 붙잡아 두면 '다시 시도'를 눌러도 영영 나아지지 않는다 → 쪽지를 남기지 않고 다음에 다시 분석한다.
    """
    if not report.privacyMasksReady:
        return False
    return not any(m.x <= 0 and m.y <= 0 and m.w >= 1 and m.h >= 1 for m in report.privacyMasks)


def remember(key: str, report: Report, *, device_id: str) -> None:
    """새 분석 결과의 쪽지를 남기고, 이 기기의 기간 지난 쪽지를 치운다. 실패해도 그냥 넘어간다."""
    ttl = hours()
    if ttl <= 0:
        return
    if not is_complete(report):
        _log.info(f"[캐시] 이번 결과({report.id})는 읽지 못한 쪽이 있어 캐시하지 않습니다 — 다시 보내면 처음부터 분석합니다")
        return
    report_id = report.id
    now = _now()
    try:
        _execute(
            "INSERT OR REPLACE INTO analysis_cache (device_id, cache_key, report_id, created_at)"
            " VALUES (?, ?, ?, ?)",
            (device_id, key, report_id, _iso(now)),
        )
        _execute(
            "DELETE FROM analysis_cache WHERE device_id = ? AND created_at < ?",
            (device_id, _iso(now - timedelta(hours=ttl))),
        )
    except Exception:  # noqa: BLE001 — 쪽지를 못 남기면 다음에 다시 분석할 뿐이다
        _log.error("[캐시] ⚠ 캐시를 남기지 못함 — 이번 리포트는 그대로 나갑니다", exc_info=True)


def with_alias(report: Report, alias: str | None, *, device_id: str) -> Report:
    """캐시로 돌려줄 리포트에 **새 별칭**을 붙인다(별칭은 판정과 무관 — 키에 넣지 않았다).

    별칭이 비었거나 같으면 그대로. 다르면 기록에도 새 별칭으로 다시 저장한다(목록 맨 위로 올라온다).
    """
    new = (alias or "").strip()
    if not new or new == report.alias:
        return report
    renamed = report.model_copy(update={"alias": new})
    try:
        store.add(renamed, device_id=device_id)
        _log.info(f"[캐시] 별칭만 바뀌어 같은 리포트({report.id})에 새 별칭을 붙였습니다")
    except Exception:  # noqa: BLE001
        _log.error("[캐시] ⚠ 새 별칭을 기록에 저장하지 못함 — 응답에만 붙입니다", exc_info=True)
    return renamed
