"""악성임대인(상습 채무불이행자) 공개 명단 — 받아 와서 **이름을 가린 채로** 서버 볼륨에 둔다 (2026-10-31).

근거: 주택도시기금법 제34조의5 — 주택도시보증공사(HUG)가 상습 채무불이행 임대인의 성명·나이·주소·채무액 등을
공개한다(안심전세포털, 공공데이터포털 15161980 '주택도시보증공사_상습 채무불이행자 정보공개' OPEN API — HUG 빅데이터
개방포털에서 키를 받는다). 공개 명단이지만 **실명이 든 개인정보**다 — 그래서:

- **저장소(git)에 명단을 절대 넣지 않는다**(저장소가 공개다). 서버가 실행 중에 받아 `${DATA_DIR}`에만 둔다.
- 서버에도 **실명을 남기지 않는다.** 이름은 HMAC(기록 DB의 소금)으로만 남긴다 — 파일만 새어 나가면 이름을 되찾을 수
  없고, 서버는 등기부의 집주인 이름을 같은 방식으로 바꿔 맞춰 본다. 화면·리포트에는 가린 이름(김○○)만.
- 출생연도(나이로 거꾸로 셈)가 있으면 함께 남긴다 — 동명이인을 거르는 데 쓸 수 있게(지금 등기부 쪽 출생연도는 못 읽어 이름만 본다).
- 받는 곳은 환경변수로 정한다(`BLACKLIST_SOURCE_URL` · `BLACKLIST_API_KEY` · `BLACKLIST_KEY_PARAM`). HUG 주소면 키 칸 이름은
  저절로 `API_KEY`(2026-10-31 확인: https://www.khug.or.kr/defaultOnDebitList.do?API_KEY=…, 쪽 나눔 없음). 없으면 아무것도 안 하고
  리포트는 지금처럼 '명단 대조 아직 안 됨'(카드 숨김 + 맨 아래 안내)이다.
- 판례 알람시계가 매주 다시 받는다(`precedent.updater._loop`). 실패하면 전에 받아 둔 명단을 그대로 쓴다.

판정: 명단과 이름이 같아도 **위험이 아니라 강한 '확인 필요'**다(동명이인 — 2026-07-06 결정 그대로).
"""

from __future__ import annotations

import csv
import hashlib
import hmac
import io
import json
import logging
import os
import re
from datetime import datetime
from pathlib import Path
from typing import Any, Callable
from zoneinfo import ZoneInfo

import requests

from .. import settings
from .formatting import mask_name

_log = logging.getLogger("jeonseai")
KST = ZoneInfo("Asia/Seoul")

STORE_FILE = "blacklist_hashed.json"
STATUS_FILE = "blacklist_status.json"
TIMEOUT = 30
PAGE_SIZE = 500
MAX_PAGES = 40
REFRESH_DAYS = 7

#: 받은 줄에서 이름·나이·출생연도·채무액을 찾을 칸 이름 후보 (API마다 다르다 — 환경변수로 덮을 수 있다)
_NAME_KEYS = ("성명", "임대인명", "임대인성명", "이름", "임대인", "채무자명", "name", "nm", "lsrNm", "lessorNm", "rprsNm",
              "lsr_nm", "lessor_nm", "dbtr_nm", "debtor_nm", "rprs_nm", "flnm")
_AGE_KEYS = ("나이", "연령", "만나이", "age")
_BIRTH_KEYS = ("출생연도", "생년", "birthYear", "brthYr", "birth_year", "brth_yr")
_DEBT_KEYS = ("채무액", "보증금반환채무액", "미반환금액", "구상채무액", "debt", "debtAmt", "amt", "debt_amt", "dbt_amt")
_DATE_KEYS = ("공개일", "공개일자", "기준일자", "rlsDt", "baseDate")


def store_path() -> Path:
    return settings.data_dir() / STORE_FILE


def status_path() -> Path:
    return settings.data_dir() / STATUS_FILE


