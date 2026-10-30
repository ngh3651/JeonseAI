"""법령 지켜보기 — 최우선변제 금액표(시행령 제10·11조)가 바뀌었는지 매주 법제처에서 확인한다 (2026-10-31).

왜 숫자를 저절로 고치지 않나: 금액표는 사람이 법령 원문과 대조해 `data/small_tenant_priority.json`에 넣는다(출처 원칙 §2-2).
자동으로 읽은 숫자로 바로 계산을 바꾸면, 원문 모양이 조금만 달라도 틀린 돈이 화면에 나간다. 그래서 이 모듈은
**바뀐 것을 알아채기만** 한다:
1. 법제처 Open API(lawSearch, target=law)에 '주택임대차보호법 시행령'을 묻고 시행일자를 본다.
2. 우리 표의 `latestAmendment`보다 새 시행일이면 본문(lawService)을 받아 제10조·제11조의 금액을 읽는다.
3. 읽은 금액이 지금 표와 같으면(다른 조만 고친 개정) 그대로, 다르면 `stale` 표시를 남긴다 →
   손실 시뮬레이터가 "법령이 바뀌어 금액을 다시 확인하고 있어요"를 붙이고, 배포 로그에 크게 경고한다(사람이 표를 고친다).

판례 자동 업데이트와 같은 알람시계(`precedent.updater._loop`)에서 돈다. 실패해도 아무것도 바꾸지 않는다.
판정 등급과 무관하다.
"""

from __future__ import annotations

import json
import logging
import re
from datetime import datetime
from pathlib import Path

import requests

from .. import settings
from . import priority_repayment as P

_log = logging.getLogger("jeonseai")

SEARCH_URL = "https://www.law.go.kr/DRF/lawSearch.do"
SERVICE_URL = "https://www.law.go.kr/DRF/lawService.do"
LAW_NAME = "주택임대차보호법 시행령"
TIMEOUT = 30
STATUS_FILE = "law_watch.json"

_WON = re.compile(r"(?:(\d+)억)?\s*(?:(\d+)천)?\s*(\d+)?\s*만\s*원")


def status_path() -> Path:
    return settings.data_dir() / STATUS_FILE


