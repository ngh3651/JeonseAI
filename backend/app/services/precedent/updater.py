"""판례 **자동 업데이트** — 법제처에서 새 판례를 받아 판례 창고를 다시 만든다 (2026-10-24 규혁 결정).

한 번 돌 때 하는 일:
1. 법제처 Open API에 전세·임대차 검색어별로 **최신 판례**(선고일 내림차순)를 묻는다.
2. 아직 없는 판례만 본문을 받아 `${DATA_DIR}/precedents/raw/`에 원문으로 남긴다(영구 볼륨 — 다음 배포에도 남는다).
3. 새로 받은 게 있으면 판례 창고(인덱스)를 **옆 폴더에 새로 만든 뒤 바꿔 끼운다** — 만드는 동안에도 기존 창고로 검색된다.
   거르기·태그는 기존과 같다(`build_documents`: 전세 관련성 필터 · 태그 규칙 · 출처 확인 · 제외 목록).
4. `update_status.json`에 확인한 날짜·창고 판례 수를 남긴다 → 앱 판례 화면의 "2026.10.24 기준".

언제 도나: 서버 안 알람시계(`start_background`) — 마지막 확인에서 `PRECEDENT_UPDATE_DAYS`(기본 7)일이 지났으면.
기록이 아예 없으면(처음 배포) 바로 한 번 돈다. 배포 서버(`PREPARE_RUNTIME_ON_START=1`)에서만 켠다.

가드레일: 이 모듈도 판정을 건드리지 않는다 — 판례 창고(설명 계층)만 바꾼다.
"""

from __future__ import annotations

import json
import logging
import re
import shutil
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests

from ... import settings

_log = logging.getLogger("jeonseai")

KST = timezone(timedelta(hours=9))
SEARCH_URL = "https://www.law.go.kr/DRF/lawSearch.do"
SERVICE_URL = "https://www.law.go.kr/DRF/lawService.do"
TIMEOUT = 30
REQUEST_INTERVAL_SECONDS = 0.5  # 공공 API 예의상 호출 간격

#: 최신 판례를 물어볼 검색어 — 우리 위험 태그(선순위 채권·신탁·압류·경매·임차권등기·대항력·보증)를 덮는다.
SEARCH_QUERIES = (
    "임대차보증금",
    "임차인 대항력",
    "전세사기",
    "근저당 임차인",
    "신탁 임대차",
    "가압류 임차인",
    "임차권등기",
    "전세보증금 반환보증",
)
PER_QUERY = 20  # 검색어마다 최신 몇 건까지 볼지
MAX_NEW_PER_RUN = 40  # 한 번에 새로 받는 최대 건수 (임베딩 크레딧 상한)

STATUS_FILE = "update_status.json"
_run_lock = threading.Lock()


# ── 기록 ──────────────────────────────────────────────────────────────────────


def status_path() -> Path:
    return settings.precedent_update_dir() / STATUS_FILE


