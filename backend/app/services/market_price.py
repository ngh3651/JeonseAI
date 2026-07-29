"""국토부 실거래가 조회·집계 — 시세 자동 조회 (STEP 2·3).

⚠ 이 모듈은 **판정에 개입하지 않는다.** 위험 등급·임계값과 무관하고, 아직 analyze
  흐름에도 배선돼 있지 않다(CLI 전용). 조회 실패·0건은 `None`으로 끝나며, 그때
  전세가율은 지금처럼 '확인 필요'로 남는다 — 리포트는 그대로 완성된다.

⚠ **모르면 채우지 않는다.** 추정·평균·인접 평형 환산을 하지 않는다. 자동으로 채운
  시세가 틀리면 전세가율 판정이 통째로 틀리고, 그중 "시세를 높게 잡는" 방향은
  위험한 매물을 안전하다고 말하는 미탐이 된다.

호출·키 로딩·타임아웃·에러 처리·원응답 저장은 `extraction.py`/`ocr.py`의 패턴을 따른다.
다만 응답이 JSON이 아니라 **XML**이고, HTTP 200인데 본문에 에러가 담겨 오므로
`resultCode`를 반드시 확인한다.

────────────────────────────────────────────────────────────────────────
[2026-07-29 실호출로 확인한 사실 — 추측한 값이 없다]

응답 필드(아파트 매매 기준):
  <dealAmount>235,000</dealAmount>  콤마 포함 문자열, **만원 단위** → ×10,000 = 원
  <excluUseAr>84.88</excluUseAr>    전용면적 ㎡ (소수점 2~4자리)
  <umdNm>○○동</umdNm>               읍면동명 — **지번과 분리돼 있다**
  <jibun>727-6</jibun>              부번은 하이픈
  <cdealType>O</cdealType>          해제거래 표시(정상 거래는 빈 문자열)
  <cdealDay>26.04.30</cdealDay>     해제일
  <aptNm>○○파크</aptNm>            등기부 단지명과 **표기가 다르다**(등기부는 동 이름이 붙은 긴 명칭)

⚠ 잘못된 코드도 정상 응답으로 온다: LAWD_CD=99999·00000·42110(폐지) 모두
  `resultCode=000 OK, totalCount=0`. **"코드가 틀렸다"와 "거래가 없다"를 응답으로
  구분할 수 없다.** 그래서 `lawd_code`의 후보를 순서대로 시도해 첫 유효 응답을 쓴다.

⚠ 건물명으로 매칭하지 않는다. 실측한 두 등기부에서 모두 어긋났다 —
  ⑴ 아파트: 등기부는 동 이름이 붙은 긴 명칭, API는 짧은 브랜드명만.
  ⑵ 다세대: 등기 명칭이 사실상 '주건축물'뿐이라 아무것도 특정하지 못한다.

⚠ 층·호로 매칭하지 않는다 — 공동주택의 동·호는 실거래가에 공개되지 않는다.
────────────────────────────────────────────────────────────────────────
"""

from __future__ import annotations

import logging
import os
import re
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from statistics import quantiles

import requests
from dotenv import load_dotenv

from ..dependencies import DEV_MODE_AUTH
from . import artifacts, lawd_code
from .lawd_code import lawd_candidates

_log = logging.getLogger("jeonseai")

_BACKEND_ROOT = Path(__file__).resolve().parents[2]

# 타임아웃 — 실측 근거: 2026-07-29 프로브에서 시군구 1개월(최대 305건) 응답이
# 1초 미만이었다. IE(300초)·OCR(120초)보다 훨씬 짧게 잡아도 안전하고, 시세 때문에
# 분석 전체가 느려지면 안 되므로 짧게 둔다.
REQUEST_TIMEOUT_SECONDS = 20

# 병렬 폭 — 월 단위 호출을 동시에 던진다. 공공 API라 크레딧 비용은 없지만
# 동시 요청을 과하게 늘리면 제한에 걸릴 위험만 커진다(ocr.py의 판단과 같은 이유).
MAX_WORKERS = 6

