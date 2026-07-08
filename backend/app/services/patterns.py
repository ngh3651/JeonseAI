"""위험 패턴 파생 (계약 §2.2 note) — 판례·질문 엔드포인트가 공용으로 쓴다.

evidences 중 grade ≠ "양호"인 항목의 id를 위험 패턴 라벨로 매핑한다.
(dummy_data.risk_labels의 승격판 — dummy_data는 E-6에서 삭제 예정)
"""

from __future__ import annotations

from ..schemas.contract import Report

# 계약 §2.2에 기록된 고정 매핑 (blacklist는 패턴 매핑 없음)
ID_TO_LABEL = {
    "senior_debt": "선순위 채권",
    "ownership": "신탁등기",
    "jeonse_ratio": "전세가율",
    "insurance": "보증보험",
}
LABEL_TO_ID = {v: k for k, v in ID_TO_LABEL.items()}


def derive_from_report(report: Report) -> list[str]:
    """리포트의 근거 카드에서 위험 패턴 라벨 목록을 파생한다."""
    return [
        ID_TO_LABEL[e.id]
        for e in report.evidences
        if e.grade != "양호" and e.id in ID_TO_LABEL
    ]
