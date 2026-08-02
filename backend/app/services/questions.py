"""질문 생성기 — data/questions.json 큐레이션 템플릿 + 조건부 변형 (LLM 미개입).

구조 (decisions.md 2026-07-07):
- **선택 로직**(규칙): 위험 패턴 파생(patterns.py) → 그룹 선택 → 항목별 조건
  (`evidenceGrade`, `marketPriceProvided`) 평가.
- **문구 렌더링**: 중괄호 빈칸({보증금} 등)을 매물 수치로 치환 — 별도 단계로 분리해
  향후 이 단계만 LLM 다듬기로 교체할 수 있다.
- safeAnswer/riskyAnswer는 사실상 판단 가이드이므로 LLM을 거치지 않는다.

데이터 파일은 비개발 팀원이 직접 편집한다(backend/data/README.md). 편집 실수는
한국어 로그로 안내하고, 파일이 깨져도 기본 그룹("어떤 집이든 꼭")은 항상 나간다
(계약 §3.6 — 빈 배열 금지).
"""

from __future__ import annotations

import json
import logging
import re
from pathlib import Path
from typing import Optional

from pydantic import BaseModel, ConfigDict, ValidationError

from ..schemas.contract import QuestionGroup, QuestionItem, Report
from . import price_resolver
from .formatting import format_won, round_half_up
from .patterns import LABEL_TO_ID, derive_from_report

_log = logging.getLogger("jeonseai")
_QUESTIONS_PATH = Path(__file__).resolve().parents[2] / "data" / "questions.json"

ALWAYS_PATTERN = "항상"


# ── 템플릿 파일 모델 (편집 실수 검증용) ──────────────────────────────────────


class ItemTemplate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    question: str
    why: str
    safeAnswer: str
    riskyAnswer: str
    condition: Optional[dict] = None


class GroupTemplate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    riskLabel: str
    triggerPattern: str
    items: list[ItemTemplate]


class QuestionsConfig(BaseModel):
    model_config = ConfigDict(extra="ignore")  # "_안내" 같은 안내 키 허용
    groups: list[GroupTemplate]


# 파일이 깨졌을 때도 계약 §3.6(기본 그룹 필수)을 지키기 위한 비상용 최소 세트.
# 평상시 문구 관리는 전부 data/questions.json에서 한다(여기 문구는 그 사본).
_EMERGENCY_BASE_GROUP = QuestionGroup(
    riskLabel="어떤 집이든 꼭",
    items=[
        QuestionItem(
            question="전세보증금 반환보증(보증보험)에 가입할 수 있는 집인가요?",
            why="가입이 되면 보증기관이 보증금을 대신 돌려줘요",
            safeAnswer="가입 가능하다고 확인해 준다",
            riskyAnswer="가입이 안 된다거나 모른다고 한다",
        ),
        QuestionItem(
            question="등기부상 소유자와 계약 당사자가 같은 사람인가요?",
            why="실소유자가 아닌 사람과 계약하면 보증금을 지키기 어려워요",
            safeAnswer="신분증과 등기부 소유자가 일치한다",
            riskyAnswer="대리인인데 위임장이 없다",
        ),
    ],
)