# [개발 모드 전용] 원응답 저장 — extraction.SAVE_IE_RAW / ocr.SAVE_OCR_RAW와 같은 스위치.
# 운영 전환(DEV_MODE_AUTH=False) 시 함께 꺼진다.
# ⚠ 실거래가 응답 자체에는 개인정보가 없지만(지번·면적·금액은 공개 정보),
#   **어느 지번을 조회했는지**가 남으므로 out/(.gitignore)에만 둔다.
SAVE_MOLIT_RAW = DEV_MODE_AUTH

_RESULT_OK = "000"


class MarketPriceError(Exception):
    """실거래가 조회 실패 — 상태코드 + 사용자용 한국어 메시지 (extraction.py 계약과 동일)."""

    def __init__(self, status_code: int, detail: str):
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


# ── 엔드포인트 ───────────────────────────────────────────────────────────────
#
# 2026-07-29 실호출로 생존 확인(양천구 11470 / 202606):
#   아파트매매 totalCount=215 · 연립다세대매매 160 · 오피스텔매매 19
#
# ⚠ 단독·다가구는 **의도적으로 넣지 않았다.** 실거래가 공개 정책상 지번이 일부만
#   제공돼 지번 매칭이 원천적으로 불가능하다. 엔드포인트를 아예 두지 않았으므로
#   이 유형은 조회 자체가 일어나지 않고, 결과는 항상 `None`(사용자 직접 입력)이 된다.
#
#   ⚠ 전세사기가 가장 많은 유형이 여기 포함된다. 이 한계는 숨기지 않는다.
#     더구나 다가구는 시세를 직접 넣어도 전세가율의 의미가 약하다 — **앞순위 세입자들의
#     보증금 합계가 등기부에 나오지 않기 때문**이다(선순위 임차인 확인 불가, 기존 미결
#     항목과 같은 뿌리). 배선 단계의 안내 문구는 "자동 조회 불가"에서 멈추지 말고
#     이 실제 한계까지 이어져야 한다.
_BASE = "http://apis.data.go.kr/1613000"
ENDPOINTS: dict[str, str] = {
    "apt": f"{_BASE}/RTMSDataSvcAptTrade/getRTMSDataSvcAptTrade",
    "row_house": f"{_BASE}/RTMSDataSvcRHTrade/getRTMSDataSvcRHTrade",
    "officetel": f"{_BASE}/RTMSDataSvcOffiTrade/getRTMSDataSvcOffiTrade",
}
HOUSE_TYPE_LABELS = {"apt": "아파트", "row_house": "연립·다세대", "officetel": "오피스텔"}

# 어느 유형인지 등기부에서 알 수 없으므로 **전부 조회해 합친다.**
# 유형이 틀린 응답은 지번·면적 필터에서 자연히 0건이 되므로, 유형 오판으로
# 엉뚱한 시세를 쓰는 사고가 구조적으로 불가능하다.
# (표제부 '건물내역'을 힌트로 써서 호출 수를 줄이는 길이 있으나 지금은 하지 않는다.)
ALL_HOUSE_TYPES = ("apt", "row_house", "officetel")

# 조회 기간 — [2026-07-29 결정]
# 기본 6개월. 0건이면 **12개월로 한 번만** 넓힌다. 그 이상 넓히지 않는다.
#
# 왜 최근 1개월이 비어 보이나: 부동산거래신고법상 신고 기한이 **계약일로부터 30일**이라
# 최근 한 달은 구조적으로 미완성이다. 시장이 아니라 제도 때문이다.
#
# 왜 무한정 넓히지 않나 (실측 단지 84.88㎡ 기준): 조회 기간을 늘리면
# 시세가 체계적으로 내려간다 — 6개월 Q1 21.75억 / 12개월 19.30억 / 24개월 17.50억.
# 상승장에서는 옛 저가 거래가 통계량 종류와 무관하게 값을 끌어내린다.
# 즉 **우리가 고른 기간이 판정을 흔든다.** 짧게 고정하는 것이 유일한 방어다.
DEFAULT_MONTHS = 6
FALLBACK_MONTHS = 12

