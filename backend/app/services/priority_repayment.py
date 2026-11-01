"""소액임차인 최우선변제 — "경매로 넘어가도 **가장 먼저** 돌려받는 돈" (2026-10-31).

**규칙 계산이다. AI가 개입하지 않는다.** 숫자는 두 곳에서만 온다.
  ① 리포트에 이미 있는 값 — 보증금 · 주소 · 살아 있는 등기 항목의 종류·접수일(`riskFacts`)
  ② `data/small_tenant_priority.json` — 주택임대차보호법 시행령 제10·11조 금액표(개정 연혁 전부)

법이 정한 것 (주택임대차보호법 제8조, 시행령 제10·11조):
- 보증금이 그 지역 **상한 이하**인 세입자는 경매 때 보증금 중 **일정액**을 다른 담보권자보다 **먼저** 받는다.
- 일정액은 낙찰가(주택가액)의 **2분의 1까지만** (시행령 제10조 ②).
- **경매신청 등기 전에** 대항요건(전입신고 + 입주)을 갖춰야 한다 (법 제8조 ①) — 이미 경매가 시작된 집에 들어가면 못 받는다.
- 표는 **가장 먼저 잡힌 담보의 날짜**로 고른다 — 시행령을 고칠 때마다 "개정 전에 담보물권을 취득한 자에게는 종전 규정"
  이라는 경과조치를 두었다. 그래서 2023년 표가 아니라 그 근저당이 잡힌 해의 표를 쓴다.

지켜야 하는 것 (보수적 편향 — 애매하면 덜 받는 쪽):
- 날짜를 못 읽은 근저당·권리가 있으면 표를 고를 수 없다 → 더하지 않는다(`unknown_date`).
- 가압류·압류는 담보물권이 아니지만 **기준일 후보에 넣는다** — 더 이른 날짜는 더 옛 표(더 적은 돈)라서, 넣어서 틀리면 덜 받는 쪽으로 틀린다.
- 지역이 애매하면(인천 경제자유구역·산업단지 동, 남양주·시흥 일부, 동 이름을 못 읽음) **보호가 적은 쪽** 지역으로 본다.
- 단독·다가구는 한 집에 소액임차인이 여럿이라 낙찰가의 절반을 나눈다(시행령 제10조 ③④) — 다른 세입자를 모르니
  **더하지 않고** 얼마까지인지만 알린다(`shared`).
- 이미 경매가 시작된 집 → 0원(`blocked_auction`).
- 임차권등기가 남아 있는 집(단독·다가구가 아닌 한 집) → 0원(`blocked_lease`, 2026-11-01). 임차권등기가 끝난 주택을
  그 뒤에 빌린 세입자는 최우선변제를 받을 권리가 없다(법 제3조의3 ⑥). 단독·다가구는 등기가 다른 호실일 수 있어
  원래대로 `shared`(더하지 않음)로 둔다.

판정 등급과는 무관하다(참고 정보). 판정 엔진은 이 파일을 모른다.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from . import price_normalize as N
from .loss_estimate import sido_of
from .registry_facts import norm_date

_log = logging.getLogger("jeonseai")
KST = ZoneInfo("Asia/Seoul")

TABLE_PATH = Path(__file__).resolve().parents[2] / "data" / "small_tenant_priority.json"

#: 기준일 후보 — 담보물권(근저당·전세권) + 보수적으로 가압류·압류 (위 docstring)
BASE_KINDS = ("근저당", "전세권", "가압류", "압류")
#: 이미 경매가 시작됐다는 표시
AUCTION_KIND = "경매개시결정"
#: 전 세입자가 보증금을 못 받고 남긴 임차권등기 — 그 뒤에 빌린 세입자는 최우선변제를 못 받는다(법 제3조의3 ⑥)
LEASE_KIND = "임차권등기"

_METRO = {"부산", "대구", "인천", "광주", "대전", "울산"}
_COUNTY_RE = re.compile(r"군$")
_DONG_RE = re.compile(r"^[가-힣0-9]+(동|가|읍|면|리)$")


# ── 결과 ─────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Priority:
    """최우선변제 계산 결과 하나."""

    status: str  # ok | over_cap | blocked_auction | blocked_lease | shared | unknown_date | no_table
    amount: int = 0  # 실제로 '돌려받음'에 더한 금액 (ok일 때만 0보다 크다)
    limit: int | None = None  # 그 표·지역의 일정액(보증금 중 먼저 받는 한도)
    cap: int | None = None  # 그 표·지역의 보증금 상한(이하여야 받는다)
    region: str | None = None  # 지역 이름 — '서울특별시' · '수도권 과밀억제권역(서울 제외)'
    region_unsure: bool = False  # 지역이 애매해 보호가 적은 쪽으로 봤다
    table_from: str | None = None  # 고른 표가 시작된 날 'YYYY-MM-DD'
    base_date: str | None = None  # 그 표를 고른 날짜(가장 먼저 잡힌 담보) — 없으면 None(오늘 기준)
    base_kind: str | None = None  # 그 날짜의 종류 — '근저당' 등
    half_capped: bool = False  # 낙찰가의 절반에 걸려 줄었다
    source: str | None = None  # '주택임대차보호법 시행령 제10·11조'


# ── 표 ───────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class _Group:
    region: str
    label: str
    cap: int
    amount: int
    cities: tuple[str, ...] = ()


@dataclass(frozen=True)
class _Table:
    start: str
    groups: tuple[_Group, ...]


@dataclass(frozen=True)
class Tables:
    tables: tuple[_Table, ...]
    source_short: str
    overcrowded: dict = field(default_factory=dict)

    def pick(self, on: str) -> _Table | None:
        """그 날짜에 쓰이던 표 — 시작일이 그날 이전인 것 중 가장 늦은 것."""
        found = [t for t in self.tables if t.start <= on]
        return max(found, key=lambda t: t.start) if found else None


_cache: tuple[float, Tables] | None = None


def load_tables(path: Path = TABLE_PATH) -> Tables:
    """파일이 바뀌면 다시 읽는다. 못 읽으면 빈 표(계산하지 않는다 — `no_table`)."""
    global _cache
    try:
        mtime = path.stat().st_mtime
        if _cache and _cache[0] == mtime:
            return _cache[1]
        raw = json.loads(path.read_text(encoding="utf-8"))
        tables = tuple(
            _Table(
                start=str(t["from"]),
                groups=tuple(
                    _Group(
                        region=str(g["region"]),
                        label=str(g["label"]),
                        cap=int(g["cap"]),
                        amount=int(g["amount"]),
                        cities=tuple(g.get("cities") or ()),
                    )
                    for g in t["groups"]
                ),
            )
            for t in raw.get("tables") or []
        )
        out = Tables(
            tables=tables,
            source_short=str(raw.get("sourceShort") or "주택임대차보호법 시행령 제10·11조"),
            overcrowded=dict(raw.get("overcrowdedArea") or {}),
        )
        _cache = (mtime, out)
        return out
    except Exception as e:  # noqa: BLE001 — 표가 깨져도 손실 계산은 산다(최우선변제만 빠진다)
        _log.error(f"[최우선변제] ⚠ 금액표를 읽지 못했습니다 ({type(e).__name__}) — 최우선변제 없이 계산합니다")
        return Tables(tables=(), source_short="", overcrowded={})


# ── 주소 → 지역 ─────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Place:
    sido: str | None  # '서울' · '경기' …
    sigungu: str | None  # '서초구' · '수원시' · '강화군'
    dong: str | None  # '서초동' · '송도동'
    tokens: tuple[str, ...] = ()


def parse_place(address: str | None) -> Place:
    text = re.sub(r"^\s*\[[^\]]*\]\s*", "", address or "").strip()
    tokens = tuple(t for t in re.split(r"\s+", text) if t)
    sido = sido_of(text)
    sigungu = None
    dong = None
    for t in tokens[1:4]:
        if sigungu is None and re.search(r"(시|군|구)$", t) and not t.endswith("특별자치시"):
            sigungu = t
            continue
        if dong is None and _DONG_RE.match(t):
            dong = t
            break
    return Place(sido=sido, sigungu=sigungu, dong=dong, tokens=tokens)


def _city_key(place: Place) -> str | None:
    """표의 'cities' 목록과 맞출 이름 — '용인시' · '경기 광주시'(광주광역시와 다르다) · '세종특별자치시'."""
    if place.sido == "세종":
        return "세종특별자치시"
    if place.sido == "경기" and place.sigungu:
        return "경기 광주시" if place.sigungu == "광주시" else place.sigungu
    return None


def _in_overcrowded(place: Place, oc: dict) -> bool | None:
    """수도권정비계획법 과밀억제권역인가 — True / False / None(애매)."""
    whole = set(oc.get("whole") or ())
    if place.sido == "서울":
        return True
    if place.sido == "경기":
        city = place.sigungu
        if city is None:
            return None
        if city in whole:
            return True
        if city == "남양주시":
            if place.dong is None:
                return None
            return True if place.dong in set(oc.get("namyangjuIncluded") or ()) else False
        if city == "시흥시":
            if place.dong is None:
                return None
            return None if place.dong in set(oc.get("siheungExcludedDongs") or ()) else True
        return False
    if place.sido == "인천":
        ex = oc.get("incheonExcluded") or {}
        if place.sigungu in set(ex.get("counties") or ()):
            return False
        if place.dong is None:
            return None
        if place.sigungu == "서구" and place.dong in set(ex.get("seoGuDongs") or ()):
            return False
        partial = set(ex.get("freeEconomicZoneDongs") or ()) | set(ex.get("industrialComplexDongs") or ())
        if place.dong in partial:
            return None  # 경제자유구역·산업단지는 동의 일부만 — 애매하다
        return True
    return False


def _is_county(place: Place) -> bool:
    return bool(place.sigungu and _COUNTY_RE.search(place.sigungu))


def _member(group: _Group, place: Place, oc: dict, table_start: str) -> bool | None:
    """이 집이 그 지역 묶음에 드는가 — True / False / None(애매)."""
    city = _city_key(place)
    if city and city in group.cities:
        return True
    r = group.region
    if r == "other":
        return True
    if r == "seoul":
        return place.sido == "서울"
    if r == "overcrowded":
        return _in_overcrowded(place, oc)
    if r == "metro":
        # 광역시(과밀억제권역에 포함된 지역과 군 지역은 제외) — 인천의 과밀억제권역 밖 구가 여기 든다
        # 인천: 과밀억제권역이면 앞 묶음(과밀억제권역)에서 이미 골랐다. 여기까지 왔으면 과밀억제권역이 아니거나
        # 애매한 곳이고, 애매하면 보호가 적은 이 묶음이 맞다.
        if place.sido not in _METRO or _is_county(place):
            return False
        return True
    if r == "metro_no_county_no_incheon":
        return place.sido in (_METRO - {"인천"}) and not _is_county(place)
    if r == "metro_no_county":
        # 특별시·광역시(군 지역 제외) — 울산은 1997-07-15에 광역시가 됐다(그 전 표에서는 보수적으로 제외)
        return place.sido in ({"서울"} | _METRO - {"울산"}) and not _is_county(place)
    if r == "metro_old":
        # 특별시·직할시 — 광주는 1986-11-01, 대전은 1989-01-01에 직할시가 됐다(그 전 표에서는 제외)
        ok = {"서울", "부산", "대구", "인천"}
        if table_start >= "1987-12-01":
            ok.add("광주")
        if table_start >= "1990-02-19":
            ok.add("대전")
        return place.sido in ok and not _is_county(place)
    return None


def _pick_group(table: _Table, place: Place, oc: dict) -> tuple[_Group | None, bool]:
    """보호가 큰 묶음부터 맞춰 본다. 애매한 묶음은 건너뛴다(보호가 적은 쪽으로). (묶음, 애매했나)."""
    unsure = False
    for g in table.groups:
        m = _member(g, place, oc, table.start)
        if m is True:
            return g, unsure
        if m is None:
            unsure = True
    return None, unsure


# ── 계산 ─────────────────────────────────────────────────────────────────────


def _base(risk_facts) -> tuple[str | None, str | None, bool]:
    """(가장 이른 날짜, 그 종류, 날짜를 못 읽은 항목이 있나)."""
    best: tuple[str, str] | None = None
    unknown = False
    for f in risk_facts or []:
        kind = getattr(f, "kind", None)
        if kind not in BASE_KINDS:
            continue
        d = norm_date(getattr(f, "receiptDate", None))
        if d is None:
            unknown = True
            continue
        if best is None or d < best[0]:
            best = (d, kind)
    return (best[0] if best else None), (best[1] if best else None), unknown


def compute(
    *,
    deposit: int,
    address: str | None,
    risk_facts,
    senior_debt: int,
    expected_sale: int | None,
    whole_building: bool | None = None,
    today: date | None = None,
    tables: Tables | None = None,
) -> Priority:
    """리포트 사실 → 최우선변제. 예외를 던지지 않는다."""
    tables = tables or load_tables()
    if not tables.tables:
        return Priority(status="no_table")
    src = tables.source_short
    facts = list(risk_facts or [])
    if any(getattr(f, "kind", None) == AUCTION_KIND for f in facts):
        return Priority(status="blocked_auction", source=src)
    if whole_building is None:
        whole_building = N.is_whole_building(address or "")
    if not whole_building and any(getattr(f, "kind", None) == LEASE_KIND for f in facts):
        return Priority(status="blocked_lease", source=src)

    base_date, base_kind, unknown = _base(facts)
    has_debt_fact = any(getattr(f, "kind", None) in ("근저당", "전세권") for f in facts)
    if unknown or (senior_debt > 0 and not has_debt_fact):
        # 날짜를 못 읽었거나, 빚은 있는데 항목 사실이 없다(2026-10-24 전 리포트) — 표를 고를 수 없다
        return Priority(status="unknown_date", source=src)

    on = base_date or (today or datetime.now(KST).date()).isoformat()
    table = tables.pick(on)
    if table is None:
        return Priority(status="no_table", source=src, base_date=base_date, base_kind=base_kind)
    place = parse_place(address)
    group, unsure = _pick_group(table, place, tables.overcrowded)
    if group is None:
        return Priority(status="no_table", source=src, table_from=table.start, base_date=base_date, base_kind=base_kind)

    common = dict(
        limit=group.amount,
        cap=group.cap,
        region=group.label,
        region_unsure=unsure,
        table_from=table.start,
        base_date=base_date,
        base_kind=base_kind,
        source=src,
    )
    if deposit > group.cap:
        return Priority(status="over_cap", **common)

    amount = min(group.amount, deposit)
    half_capped = False
    if expected_sale is not None:
        half = max(0, expected_sale // 2)
        if amount > half:
            amount, half_capped = half, True
    if whole_building:
        return Priority(status="shared", amount=0, half_capped=half_capped, **common)
    return Priority(status="ok", amount=amount, half_capped=half_capped, **common)
