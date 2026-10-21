"""분석 기록 저장소 — **기기별**로 나누고 **SQLite 파일**에 남긴다 (2026-10-21 배포 준비).

예전(2026-08-14까지)에는 메모리 목록 하나였다. 그래서 ⑴ 서버를 다시 켜면 기록·대조 기준이
전부 사라졌고, ⑵ `GET /api/reports`가 **모든 사람의 기록**을 돌려줬다. 지금은:

- 리포트·대조 스냅샷은 `${DATA_DIR}/app.db`(기본 `backend/data/runtime/app.db`, git 제외)에
  **주인 기기 id·저장 시각과 함께** 저장한다 → 재시작해도 남는다(클라우드에서는 영구 볼륨 `/data`).
- 모든 조회는 **호출한 기기의 것만** 본다. 다른 기기의 리포트는 "없는 것"과 같다(라우터가 404).
- 예시 리포트(`dummy-example`)는 저장하지 않는다 — 첫 조회 때 규칙 엔진으로 만들어
  **모든 기기에 보이고**, 지울 수 없다(라우터가 403).
- 판례 카드 캐시는 **메모리에만** 둔다(기기·리포트 단위). 재시작하면 첫 조회 때 다시 만든다 —
  판례 인덱스를 다시 만든 뒤 옛 카드가 영원히 남는 일을 막기 위해서다(decisions.md 2026-10-21).

개인정보: 여기에 들어오는 리포트·스냅샷에는 **집주인 실명이 없다** — 하이라이트 제목은
마스킹되고(`highlight.py`), 스냅샷은 이름 대신 해시만 든다(`compare.py`).
`tests/test_pii_persistence.py`가 DB·로그·저장 JSON에 실명이 0건인지 확인한다.

⚠ 예시 시드는 **첫 조회 때 만든다** (2026-08-14 D13). 예시가 규칙 엔진 산출물이라
  `dummy_data → report_builder → store` 순환에 걸리지 않게, 모듈을 읽는 시점에는 만들지 않는다.
"""

from __future__ import annotations

import json
import logging
import secrets
import sqlite3
import threading
from contextlib import closing
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

from .. import dummy_data, settings
from ..schemas.contract import CaseMatch, Report
from .compare import Fingerprint, RegistrySnapshot

_log = logging.getLogger("jeonseai")

EXAMPLE_IDS = dummy_data.EXAMPLE_IDS  # {"dummy-example"} — 모든 기기가 보고, 삭제 금지(403)

DB_FILENAME = "app.db"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS reports (
    device_id   TEXT NOT NULL,
    id          TEXT NOT NULL,
    created_at  TEXT NOT NULL,
    report_json TEXT NOT NULL,
    PRIMARY KEY (device_id, id)
);
CREATE INDEX IF NOT EXISTS idx_reports_device_created ON reports (device_id, created_at);
CREATE TABLE IF NOT EXISTS snapshots (
    device_id     TEXT NOT NULL,
    report_id     TEXT NOT NULL,
    created_at    TEXT NOT NULL,
    snapshot_json TEXT NOT NULL,
    PRIMARY KEY (device_id, report_id)
);
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


# ── 스냅샷 ↔ JSON ────────────────────────────────────────────────────────────
# ⚠ 대조는 `owner_keys`·`entries`를 **튜플끼리** 비교한다. JSON은 튜플을 리스트로 바꾸므로
#   되읽을 때 반드시 튜플로 되돌린다 — 안 그러면 tuple != list라 늘 "집주인이 달라요"가 뜬다.


def snapshot_to_json(snapshot: RegistrySnapshot) -> str:
    return json.dumps(asdict(snapshot), ensure_ascii=False)


def snapshot_from_json(text: str) -> RegistrySnapshot:
    raw = json.loads(text)
    raw["owner_keys"] = tuple(raw.get("owner_keys") or ())
    raw["missing_fields"] = tuple(raw.get("missing_fields") or ())
    raw["entries"] = {
        name: tuple(Fingerprint(**fp) for fp in fps)
        for name, fps in (raw.get("entries") or {}).items()
    }
    return RegistrySnapshot(**raw)


class _Store:
    """SQLite 파일 하나. 연결은 작업마다 열고 닫는다(스레드풀·이벤트 루프 어디서 불러도 안전)."""

    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self._lock = threading.Lock()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._lock, closing(self._connect()) as conn, conn:
            conn.executescript(_SCHEMA)
            row = conn.execute("SELECT value FROM meta WHERE key = 'name_salt'").fetchone()
            if row is None:
                salt = secrets.token_hex(16)
                conn.execute("INSERT INTO meta (key, value) VALUES ('name_salt', ?)", (salt,))
            else:
                salt = row[0]
        # 이름 해시용 소금 — **DB와 운명을 같이한다.** 재시작해도 같은 값이라 옛 스냅샷과 견줄 수 있고,
        # DB를 지우면 해시도 함께 의미를 잃는다(compare._name_key).
        self.name_salt = bytes.fromhex(salt)

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path, timeout=10)
        conn.execute("PRAGMA journal_mode=WAL")
        return conn

    def execute(self, sql: str, params: tuple = ()) -> list[tuple]:
        with self._lock, closing(self._connect()) as conn, conn:
            return conn.execute(sql, params).fetchall()


_store: _Store | None = None
_store_lock = threading.Lock()


def _db() -> _Store:
    global _store
    with _store_lock:
        if _store is None:
            path = settings.data_dir() / DB_FILENAME
            _store = _Store(path)
            _log.info(f"[이력] 기록 DB 사용: {path}")
        return _store


def db_path() -> Path:
    """지금 쓰는(또는 쓸) 기록 DB 경로 — 헬스체크·테스트용."""
    return _store.path if _store is not None else settings.data_dir() / DB_FILENAME


