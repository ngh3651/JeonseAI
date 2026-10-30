"""사진 위 표시 하나의 '이 집에서 본 것'과 '이 집 맞춤 할 일' (2026-10-31 사진에서 보기 자세히 보기 개편).

규혁(2026-10-31): 자세히 보기의 글이 길고 흐리며, 어느 집에나 같은 말이라 쓸모가 없다 → **기본 확인**(어느 집에나
같은 안내, 원래 문구)과 **이 집 맞춤 할 일**(이 집 날짜·금액·순위로 쓴 할 일)을 나눈다.

⚠ **규칙 문장이다. AI가 쓰지 않는다**(AI 설명은 앱이 리포트 근거 카드의 설명을 함께 보여 준다 — 같은 리포트, 추가 호출 0).
⚠ 할 일의 내용은 **원래 표시 문구(`highlight._SPECS`)와 4장 질문 문구에 이미 있는 행동**만 쓴다 — 이 집 숫자를 끼울 뿐,
  새 법률 판단을 만들지 않는다. 대시(—) 없이 쓴다.
⚠ 판정과 무관하다(표시 전용). 사람 이름은 넣지 않는다 — 권리자가 사람이면 '개인'.
"""

from __future__ import annotations

from typing import Any

from .formatting import format_won, looks_like_institution
from .registry_facts import norm_date

#: 종류 → (권리자 칸, 금액 이름)
_HOLDER = {
    "mortgage": ("mortgagee", "빚 최대 한도"),  # 등기부 낱말은 '채권최고액' — 칩은 풀어 쓴다(용어 풀이와 같은 말)
    "jeonse": ("holder", "전세금"),
    "lease_registration": ("holder", "보증금"),
    "provisional_seizure": ("claimant", "청구한 돈"),
    "seizure": ("claimant", None),
    "auction": ("claimant", None),
    "trust": ("trustee", None),
}


def dot(iso: str | None) -> str | None:
    d = norm_date(iso)
    if not d:
        return None
    y, m, dd = d.split("-")
    return f"{int(y)}.{int(m)}.{int(dd)}"


def _holder(raw: dict[str, Any], key: str | None) -> str | None:
    if not key:
        return None
    name = str(raw.get(key) or "").strip()
    if not name:
        return None
    return name if looks_like_institution(name) else "개인"


def ranked(kind: str, entry: Any, amount: int | None, rank: str | None) -> tuple[list[str], list[str]]:
    """근저당·압류 같은 순위 항목 하나 → (이 집에서 본 것, 이 집 맞춤 할 일)."""
    raw = entry.model_dump() if hasattr(entry, "model_dump") else dict(entry or {})
    holder_key, amount_name = _HOLDER.get(kind, (None, None))
    date = dot(raw.get("receipt_date"))
    holder = _holder(raw, holder_key)
    money = format_won(amount) if amount is not None else None
    facts = [x for x in (
        f"{rank}순위" if rank else None,
        f"{date} 접수" if date else None,
        holder,
        f"{amount_name} {money}" if (amount_name and money) else None,
    ) if x]
    when = f"{date} " if date else ""
    plan: list[str]
    if kind == "mortgage":
        plan = [
            f"잔금 날 이 빚{f'({money})' if money else ''}을 갚고 등기부에서 **지우는지(말소)** 중개사에게 묻고, 답을 계약서 **특약**에 적으세요",
            "지금 남은 빚은 집주인 **대출 잔액 확인서(부채증명원)**로 확인하세요",
        ]
        if holder == "개인":
            plan.append("돈을 빌려준 쪽이 **개인**이에요. 갚았다는 말만 믿지 말고 이 빚이 지워진 등기부로 확인하세요")
    elif kind == "jeonse":
        plan = [
            f"이 전세권{f'({money})' if money else ''}이 언제 지워지는지 중개사에게 확인하세요",
            "전세권이 지워진 등기부를 다시 떼어 이 앱으로 대조한 뒤 계약하세요",
        ]
    elif kind == "lease_registration":
        plan = [
            f"전 세입자 보증금{f'({money})' if money else ''}이 정리됐는지 중개사에게 확인하세요",
            "**임차권등기가 지워진 등기부**를 받은 뒤에 계약하세요",
        ]
    elif kind == "provisional_seizure":
        plan = [
            f"{when}가압류{f'({money})' if money else ''}가 언제 풀리는지 중개사에게 확인하세요",
            "가압류가 풀린 등기부를 직접 확인하기 전에는 **계약금을 보내지 마세요**",
        ]
    elif kind == "seizure":
        plan = [
            f"{when}압류가 풀린 등기부를 직접 확인한 뒤에 계약하세요",
            "아직 안 풀렸다면 **계약을 미루세요**",
        ]
    elif kind == "auction":
        plan = [
            "이 집은 **계약금을 보내지 마세요**",
            f"{when}시작된 경매가 어떻게 정리되는지 중개사에게 묻고, 답이 분명하지 않으면 이 집은 계약하지 마세요",
        ]
    elif kind == "trust":
        plan = [
            "**신탁원부**를 받아 누구와 계약해야 하는지 확인하세요",
            "신탁회사 **동의서 원본**을 받기 전에는 돈을 보내지 마세요",
        ]
    else:
        plan = []
    return facts, plan


