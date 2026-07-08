"""요약본('주요 등기사항 요약(참고용)') 거부 테스트 — decisions.md 2026-07-07.

요약본에는 말소 이력이 없어 그대로 분석하면 '깨끗한 집'으로 오판(미탐)할 수 있다.
"""

import pytest

from app.services.extraction import (
    SUMMARY_REJECT_DETAIL,
    ExtractionError,
    reject_summary_document,
)


def test_summary_title_rejected():
    raw = {"document_title": "주요 등기사항 요약 (참고용)", "mortgages": []}
    with pytest.raises(ExtractionError) as exc:
        reject_summary_document(raw)
    assert exc.value.status_code == 400
    assert exc.value.detail == SUMMARY_REJECT_DETAIL  # 기존 {"detail": ...} 형식 재사용


def test_keyword_anywhere_rejected():
    """제목 추출이 실패해도 다른 필드에 키워드가 있으면 잡는다 (이중 검사)."""
    raw = {"document_title": None, "address": "서울 ○○구", "note": "본 서류는 참고용입니다"}
    with pytest.raises(ExtractionError):
        reject_summary_document(raw)


def test_full_certificate_passes():
    raw = {
        "document_title": "등기사항전부증명서(말소사항 포함) - 집합건물",
        "address": "서울 ○○구 ○○동",
        "mortgages": [{"max_claim_amount": 100, "is_canceled": True}],
    }
    reject_summary_document(raw)  # 예외 없어야 함