# 면적 허용오차 — [2026-07-29 실측 확정]
# 등기부 전유면적과 API 전용면적은 **같은 건축물대장에서 나와 정확히 일치한다.**
# 실측 1쌍: 등기부 표제부 114.756㎡ ↔ API excluUseAr 114.756 (소수점 3자리까지 동일).
# 따라서 허용오차는 '평형을 넓게 묶기' 위한 것이 아니라 **OCR/추출 반올림을 흡수**하기
# 위한 것이다. ±1%면 충분하다.
#
# 왜 애초 계획한 ±10%를 쓰지 않나: 같은 단지에 84.74와 84.88이 **0.17% 차이로 공존**한다.
# ±10%(84.88 기준 76.4~93.4㎡)는 인접 평형을 섞을 수 있고, 값이 다른 물건을 한 바구니에
# 넣으면 시세가 흐려진다. 실측상 ±1%로도 대상 평형 10건이 전부 잡혔다.
AREA_TOLERANCE_RATIO = 0.01

# 집계에서 최저가 대신 하위 25% 분위수를 쓰는 표본 하한.
# 3건 이하에서는 분위수가 의미를 잃어 최저가로 떨어뜨린다.
QUANTILE_MIN_SAMPLES = 4


@dataclass(frozen=True)
class Trade:
    """실거래 1건 — 원본 필드를 우리 이름으로 옮긴 것."""

    house_type: str  # 'apt' | 'row_house' | 'officetel'
    umd_nm: str  # 읍면동
    jibun: str  # 지번 (부번은 '727-6')
    area_sqm: float  # 전용면적
    price_won: int  # 거래금액(원)
    deal_year: int
    deal_month: int
    deal_day: int
    floor: str
    building_name: str  # 참고용 — **매칭에 쓰지 않는다**
    canceled: bool  # 해제거래 여부

    @property
    def deal_date(self) -> date:
        return date(self.deal_year, self.deal_month, self.deal_day)


@dataclass(frozen=True)
class MarketPriceResult:
    """집계 결과. 숫자만 내려보내지 않는다 — 기간·건수가 항상 따라붙는다."""

    price_won: int  # 채택된 시세(원)
    sample_count: int
    period_from: str  # 'YYYY-MM'
    period_to: str  # 'YYYY-MM'
    method: str  # 'quantile_25' | 'min'
    source: str  # 출처 문구
    latest_deal_date: date  # 표본 중 가장 최근 거래일
    low_won: int  # 표본 최저가 (화면 표시용 범위)
    high_won: int  # 표본 최고가
    months_used: int  # 실제로 사용한 조회 개월 수 (6 또는 12)


# ── 키·요청 ──────────────────────────────────────────────────────────────────


def _load_api_key() -> str:
    """backend/.env의 MOLIT_API_KEY를 읽는다 (하드코딩 금지 — api-design 규칙)."""
    load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")
    key = os.environ.get("MOLIT_API_KEY", "").strip()
    if not key:
        raise MarketPriceError(500, "서버에 실거래가 API 키가 설정되지 않았어요 (backend/.env)")
    return key


def parse_amount_won(raw: str) -> int:
    """`dealAmount` → 원 단위 int.

    실측: `<dealAmount>235,000</dealAmount>` = **235,000만원 = 23.5억원**.
    콤마가 들어간 문자열이고 단위가 만원이므로, 콤마를 지우고 10,000을 곱한다.
    (단위를 추측하지 않았다 — 서울 84.88㎡ 아파트가 23.5억이라는 현실적인 값이 나오는지
     교차 확인했다.)
    """
    digits = raw.replace(",", "").strip()
    if not digits:
        raise ValueError("빈 거래금액")
    return int(digits) * 10_000


def month_codes(months: int, *, today: date) -> list[str]:
    """최근 N개월의 `DEAL_YMD`(YYYYMM) 목록 — 이번 달 포함, 과거로 거슬러."""
    out: list[str] = []
    y, m = today.year, today.month
    for _ in range(months):
        out.append(f"{y}{m:02d}")
        m -= 1
        if m == 0:
            y, m = y - 1, 12
    return list(reversed(out))


def _text(node: ET.Element, tag: str) -> str:
    return (node.findtext(tag) or "").strip()