# ── 이름 열쇠 ────────────────────────────────────────────────────────────────


def _salt() -> bytes:
    from . import store

    return store.name_salt()


def salt_id(salt: bytes | None = None) -> str:
    """소금 지문(되돌릴 수 없음) — 받아 둔 명단이 **지금 소금으로 만든 것인지** 확인한다(2026-10-31 규칙 감사 경고 6).

    기록 DB를 새로 만들어 소금이 바뀌면 옛 명단의 이름 열쇠는 하나도 맞지 않는다. 그대로 쓰면 다음 주 갱신까지
    모든 집이 '같은 이름 없음(양호)'이 된다 → 지문이 다르면 명단이 없는 것으로 보고(대조 안 됨) 바로 다시 받는다.
    """
    return hmac.new(salt or _salt(), b"jeonseai-blacklist-salt-check", hashlib.sha256).hexdigest()[:12]


def name_key(name: str, salt: bytes | None = None) -> str:
    """이름 → HMAC 열쇠 (공백·가운뎃점 무시). 실명은 남기지 않는다."""
    normalized = re.sub(r"[\s·.]", "", name or "")
    if not normalized:
        return ""
    return hmac.new(salt or _salt(), normalized.encode("utf-8"), hashlib.sha256).hexdigest()[:32]


# ── 받은 자료 읽기 ───────────────────────────────────────────────────────────


def _env_keys(var: str, default: tuple[str, ...]) -> tuple[str, ...]:
    raw = os.environ.get(var, "").strip()
    return tuple(k.strip() for k in raw.split(",") if k.strip()) + default if raw else default


def _pick(row: dict, keys: tuple[str, ...]) -> Any:
    """칸 이름 후보 중 처음 값이 있는 것 — **대소문자 무시**(HUG API는 `ERROR_MSG`처럼 대문자 칸을 쓴다)."""
    lowered = {str(k).lower(): v for k, v in row.items()}
    for k in keys:
        v = lowered.get(k.lower())
        if v not in (None, ""):
            return v
    return None


def _int(v: Any) -> int | None:
    if v is None:
        return None
    digits = re.sub(r"[^\d]", "", str(v))
    return int(digits) if digits else None


def find_rows(data: Any) -> list[dict]:
    """JSON 어디에 있든 '이름 칸이 있는 줄 목록'을 찾는다(API마다 감싸는 모양이 다르다)."""
    name_keys = _env_keys("BLACKLIST_FIELD_NAME", _NAME_KEYS)
    if isinstance(data, list):
        if data and all(isinstance(x, dict) for x in data) and any(_pick(x, name_keys) for x in data):
            return data
        for x in data:
            found = find_rows(x)
            if found:
                return found
        return []
    if isinstance(data, dict):
        for v in data.values():
            found = find_rows(v)
            if found:
                return found
    return []


def parse_csv(text: str) -> list[dict]:
    return [dict(r) for r in csv.DictReader(io.StringIO(text))]


def to_entries(rows: list[dict], *, salt: bytes | None = None, year: int | None = None) -> list[dict]:
    """받은 줄 → 가린 항목 {h(이름 열쇠), by(출생연도), m(가린 이름), debt}. 실명은 여기서 끝난다."""
    name_keys = _env_keys("BLACKLIST_FIELD_NAME", _NAME_KEYS)
    age_keys = _env_keys("BLACKLIST_FIELD_AGE", _AGE_KEYS)
    year = year or datetime.now(KST).year
    out: list[dict] = []
    seen: set[tuple[str, int | None]] = set()
    for row in rows:
        name = str(_pick(row, name_keys) or "").strip()
        h = name_key(name, salt)
        if not h:
            continue
        birth = _int(_pick(row, _BIRTH_KEYS))
        if birth is None:
            age = _int(_pick(row, age_keys))
            birth = (year - age) if age and 15 < age < 120 else None
        if birth is not None and not (1900 < birth <= year):
            birth = None
        key = (h, birth)
        if key in seen:
            continue
        seen.add(key)
        out.append({"h": h, "by": birth, "m": mask_name(name), "debt": _int(_pick(row, _DEBT_KEYS))})
    return out