def reset() -> None:
    """DB 연결 정보와 메모리 캐시를 버린다 — 다음 호출 때 `DATA_DIR`을 다시 읽어 연다.

    테스트가 "서버 재시작"을 흉내 낼 때 쓴다(파일은 그대로 남는다).
    """
    global _store, _examples
    with _store_lock:
        _store = None
    _examples = None
    _cases_cache.clear()


def name_salt() -> bytes:
    """이름 해시용 소금 (compare._name_key가 쓴다)."""
    return _db().name_salt


# ── 예시 리포트 (저장하지 않음, 모든 기기 공용) ─────────────────────────────────

_examples: list[Report] | None = None


def _example_reports() -> list[Report]:
    global _examples
    if _examples is None:
        _examples = dummy_data.get_history()
    return _examples


def _example(report_id: str) -> Report | None:
    if report_id not in EXAMPLE_IDS:
        return None
    return next((r for r in _example_reports() if r.id == report_id), None)


# ── 리포트 ───────────────────────────────────────────────────────────────────


def list_reports(*, device_id: str) -> list[Report]:
    """이 기기의 이력(최신순) + 맨 끝에 예시 리포트."""
    rows = _db().execute(
        "SELECT report_json FROM reports WHERE device_id = ? ORDER BY created_at DESC, rowid DESC",
        (device_id,),
    )
    mine = [Report.model_validate_json(r[0]) for r in rows]
    return mine + list(_example_reports())


def get(report_id: str, *, device_id: str) -> Report | None:
    """이 기기의 리포트 또는 예시. 다른 기기의 리포트는 **None**(=없는 것과 같다)."""
    example = _example(report_id)
    if example is not None:
        return example
    rows = _db().execute(
        "SELECT report_json FROM reports WHERE device_id = ? AND id = ?",
        (device_id, report_id),
    )
    return Report.model_validate_json(rows[0][0]) if rows else None


def add(report: Report, *, device_id: str) -> None:
    """새 분석 결과를 이 기기의 이력에 넣는다."""
    _db().execute(
        "INSERT OR REPLACE INTO reports (device_id, id, created_at, report_json) VALUES (?, ?, ?, ?)",
        (device_id, report.id, _now_iso(), report.model_dump_json()),
    )


def remove(report_id: str, *, device_id: str) -> None:
    """이 기기의 리포트와 그 대조 기준·판례 캐시를 지운다. 예시는 지우지 않는다."""
    if report_id in EXAMPLE_IDS:
        return
    db = _db()
    db.execute("DELETE FROM reports WHERE device_id = ? AND id = ?", (device_id, report_id))
    db.execute(
        "DELETE FROM snapshots WHERE device_id = ? AND report_id = ?", (device_id, report_id)
    )
    _cases_cache.pop((device_id, report_id), None)


# ── 등기부 스냅샷 (S-11 대조, 2026-08-14) ────────────────────────────────────
# 대조는 **판정이 아니라 추출 결과**를 맞춰보는 것이라, 리포트만으로는 할 수 없다
# (리포트에는 근저당 몇 건이 어떤 접수일로 잡혔는지가 남지 않는다). 그래서 분석할 때
# 견줄 재료를 따로 남긴다. 실명은 담지 않는다(services/compare.py 참고).
#
# ⚠ 스냅샷이 없는 리포트 = 대조 기준으로 쓸 수 없는 리포트다. 이 기능 이전에 분석한
#   이력과 예시 리포트가 여기 해당한다 — 앱은 `Report.comparable`로 미리 알고
#   "기준 없음" 화면을 사진 촬영 **전에** 보여준다.


def put_snapshot(report_id: str, snapshot: RegistrySnapshot, *, device_id: str) -> None:
    _db().execute(
        "INSERT OR REPLACE INTO snapshots (device_id, report_id, created_at, snapshot_json)"
        " VALUES (?, ?, ?, ?)",
        (device_id, report_id, _now_iso(), snapshot_to_json(snapshot)),
    )


def get_snapshot(report_id: str, *, device_id: str) -> RegistrySnapshot | None:
    rows = _db().execute(
        "SELECT snapshot_json FROM snapshots WHERE device_id = ? AND report_id = ?",
        (device_id, report_id),
    )
    return snapshot_from_json(rows[0][0]) if rows else None


# ── 판례 카드 캐시 (E-3 라우터 통합, 2026-08-07 · 2026-10-21 기기별) ─────────────
# 판례 섹션은 하이브리드 검색 + 판례 수만큼의 Solar 호출이라 몇 초가 걸린다.
# 리포트는 한 번 만들어지면 변하지 않으므로 결과를 그대로 재사용한다.
# **메모리에만 둔다** — 재시작하면 첫 조회 때 다시 만든다(인덱스를 다시 만든 뒤 반영되게).
# 예시 리포트는 모든 기기가 같은 카드를 보므로 공용 칸(`*`)에 둔다.
_SHARED = "*"
_cases_cache: dict[tuple[str, str], list[CaseMatch]] = {}


def _cases_key(report_id: str, device_id: str) -> tuple[str, str]:
    return (_SHARED if report_id in EXAMPLE_IDS else device_id, report_id)


def get_cases(report_id: str, *, device_id: str) -> list[CaseMatch] | None:
    return _cases_cache.get(_cases_key(report_id, device_id))


def put_cases(report_id: str, cases: list[CaseMatch], *, device_id: str) -> None:
    _cases_cache[_cases_key(report_id, device_id)] = cases


def clear_cases(report_id: str, *, device_id: str) -> None:
    _cases_cache.pop(_cases_key(report_id, device_id), None)
