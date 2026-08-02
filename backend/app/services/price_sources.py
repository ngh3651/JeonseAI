"""공시가격·기준시가 원본 파일의 **컬럼 매핑 설정** 로더.

왜 이 파일이 따로 있나 (2026-08-03 설계):
공공데이터 CSV의 컬럼 이름은 우리가 정할 수 없고, 연도·기관에 따라 바뀐다.
컬럼 이름을 코드 여기저기에 박으면 파일이 바뀔 때마다 코드를 뒤져야 한다.
그래서 **컬럼 이름은 `backend/data/price_sources.json` 한 곳에만** 두고, 나머지
코드는 이 모듈이 돌려주는 정규 필드명(`PriceColumns`)으로만 데이터에 접근한다.

⚠ **모르면 조용히 실패하지 않는다.** 매핑이 비어 있거나 아직 사람이 확인하지 않았으면
  `PriceSourceNotReady`를 던지고, 무엇을 실행하면 되는지 한국어로 알려준다.
  없는 값을 0이나 빈 문자열로 흘려보내면 시세가 틀린 채로 판정까지 흘러간다.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

_BACKEND_ROOT = Path(__file__).resolve().parents[2]
CONFIG_PATH = _BACKEND_ROOT / "data" / "price_sources.json"

# 소스 키 — 이 두 개만 존재한다(실거래가는 market_price.py 담당).
SOURCE_OFFICIAL_PRICE = "official_price"  # 국토부 공동주택 공시가격
SOURCE_TAX_BASE = "tax_base"  # 국세청 오피스텔 기준시가
ALL_SOURCES = (SOURCE_OFFICIAL_PRICE, SOURCE_TAX_BASE)

# 가격 단위 → 원 환산 배수. 이 표에 없는 값은 오류로 멈춘다(추측 금지).
PRICE_UNIT_MULTIPLIER: dict[str, int] = {
    "won": 1,
    "thousand_won": 1_000,
    "man_won": 10_000,
}

# 정규 필드명 — 코드는 **이 이름으로만** 데이터에 접근한다.
CANONICAL_FIELDS = (
    "bjd_cd",  # 법정동코드 10자리
    "sido",  # 시도명
    "sigungu",  # 시군구명
    "umd",  # 읍면동명
    "jibun_full",  # '1234-5' 처럼 한 컬럼에 든 지번
    "jibun_bon",  # 본번
    "jibun_bu",  # 부번
    "dong_nm",  # 동 명칭 ('101동' / '101')
    "ho_nm",  # 호 명칭 ('501호' / '501')
    "area_sqm",  # 전용면적(㎡)
    "area_common_sqm",  # 공유면적(㎡) — 기준시가에서만 의미가 있다
    "price",  # 가격 (단위는 price_unit)
    "as_of",  # 행 단위 기준일 (없으면 소스의 as_of를 쓴다)
)


class PriceSourceNotReady(Exception):
    """매핑 설정이 아직 준비되지 않음 — 사용자/개발자에게 '무엇을 하면 되는지'를 담는다."""


@dataclass(frozen=True)
class PriceSourceConfig:
    """한 소스(공시가격 또는 기준시가)의 읽기 설정."""

    key: str
    label: str
    source_name: str
    as_of: str | None
    verified: bool
    file_encoding: str | None
    delimiter: str | None
    has_header: bool
    price_unit: str | None
    price_is_total: bool | None
    columns: dict[str, Optional[str]]

    # ── 준비 상태 ────────────────────────────────────────────────────────────

    def missing_items(self) -> list[str]:
        """아직 정해지지 않은 항목의 한국어 목록. 비어 있으면 쓸 수 있다."""
        missing: list[str] = []
        if not self.verified:
            missing.append("verified 가 false (사람이 실제 파일로 확인하지 않음)")
        if not self.file_encoding:
            missing.append("file_encoding (예: cp949 / utf-8)")
        if not self.delimiter:
            missing.append("delimiter (예: ',' 또는 '|')")
        if self.price_unit not in PRICE_UNIT_MULTIPLIER:
            missing.append("price_unit (won / thousand_won / man_won)")
        if self.price_is_total is None:
            missing.append("price_is_total (호별 총액이면 true, ㎡당 단가면 false)")
        if not self.as_of and not self.columns.get("as_of"):
            missing.append("as_of (기준일) 또는 columns.as_of")
        if not self.columns.get("price"):
            missing.append("columns.price (가격 컬럼)")
        if not self.columns.get("area_sqm"):
            missing.append("columns.area_sqm (전용면적 컬럼)")
        if not (self.columns.get("bjd_cd") or (self.columns.get("sigungu") and self.columns.get("umd"))):
            missing.append("columns.bjd_cd 또는 (columns.sigungu + columns.umd) — 지역 식별 수단")
        if not (self.columns.get("jibun_full") or self.columns.get("jibun_bon")):
            missing.append("columns.jibun_full 또는 columns.jibun_bon (지번)")
        if self.price_is_total is False and not self.columns.get("area_common_sqm"):
            missing.append(
                "columns.area_common_sqm — price_is_total=false면 (전용+공유)면적을 곱해야 총액이 된다"
            )
        return missing

    @property
    def ready(self) -> bool:
        return not self.missing_items()

    def require_ready(self) -> None:
        """준비되지 않았으면 '무엇을 하면 되는지'와 함께 멈춘다."""
        missing = self.missing_items()
        if not missing:
            return
        raise PriceSourceNotReady(
            f"[{self.label}] 컬럼 매핑이 아직 설정되지 않았습니다.\n"
            + "\n".join(f"  · 미설정: {m}" for m in missing)
            + f"\n\n다음을 실행해 초안을 만든 뒤 {CONFIG_PATH.name} 을 검토·수정하세요:\n"
            f"  python scripts/inspect_price_source.py <원본파일경로> --source {self.key} --write"
        )

    # ── 단위 환산 ────────────────────────────────────────────────────────────

    def price_multiplier(self) -> int:
        if self.price_unit not in PRICE_UNIT_MULTIPLIER:
            raise PriceSourceNotReady(
                f"[{self.label}] price_unit 이 {self.price_unit!r} 입니다. "
                f"{'/'.join(PRICE_UNIT_MULTIPLIER)} 중 하나여야 합니다."
            )
        return PRICE_UNIT_MULTIPLIER[self.price_unit]


def _read_raw() -> dict:
    if not CONFIG_PATH.exists():
        raise PriceSourceNotReady(
            f"매핑 설정 파일이 없습니다: {CONFIG_PATH}\n"
            "저장소에 포함된 파일이므로, 지워졌다면 git에서 되살리세요."
        )
    try:
        return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except ValueError as e:
        raise PriceSourceNotReady(
            f"{CONFIG_PATH.name} 이 올바른 JSON이 아닙니다 (쉼표·따옴표 확인): {e}"
        ) from e


def load(source_key: str) -> PriceSourceConfig:
    """소스 키 → 설정. 파일·키가 없으면 안내와 함께 멈춘다."""
    if source_key not in ALL_SOURCES:
        raise PriceSourceNotReady(
            f"모르는 시세 소스 키 {source_key!r} (가능: {', '.join(ALL_SOURCES)})"
        )
    raw = _read_raw()
    sources = raw.get("sources") or {}
    node = sources.get(source_key)
    if not isinstance(node, dict):
        raise PriceSourceNotReady(
            f"{CONFIG_PATH.name} 의 sources 에 {source_key!r} 항목이 없습니다."
        )

    cols_raw = node.get("columns") or {}
    unknown = [k for k in cols_raw if k not in CANONICAL_FIELDS]
    if unknown:
        raise PriceSourceNotReady(
            f"[{source_key}] columns 에 모르는 필드명이 있습니다: {', '.join(sorted(unknown))}\n"
            f"쓸 수 있는 이름: {', '.join(CANONICAL_FIELDS)}"
        )
    columns = {f: (cols_raw.get(f) or None) for f in CANONICAL_FIELDS}

    return PriceSourceConfig(
        key=source_key,
        label=str(node.get("label") or source_key),
        source_name=str(node.get("source_name") or node.get("label") or source_key),
        as_of=(node.get("as_of") or None),
        verified=bool(node.get("verified")),
        file_encoding=(node.get("file_encoding") or None),
        delimiter=(node.get("delimiter") or None),
        has_header=bool(node.get("has_header", True)),
        price_unit=(node.get("price_unit") or None),
        price_is_total=node.get("price_is_total") if isinstance(node.get("price_is_total"), bool) else None,
        columns=columns,
    )


def load_all() -> dict[str, PriceSourceConfig]:
    return {k: load(k) for k in ALL_SOURCES}


def write_draft(source_key: str, updates: dict) -> Path:
    """inspect 스크립트가 만든 초안을 설정 파일에 병합해 저장한다.

    ⚠ `verified`는 **절대 자동으로 true로 만들지 않는다.** 사람이 눈으로 확인한 뒤
      직접 바꾸게 한다 — 자동 추론이 맞았는지 아무도 확인하지 않은 채 조회가
      시작되는 것이 이 기능에서 가장 위험한 실패다.
    """
    raw = _read_raw()
    node = raw.setdefault("sources", {}).setdefault(source_key, {})
    for key, value in updates.items():
        if key == "verified":
            continue
        if key == "columns":
            node.setdefault("columns", {})
            for field, col in value.items():
                if field in CANONICAL_FIELDS:
                    node["columns"][field] = col
        else:
            node[key] = value
    node["verified"] = False
    CONFIG_PATH.write_text(
        json.dumps(raw, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return CONFIG_PATH
