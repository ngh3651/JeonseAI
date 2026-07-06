"""금액 표기 유틸 — 앱 money_format.dart(formatWon)과 동일 동작.

dummy_data.py의 사본을 서비스로 승격한 것(dummy_data는 E-6에서 삭제 예정).
"""

from __future__ import annotations

import re
from math import floor


def _comma(n: int) -> str:
    s = str(n)
    out: list[str] = []
    for i, ch in enumerate(s):
        if i > 0 and (len(s) - i) % 3 == 0:
            out.append(",")
        out.append(ch)
    return "".join(out)


def format_won(won: int) -> str:
    if won <= 0:
        return "0원"
    eok = won // 100_000_000
    man = (won % 100_000_000) // 10_000
    parts: list[str] = []
    if eok > 0:
        parts.append(f"{eok}억")
    if man > 0:
        parts.append((" " if eok > 0 else "") + f"{_comma(man)}만")
    if not parts:
        parts.append(_comma(won))
    return "".join(parts) + "원"


def round_half_up(x: float) -> int:
    """Dart double.round()(0.5는 올림) 동작에 맞춘 반올림 — 앱 표시와 일치."""
    return floor(x + 0.5)


_DONG_RE = re.compile(r"[가-힣0-9]+(?:동|읍|면|리|가)(?=\s)")
_ROAD_RE = re.compile(r"[가-힣0-9]+(?:로|길)(?=\s)")


def short_address(address: str) -> str:
    """표시용 축약 주소 — 시·도/구를 떼고 '○○동(읍·면, 없으면 도로명)'부터 시작.

    홈 카드 별칭 폴백 등 **표시에만** 쓴다. 판정·저장·Report.address는 전체 주소 유지
    (전체 주소는 리포트 화면 헤더에서 확인). 매칭 실패 시 원본을 그대로 돌려준다.
    """
    if not address:
        return address
    head = address.split(",")[0].strip()  # 등기부의 '지번, 도로명' 병기 중 앞부분만
    m = _DONG_RE.search(head) or _ROAD_RE.search(head)
    return head[m.start():] if m else head