def _load_config() -> QuestionsConfig | None:
    """questions.json을 읽고 검증한다. 실수는 몇 번째 그룹/항목인지 한국어로 안내."""
    try:
        raw = json.loads(_QUESTIONS_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        _log.info("[질문] questions.json이 없어요 — 비상용 기본 질문만 제공합니다")
        return None
    except ValueError as e:
        _log.info(f"[질문] questions.json이 올바른 JSON이 아니에요 (쉼표·따옴표 확인): {e}")
        return None
    try:
        return QuestionsConfig.model_validate(raw)
    except ValidationError as e:
        first = e.errors()[0]
        loc = " → ".join(str(p) for p in first["loc"])
        _log.info(
            f"[질문] questions.json 형식 오류 — 위치 [{loc}]: {first['msg']} "
            "(README.md의 칸 설명을 확인해 주세요)"
        )
        return None


# ── ① 선택 로직 (규칙) ───────────────────────────────────────────────────────


def _grade_of_pattern(report: Report, pattern: str) -> str | None:
    """그룹의 트리거 패턴에 대응하는 근거 카드 등급."""
    evidence_id = LABEL_TO_ID.get(pattern)
    if evidence_id is None:
        return None
    for e in report.evidences:
        if e.id == evidence_id:
            return e.grade
    return None


def _gap_direction(report: Report) -> str | None:
    """실거래가 ↔ 공시 기준 괴리의 방향. 임계값은 price_resolver의 **잠정값**이다.

    ⚠ 판정이 아니다 — 어떤 질문을 보여줄지 고르는 데만 쓴다.
    """
    gap = report.marketPriceGapPct
    if gap is None:
        return None
    if gap >= price_resolver.TRADE_INFLATED_GAP_PCT:
        return "trade_inflated"
    if gap <= price_resolver.TRADE_DEPRESSED_GAP_PCT:
        return "trade_depressed"
    return "similar"


def _condition_met(condition: dict | None, report: Report, pattern: str) -> bool:
    if not condition:
        return True
    for key, expected in condition.items():
        if key == "evidenceGrade":
            if _grade_of_pattern(report, pattern) != expected:
                return False
        elif key == "marketPriceProvided":
            # ⚠ '값이 있는가'만 본다 — 사용자가 넣었든 자동 조회로 채워졌든 상관없다.
            #   출처를 가리고 싶으면 아래 marketPriceSource 를 쓴다(2026-08-03 추가).
            if (report.marketPrice is not None) != bool(expected):
                return False
        elif key == "marketPriceSource":
            # 'manual' | 'actual_trade' | 'official_price' | 'tax_base' | 'auto' | 'none'
            actual = report.marketPriceSource
            if expected == "auto":
                if actual is None or actual == price_resolver.SOURCE_MANUAL:
                    return False
            elif expected == "none":
                if actual is not None:
                    return False
            elif actual != expected:
                return False
        elif key == "marketPriceGap":
            # 'trade_inflated' | 'trade_depressed' | 'similar'
            if _gap_direction(report) != expected:
                return False
        else:
            # 모르는 조건 키 → 노출하지 않음(보수적) + 편집자 안내
            _log.info(f"[질문] 알 수 없는 condition 키 '{key}' — 해당 질문은 건너뜁니다")
            return False
    return True


# ── ② 문구 렌더링 (향후 이 단계만 LLM 다듬기로 교체 가능) ────────────────────

_PLACEHOLDER_RE = re.compile(r"\{([^{}]+)\}")


def _render_values(report: Report) -> dict[str, str]:
    values = {
        "보증금": format_won(report.deposit),
        "선순위채권합계": format_won(report.seniorDebtAmount),
    }
    if report.marketPrice:
        values["시세"] = format_won(report.marketPrice)
        values["전세가율"] = f"{round_half_up(report.deposit / report.marketPrice * 100)}%"
    return values


def _render(text: str, values: dict[str, str]) -> str | None:
    """빈칸 치환. 채울 수 없는 빈칸이 있으면 None(그 질문은 건너뜀)."""
    keys = _PLACEHOLDER_RE.findall(text)
    for key in keys:
        if key not in values:
            return None
    for key in keys:
        text = text.replace("{" + key + "}", values[key])
    return text


# ── 조립 ─────────────────────────────────────────────────────────────────────


def build_question_groups(report: Report) -> list[QuestionGroup]:
    """리포트 → 질문 그룹 목록 (계약 §3.6 — 기본 그룹 항상 포함)."""
    config = _load_config()
    if config is None:
        _log.info("[질문] 템플릿 선택: 그룹 1개 · 질문 2건 (비상용, LLM 미사용)")
        return [_EMERGENCY_BASE_GROUP]

    patterns = derive_from_report(report)
    values = _render_values(report)

    groups: list[QuestionGroup] = []
    total_items = 0
    for group in config.groups:
        if group.triggerPattern != ALWAYS_PATTERN and group.triggerPattern not in patterns:
            continue
        items: list[QuestionItem] = []
        for item in group.items:
            if not _condition_met(item.condition, report, group.triggerPattern):
                continue
            question = _render(item.question, values)
            why = _render(item.why, values)
            if question is None or why is None:
                _log.info(
                    f"[질문] '{group.riskLabel}' 질문 1건 건너뜀 — 채울 수 없는 빈칸 존재"
                )
                continue
            items.append(
                QuestionItem(
                    question=question,
                    why=why,
                    safeAnswer=item.safeAnswer,
                    riskyAnswer=item.riskyAnswer,
                )
            )
        if items:
            groups.append(QuestionGroup(riskLabel=group.riskLabel, items=items))
            total_items += len(items)

    if not any(g.riskLabel == _EMERGENCY_BASE_GROUP.riskLabel for g in groups):
        groups.append(_EMERGENCY_BASE_GROUP)  # 계약 §3.6 — 기본 그룹은 어떤 경우에도 존재
        total_items += len(_EMERGENCY_BASE_GROUP.items)

    _log.info(f"[질문] 템플릿 선택: 그룹 {len(groups)}개 · 질문 {total_items}건 (LLM 미사용)")
    return groups