def _parse_items(xml_text: str, house_type: str) -> list[Trade]:
    """XML 본문 → Trade 목록. `resultCode`가 성공이 아니면 예외."""
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as e:
        raise MarketPriceError(502, "실거래가 응답을 해석하지 못했어요") from e

    # HTTP 200인데 본문에 에러가 담겨 오는 경우가 있다 — 반드시 확인한다.
    code = (root.findtext("./header/resultCode") or "").strip()
    if code and code != _RESULT_OK:
        msg = (root.findtext("./header/resultMsg") or "").strip()
        raise MarketPriceError(502, f"실거래가 조회에 실패했어요 (코드 {code}: {msg})")

    trades: list[Trade] = []
    for item in root.findall("./body/items/item"):
        try:
            area = float(_text(item, "excluUseAr"))
            price = parse_amount_won(_text(item, "dealAmount"))
            year = int(_text(item, "dealYear"))
            month = int(_text(item, "dealMonth"))
            day = int(_text(item, "dealDay"))
        except (TypeError, ValueError):
            continue  # 한 건이 깨져도 나머지는 살린다
        trades.append(
            Trade(
                house_type=house_type,
                umd_nm=_text(item, "umdNm"),
                jibun=_text(item, "jibun"),
                area_sqm=area,
                price_won=price,
                deal_year=year,
                deal_month=month,
                deal_day=day,
                floor=_text(item, "floor"),
                # 아파트는 aptNm, 연립다세대는 mhouseNm, 오피스텔은 offiNm — 참고용일 뿐이다
                building_name=_text(item, "aptNm")
                or _text(item, "mhouseNm")
                or _text(item, "offiNm"),
                canceled=bool(_text(item, "cdealType")),
            )
        )
    return trades


def fetch_month(
    house_type: str, lawd_cd: str, ymd: str, *, api_key: str, run_id: str | None = None
) -> list[Trade]:
    """시군구 1개월치 조회. 실패는 예외로 올린다(호출부가 삼킬지 정한다)."""
    url = ENDPOINTS[house_type]
    try:
        resp = requests.get(
            url,
            params={
                "serviceKey": api_key,
                "LAWD_CD": lawd_cd,
                "DEAL_YMD": ymd,
                "numOfRows": 1000,
                "pageNo": 1,
            },
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
    except requests.exceptions.Timeout as e:
        raise MarketPriceError(504, "실거래가 조회가 너무 오래 걸렸어요") from e
    except requests.exceptions.RequestException as e:
        raise MarketPriceError(502, "실거래가 서버에 연결하지 못했어요") from e

    if resp.status_code != 200:
        raise MarketPriceError(502, f"실거래가 서버가 오류를 돌려줬어요 (HTTP {resp.status_code})")

    trades = _parse_items(resp.text, house_type)
    if SAVE_MOLIT_RAW and run_id:
        artifacts.save_json(
            run_id,
            f"molit_{house_type}_{lawd_cd}_{ymd}.json",
            {"url": url, "lawd_cd": lawd_cd, "deal_ymd": ymd, "raw_xml": resp.text},
        )
    return trades


def collect_trades(
    lawd_cd: str,
    *,
    months: int = DEFAULT_MONTHS,
    house_types: tuple[str, ...] = ALL_HOUSE_TYPES,
    today: date | None = None,
    run_id: str | None = None,
) -> tuple[list[Trade], list[str]]:
    """시군구 코드로 최근 N개월 × 주택유형을 **병렬** 조회해 합친다.

    반환: (거래 목록, 실패 메시지 목록). 일부 실패해도 나머지는 살린다 —
    시세는 리포트의 부가 정보이므로 한 달 조회가 깨졌다고 전체를 실패시키지 않는다.
    """
    today = today or date.today()
    api_key = _load_api_key()
    jobs = [(ht, ym) for ht in house_types for ym in month_codes(months, today=today)]

    trades: list[Trade] = []
    errors: list[str] = []
    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=MAX_WORKERS, thread_name_prefix="molit") as pool:
        futures = {
            pool.submit(fetch_month, ht, lawd_cd, ym, api_key=api_key, run_id=run_id): (ht, ym)
            for ht, ym in jobs
        }
        for future, (ht, ym) in futures.items():
            try:
                trades.extend(future.result())
            except MarketPriceError as e:
                errors.append(f"{HOUSE_TYPE_LABELS[ht]} {ym}: {e.detail}")
            except Exception as e:  # noqa: BLE001 — 시세 실패가 분석을 막지 못한다
                errors.append(f"{HOUSE_TYPE_LABELS[ht]} {ym}: {type(e).__name__}")

    _log.info(
        f"[시세] {lawd_cd} {months}개월 × {len(house_types)}유형 조회 — "
        f"{len(trades)}건 ({time.perf_counter() - t0:.1f}초)"
        + (f", 실패 {len(errors)}건" if errors else "")
    )
    return trades, errors


