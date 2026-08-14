"""내부 데이터 모델 — 추출 정형화(RegistryExtract)와 규칙 판정(RuleVerdict).

- `RegistryExtract`: Upstage Information Extract의 원본(raw) JSON을 정형화한 것.
  누락 필드를 허용하되, 어떤 필드가 누락됐는지(`missing_fields`)를 함께 운반한다.
- `RuleVerdict`: 규칙 엔진의 판정 결과. E-2에서 LLM(설명 생성)의 **유일한 입력**이며,
  LLM은 이 값을 바꿀 수 없다(가드레일 경계 — CLAUDE.md 3절).

보수적 편향(구조적 강제):
- 말소 여부를 모르면(`is_canceled` 누락) **유효한 것으로 간주**한다 — 말소 단정 금지.
- 금액 해석 실패는 0이 아니라 **None** — 0 치환은 '빚이 없다'는 위험 축소이므로 금지.
"""

from __future__ import annotations

import re
from enum import Enum
from typing import Any, ClassVar, Optional

from pydantic import BaseModel, ConfigDict, Field


class Grade(str, Enum):
    """위험 등급 3단계 (계약 §1.4의 문자열과 동일)."""

    DANGER = "위험"
    CAUTION = "확인 필요"
    GOOD = "양호"


_SEVERITY = {Grade.GOOD: 0, Grade.CAUTION: 1, Grade.DANGER: 2}


def worst(grades: list[Grade]) -> Grade:
    """여러 등급 중 가장 나쁜 등급을 고른다 (worst-of 결합 — decisions.md 2026-07-06)."""
    if not grades:
        return Grade.CAUTION  # 판정할 근거가 없으면 양호 단정 금지
    return max(grades, key=lambda g: _SEVERITY[g])


def floor_caution(grade: Grade) -> Grade:
    """등급 하한을 '확인 필요'로 강제한다 — 데이터 불완전 시 양호 금지의 단일 지점."""
    return Grade.CAUTION if grade is Grade.GOOD else grade


# ── 금액 파싱 ────────────────────────────────────────────────────────────────

_PLAIN_RE = re.compile(r"^\d[\d,]*$")
_UNIT_RE = re.compile(r"(\d[\d,]*)(억|만)")


def parse_amount(value: object) -> int | None:
    """금액 값을 원 단위 정수로 해석한다. **실패하면 None** (0 치환 금지).

    허용 예: 120000000 / "120,000,000" / "금120,000,000원" / "1억 2,000만원"
    실패 예: "일억이천만원"(한글 수사), 빈 문자열, 음수 → None
    """
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value >= 0 else None
    if isinstance(value, float):
        return int(value) if value >= 0 else None
    if not isinstance(value, str):
        return None

    s = value.strip().replace(" ", "")
    for token in ("원정", "원", "금", "￦", "₩"):
        s = s.replace(token, "")
    if not s:
        return None
    if _PLAIN_RE.match(s):
        return int(s.replace(",", ""))

    total = 0
    matched = False

    def _consume(m: re.Match) -> str:
        nonlocal total, matched
        matched = True
        n = int(m.group(1).replace(",", ""))
        total += n * (100_000_000 if m.group(2) == "억" else 10_000)
        return ""

    rest = _UNIT_RE.sub(_consume, s).replace(",", "")
    if not matched:
        return None
    if rest:
        if rest.isdigit():
            total += int(rest)
        else:
            return None  # 해석 불가 잔여(한글 수사 등) → 실패. 0 치환 금지.
    return total


# ── 추출 정형화 모델 ─────────────────────────────────────────────────────────


class Owner(BaseModel):
    model_config = ConfigDict(extra="allow")
    name: Optional[str] = None
    share: Optional[str] = None


class RegistryEntry(BaseModel):
    """등기 항목 공통 — 말소 여부만 공통 해석하고 나머지는 원본 필드를 그대로 보존."""

    model_config = ConfigDict(extra="allow")
    is_canceled: Optional[bool] = None

    @property
    def is_active(self) -> bool:
        # 말소 여부를 모르면(None) 유효로 간주 — 말소 단정 금지(보수적 편향)
        return self.is_canceled is not True