# ── 받기 ─────────────────────────────────────────────────────────────────────


def configured() -> bool:
    return bool(os.environ.get("BLACKLIST_SOURCE_URL", "").strip())


#: HUG 빅데이터 개방포털의 실제 주소(2026-10-31 확인 — 공공데이터포털 15161980의 연결처). 인증키 칸 이름이 `API_KEY`다.
HUG_ENDPOINT = "https://www.khug.or.kr/defaultOnDebitList.do"


class SourceError(RuntimeError):
    """받는 곳이 오류를 돌려줬다(HTTP 200이어도) — 예: HUG `[{"ERROR_CODE": …, "ERROR_MSG": "EXPIRED API_KEY."}]`."""


def _key_param(url: str) -> str:
    """인증키 칸 이름 — 환경변수가 먼저, 없으면 HUG 주소는 `API_KEY`, 그 밖(공공데이터포털 방식)은 `serviceKey`."""
    explicit = os.environ.get("BLACKLIST_KEY_PARAM", "").strip()
    if explicit:
        return explicit
    return "API_KEY" if "khug.or.kr" in url.lower() else "serviceKey"


def _api_error(data: Any) -> str | None:
    """응답 안의 오류 칸(ERROR_MSG·ERROR_CODE …)을 찾는다. 오류 글은 사람 이름이 아니라서 로그에 남겨도 된다(짧게)."""
    first = data[0] if isinstance(data, list) and data else data
    if isinstance(first, dict):
        msg = _pick(first, ("error_msg", "errmsg", "error_message", "resultmsg"))
        code = _pick(first, ("error_code", "errcode", "resultcode"))
        name = _pick(first, _env_keys("BLACKLIST_FIELD_NAME", _NAME_KEYS))
        if (msg or code) and not name and str(code or "") not in ("0", "00", "000"):
            return str(msg or code)[:80]
    return None


def _fetch_all(get: Callable[..., Any]) -> list[dict]:
    url = os.environ["BLACKLIST_SOURCE_URL"].strip()
    key = os.environ.get("BLACKLIST_API_KEY", "").strip()
    key_param = _key_param(url)
    rows: list[dict] = []
    previous: list[dict] | None = None
    for page in range(1, MAX_PAGES + 1):
        params: dict[str, Any] = {"pageNo": page, "numOfRows": PAGE_SIZE, "type": "json", "returnType": "json"}
        if key:
            params[key_param] = key
        resp = get(url, params=params, timeout=TIMEOUT)
        resp.raise_for_status()
        text = resp.text
        if url.lower().endswith(".csv") or "text/csv" in (resp.headers.get("content-type") or ""):
            got = parse_csv(text)
        else:
            data = json.loads(text)
            err = _api_error(data)
            if err:
                raise SourceError(err)
            got = find_rows(data)
        # 쪽 나눔이 없는 API(HUG)는 몇 쪽을 달라 해도 같은 목록을 준다 — 같은 쪽이 또 오면 멈춘다(같은 요청 40번 X)
        if previous is not None and got == previous:
            break
        rows += got
        previous = got
        if len(got) < PAGE_SIZE:
            break
    return rows