# ── 순수 함수: 필터·집계 (API 없이 테스트 가능) ─────────────────────────────


_JIBUN_RE = re.compile(r"(\d+)(?:-(\d+))?")


def normalize_jibun(raw: str) -> str:
    """지번 표기를 비교용으로 정규화한다.

    실측: API는 `1234`·`727-6` 형태. 등기부 주소에서도 같은 형태로 뽑힌다.
    부번 `0`은 없는 것과 같게 본다(`1234-0` == `1234`).
    """
    m = _JIBUN_RE.search(raw or "")
    if not m:
        return ""
    bon, bu = m.group(1), m.group(2)
    bon = str(int(bon))
    if bu is None or int(bu) == 0:
        return bon
    return f"{bon}-{int(bu)}"


@dataclass(frozen=True)
class AddressParts:
    """등기부 주소에서 조회에 필요한 조각만 뽑은 것."""

    lawd_codes: list[str]  # 시도해 볼 시군구 코드 (우선순위 순)
    umd_nm: str  # 읍면동 — API의 `umdNm`과 맞춘다
    jibun: str  # 지번 — API의 `jibun`과 맞춘다


def parse_address_parts(address: str) -> AddressParts | None:
    """등기부 주소 → (시군구 후보, 읍면동, 지번). 확신이 없으면 `None`.

    시군구까지의 경계는 `lawd_code`가 실제로 몇 토큰을 맞췄는지로 정한다 —
    '경기도 수원시 장안구'(3토큰)와 '세종특별자치시'(1토큰)의 경계가 다르기 때문에
    토큰 수를 고정할 수 없다. 후보 중 **가장 길게 맞은 값**을 경계로 쓴다
    (부천 원미구처럼 2토큰·3토큰 후보가 섞이면 3토큰이 옳은 경계다).

    지번이 숫자 형태가 아니면(예: '산 12-3') `None`을 돌려준다 — 추측하지 않는다.
    """
    candidates = lawd_candidates(address)
    if not candidates:
        return None

    tokens = lawd_code.address_head(address).split()
    boundary = max(c.matched_tokens for c in candidates)
    rest = tokens[boundary:]
    if len(rest) < 2:
        _log.info("[시세] 주소에서 읍면동·지번을 찾지 못했어요")
        return None

    umd, jibun_raw = rest[0], rest[1]
    if not _JIBUN_RE.fullmatch(jibun_raw):
        # '산 12-3' 같은 산번지 등 — 실거래가와 표기 대응을 확인하지 못했다
        _log.info(f"[시세] 지번 형태가 아니라 조회를 건너뜁니다 ({umd})")
        return None

    return AddressParts(
        lawd_codes=[c.lawd_cd for c in candidates],
        umd_nm=umd,
        jibun=normalize_jibun(jibun_raw),
    )


def filter_trades(
    trades: list[Trade],
    *,
    umd_nm: str,
    jibun: str,
    area_sqm: float,
    tolerance: float = AREA_TOLERANCE_RATIO,
) -> list[Trade]:
    """같은 읍면동·같은 지번이고 전용면적이 허용오차 이내인 거래만 남긴다.

    해제(취소)된 거래는 **집계 전에 제외한다.** 취소된 고가 거래가 섞이면 시세가
    높아지고, 그러면 전세가율이 낮게 나와 위험한 매물을 안전하다고 말하게 된다 —
    우리에게 가장 위험한 방향의 오류다. (실측: 양천구 6개월 1,411건 중 41건이 해제)

    건물명·층·호는 쓰지 않는다(이 파일 상단 주석 참조).
    """
    if not umd_nm or not jibun or not area_sqm or area_sqm <= 0:
        return []
    want_jibun = normalize_jibun(jibun)
    if not want_jibun:
        return []
    lo, hi = area_sqm * (1 - tolerance), area_sqm * (1 + tolerance)
    return [
        t
        for t in trades
        if not t.canceled
        and t.umd_nm == umd_nm
        and normalize_jibun(t.jibun) == want_jibun
        and lo <= t.area_sqm <= hi
    ]


