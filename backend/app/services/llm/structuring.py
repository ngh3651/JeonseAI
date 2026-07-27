"""작업 ① — OCR 레이아웃 텍스트 → 등기 필드 구조화 (**두 번째 경로**).

가드레일 (판정에 닿지 않는 구조적 보장):
1. 출력 모델 `LlmRegistryPayload`에 **등급·점수·의견 필드가 없다.**
2. 전 모델이 `extra="forbid"` — LLM이 `grade`·`risk`·`comment` 같은 키를 실어 보내면
   pydantic 검증에서 **통째로 떨어진다**(부분 채택 없음).
3. 검증을 통과한 결과도 `RegistryExtract`로 정형화될 뿐, **규칙 엔진에 들어가지 않는다.**
   판정은 IE 결과 기준을 유지한다(`report_builder`가 IE 결과만 `rule_engine`에 넘긴다).

실패는 전부 조용한 폴백이다 — 이 경로가 없어도 리포트는 지금과 똑같이 완성된다.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Optional

from pydantic import BaseModel, ConfigDict, ValidationError

from ...schemas.internal import RegistryExtract
from .base import LlmError

if TYPE_CHECKING:  # 순환 import 방지
    from .base import LlmProvider

_log = logging.getLogger("jeonseai")


class _Strict(BaseModel):
    """모든 항목 모델의 부모 — 스키마에 없는 키는 **전부 거부**한다."""

    model_config = ConfigDict(extra="forbid")


class OwnerItem(_Strict):
    name: Optional[str] = None
    share: Optional[str] = None


class OwnershipChangeItem(_Strict):
    rank_number: Optional[str] = None
    purpose: Optional[str] = None
    receipt_date: Optional[str] = None
    cause: Optional[str] = None
    cause_date: Optional[str] = None
    holder: Optional[str] = None
    is_canceled: Optional[bool] = None


class ClaimItem(_Strict):
    """가압류·가처분·압류·경매개시결정 공통 (registry_schema `_claim_like_entry`와 동형)."""

    rank_number: Optional[str] = None
    purpose: Optional[str] = None
    receipt_date: Optional[str] = None
    cause: Optional[str] = None
    claimant: Optional[str] = None
    claim_amount: Optional[float] = None
    is_canceled: Optional[bool] = None


class TrustItem(_Strict):
    rank_number: Optional[str] = None
    receipt_date: Optional[str] = None
    trustee: Optional[str] = None
    is_canceled: Optional[bool] = None


class MortgageItem(_Strict):
    rank_number: Optional[str] = None
    max_claim_amount: Optional[float] = None
    debtor: Optional[str] = None
    mortgagee: Optional[str] = None
    receipt_date: Optional[str] = None
    is_canceled: Optional[bool] = None


class DepositItem(_Strict):
    """전세권·임차권등기 공통."""

    rank_number: Optional[str] = None
    deposit_amount: Optional[float] = None
    holder: Optional[str] = None
    receipt_date: Optional[str] = None
    is_canceled: Optional[bool] = None


class LlmRegistryPayload(_Strict):
    """LLM이 채울 수 있는 필드의 전부.

    ⚠ `registry_schema.py`(IE 스키마)의 최상위 키와 **1:1로 맞춘다.** 같은 형태여야
      같은 규칙 엔진·같은 매칭 코드를 그대로 쓸 수 있고, 두 경로를 항목 단위로 비교할 수 있다.
    ⚠ 등급·점수·의견 필드는 **없다.** 있어야 할 이유가 없고, 있으면 가드레일이 뚫린다.
    """

    document_title: Optional[str] = None
    address: Optional[str] = None
    exclusive_area_sqm: Optional[float] = None
    current_owners: list[OwnerItem] = []
    ownership_changes: list[OwnershipChangeItem] = []
    provisional_seizures: list[ClaimItem] = []
    provisional_dispositions: list[ClaimItem] = []
    seizures: list[ClaimItem] = []
    auction_commencements: list[ClaimItem] = []
    trust_registrations: list[TrustItem] = []
    mortgages: list[MortgageItem] = []
    jeonse_rights: list[DepositItem] = []
    lease_registrations: list[DepositItem] = []


def structure_registry(
    provider: "LlmProvider", layout_text: str, *, timeout: float | None = None
) -> RegistryExtract:
    """OCR 레이아웃 텍스트 → `RegistryExtract`. 실패하면 `LlmError`.

    호출부는 실패를 **조용히 삼키고** 두 번째 경로 없이 진행해야 한다.
    """
    from .prompts import LAYOUT_TEXT_WARN_CHARS, STRUCTURE_SYSTEM_PROMPT

    if not layout_text.strip():
        raise LlmError(f"{provider.name}: 넘길 레이아웃 텍스트가 비어 있음")
    if len(layout_text) > LAYOUT_TEXT_WARN_CHARS:
        _log.info(
            f"[LLM:{provider.name}] ⚠ 레이아웃 텍스트 {len(layout_text):,}자 —"
            f" 상한 {LAYOUT_TEXT_WARN_CHARS:,}자를 넘었습니다(자르지 않고 그대로 보냅니다)"
        )

    payload, resp = provider.chat_json(
        STRUCTURE_SYSTEM_PROMPT,
        "등기부 OCR 결과:\n" + layout_text,
        max_tokens=4000,
        timeout=timeout,
    )
    try:
        validated = LlmRegistryPayload.model_validate(payload)
    except ValidationError as e:
        # 어느 키 때문에 떨어졌는지만 남긴다 — **값은 남기지 않는다**(실명·주소 포함 가능).
        # 배열 인덱스는 빼고 `배열.키` 형태로 접는다: `seizures.0.amount` → `seizures.amount`.
        # 이래야 "같은 키를 여러 항목에서 반복해 틀렸다"가 한눈에 보인다.
        problems: list[str] = []
        for err in e.errors():
            parts = [str(p) for p in err.get("loc", ()) if not isinstance(p, int)]
            label = ".".join(parts) or "?"
            if err.get("type") == "extra_forbidden":
                label += "(스키마에 없는 키)"
            if label not in problems:
                problems.append(label)
        raise LlmError(
            f"{provider.name}: 스키마 검증 실패 — {len(e.errors())}건"
            f" (문제 키: {', '.join(problems[:8])})"
        ) from e

    extract = RegistryExtract.from_raw(validated.model_dump(exclude_none=False))
    _log.info(
        f"[LLM:{provider.name}] 구조화 {resp.elapsed:.1f}초"
        f" / 토큰 {resp.total_tokens if resp.total_tokens is not None else '미제공'}"
        f" — 소유자 {len(extract.current_owners)}명"
        f" · 근저당 {len(extract.mortgages)}건"
        f" · 압류 {len(extract.seizures)}건"
        f" · 가압류 {len(extract.provisional_seizures)}건"
    )
    return extract
