"""분석 기록 저장소 — **기기별**로 나누고 **SQLite 파일**에 남긴다 (2026-10-21 배포 준비).

예전(2026-08-14까지)에는 메모리 목록 하나였다. 그래서 ⑴ 서버를 다시 켜면 기록·대조 기준이
전부 사라졌고, ⑵ `GET /api/reports`가 **모든 사람의 기록**을 돌려줬다. 지금은:

- 리포트·대조 스냅샷은 `${DATA_DIR}/app.db`(기본 `backend/data/runtime/app.db`, git 제외)에
  **주인 기기 id·저장 시각과 함께** 저장한다 → 재시작해도 남는다(클라우드에서는 영구 볼륨 `/data`).
- 모든 조회는 **호출한 기기의 것만** 본다. 다른 기기의 리포트는 "없는 것"과 같다(라우터가 404).
- 모든 기기에 붙던 예시 리포트(`dummy-example`)는 2026-10-29에 없앴다 — 목록은 **그 기기의 기록만**이다.
- 판례 카드 캐시는 **메모리에만** 둔다(기기·리포트 단위). 재시작하면 첫 조회 때 다시 만든다 —
  판례 인덱스를 다시 만든 뒤 옛 카드가 영원히 남는 일을 막기 위해서다(decisions.md 2026-10-21).

개인정보: 여기에 **남는** 리포트·스냅샷에는 실명이 없다. 분석 응답은 실명이지만(2026-10-22 — 화면엔 실명),
`add`가 저장 직전에 `name_privacy.mask_report_for_storage`로 **가린 사본**을 만들어 그것만 쓴다.
스냅샷은 이름 대신 해시만 든다(`compare.py`). `tests/test_pii_persistence.py`가 DB·로그·저장 JSON에 실명이 0건인지 확인한다.
"""

from __future__ import annotations

import json
import logging
import re
import secrets
import sqlite3
import threading
from contextlib import closing
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

from .. import settings
from ..schemas.contract import CaseMatch, Report
from . import name_privacy, sealing
from .compare import Fingerprint, RegistrySnapshot