def aggregate(
    trades: list[Trade], *, period_from: str, period_to: str, months_used: int
) -> MarketPriceResult | None:
    """거래 목록 → 시세 하나. **0건이면 None. 절대 추정하지 않는다.**

    채택값은 **하위 25% 분위수(Q1)**다. [2026-07-29 결정]
    - 중앙값·평균보다 낮아 보수편향 방향이다. 시세를 높게 잡으면 전세가율이 낮게 나와
      위험한 매물을 안전하다고 판정한다(미탐) — 자동값은 그 반대로 틀려야 한다.
    - 단순 최저가는 급매·특수관계 거래 1건에 지배된다. 실측상 최저↔Q1 차이가 6.8%로,
      한 건이 시세를 그만큼 끌어내릴 수 있다. 급매 1건은 그 단지의 시세가 아니다.
    - 표본 3건 이하에서는 분위수가 의미를 잃으므로 최저가로 떨어뜨린다.

    ⚠ 평균·최고가는 쓰지 않는다.
    ⚠ 사용자 화면에 '하위 25% 분위수'라는 말을 쓰지 않는다 — 기간·건수·범위를 보여주고
      사람이 판단하게 한다(계산 방식은 decisions.md에만 남긴다).
    """
    if not trades:
        return None

    prices = sorted(t.price_won for t in trades)
    if len(prices) >= QUANTILE_MIN_SAMPLES:
        price = int(quantiles(prices, n=4)[0])
        method = "quantile_25"
    else:
        price = prices[0]
        method = "min"

    return MarketPriceResult(
        price_won=price,
        sample_count=len(prices),
        period_from=period_from,
        period_to=period_to,
        method=method,
        source="국토교통부 실거래가 공개시스템",
        latest_deal_date=max(t.deal_date for t in trades),
        low_won=prices[0],
        high_won=prices[-1],
        months_used=months_used,
    )


def _period_bounds(months: int, today: date) -> tuple[str, str]:
    codes = month_codes(months, today=today)
    fmt = lambda c: f"{c[:4]}-{c[4:]}"  # noqa: E731
    return fmt(codes[0]), fmt(codes[-1])


def lookup_market_price(
    *,
    lawd_cd: str,
    umd_nm: str,
    jibun: str,
    area_sqm: float,
    today: date | None = None,
    run_id: str | None = None,
    house_types: tuple[str, ...] = ALL_HOUSE_TYPES,
) -> tuple[MarketPriceResult | None, list[str]]:
    """시군구 코드 + 읍면동/지번/면적 → 시세. 못 구하면 `(None, 실패목록)`.

    기간 정책 [2026-07-29 결정]: 기본 6개월. **0건이면 12개월로 한 번만** 넓힌다.
    그 이상은 넓히지 않는다 — 넓히면 언젠가 숫자는 나오지만 그게 '오래된 거래를
    시세로 쓰는' 틀린 값이다. 확장했을 때 `months_used`가 12로 내려가므로,
    호출부는 "6개월 내 거래 없음"을 사용자에게 알릴 수 있다.
    """
    today = today or date.today()
    all_errors: list[str] = []

    for months in (DEFAULT_MONTHS, FALLBACK_MONTHS):
        trades, errors = collect_trades(
            lawd_cd, months=months, house_types=house_types, today=today, run_id=run_id
        )
        all_errors.extend(errors)
        matched = filter_trades(trades, umd_nm=umd_nm, jibun=jibun, area_sqm=area_sqm)
        if matched:
            period_from, period_to = _period_bounds(months, today)
            return (
                aggregate(
                    matched, period_from=period_from, period_to=period_to, months_used=months
                ),
                all_errors,
            )
        _log.info(f"[시세] {months}개월 매칭 0건 — {umd_nm} {jibun} {area_sqm}㎡")

    return None, all_errors