def read_status() -> dict:
    try:
        return json.loads(status_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _write_status(data: dict) -> None:
    path = status_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def index_doc_count(index_dir: Path | None = None) -> int | None:
    """지금 판례 창고에 든 판례 수 (인덱스 meta.json). 창고가 없으면 None."""
    try:
        meta = json.loads(
            ((index_dir or settings.precedent_index_dir()) / "meta.json").read_text(encoding="utf-8")
        )
        return int(meta["doc_count"])
    except (OSError, ValueError, KeyError, TypeError):
        return None


def public_status() -> dict:
    """앱에 보낼 값 — `{"docCount": 40, "updatedAt": "2026-10-24"}` (모르면 null)."""
    st = read_status()
    updated = st.get("lastSuccessAt")
    if not updated:
        # 자동 업데이트가 아직 한 번도 성공하지 않았으면 창고를 만든 날
        try:
            meta = json.loads((settings.precedent_index_dir() / "meta.json").read_text(encoding="utf-8"))
            updated = str(meta.get("ingested_at") or "")[:10] or None
        except (OSError, ValueError):
            updated = None
    return {"docCount": index_doc_count(), "updatedAt": updated}


def health_summary() -> dict:
    """헬스체크(`GET /`)용 — 마지막 확인·성공 날짜, 이번에 새로 받은 수, 성공 여부, 실패 종류(쉬운 말)."""
    st = read_status()
    err = st.get("error") or ""
    if not err:
        kind = None
    elif "검증" in err:
        kind = "법제처 인증 실패(OC·서버 IP 등록)"
    elif any(k in err for k in ("Connection", "Timeout", "SSL", "ProxyError")):
        kind = "법제처 연결 실패"
    else:
        kind = err.split(":")[0][:40]
    return {
        "lastCheckAt": st.get("lastCheckAt"),
        "lastSuccessAt": st.get("lastSuccessAt"),
        "added": st.get("added"),
        "ok": bool(st.get("lastCheckAt")) and not err,
        "error": kind,
    }


# ── 법제처 ────────────────────────────────────────────────────────────────────


def _get_json(url: str, params: dict) -> dict:
    resp = requests.get(url, params=params, timeout=TIMEOUT)
    resp.raise_for_status()
    data = resp.json()
    if "검증에 실패" in json.dumps(data, ensure_ascii=False):
        raise RuntimeError("법제처 API 사용자 검증 실패 — LAW_API_OC·서버 IP 등록 확인 필요")
    return data


def _search_latest(oc: str, query: str) -> list[dict]:
    data = _get_json(
        SEARCH_URL,
        {
            "OC": oc, "target": "prec", "type": "JSON", "query": query,
            "search": 2, "sort": "ddes", "display": PER_QUERY, "page": 1,
        },
    )
    items = data.get("PrecSearch", {}).get("prec", [])
    return [items] if isinstance(items, dict) else list(items or [])


def _clean(text: str | None) -> str:
    if not text:
        return ""
    text = re.sub(r"<br\s*/?>", "\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    return text.replace("&nbsp;", " ").strip()


def _to_raw(detail: dict) -> dict:
    """본문 응답 → raw 원문 형식 (scripts/collect_precedents.py의 save_raw와 같은 모양)."""
    prec_id = str(detail.get("판례정보일련번호", "")).strip()
    if not prec_id:
        raise ValueError("판례정보일련번호가 없는 응답")
    return {
        "_source": "law.go.kr Open API (lawService.do?target=prec) — 자동 업데이트",
        "_collected_at": datetime.now(KST).strftime("%Y-%m-%d"),
        "prec_id": prec_id,
        "case_no": _clean(detail.get("사건번호")),
        "case_name": _clean(detail.get("사건명")),
        "court": _clean(detail.get("법원명")),
        "decided": _clean(detail.get("선고일자")),
        "case_type": _clean(detail.get("사건종류명")),
        "holding_points": _clean(detail.get("판시사항")),
        "holding_summary": _clean(detail.get("판결요지")),
        "ref_articles": _clean(detail.get("참조조문")),
        "ref_precedents": _clean(detail.get("참조판례")),
        "full_text": _clean(detail.get("판례내용")),
        "source_url": f"https://www.law.go.kr/LSW/precInfoP.do?precSeq={prec_id}",
        "raw": detail,
    }


def collect_new(oc: str, known_ids: set[str], *, fetch=None, search=None) -> list[dict]:
    """검색어마다 최신 판례를 보고, 처음 보는 것만 본문을 받아 원문으로 돌려준다."""
    real = search is None  # 진짜 법제처를 부를 때만 호출 간격을 둔다(테스트는 바로)
    search = search or _search_latest
    fetch = fetch or (lambda pid: _get_json(SERVICE_URL, {"OC": oc, "target": "prec", "type": "JSON", "ID": pid}))
    new: list[dict] = []
    seen = set(known_ids)
    for q in SEARCH_QUERIES:
        for item in search(oc, q):
            if len(new) >= MAX_NEW_PER_RUN:
                return new
            pid = str(item.get("판례일련번호", "")).strip()
            if not pid or pid in seen:
                continue
            seen.add(pid)
            if real:
                time.sleep(REQUEST_INTERVAL_SECONDS)
            try:
                body = fetch(pid)
                new.append(_to_raw(body.get("PrecService", body)))
            except Exception as e:  # noqa: BLE001 — 한 건 실패는 건너뛴다
                _log.info(f"[판례 업데이트] 본문 실패 {item.get('사건번호')} ({type(e).__name__})")
    return new


# ── 창고 다시 만들기 ───────────────────────────────────────────────────────────


def _rebuild_index(ingest_fn=None) -> int:
    """옆 폴더에 새 창고를 만든 뒤 바꿔 끼운다 → 새 판례 수."""
    from . import service
    from .ingest import ingest
    from ...services import store as record_store

    live = settings.precedent_index_dir()
    building = live.with_name(live.name + ".building")
    old = live.with_name(live.name + ".old")
    shutil.rmtree(building, ignore_errors=True)
    if ingest_fn is None:
        from .embedding import get_backend

        meta = ingest(index_dir=building, backend=get_backend("upstage"), verbose=False)
    else:
        meta = ingest_fn(building)
    shutil.rmtree(old, ignore_errors=True)
    if live.exists():
        live.rename(old)
    building.rename(live)
    shutil.rmtree(old, ignore_errors=True)
    service._service = None  # 다음 검색 때 새 창고를 읽는다
    record_store.clear_all_cases()  # 리포트별 판례 카드 캐시도 새로
    return int(meta.get("doc_count", 0))


def run_update(*, collect=None, rebuild=None, now: datetime | None = None) -> dict:
    """한 번 돈다 — 새 판례 받기 → (있으면) 창고 다시 만들기 → 기록. 결과 기록을 돌려준다."""
    if not _run_lock.acquire(blocking=False):
        return read_status()
    try:
        from .ingest import extra_raw_dir, load_raw_docs

        now = now or datetime.now(KST)
        st = read_status()
        st["lastCheckAt"] = now.strftime("%Y-%m-%d")
        try:
            known = {str(d.get("prec_id")) for d in load_raw_docs()}
            new = (collect or (lambda k: collect_new(settings.law_api_oc(), k)))(known)
            if new:
                out = extra_raw_dir()
                out.mkdir(parents=True, exist_ok=True)
                for raw in new:
                    (out / f"prec-{raw['prec_id']}.json").write_text(
                        json.dumps(raw, ensure_ascii=False, indent=2), encoding="utf-8"
                    )
                doc_count = (rebuild or _rebuild_index)()
            else:
                doc_count = index_doc_count()
            st.update(
                {
                    "lastSuccessAt": now.strftime("%Y-%m-%d"),
                    "added": len(new),
                    "docCount": doc_count,
                    "error": None,
                }
            )
            _log.info(f"[판례 업데이트] 완료 — 새 원문 {len(new)}건 · 창고 {doc_count}건")
        except Exception as e:  # noqa: BLE001 — 실패해도 서버·기존 창고는 그대로
            st["error"] = f"{type(e).__name__}: {str(e)[:160]}"
            _log.info(f"[판례 업데이트] ⚠ 실패 — 기존 창고 그대로 ({st['error']})")
        try:
            _write_status(st)
        except OSError:
            pass
        return st
    finally:
        _run_lock.release()


def is_due(now: datetime | None = None) -> bool:
    """마지막 확인에서 업데이트 간격이 지났나 (기록이 없으면 바로)."""
    days = settings.precedent_update_days()
    if days <= 0:
        return False
    last = read_status().get("lastCheckAt")
    if not last:
        return True
    try:
        last_day = datetime.strptime(last, "%Y-%m-%d").replace(tzinfo=KST)
    except ValueError:
        return True
    return (now or datetime.now(KST)) - last_day >= timedelta(days=days)


# ── 알람시계 ──────────────────────────────────────────────────────────────────

_thread: threading.Thread | None = None
FIRST_WAIT_SECONDS = 180  # 서버가 뜨고 시작 준비(시세 DB·판례 창고)가 먼저 끝나게
CHECK_EVERY_SECONDS = 6 * 3600


def _loop() -> None:
    time.sleep(FIRST_WAIT_SECONDS)
    while True:
        try:
            if index_doc_count() is not None and is_due():
                run_update()
        except Exception as e:  # noqa: BLE001
            _log.info(f"[판례 업데이트] ⚠ 알람시계 오류 ({type(e).__name__})")
        time.sleep(CHECK_EVERY_SECONDS)


def start_background() -> None:
    """서버 시작 때 부른다(배포 서버만). 간격이 0이면 켜지 않는다."""
    global _thread
    if settings.precedent_update_days() <= 0:
        return
    if _thread is not None and _thread.is_alive():
        return
    _thread = threading.Thread(target=_loop, name="precedent-updater", daemon=True)
    _thread.start()