class MoneyEntry(RegistryEntry):
    """금액이 있어야 하는 항목(근저당·전세권). amount=None이면 '금액 미상'."""

    amount: Optional[int] = None
    amount_unknown: bool = False


_LIST_KEYS = (
    "current_owners",
    "ownership_changes",
    "provisional_seizures",
    "provisional_dispositions",
    "seizures",
    "auction_commencements",
    "trust_registrations",
    "mortgages",
    "jeonse_rights",
    "lease_registrations",
)


def _dict_items(raw: dict, key: str, missing: list[str]) -> list[dict]:
    value = raw.get(key)
    if not isinstance(value, list):
        missing.append(key)  # 키 자체가 없거나 null → 페이지 누락 가능성
        return []
    return [x for x in value if isinstance(x, dict)]


class RegistryExtract(BaseModel):
    """Information Extract 결과의 정형화본 (registry_schema.py 최상위 필드와 1:1)."""

    # 부동산고유번호 — 대조(compare)에서 "같은 집인가"를 가리는 확정 근거.
    # ⚠ 판정에는 쓰지 않는다. 못 읽으면 None이고, 그때 대조는 주소로 견준다.
    unique_number: Optional[str] = None
    address: Optional[str] = None
    exclusive_area_sqm: Optional[float] = None
    current_owners: list[Owner] = Field(default_factory=list)
    ownership_changes: list[RegistryEntry] = Field(default_factory=list)
    provisional_seizures: list[RegistryEntry] = Field(default_factory=list)
    provisional_dispositions: list[RegistryEntry] = Field(default_factory=list)
    seizures: list[RegistryEntry] = Field(default_factory=list)
    auction_commencements: list[RegistryEntry] = Field(default_factory=list)
    trust_registrations: list[RegistryEntry] = Field(default_factory=list)
    mortgages: list[MoneyEntry] = Field(default_factory=list)
    jeonse_rights: list[MoneyEntry] = Field(default_factory=list)
    lease_registrations: list[RegistryEntry] = Field(default_factory=list)
    missing_fields: list[str] = Field(default_factory=list)

    LIST_KEYS: ClassVar[tuple[str, ...]] = _LIST_KEYS

    @classmethod
    def from_raw(cls, raw: dict | None) -> "RegistryExtract":
        raw = raw or {}
        missing: list[str] = []

        def money_items(key: str, amount_key: str) -> list[MoneyEntry]:
            items = []
            for x in _dict_items(raw, key, missing):
                amount = parse_amount(x.get(amount_key))
                items.append(
                    MoneyEntry(
                        **{k: v for k, v in x.items() if k not in ("amount", "amount_unknown")},
                        amount=amount,
                        amount_unknown=amount is None,
                    )
                )
            return items

        def entry_items(key: str) -> list[RegistryEntry]:
            return [RegistryEntry(**x) for x in _dict_items(raw, key, missing)]

        address = raw.get("address")
        if not (isinstance(address, str) and address.strip()):
            address = None

        unique_number = raw.get("unique_number")
        if not (isinstance(unique_number, str) and unique_number.strip()):
            unique_number = None

        area = raw.get("exclusive_area_sqm")
        if not isinstance(area, (int, float)) or isinstance(area, bool):
            area = None

        return cls(
            unique_number=unique_number,
            address=address,
            exclusive_area_sqm=area,
            current_owners=[Owner(**x) for x in _dict_items(raw, "current_owners", missing)],
            ownership_changes=entry_items("ownership_changes"),
            provisional_seizures=entry_items("provisional_seizures"),
            provisional_dispositions=entry_items("provisional_dispositions"),
            seizures=entry_items("seizures"),
            auction_commencements=entry_items("auction_commencements"),
            trust_registrations=entry_items("trust_registrations"),
            mortgages=money_items("mortgages", "max_claim_amount"),
            jeonse_rights=money_items("jeonse_rights", "deposit_amount"),
            lease_registrations=entry_items("lease_registrations"),
            missing_fields=missing,
        )

    @property
    def doc_incomplete(self) -> bool:
        """문서 신뢰도 게이트 — 주소·현소유자는 모든 등기부에 반드시 있으므로,
        없으면 페이지 누락·추출 실패로 보고 어떤 항목도 '양호' 단정을 금지한다."""
        return bool(self.missing_fields) or self.address is None or not self.current_owners