def owner(owner_count: int, corporate: bool) -> tuple[list[str], list[str]]:
    facts = [f"지금 소유자 {owner_count}명" if owner_count else "소유자"]
    if owner_count > 1:
        facts.append("공동명의")
    if corporate:
        facts.append("회사(법인)")
    plan = ["계약 자리에 나온 사람의 **신분증 이름**이 이 이름과 같은지 맞춰 보세요"]
    if owner_count > 1:
        plan.append(f"{owner_count}명 **모두의 서명**이나, 안 나온 사람의 **위임장과 인감증명서**를 받으세요")
    if corporate:
        plan.append("집주인이 **회사(법인)**예요. 회사 이름으로 된 **납세증명서**를 받으세요")
    plan.append("보증금은 **이 이름의 계좌**로만 보내세요")
    return facts, plan


BLACKLIST_MATCHED_FACT = "공개 명단에 같은 이름"
BLACKLIST_CLEAR_FACT = "공개 명단에 같은 이름 없음"


def blacklist_line(status_label: str | None, grade: str | None) -> tuple[str | None, str | None]:
    """소유자 표시에 붙일 '악성임대인 공개 명단과 맞춰 본 결과' (사실, 할 일). 판정은 규칙 엔진 카드 그대로 옮길 뿐이다.

    명단을 아직 못 받았으면(카드 숨김) 아무것도 붙이지 않는다. 일치해도 단정하지 않는다(동명이인).
    """
    if (status_label or "").startswith("명단 일치"):
        return (BLACKLIST_MATCHED_FACT,
                "**안심전세포털 악성임대인 명단**에서 이름과 나이를 직접 맞춰 보세요. 이름만 같은 다른 사람일 수도 있어요")
    if grade == "양호":
        return BLACKLIST_CLEAR_FACT, None
    return None, None


def document(kind: str, *, viewed_at: str | None = None, area: float | None = None) -> tuple[list[str], list[str]]:
    """주소·면적·서류 종류·뗀 날."""
    if kind == "address":
        return [], [
            "계약서 주소·**동·호수**가 이 주소와 글자까지 같은지 맞춰 보세요",
            "실제로 본 집 현관 호수와 같은지도 확인하세요",
        ]
    if kind == "area":
        return ([f"전용면적 {area:g}㎡"] if area else []), ["계약서 면적이 이 **전용면적**과 같은지 확인하세요"]
    if kind == "doc_title":
        return [], ["**말소사항 포함** 전부증명서인지 확인하세요. 아니면 다시 떼어 달라고 하세요"]
    if kind == "viewed_at":
        return ([f"{viewed_at} 뗀 서류"] if viewed_at else []), [
            "계약서 쓰는 날, 그리고 **잔금 보내는 날 아침**에 다시 떼서 이 앱으로 대조하세요",
            "잔금 보낸 날 **전입신고·확정일자**까지 마치세요",
        ]
    return [], []


def text_rule(kind: str, *, viewed_at: str | None = None) -> tuple[list[str], list[str]]:
    """OCR 글자로 찾은 3종."""
    if kind == "pending_application":
        return ([f"{viewed_at} 뗀 날 처리 중"] if viewed_at else ["뗀 날 처리 중"]), [
            "중개사에게 **무슨 신청인지**(근저당·말소 등) 물어보세요",
            "처리가 끝난 등기부를 다시 떼어 **이 앱으로 대조**하세요",
            "그 전에는 계약금·잔금을 **보내지 마세요**",
        ]
    if kind == "separate_land":
        return [], ["**토지 등기부**도 보여 달라고 해서 땅에 걸린 빚을 확인하세요"]
    if kind == "joint_collateral":
        return [], ["**공동담보목록**을 보여 달라고 해서 몇 채가 함께 묶였는지 확인하세요"]
    return [], []


def house_type_line(region: str | None, use: str | None, guessed: bool) -> tuple[str | None, str | None]:
    """주소 표시에 붙일 '이 집을 무엇으로 계산했나' (손실 시뮬레이터가 쓴 지역·용도). (사실, 할 일)."""
    if not use:
        return None, None
    where = f"{region} " if region else ""
    if guessed:
        return (f"{where}용도 확실하지 않음",
                "용도를 확실히 몰라 경매 통계가 가장 낮은 용도로 계산했어요. 아파트·빌라·오피스텔 중 무엇인지 확인하세요")
    return (f"{where}{use}로 계산",
            f"이 집을 **{where}{use}**로 보고 경매 통계를 썼어요. 맞는지 확인하세요")