def read_status() -> dict:
    try:
        return json.loads(status_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def priority_table_stale() -> bool:
    """법령이 바뀌었는데 우리 표가 아직 그대로인가 — 손실 시뮬레이터가 한 줄 붙인다."""
    st = read_status()
    return bool(st.get("stale")) and st.get("ourAmendment") == _our_amendment()


def due(now: datetime | None = None, days: int = 7) -> bool:
    """마지막 확인에서 일주일이 지났나 (기록이 없으면 바로)."""
    last = read_status().get("checkedAt")
    if not last:
        return True
    try:
        last_day = datetime.strptime(last, "%Y-%m-%d").replace(tzinfo=P.KST)
    except ValueError:
        return True
    return ((now or datetime.now(P.KST)) - last_day).days >= days


def parse_won(text: str) -> int | None:
    """'1억6천500만원' → 165000000 · '8천500만원' → 85000000. 못 읽으면 None."""
    m = _WON.search(text or "")
    if not m or not any(m.groups()):
        return None
    eok, cheon, man = (int(x) if x else 0 for x in m.groups())
    return eok * 100_000_000 + cheon * 10_000_000 + man * 10_000


def amounts_in(text: str) -> list[int]:
    out = []
    for m in _WON.finditer(text or ""):
        if any(m.groups()):
            eok, cheon, man = (int(x) if x else 0 for x in m.groups())
            out.append(eok * 100_000_000 + cheon * 10_000_000 + man * 10_000)
    return out


def _flatten(node) -> str:
    if isinstance(node, dict):
        return "\n".join(_flatten(v) for v in node.values())
    if isinstance(node, list):
        return "\n".join(_flatten(v) for v in node)
    return str(node) if node is not None else ""


def article(text: str, number: int) -> str:
    """본문 글자에서 제N조 하나 — 다음 조('제N+1조(')가 나올 때까지."""
    start = text.find(f"제{number}조(")
    if start < 0:
        return ""
    end = text.find(f"제{number + 1}조(", start + 1)
    return text[start:end if end > 0 else len(text)]


def _our_amendment() -> str:
    try:
        raw = json.loads(P.TABLE_PATH.read_text(encoding="utf-8"))
        return str(raw.get("latestAmendment") or "")
    except (OSError, ValueError):
        return ""


def _current_amounts() -> tuple[set[int], set[int]]:
    """지금 표의 (상한들, 일정액들)."""
    t = P.load_tables()
    latest = max(t.tables, key=lambda x: x.start) if t.tables else None
    if latest is None:
        return set(), set()
    return {g.cap for g in latest.groups}, {g.amount for g in latest.groups}


def _get_json(url: str, params: dict) -> dict:
    resp = requests.get(url, params=params, timeout=TIMEOUT)
    resp.raise_for_status()
    data = resp.json()
    if "검증에 실패" in json.dumps(data, ensure_ascii=False):
        raise RuntimeError("법제처 API 사용자 검증 실패 — LAW_API_OC·서버 IP 등록 확인 필요")
    return data


def _effective_date(item: dict) -> str | None:
    raw = str(item.get("시행일자") or "").strip()
    if len(raw) == 8 and raw.isdigit():
        return f"{raw[:4]}-{raw[4:6]}-{raw[6:]}"
    return None


def check(*, get_json=None, now: datetime | None = None) -> dict:
    """한 번 확인하고 기록을 남긴다. 예외를 던지지 않는다. 돌려주는 값 = 남긴 기록."""
    get_json = get_json or _get_json
    oc = settings.law_api_oc()
    ours = _our_amendment()
    st: dict = {"checkedAt": (now or datetime.now(P.KST)).strftime("%Y-%m-%d"), "ourAmendment": ours, "stale": False}
    try:
        data = get_json(SEARCH_URL, {"OC": oc, "target": "law", "type": "JSON", "query": LAW_NAME, "display": 20})
        items = data.get("LawSearch", {}).get("law", [])
        items = [items] if isinstance(items, dict) else list(items or [])
        exact = [i for i in items if str(i.get("법령명한글") or "").replace(" ", "") == LAW_NAME.replace(" ", "")]
        if not exact:
            st["note"] = "법령을 찾지 못함"
            return _save(st)
        latest = max(exact, key=lambda i: _effective_date(i) or "")
        eff = _effective_date(latest)
        st["lawEffective"] = eff
        if not eff or not ours or eff <= ours:
            return _save(st)
        # 새 시행일 — 본문의 제10조·제11조 금액이 지금 표와 같은지 본다
        mst = latest.get("법령일련번호") or latest.get("MST")
        body = get_json(SERVICE_URL, {"OC": oc, "target": "law", "type": "JSON", "MST": mst})
        text = _flatten(body)
        caps, amounts = set(amounts_in(article(text, 11))), set(amounts_in(article(text, 10)))
        our_caps, our_amounts = _current_amounts()
        if caps and amounts and caps == our_caps and our_amounts <= amounts:
            st["note"] = "다른 조를 고친 개정 — 금액 그대로"
            return _save(st)
        st["stale"] = True
        st["note"] = "제10·11조 금액이 바뀐 것 같음 — data/small_tenant_priority.json을 법령 원문과 대조해 고칠 것"
        _log.warning(
            f"[법령] ⚠⚠ {LAW_NAME} 시행일 {eff} — 최우선변제 금액표(우리 표 {ours})가 바뀐 것 같아요. "
            "사람이 원문과 대조해 표를 고칠 때까지 손실 시뮬레이터에 '확인 중'이 붙어요"
        )
        return _save(st)
    except Exception as e:  # noqa: BLE001 — 확인 실패는 아무것도 바꾸지 않는다
        st["note"] = f"확인 실패 ({type(e).__name__})"
        return _save(st)


def _save(st: dict) -> dict:
    try:
        path = status_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(st, ensure_ascii=False, indent=2), encoding="utf-8")
    except OSError:
        pass
    _log.info(f"[법령] 최우선변제 표 확인 — {st.get('note') or ('바뀜' if st.get('stale') else '그대로')}")
    return st