# ── 판정 결과 모델 ───────────────────────────────────────────────────────────


class EvidenceVerdict(BaseModel):
    """근거 카드 1건의 [판정] 부분 (계약 §2.2의 판정 필드와 대응)."""

    id: str
    grade: Grade
    status_label: Optional[str] = None
    detail_text: Optional[str] = None
    source_text: Optional[str] = None
    action_label: Optional[str] = None
    facts: dict[str, Any] = Field(default_factory=dict)  # LLM 설명·질문 치환용 수치 사실


class PriceProvenance(BaseModel):
    """시세가 **어디서 왔는가** — 설명 전용 부속 정보 (2026-08-05).

    왜 여기 있나: 2026-08-03에 시세 자동조회가 붙으면서 `market_price`가 사용자 입력일
    수도, 국토부 실거래가일 수도, 공시가격 기준일 수도 있게 됐다. 그런데 설명 LLM은
    출처를 볼 통로가 없어 프롬프트가 시키는 대로 **무조건 "입력하신 시세"**라고 불렀다
    (감사 2026-08-05 §A-4-⑶에서 실호출로 확인).

    ⚠ **판정에 쓰지 않는다.** 규칙 엔진은 이 값을 읽지 않고, 채우는 것도 규칙 엔진이
      아니라 `report_builder`다(`price_resolver` 결과를 그대로 옮긴다).
    """

    source: Optional[str] = None  # manual | actual_trade | official_price | tax_base
    source_name: Optional[str] = None  # 사람이 읽는 출처명
    as_of: Optional[str] = None  # 기준일 또는 조회 기간
    sample_count: Optional[int] = None  # 실거래가일 때 표본 수
    gap_pct: Optional[int] = None  # 실거래가 ↔ 공시 기준 괴리율
    detail: Optional[str] = None  # 매칭 방법 등 산정 근거 한 줄
    alternatives: list[dict[str, Any]] = Field(default_factory=list)  # 채택 안 된 후보


class RuleVerdict(BaseModel):
    """규칙 엔진의 최종 판정 — E-2 LLM의 유일한 입력(읽기 전용)."""

    grade: Grade
    gauge_progress: float
    deposit: int
    market_price: Optional[int] = None
    senior_debt_amount: int
    address: Optional[str] = None
    evidences: list[EvidenceVerdict]
    doc_flags: list[str] = Field(default_factory=list)
    # ── 설명 재료 (2026-08-05 추가) — 전부 선택적. 판정에 쓰이지 않는다. ──
    # 규칙 엔진이 **이미 계산했거나 이미 손에 쥐고 있던** 값을 설명 계층에도 보여주기
    # 위한 통로다. 새 판정을 만들지 않으며, 이 필드들이 비어 있어도 판정은 동일하다.
    price_provenance: Optional[PriceProvenance] = None  # report_builder가 채운다
    ownership_history: dict[str, Any] = Field(default_factory=dict)  # 소유권 이전 횟수·최근일
    # ── 등기부 자체의 사실 (2026-08-05 2차) — report_builder가 채운다 ──────────
    # 열람일시: 등기부는 **그 시점의 스냅샷**이다. 계약 직전 근저당 설정이 실제 수법이라
    # "이 서류는 언제 기준인가"를 설명이 말할 수 있어야 한다.
    # ⚠ None이면 None인 채로 넘긴다 — 분석일로 대체하면 "오늘 서류"로 믿게 만든다.
    registry_viewed_at: Optional[str] = None  # 'YYYY.MM.DD'
    # 무엇을 찾아봤고 무엇을 왜 뺐는지(말소된 근저당 등). "을구를 읽었다"는 신뢰 장치다.
    checked_notes: list[str] = Field(default_factory=list)
