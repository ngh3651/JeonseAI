"""화면엔 실명, 서버엔 가린 사본 (2026-10-22 규혁 결정 — "폰엔 원본, 서버엔 가린 사본").

왜 있나: PR #3은 화면 문장(하이라이트 제목 `집주인 이름 · 홍○○`)을 **만들 때부터** 가렸다. 그래서 사용자 폰에도
실명이 안 보여, 실제로 만난 계약자와 이름을 맞춰 보기가 불편했다. 이제는 이렇게 나눈다:

- 분석 **응답**은 실명이다 — 사용자가 자기 폰에서 대조할 수 있어야 한다. 회사·은행 이름은 원래부터 그대로.
  앱의 '사진 속 이름 가리기' 스위치가 쓸 수 있게 응답에 `personNames`(사람 이름 목록)도 싣는다.
- 서버가 **디스크에 남기는** 리포트는 전부 `mask_report_for_storage`를 거친 **가린 사본**이다.
  `store.add`가 직접 부른다 — 부르는 쪽이 잊을 수 없게. 그래서 기록 API·캐시 적중·대조는 가린 이름을 돌려준다.
- 설명(Solar) 입력과 로그는 원래대로 가린 이름이다(규칙 엔진 재료 `mask_person_name`, 로그 `mask_name`).
  이 모듈은 그쪽을 건드리지 않는다.
"""

from __future__ import annotations

import logging
from typing import Any

from ..schemas.contract import Report
from ..schemas.internal import RegistryExtract
from . import privacy_masks
from .formatting import mask_name

_log = logging.getLogger("jeonseai")

#: 가리지 않는 필드 — 집 **주소**는 사람 이름 칸이 아니다(등기부 표제부). `grade`는 정해진 말
#: (`위험`·`확인 필요`·`양호`)이라 `양호`라는 이름이 있어도 등급 값이 깨지면 안 된다.
_KEEP_FIELDS = frozenset({"address", "grade"})


def person_names(extract: RegistryExtract | None) -> list[str]:
    """추출 결과의 **사람** 이름 전부 (긴 것부터) — 응답 `personNames`와 저장 사본 가리기가 쓴다.

    갑구 소유자·권리자(이전 소유자 포함), 을구 근저당권자·채무자·전세권자·임차권자, 가압류·가처분·압류·경매 채권자,
    신탁 수탁자 — 사진 속 이름 자리(`privacy_masks`)와 **같은 칸·같은 기관 판별**을 쓴다(은행·회사·관공서는 뺀다).
    **이름 칸 글자 그대로**(`홍 길동`처럼 띄어 쓴 것까지, `외 1명` 꼬리를 뗀 꼴도)만 넣는다 — 하이라이트 제목이 그 글자를
    그대로 쓰므로 저장 사본에서 같은 글자를 찾아 가릴 수 있다. 쪼갠 낱말(`길동`)은 넣지 않는다 — 짧은 낱말은
    다른 글자(`양호해요`)까지 망가뜨린다(사진 가림 상자는 위치만 쓰니 낱말로 찾아도 된다 — `privacy_masks`).
    """
    if extract is None:
        return []
    names: set[str] = set()
    for value in privacy_masks.name_values(extract):
        if not privacy_masks.is_person_value(value):
            continue
        names.add(value.strip())
        without_tail = privacy_masks.without_others_tail(value).strip()
        if len(without_tail) >= 2:
            names.add(without_tail)
    return sorted(names, key=len, reverse=True)


def owner_names_fallback(extract: RegistryExtract | None) -> list[str]:
    """`person_names`가 실패했을 때의 최소 목록 — 서버가 실명으로 쓰는 글자는 집주인 이름(하이라이트 제목)뿐이다."""
    if extract is None:
        return []
    return sorted({o.name.strip() for o in extract.current_owners if o.name and o.name.strip()}, key=len, reverse=True)


def mask_text(text: str, names: list[str]) -> str:
    """글자 속 사람 이름을 `mask_name`으로(`홍길동` → `홍○○`). 긴 이름부터 바꾼다(`김철수`가 `철수`보다 먼저)."""
    for name in sorted({n for n in names if n and n.strip()}, key=len, reverse=True):
        if name in text:
            text = text.replace(name, mask_name(name))
    return text


def _mask_value(value: Any, names: list[str]) -> Any:
    if isinstance(value, str):
        return mask_text(value, names)
    if isinstance(value, list):
        return [_mask_value(v, names) for v in value]
    if isinstance(value, dict):
        return {k: (v if k in _KEEP_FIELDS else _mask_value(v, names)) for k, v in value.items()}
    return value


def mask_report_for_storage(report: Report, names: list[str] | None = None) -> Report:
    """리포트의 **가린 깊은 사본** — 모든 문자열 필드의 사람 이름을 `mask_name`으로 바꾼다(주소만 그대로).

    `names`가 없으면 리포트 자신의 `personNames`를 쓴다 — 그 목록도 가려진다(`["홍○○"]`).
    원본은 바꾸지 않는다(응답은 실명 그대로 나간다). 이미 가린 사본을 다시 넣어도 그대로다(`홍○○` → `홍○○`).
    """
    use = list(report.personNames if names is None else names)
    if not use:
        return report.model_copy(deep=True)
    return Report.model_validate(_mask_value(report.model_dump(mode="json"), use))
