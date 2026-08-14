"""계약 여정 단계 — `data/journey_stages.json` 큐레이션 로더 (LLM 미개입).

왜 코드가 아니라 데이터 파일인가:
단계 문구는 **판정이 아니라 안내문**이라 비개발 팀원이 직접 고칠 수 있어야 한다
(CLAUDE.md 2절 · `backend/data/README.md`). 예전에는 `dummy_data.py` 안 파이썬
리터럴이라 개발자만 고칠 수 있었다.

깨져도 화면은 산다:
파일이 없거나 JSON 문법이 틀리면 **어디가 문제인지 한국어로 로그를 남기고**
코드 안 최소 단계 묶음으로 응답한다. 여정 탭이 통째로 빈 화면이 되는 것보다
낫기 때문이다(계약 §3.7은 빈 배열을 금지하지 않지만, 빈 화면은 '고장'으로 읽힌다).
"""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Optional

from pydantic import BaseModel, ConfigDict, ValidationError

from ..schemas.contract import JourneyItem, JourneyStage

_log = logging.getLogger("jeonseai")
_STAGES_PATH = Path(__file__).resolve().parents[2] / "data" / "journey_stages.json"

#: `kind` 칸에 쓸 수 있는 값 — 그 외 값은 편집 실수로 보고 'action'으로 떨어뜨린다.
KINDS = ("analysis", "action", "later")

#: `dateKey` 칸에 쓸 수 있는 값. 앱의 일정 시트 4칸 + 자동 계산 1개와 1:1이다.
DATE_KEYS = ("downPayment", "contract", "balance", "moveIn", "moveInNext")


class _ItemTemplate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    text: str
    why: str


class _StageTemplate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str
    subtitle: str
    items: list[_ItemTemplate]
    kind: str = "action"
    compare: bool = False
    askDates: bool = False
    agency: Optional[str] = None
    dateKey: Optional[str] = None


class _StagesConfig(BaseModel):
    model_config = ConfigDict(extra="ignore")  # "_안내" 같은 안내 키 허용
    stages: list[_StageTemplate]


#: 파일을 못 읽었을 때의 최소 묶음. **문구를 여기서 늘리지 않는다** — 정본은 데이터 파일이다.
_FALLBACK: tuple[JourneyStage, ...] = (
    JourneyStage(
        title="집 둘러보고 등기부 분석하기",
        subtitle="이미 끝난 단계예요",
        kind="analysis",
        items=[],
    ),
    JourneyStage(
        title="잔금 보내는 날",
        subtitle="가장 큰 돈이 나가는 날",
        kind="action",
        compare=True,
        dateKey="balance",
        items=[
            JourneyItem(
                text="등기부를 다시 떼서 달라진 게 없는지 보기",
                why="잔금 직전에 근저당을 새로 설정하는 방식이 많아요",
            )
        ],
    ),
)


def _to_stage(t: _StageTemplate, index: int) -> JourneyStage:
    kind = t.kind if t.kind in KINDS else "action"
    if kind != t.kind:
        _log.warning(
            f"[여정] {index + 1}번째 단계의 kind 칸이 '{t.kind}'입니다 — "
            f"쓸 수 있는 값은 {', '.join(KINDS)}. 'action'으로 보고 진행합니다"
        )
    date_key = t.dateKey if t.dateKey in DATE_KEYS else None
    if t.dateKey and date_key is None:
        _log.warning(
            f"[여정] {index + 1}번째 단계의 dateKey 칸이 '{t.dateKey}'입니다 — "
            f"쓸 수 있는 값은 {', '.join(DATE_KEYS)}. 날짜를 붙이지 않고 진행합니다"
        )
    return JourneyStage(
        title=t.title,
        subtitle=t.subtitle,
        items=[JourneyItem(text=i.text, why=i.why) for i in t.items],
        kind=kind,
        compare=t.compare,
        askDates=t.askDates,
        agency=(t.agency or None),
        dateKey=date_key,
    )


def load_stages() -> list[JourneyStage]:
    """데이터 파일 → 단계 목록. 파일이 깨져 있으면 [_FALLBACK]."""
    try:
        raw = json.loads(_STAGES_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        _log.error(f"[여정] 단계 파일을 찾지 못했습니다 ({_STAGES_PATH}) — 최소 단계로 응답합니다")
        return list(_FALLBACK)
    except json.JSONDecodeError as e:
        _log.error(
            f"[여정] 단계 파일의 JSON 문법이 틀렸습니다 — {e.lineno}번째 줄 근처: {e.msg}. "
            "쉼표·따옴표·괄호 짝을 확인해 주세요 (data/README.md). 최소 단계로 응답합니다"
        )
        return list(_FALLBACK)

    try:
        config = _StagesConfig.model_validate(raw)
    except ValidationError as e:
        first = e.errors()[0] if e.errors() else {}
        where = " → ".join(str(x) for x in first.get("loc", ()))
        _log.error(
            f"[여정] 단계 파일의 칸 구성이 계약과 다릅니다 — '{where}' 위치: "
            f"{first.get('msg', '알 수 없는 문제')}. 최소 단계로 응답합니다"
        )
        return list(_FALLBACK)

    if not config.stages:
        _log.error("[여정] 단계 파일에 단계가 하나도 없습니다 — 최소 단계로 응답합니다")
        return list(_FALLBACK)

    return [_to_stage(t, i) for i, t in enumerate(config.stages)]
