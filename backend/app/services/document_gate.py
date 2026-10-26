"""**등기부가 아닌 사진** 거르기 (2026-10-24 규혁 결정).

두 상황을 가른다:
- 등기부인데 잘 못 읽음(흐림·잘림) → 분석은 하고 '확인 필요' + '그 장만 다시 찍기' (지금 그대로)
- **등기부가 아님**(키보드·화면·아무 사진) → 분석하지 않고 거절(400). 리포트도 기록도 남기지 않는다.

판단은 두 경로를 **함께** 본다(하나만 보면 진짜 등기부를 막을 수 있다):
① Information Extract가 등기부 내용을 하나도 못 찾았다(주소·소유자·등기 항목 전부 없음)
② Document OCR 글자에 등기부의 표지 낱말(표제부·갑구·을구·순위번호·등기목적 …)이 2개 미만이다(또는 OCR이 실패했다)
둘 다일 때만 거절한다. 등기부 낱말이 보이는데 내용을 못 읽었으면 '잘 못 읽은 등기부'로 보고 분석을 계속한다.

⚠ 판정 규칙이 아니다 — 판정할 **재료가 등기부인지**만 본다. AI 호출 없음(이미 받은 결과를 읽기만).
"""

from __future__ import annotations

from ..schemas.internal import RegistryExtract

#: 등기부 표지 낱말(띄어쓰기 무시) — 어느 쪽을 찍어도 2개 이상은 보인다(표제부·갑구·을구 머리 칸·꼬리말).
REGISTRY_MARKERS = (
    "등기사항전부증명서",
    "등기사항증명서",
    "등기부등본",
    "표제부",
    "갑구",
    "을구",
    "순위번호",
    "등기목적",
    "등기원인",
    "권리자및기타사항",
    "소유권",
    "고유번호",
    "관할등기소",
    "열람일시",
    "접수",
)
MIN_MARKERS = 2

NOT_REGISTRY_DETAIL = (
    "등기부등본이 아닌 사진 같아요. 인터넷등기소에서 뗀 '등기사항전부증명서'를 찍어 주세요"
)

_ENTRY_FIELDS = (
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


def ie_found_anything(extract: RegistryExtract) -> bool:
    """IE가 등기부 내용을 하나라도 찾았나 (주소·현 소유자·등기 항목)."""
    if extract.address or extract.current_owners:
        return True
    return any(getattr(extract, f, None) for f in _ENTRY_FIELDS)


def entry_count(extract: RegistryExtract) -> int:
    """IE가 찾은 등기 항목 수(현 소유자 + 권리 항목) — 두 번 읽은 결과를 견줄 때 쓴다."""
    return len(extract.current_owners or []) + sum(len(getattr(extract, f, None) or []) for f in _ENTRY_FIELDS)


def ocr_marker_count(pages) -> int | None:
    """OCR 글자 속 등기부 표지 낱말 수. OCR 결과가 없으면 None."""
    if not pages:
        return None
    text = "".join(w.text for p in pages for w in getattr(p, "words", []) or [])
    text = "".join(text.split())
    return sum(1 for m in REGISTRY_MARKERS if m in text)


def looks_not_registry(extract: RegistryExtract, pages) -> bool:
    if ie_found_anything(extract):
        return False
    markers = ocr_marker_count(pages)
    return markers is None or markers < MIN_MARKERS
