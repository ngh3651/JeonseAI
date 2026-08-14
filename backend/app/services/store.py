"""인메모리 리포트 저장소 (DB 없음 유지 — 서버 재시작 시 초기화).

- 예시 리포트 1건(dummy-example)은 계약 §3.4(비회원 조회 허용, 삭제 시도 403)를
  위해 시드로 유지한다. dummy_data가 E-6에서 삭제될 때 이 모듈(또는 backend/data/)로
  이전한다 — cleanup-tracker.md.

⚠ **시드는 첫 조회 때 만든다** (2026-08-14 D13). 예시가 규칙 엔진 산출물이 되면서
  `dummy_data`가 `report_builder`를 부르게 됐는데, 그 `report_builder`가 이 모듈을
  import한다. 모듈을 읽는 시점에 시드를 만들면 `report_builder → store → dummy_data →
  report_builder` 순환에 걸린다. 첫 호출 시점에는 세 모듈이 모두 적재를 마친 뒤다.
"""

from __future__ import annotations

from .. import dummy_data
from ..schemas.contract import CaseMatch, Report
from .compare import RegistrySnapshot

EXAMPLE_IDS = dummy_data.EXAMPLE_IDS  # {"dummy-example"} — 삭제 금지(403)

_history: list[Report] | None = None


def _seeded() -> list[Report]:
    """예시 시드를 붙인 이력 목록. **모든 접근은 이 함수를 거친다.**"""
    global _history
    if _history is None:
        _history = dummy_data.get_history()
    return _history


def list_reports() -> list[Report]:
    """이력 목록(최신순)."""
    return list(_seeded())


def get(report_id: str) -> Report | None:
    for r in _seeded():
        if r.id == report_id:
            return r
    return None


def add(report: Report) -> None:
    """새 분석 결과를 이력 맨 앞에 넣는다."""
    _seeded().insert(0, report)


def remove(report_id: str) -> None:
    global _history
    _history = [r for r in _seeded() if r.id != report_id]
    _cases_cache.pop(report_id, None)
    _snapshots.pop(report_id, None)


# ── 등기부 스냅샷 (S-11 대조, 2026-08-14) ────────────────────────────────────
# 대조는 **판정이 아니라 추출 결과**를 맞춰보는 것이라, 리포트만으로는 할 수 없다
# (리포트에는 근저당 몇 건이 어떤 접수일로 잡혔는지가 남지 않는다). 그래서 분석할 때
# 견줄 재료를 따로 남긴다. 실명은 담지 않는다(services/compare.py 참고).
#
# ⚠ 스냅샷이 없는 리포트 = 대조 기준으로 쓸 수 없는 리포트다. 이 기능 이전에 분석한
#   이력과 예시 리포트가 여기 해당한다 — 앱은 `Report.comparable`로 미리 알고
#   "기준 없음" 화면을 사진 촬영 **전에** 보여준다.
_snapshots: dict[str, RegistrySnapshot] = {}


def put_snapshot(report_id: str, snapshot: RegistrySnapshot) -> None:
    _snapshots[report_id] = snapshot


def get_snapshot(report_id: str) -> RegistrySnapshot | None:
    return _snapshots.get(report_id)


# ── 판례 카드 캐시 (E-3 라우터 통합, 2026-08-07) ─────────────────────────────
# 판례 섹션은 하이브리드 검색 + 판례 수만큼의 Solar 호출이라 몇 초가 걸린다.
# 리포트는 한 번 만들어지면 변하지 않으므로 결과를 그대로 재사용한다.
# (인덱스를 다시 만들면 서버를 재시작해야 반영된다 — precedent/service.get_service 주석 참고)
_cases_cache: dict[str, list[CaseMatch]] = {}


def get_cases(report_id: str) -> list[CaseMatch] | None:
    return _cases_cache.get(report_id)


def put_cases(report_id: str, cases: list[CaseMatch]) -> None:
    _cases_cache[report_id] = cases
