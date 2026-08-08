"""인메모리 리포트 저장소 (DB 없음 유지 — 서버 재시작 시 초기화).

- 예시 리포트 2건(dummy-danger / dummy-caution)은 계약 §3.4(비회원 조회 허용,
  삭제 시도 403)를 위해 시드로 유지한다.
- 지금은 dummy_data의 예시 빌더 산출물을 그대로 시드로 쓴다. dummy_data가 E-6에서
  삭제될 때 예시 시드를 이 모듈(또는 backend/data/)로 이전한다 — cleanup-tracker.md.
"""

from __future__ import annotations

from .. import dummy_data
from ..schemas.contract import CaseMatch, Report

EXAMPLE_IDS = dummy_data.EXAMPLE_IDS  # {"dummy-danger", "dummy-caution"} — 삭제 금지(403)

# 시드: 예시 2건 (최신순 정렬은 dummy_data가 보장)
_history: list[Report] = dummy_data.get_history()


def list_reports() -> list[Report]:
    """이력 목록(최신순)."""
    return list(_history)


def get(report_id: str) -> Report | None:
    for r in _history:
        if r.id == report_id:
            return r
    return None


def add(report: Report) -> None:
    """새 분석 결과를 이력 맨 앞에 넣는다."""
    _history.insert(0, report)


def remove(report_id: str) -> None:
    global _history
    _history = [r for r in _history if r.id != report_id]
    _cases_cache.pop(report_id, None)


# ── 판례 카드 캐시 (E-3 라우터 통합, 2026-08-07) ─────────────────────────────
# 판례 섹션은 하이브리드 검색 + 판례 수만큼의 Solar 호출이라 몇 초가 걸린다.
# 리포트는 한 번 만들어지면 변하지 않으므로 결과를 그대로 재사용한다.
# (인덱스를 다시 만들면 서버를 재시작해야 반영된다 — precedent/service.get_service 주석 참고)
_cases_cache: dict[str, list[CaseMatch]] = {}


def get_cases(report_id: str) -> list[CaseMatch] | None:
    return _cases_cache.get(report_id)


def put_cases(report_id: str, cases: list[CaseMatch]) -> None:
    _cases_cache[report_id] = cases
