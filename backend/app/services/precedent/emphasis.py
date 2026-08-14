"""판례 카드 본문에서 **굵게 보일 구간**을 고른다 (2026-08-14 D23).

⚠ **표시 전용이다.** 여기서 나온 어떤 값도 문장을 바꾸지 않는다 — 이미 확정된 본문에서
  "어디를 굵게 그릴지"만 고른다. 판정(등급·점수)과는 아무 관계가 없다.

왜 마크다운(`**굵게**`)이 아닌가:
  본문에 별표를 심으면 **문장 자체가 달라진다.** `advice`는 정민재 큐레이션 값이라
  문구 변경이 금지돼 있고(decisions.md 2026-07-09), 검수한 문장과 화면에 나가는 문장이
  달라지는 순간 검수가 무의미해진다. 그래서 본문은 그대로 두고 **구간만 따로** 내려보낸다.
  앱은 그 문자열을 본문에서 찾아(indexOf) 그 자리만 w700으로 그린다 — 못 찾으면
  아무 일도 일어나지 않는다(굵기만 사라진다).

누가 고르는가:
  ⑴ **Solar Pro** — 자기가 쓴 문장(`common_point`)과 결과 문장에서 핵심 구절을 고른다.
  ⑵ 그 선택이 아래 검증을 하나라도 어기면 그 필드는 통째로 버리고,
  ⑶ **금액·비율·기간 정규식**으로 대신 고른다. 그것도 없으면 굵게 없음.

  `advice`는 ⑴을 아예 거치지 않는다 — 큐레이션 문구라 LLM 입력에서 분리돼 있고
  (models.PrecedentDoc), 그 분리를 표시 계층 편의로 깨뜨리지 않는다.
"""

from __future__ import annotations

import re

#: 한 필드에 굵게 표시할 구간 수 상한. 셋 이상이면 "강조"가 아니라 그냥 굵은 문단이 된다.
MAX_ITEMS_PER_FIELD = 2
#: 한 구간의 길이 상한 — 문장 하나를 통째로 굵게 만드는 것을 막는다.
MAX_ITEM_CHARS = 30
#: 굵은 글자가 본문에서 차지할 수 있는 최대 비율.
MAX_BOLD_RATIO = 0.30

#: 폴백으로 고를 것 — 금액 · 비율 · 기간. 판례 본문에서 사람이 눈으로 먼저 잡는 값들이다.
#: (긴 표기가 먼저 잡히도록 금액을 앞에 둔다: `5억원`이 `5`로 쪼개지지 않게.)
_FALLBACK_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"\d[\d,]*(?:\.\d+)?\s*(?:억|천만|백만|만|천)?\s*원"),   # 금액
    re.compile(r"\d+(?:\.\d+)?\s*%"),                                  # 비율
    re.compile(r"\d+\s*(?:년|개월|달|주|일)"),                          # 기간
)


def _ranges(text: str, items: list[str]) -> list[tuple[int, int]]:
    """각 구간의 **첫 등장 위치**들 — 앱의 indexOf 렌더와 같은 규칙으로 센다.

    겹치는 구간은 하나로 합친다. 합치지 않으면 `보증금`과 `보증금 5억`이 둘 다 들어왔을 때
    굵은 글자 수가 실제보다 부풀어 30% 규칙이 엉뚱하게 통과·탈락한다.
    """
    spans: list[tuple[int, int]] = []
    for item in items:
        idx = text.find(item)
        if idx < 0:
            continue
        spans.append((idx, idx + len(item)))
    if not spans:
        return []
    spans.sort()
    merged = [spans[0]]
    for start, end in spans[1:]:
        last_start, last_end = merged[-1]
        if start <= last_end:
            merged[-1] = (last_start, max(last_end, end))
        else:
            merged.append((start, end))
    return merged


def validate(text: str, items: list[str]) -> list[str] | None:
    """LLM이 고른 구간이 규칙을 지키면 그대로, **하나라도 어기면 None**(= 필드 통째로 폐기).

    부분 폐기를 하지 않는 이유: 두 구간 중 하나가 지어낸 문자열이면 나머지 하나의
    판단력도 믿을 수 없다. 섞어 쓰느니 결정적 폴백으로 내려가는 편이 예측 가능하다.
    """
    if not text or not items:
        return None
    if len(items) > MAX_ITEMS_PER_FIELD:
        return None
    for item in items:
        if not item or not item.strip():
            return None
        if len(item) > MAX_ITEM_CHARS:
            return None
        if item not in text:  # 1글자만 달라도 폐기 — 앱은 indexOf로 찾으므로 못 찾는다
            return None
    spans = _ranges(text, items)
    if not spans:
        return None
    bold = sum(end - start for start, end in spans)
    if bold > len(text) * MAX_BOLD_RATIO:
        return None
    return items


def fallback(text: str) -> list[str]:
    """결정적 폴백 — 금액·비율·기간을 앞에서부터 최대 2개."""
    if not text:
        return []
    found: list[tuple[int, str]] = []
    taken: list[tuple[int, int]] = []
    for pattern in _FALLBACK_PATTERNS:
        for m in pattern.finditer(text):
            chunk = m.group(0).strip()
            if not chunk or len(chunk) > MAX_ITEM_CHARS:
                continue
            if any(m.start() < end and start < m.end() for start, end in taken):
                continue  # 이미 잡힌 구간과 겹친다 (금액 안의 숫자가 기간으로 또 잡히는 경우)
            taken.append((m.start(), m.end()))
            found.append((m.start(), chunk))
    found.sort()
    items = [chunk for _, chunk in found[:MAX_ITEMS_PER_FIELD]]
    # 폴백도 같은 비율 규칙을 지킨다 — 짧은 문장에서 금액 두 개가 절반을 먹지 않게.
    spans = _ranges(text, items)
    while items and sum(e - s for s, e in spans) > len(text) * MAX_BOLD_RATIO:
        items.pop()
        spans = _ranges(text, items)
    return items


def choose(text: str, llm_items: list[str] | None = None) -> list[str]:
    """이 본문에서 굵게 그릴 구간 — LLM 선택이 검증을 통과하면 그것, 아니면 폴백."""
    if llm_items:
        approved = validate(text, llm_items)
        if approved is not None:
            return approved
    return fallback(text)