def refresh(*, get: Callable[..., Any] | None = None, salt: bytes | None = None) -> dict:
    """명단을 다시 받아 가린 채로 저장한다. 예외를 던지지 않는다. 실패하면 전에 받은 명단을 그대로 둔다."""
    now = datetime.now(KST).strftime("%Y-%m-%d")
    st: dict = {"checkedAt": now, "ok": False}
    if not configured():
        st["note"] = "받는 곳 설정 없음(BLACKLIST_SOURCE_URL)"
        return _save_status(st)
    try:
        rows = _fetch_all(get or requests.get)
        entries = to_entries(rows, salt=salt)
        if not entries:
            st["note"] = f"받은 줄 {len(rows)}개에서 이름을 찾지 못함 — BLACKLIST_FIELD_NAME 확인"
            return _save_status(st)
        path = store_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"fetchedAt": now, "count": len(entries), "saltId": salt_id(salt),
                                   "entries": entries}, ensure_ascii=False), encoding="utf-8")
        tmp.replace(path)
        st.update(ok=True, count=len(entries), note="받음")
        _log.info(f"[명단] 악성임대인 공개 명단 {len(entries)}명을 이름을 가려 저장했어요")
    except SourceError as e:  # 받는 곳이 말해 준 오류(키 만료 등) — 그 글을 그대로 남긴다(사람 이름 아님)
        st["note"] = f"받는 곳 오류: {e}"
        _log.info(f"[명단] ⚠ 악성임대인 명단 받는 곳 오류 — {e} (BLACKLIST_API_KEY 확인) · 전에 받은 명단 그대로")
    except Exception as e:  # noqa: BLE001 — 실패해도 전에 받은 명단 그대로
        st["note"] = f"받기 실패 ({type(e).__name__})"
        _log.info(f"[명단] ⚠ 악성임대인 명단 받기 실패 ({type(e).__name__}) — 전에 받은 명단 그대로")
    return _save_status(st)


def _save_status(st: dict) -> dict:
    try:
        p = status_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(st, ensure_ascii=False), encoding="utf-8")
    except OSError:
        pass
    return st


def due(days: int = REFRESH_DAYS) -> bool:
    if not configured():
        return False
    if store_path().exists() and not load():
        return True  # 받아 둔 파일이 지금 소금과 안 맞거나(소금이 바뀜) 비었다 — 기다리지 않고 다시 받는다
    try:
        last = json.loads(status_path().read_text(encoding="utf-8")).get("checkedAt")
        return (datetime.now(KST) - datetime.strptime(last, "%Y-%m-%d").replace(tzinfo=KST)).days >= days
    except (OSError, ValueError, TypeError):
        return True


# ── 읽기·맞춰 보기 ───────────────────────────────────────────────────────────

_cache: tuple[float, str, list[dict]] | None = None


def load() -> list[dict]:
    """가린 명단(없으면 빈 목록). 파일이 바뀌면 다시 읽는다. **지금 소금으로 만든 명단이 아니면 빈 목록**(대조 안 됨)."""
    global _cache
    try:
        p = store_path()
        mtime = p.stat().st_mtime
        current = salt_id()
        if _cache and _cache[0] == mtime and _cache[1] == current:
            return _cache[2]
        raw = json.loads(p.read_text(encoding="utf-8"))
        entries = list(raw.get("entries") or [])
        if raw.get("saltId") != current:
            # 소금이 바뀐 뒤의 옛 명단 — 맞춰 봐도 다 빗나가 '같은 이름 없음'만 나온다. 없는 것으로 본다.
            _log.info("[명단] ⚠ 받아 둔 명단이 지금 기록 DB와 맞지 않아요(소금이 바뀜) — 다시 받을 때까지 대조 안 함")
            entries = []
        _cache = (mtime, current, entries)
        return entries
    except (OSError, ValueError):
        return []


def match(owner_names: list[str], entries: list[dict], *, salt: bytes | None = None) -> list[str]:
    """집주인 이름 중 명단과 같은 사람 → 가린 이름 목록. 가린 명단(h)과 옛 실명 견본({name}) 모두 받는다."""
    hashed = {e.get("h") for e in entries if e.get("h")}
    plain = {str(e.get("name") or "").strip() for e in entries if e.get("name")}
    out: set[str] = set()
    for n in owner_names:
        if (hashed and name_key(n, salt) in hashed) or (n in plain):
            out.add(mask_name(n))
    return sorted(out)