_log = logging.getLogger("jeonseai")

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
CREATE TABLE IF NOT EXISTS rejudge_kits (
    device_id  TEXT NOT NULL,
    report_id  TEXT NOT NULL,
    created_at TEXT NOT NULL,
    kit_json   TEXT NOT NULL,
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
    raw["missing_pages"] = tuple(raw.get("missing_pages") or ())  # 2026-10-27 전 스냅샷엔 없다
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
        return connect(self.path)

    def execute(self, sql: str, params: tuple = ()) -> list[tuple]:
        with self._lock, closing(self._connect()) as conn, conn:
            return conn.execute(sql, params).fetchall()


def connect(path: Path) -> sqlite3.Connection:
    """기록 DB 연결 하나 — 이 DB를 여는 모든 모듈(리포트·계정·결제·캐시 쪽지)이 이 함수로 연다.

    `secure_delete` — 지우거나 고친 행의 옛 내용을 파일에서 0으로 덮는다(2026-10-30 보안). SQLite 빌드 기본값에
    기대지 않는다: 이 설정이 꺼져 있으면 지운 리포트의 주소가 DB 파일 빈칸에 그대로 남는 것을 확인했다.
    """
    conn = sqlite3.connect(path, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA secure_delete=ON")
    return conn


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
    global _store
    with _store_lock:
        _store = None
    _cases_cache.clear()


def clear_all_cases() -> None:
    """판례 카드 캐시를 전부 비운다 — 판례 창고가 새로 바뀌었을 때(자동 업데이트, 2026-10-24)."""
    _cases_cache.clear()


def name_salt() -> bytes:
    """이름 해시용 소금 (compare._name_key가 쓴다)."""
    return _db().name_salt


def writable() -> bool:
    """기록 DB에 지금 **쓸 수 있는가** — 헬스체크(`historyDb`)용. 예외를 밖으로 내지 않는다.

    볼륨이 root 소유로 붙어 못 쓰는 경우(Railway `RAILWAY_RUN_UID=0` 누락)를 바로 보이게 한다.
    """
    try:
        _db().execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('health_probe', ?)", (_now_iso(),))
        return True
    except Exception:  # noqa: BLE001 — 헬스체크는 참/거짓만 말한다
        return False


# ── 리포트 ───────────────────────────────────────────────────────────────────


def _parse_reports(rows: list[tuple]) -> list[Report]:
    """저장된 JSON → Report. **읽지 못하는 행은 건너뛰고 로그만 남긴다** (2026-10-22 리뷰).

    리포트 모양이 바뀐 뒤 옛 행 하나가 검증에 걸리면, 예전에는 목록 전체가 500으로 죽었다.
    """
    out: list[Report] = []
    for row in rows:
        try:
            out.append(Report.model_validate_json(sealing.unseal(row[0])))
        except Exception as e:  # noqa: BLE001 — 행 하나가 목록 전체를 깨뜨리지 않게
            _log.error(f"[이력] ⚠ 저장된 리포트 1건을 읽지 못해 건너뜀 ({type(e).__name__})")
    return out


def list_reports(*, device_id: str) -> list[Report]:
    """이 기기의 이력(최신순). 기록이 없으면 빈 목록 — 앱이 빈 화면 안내를 띄운다.

    ⚠ 기록 DB를 열 수 없어도(볼륨 권한·디스크 문제) 500 대신 **빈 목록**이 나간다 — 홈 화면이 에러로
      덮이지 않게(2026-10-22 리뷰). 원인은 로그와 헬스체크 `historyDb=false`로 보인다.
    """
    try:
        rows = _db().execute(
            "SELECT report_json FROM reports WHERE device_id = ? ORDER BY created_at DESC, rowid DESC",
            (device_id,),
        )
    except Exception as e:  # noqa: BLE001
        _log.error(f"[이력] ⚠ 기록 DB를 읽지 못해 빈 목록을 보냅니다 ({type(e).__name__})")
        rows = []
    return _fill_property_ids(_parse_reports(rows), device_id=device_id)


def get(report_id: str, *, device_id: str) -> Report | None:
    """이 기기의 리포트. 다른 기기의 리포트는 **None**(=없는 것과 같다)."""
    rows = _db().execute(
        "SELECT report_json FROM reports WHERE device_id = ? AND id = ?",
        (device_id, report_id),
    )
    found = _fill_property_ids(_parse_reports(rows), device_id=device_id)
    return found[0] if found else None


def add(report: Report, *, device_id: str) -> None:
    """새 분석 결과를 이 기기의 이력에 넣는다 — **가린 사본만** 남긴다(사람 이름 → `홍○○`, 2026-10-22)."""
    stored = name_privacy.mask_report_for_storage(report)
    _db().execute(
        "INSERT OR REPLACE INTO reports (device_id, id, created_at, report_json) VALUES (?, ?, ?, ?)",
        (device_id, report.id, _now_iso(), sealing.seal(stored.model_dump_json())),
    )


def update(report: Report, *, device_id: str) -> None:
    """이미 있는 리포트의 본문만 바꾼다 — **만든 시각은 그대로**(2026-10-29, 보증금·시세·별칭 고치기).

    `add`는 만든 시각을 지금으로 바꿔, 지난 리포트를 고치면 그것이 '가장 최근'이 되어 버린다. 가린 사본만 남기는 것은 같다.
    """
    stored = name_privacy.mask_report_for_storage(report)
    _db().execute(
        "UPDATE reports SET report_json = ? WHERE device_id = ? AND id = ?",
        (sealing.seal(stored.model_dump_json()), device_id, report.id),
    )


#: 같은 집(주소가 같은 리포트)에 남기는 최대 개수 — 앱의 '이전 리포트'·폰 원본 보관(최근 5건)과 같다.
KEEP_VERSIONS_PER_PROPERTY = 5


#: 등기부 소재지에 붙어 나오는 도로명 병기 — 이 뒤는 읽을 때마다 붙었다 빠졌다 해서 같은 집 키에서 뺀다.
_ROAD_NOTE_RE = re.compile(r"[\[(（]\s*도로명\s*주소\s*[\])）].*$")
#: 주소를 못 읽은 리포트의 자리표시 (`report_builder`) — 이런 리포트끼리는 묶지 않는다.
_UNKNOWN_ADDRESS_PREFIX = "주소미확인"


def property_id(unique_number: str | None) -> str | None:
    """부동산고유번호 → 숫자만. 숫자가 10자리 미만이면(잘못 읽음) None — 엉뚱한 집끼리 묶지 않게."""
    digits = re.sub(r"\D", "", unique_number or "")
    return digits if len(digits) >= 10 else None


def property_key(address: str | None) -> str:
    """주소로 같은 집을 가르는 키 — 도로명 병기('[도로명주소] …')를 떼고 띄어쓰기를 뺀 것.

    앱 `addressPropertyKey`와 같은 규칙. 주소를 못 읽었으면 빈 문자열(묶지 않는다).
    """
    head = _ROAD_NOTE_RE.sub("", address or "")
    key = "".join(head.split())
    return "" if key.startswith(_UNKNOWN_ADDRESS_PREFIX) else key


def same_property(a: Report, b: Report) -> bool:
    """같은 집인가 (2026-10-27). 고유번호가 **둘 다** 있으면 그것만 본다, 아니면 주소 키로 견준다.

    앱 `groupByProperty`와 같은 규칙. 판정과는 상관없다 — 목록을 묶고 지난 리포트를 정리하는 데만 쓴다.
    """
    if a.propertyId and b.propertyId:
        return a.propertyId == b.propertyId
    # 쪽 머리 주소(호수까지)가 둘 다 있으면 그것으로 — IE 주소는 쪽에 따라 건물 주소(호수 없음)가 되기도 한다
    if a.propertyAddress and b.propertyAddress:
        ka, kb = property_key(a.propertyAddress), property_key(b.propertyAddress)
    else:
        ka, kb = property_key(a.address), property_key(b.address)
    return bool(ka) and ka == kb


def previous_version(report: Report, *, device_id: str) -> Report | None:
    """[report]와 같은 집의 **바로 전** 리포트 (없으면 None) — '등기부 변동 기록'에 한 줄을 만들 때."""
    try:
        rows = list(
            _db().execute(
                "SELECT report_json FROM reports WHERE device_id = ? ORDER BY created_at DESC, rowid DESC",
                (device_id,),
            )
        )
    except Exception:  # noqa: BLE001
        return None
    target = _fill_property_ids([report], device_id=device_id)[0]
    for r in _fill_property_ids(_parse_reports(rows), device_id=device_id):
        if r.id != target.id and r.analyzedAt <= target.analyzedAt and same_property(r, target):
            return r
    return None


def _fill_property_ids(reports: list[Report], *, device_id: str) -> list[Report]:
    """고유번호 칸이 생기기 전(2026-10-27 전)에 저장된 리포트 → 대조 기준 스냅샷의 고유번호로 채운다."""
    missing = [r for r in reports if r.propertyId is None]
    if not missing:
        return reports
    try:
        rows = _db().execute(
            "SELECT report_id, snapshot_json FROM snapshots WHERE device_id = ?", (device_id,)
        )
    except Exception as e:  # noqa: BLE001 — 못 채우면 앱이 주소로 묶는다
        _log.error(f"[이력] ⚠ 고유번호를 채우지 못함 — 주소로 묶습니다 ({type(e).__name__})")
        return reports
    ids: dict[str, str] = {}
    for report_id, raw in rows:
        try:
            pid = property_id(json.loads(sealing.unseal(raw)).get("unique_number"))
        except Exception:  # noqa: BLE001
            continue
        if pid:
            ids[report_id] = pid
    return [
        r.model_copy(update={"propertyId": ids[r.id]}) if r.propertyId is None and r.id in ids else r
        for r in reports
    ]


def prune_versions(report: Report, *, device_id: str, keep: int = KEEP_VERSIONS_PER_PROPERTY) -> int:
    """[report]와 같은 집의 리포트를 최신 [keep]개만 남기고 지운다 (2026-10-26 같은 집 덮어쓰기). 지운 개수를 돌려준다.

    같은 집을 다시 분석·대조하면 화면에는 최신 1개만 보이고, 지난 것은 '이전 리포트'에서 최근 5건까지 본다.
    그보다 오래된 것은 대조 기준·판례 캐시와 함께 지운다. 같은 집 = [same_property] (고유번호 → 주소).
    """
    try:
        rows = list(
            _db().execute(
                "SELECT report_json FROM reports WHERE device_id = ? ORDER BY created_at DESC, rowid DESC",
                (device_id,),
            )
        )
    except Exception as e:  # noqa: BLE001 — 정리 실패가 분석 결과를 막지 않게
        _log.error(f"[이력] ⚠ 같은 집 정리를 건너뜀 ({type(e).__name__})")
        return 0
    target = _fill_property_ids([report], device_id=device_id)[0]
    history = _fill_property_ids(_parse_reports(rows), device_id=device_id)
    same = [r.id for r in history if r.id == target.id or same_property(r, target)]
    stale = same[keep:]
    for report_id in stale:
        remove(report_id, device_id=device_id)
    if stale:
        _log.info(f"[이력] 같은 집 지난 리포트 {len(stale)}건 정리 (최신 {keep}건 유지)")
    return len(stale)


def remove(report_id: str, *, device_id: str) -> None:
    """이 기기의 리포트와 그 대조 기준·판례 캐시를 지운다."""
    db = _db()
    db.execute("DELETE FROM reports WHERE device_id = ? AND id = ?", (device_id, report_id))
    db.execute(
        "DELETE FROM snapshots WHERE device_id = ? AND report_id = ?", (device_id, report_id)
    )
    db.execute(
        "DELETE FROM rejudge_kits WHERE device_id = ? AND report_id = ?", (device_id, report_id)
    )
    _cases_cache.pop((device_id, report_id), None)


# ── 등기부 스냅샷 (S-11 대조, 2026-08-14) ────────────────────────────────────
# 대조는 **판정이 아니라 추출 결과**를 맞춰보는 것이라, 리포트만으로는 할 수 없다
# (리포트에는 근저당 몇 건이 어떤 접수일로 잡혔는지가 남지 않는다). 그래서 분석할 때
# 견줄 재료를 따로 남긴다. 실명은 담지 않는다(services/compare.py 참고).
#
# ⚠ 스냅샷이 없는 리포트 = 대조 기준으로 쓸 수 없는 리포트다. 이 기능 이전에 분석한
#   이력이 여기 해당한다 — 앱은 `Report.comparable`로 미리 알고
#   "기준 없음" 화면을 사진 촬영 **전에** 보여준다.


def put_snapshot(report_id: str, snapshot: RegistrySnapshot, *, device_id: str) -> None:
    _db().execute(
        "INSERT OR REPLACE INTO snapshots (device_id, report_id, created_at, snapshot_json)"
        " VALUES (?, ?, ?, ?)",
        (device_id, report_id, _now_iso(), sealing.seal(snapshot_to_json(snapshot))),
    )


def get_snapshot(report_id: str, *, device_id: str) -> RegistrySnapshot | None:
    rows = _db().execute(
        "SELECT snapshot_json FROM snapshots WHERE device_id = ? AND report_id = ?",
        (device_id, report_id),
    )
    if not rows:
        return None
    try:
        return snapshot_from_json(sealing.unseal(rows[0][0]))
    except Exception as e:  # noqa: BLE001 — 읽지 못하는 기준 = 기준 없음(대조 화면이 그렇게 안내한다)
        _log.error(f"[대조] ⚠ 저장된 기준 스냅샷을 읽지 못함 — 기준 없음으로 처리 ({type(e).__name__})")
        return None


# ── 다시 판정 재료 (2026-10-29 QA — 보증금·시세를 고치면 사진을 다시 읽지 않고 판정만 다시) ─────────
# 분석 때 IE가 읽은 등기부 내용(**사람 이름을 가린 사본**)과, 이름이 있어야만 할 수 있는 판정(악성임대인 명단 대조)의
# 결과를 남긴다. 보증금·시세가 바뀌어도 등기부 내용은 그대로라 IE·OCR을 다시 부를 필요가 없다(크레딧 0원).
# ⚠ 실명은 남기지 않는다(CLAUDE.md §2-5) — 명단 대조는 실명으로 분석 때 이미 끝났고 그 **결과**만 다시 쓴다.


def put_rejudge_kit(report_id: str, kit: dict, *, device_id: str) -> None:
    _db().execute(
        "INSERT OR REPLACE INTO rejudge_kits (device_id, report_id, created_at, kit_json) VALUES (?, ?, ?, ?)",
        (device_id, report_id, _now_iso(), sealing.seal(json.dumps(kit, ensure_ascii=False))),
    )


def get_rejudge_kit(report_id: str, *, device_id: str) -> dict | None:
    rows = _db().execute(
        "SELECT kit_json FROM rejudge_kits WHERE device_id = ? AND report_id = ?", (device_id, report_id)
    )
    if not rows:
        return None
    try:
        kit = json.loads(sealing.unseal(rows[0][0]))
        return kit if isinstance(kit, dict) else None
    except (ValueError, sealing.SealedUnavailable):
        _log.error("[다시판정] ⚠ 저장된 재료를 읽지 못함 — 사진으로 다시 분석해야 해요")
        return None


# ── 판례 카드 캐시 (E-3 라우터 통합, 2026-08-07 · 2026-10-21 기기별) ─────────────
# 판례 섹션은 하이브리드 검색 + 판례 수만큼의 Solar 호출이라 몇 초가 걸린다.
# 리포트는 한 번 만들어지면 변하지 않으므로 결과를 그대로 재사용한다.
# **메모리에만 둔다** — 재시작하면 첫 조회 때 다시 만든다(인덱스를 다시 만든 뒤 반영되게).
_cases_cache: dict[tuple[str, str], list[CaseMatch]] = {}


def _cases_key(report_id: str, device_id: str) -> tuple[str, str]:
    return (device_id, report_id)


def get_cases(report_id: str, *, device_id: str) -> list[CaseMatch] | None:
    return _cases_cache.get(_cases_key(report_id, device_id))


def put_cases(report_id: str, cases: list[CaseMatch], *, device_id: str) -> None:
    _cases_cache[_cases_key(report_id, device_id)] = cases


def clear_cases(report_id: str, *, device_id: str) -> None:
    _cases_cache.pop(_cases_key(report_id, device_id), None)


# ── 주인 바꾸기·지우기 (카카오 로그인 — 2026-10-22, P2-1) ─────────────────────────
# 로그인하는 순간 그 기기의 기록을 계정으로 옮기고(`accounts.claim_device_records`),
# 회원 탈퇴하면 그 계정의 기록을 전부 지운다(`accounts.delete_account`). 이 파일의 표(리포트·대조 기준)와
# 메모리의 판례 카드 캐시만 다룬다 — 캐시 쪽지·패스는 각자의 모듈이 옮긴다.


def move_owner(from_owner: str, to_owner: str) -> int:
    """`from_owner`의 리포트·대조 기준·판례 캐시를 `to_owner`로 옮긴다. 옮긴 리포트 수를 돌려준다.

    같은 리포트 id가 이미 `to_owner`에 있으면 옮겨 오는 쪽이 이긴다(`UPDATE OR REPLACE`).
    여러 번 불러도 같다(두 번째는 0건).
    """
    if not from_owner or from_owner == to_owner:
        return 0
    db = _db()
    moved = db.execute("SELECT COUNT(*) FROM reports WHERE device_id = ?", (from_owner,))[0][0]
    db.execute(
        "UPDATE OR REPLACE reports SET device_id = ? WHERE device_id = ?", (to_owner, from_owner)
    )
    db.execute(
        "UPDATE OR REPLACE snapshots SET device_id = ? WHERE device_id = ?", (to_owner, from_owner)
    )
    db.execute(
        "UPDATE OR REPLACE rejudge_kits SET device_id = ? WHERE device_id = ?", (to_owner, from_owner)
    )
    for key in [k for k in _cases_cache if k[0] == from_owner]:
        _cases_cache[(to_owner, key[1])] = _cases_cache.pop(key)
    return int(moved)


def last_report_by_owner() -> dict[str, str]:
    """주인 → 그 주인의 가장 최근 리포트를 만든 시각(ISO). 오래 쓰지 않은 기기 칸을 찾는 데 쓴다(2026-10-30)."""
    rows = _db().execute("SELECT device_id, MAX(created_at) FROM reports GROUP BY device_id")
    return {owner: created for owner, created in rows if owner and created}


def delete_owner(owner: str) -> int:
    """`owner`의 리포트·대조 기준·판례 캐시를 **전부** 지운다(회원 탈퇴). 지운 리포트 수를 돌려준다."""
    if not owner:
        return 0
    db = _db()
    deleted = db.execute("SELECT COUNT(*) FROM reports WHERE device_id = ?", (owner,))[0][0]
    db.execute("DELETE FROM reports WHERE device_id = ?", (owner,))
    db.execute("DELETE FROM snapshots WHERE device_id = ?", (owner,))
    db.execute("DELETE FROM rejudge_kits WHERE device_id = ?", (owner,))
    for key in [k for k in _cases_cache if k[0] == owner]:
        _cases_cache.pop(key, None)
    return int(deleted)


# ── 저장 데이터 잠금 (2026-10-30 보안) ──────────────────────────────────────────
#: 칸 암호화 대상 — (표, 내용 칸). 주인·id·시각 칸은 찾기·정렬에 쓰여 그대로 둔다(주인 칸은 기기 id 대신 HMAC 값).
SEALED_COLUMNS = (
    ("reports", "report_json"),
    ("snapshots", "snapshot_json"),
    ("rejudge_kits", "kit_json"),
)


def seal_existing() -> int:
    """이 기능 전에 평문으로 쓴 행을 잠근다 — 서버가 켜질 때 뒤에서 한 번. 잠근 행 수를 돌려준다.

    열쇠(`DATA_SECRET`)가 없으면 아무것도 안 한다. 다 잠그면 `VACUUM`으로 파일의 빈칸까지 새로 쓴다
    (지운 평문 조각이 파일에 남지 않게). 여러 번 불러도 같다(이미 잠긴 행은 건너뛴다).
    """
    if not sealing.enabled():
        return 0
    db = _db()
    count = 0
    for table, column in SEALED_COLUMNS:
        rows = db.execute(f"SELECT rowid, {column} FROM {table} WHERE {column} NOT LIKE ?", (sealing.PREFIX + "%",))
        for rowid, value in rows:
            db.execute(f"UPDATE {table} SET {column} = ? WHERE rowid = ?", (sealing.seal(value), rowid))
            count += 1
    if count:
        with db._lock, closing(db._connect()) as conn:
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            conn.execute("VACUUM")
        _log.info(f"[보안] 평문으로 남아 있던 기록 {count}건을 잠갔어요")
    return count


def adopt_owner(from_owner: str, to_owner: str) -> int:
    """기기 id 원문으로 쌓인 기록을 가린 주인 값으로 옮긴다(2026-10-30). [move_owner]와 같다 — 이름만 뜻을 밝힌다."""
    return move_owner(from_owner, to_owner)
