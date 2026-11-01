"""먼저 받아갈 빚의 **받는 순서** — 등기부 순위번호와 화면의 'N순위'를 갈라 두는 한 곳 (2026-11-01).

규혁(2026-11-01 실기기): 을구 1번 근저당이 말소되고(2번은 그 말소 기록) 3번·4번만 살아 있는 등기부에서
리포트가 '3순위 근저당 · 4순위 근저당'이라고 보여 줬다 → "1순위 2순위는 어디 갔지?" 사용자는 헷갈린다.

- 등기부의 **순위번호**는 표의 칸 번호다. 말소된 줄도 번호를 그대로 차지한다(지워져도 번호는 안 당겨진다).
- 사용자가 궁금한 것은 경매로 팔리면 **몇 번째로 받아 가나**다. 그래서 화면의 'N순위'는 **살아 있는 빚끼리의 순서**로 쓴다.
  등기부 칸 번호는 사진과 맞춰 볼 때만 '을구 3번'처럼 따로 적는다.

순서의 근거 — 부동산등기법 제4조: 같은 구(區)에서 한 등기 사이의 순위는 **순위번호**를 따른다.
먼저 받아갈 빚(근저당권·전세권)은 모두 **을구**라 순위번호 순서가 곧 받는 순서다.

⚠ 순서를 **확실히 알 때만** 번호를 붙인다(지어내지 않는다).
  ① 모든 항목의 순위번호를 읽었으면 → 순위번호 순.
  ② 하나라도 못 읽었으면(IE가 같은 서류에서도 순위번호를 빼먹을 때가 있다 — compare.py 참고) → 접수일이 모두 다르면 접수일 순.
  ③ 그것도 안 되면 → 번호 없음('근저당'으로만). 그림(줄 서기)의 칸 순서는 예전처럼 가능한 만큼 맞춘다.
⚠ 판정과 무관하다(표시·설명 재료). 등급·합계는 이 파일을 보지 않는다.
"""

from __future__ import annotations

import re
from typing import Any, Iterable

from .registry_facts import norm_date

_RANK_RE = re.compile(r"^\s*(\d+)(?:\s*-\s*(\d+))?\s*$")


def rank_key(rank_number: object) -> tuple[int, int] | None:
    """'3' → (3, 0) · '3-1' → (3, 1). 못 읽으면 None."""
    m = _RANK_RE.match(str(rank_number or ""))
    if not m:
        return None
    return int(m.group(1)), int(m.group(2) or 0)


def _get(entry: Any, key: str) -> Any:
    if isinstance(entry, dict):
        return entry.get(key)
    if hasattr(entry, "model_dump"):
        return entry.model_dump().get(key)
    return getattr(entry, key, None)


def orders(entries: Iterable[Any]) -> list[int | None]:
    """을구 빚 항목들(근저당·전세권, **살아 있는 것만** 넘긴다) → 같은 순서의 받는 순서(1부터) 목록.

    순서를 확실히 모르면 전부 None. 항목은 dict(rule_engine facts)든 등기 항목 객체든 된다.
    """
    items = list(entries)
    if not items:
        return []
    ranks = [rank_key(_get(e, "rank_number")) for e in items]
    if all(r is not None for r in ranks) and len(set(ranks)) == len(ranks):
        keys: list[tuple] = [r for r in ranks]  # type: ignore[misc]
    else:
        dates = [norm_date(_get(e, "receipt_date")) for e in items]
        if all(dates) and len(set(dates)) == len(dates):
            keys = [(d,) for d in dates]
        else:
            return [None] * len(items)
    order_of = {i: n for n, i in enumerate(sorted(range(len(items)), key=lambda i: keys[i]), start=1)}
    return [order_of[i] for i in range(len(items))]


def sort_key(entry: Any) -> tuple:
    """줄 서기 칸을 늘어놓는 순서 — 순위번호가 있으면 그것, 없으면 접수일(예전 evidence_view와 같은 규칙)."""
    r = rank_key(_get(entry, "rank_number"))
    if r is not None:
        return (0, r)
    return (1, str(norm_date(_get(entry, "receipt_date")) or "9999-99-99"))


def label(kind: str, order: int | None) -> str:
    """'1순위 근저당' · 순서를 모르면 '근저당'."""
    return f"{order}순위 {kind}" if order else kind


def registry_ref(section: str | None, rank_number: object) -> str | None:
    """사진과 맞춰 볼 등기부 칸 번호 — '을구 3번'. 순위번호를 못 읽었으면 None."""
    r = str(rank_number or "").strip()
    if not r or rank_key(r) is None:
        return None
    return f"{section} {r}번" if section else f"{r}번"
