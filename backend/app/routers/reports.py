"""리포트·분석 관련 라우터 (계약 §3.1~§3.6).

- POST   /api/analyze                    분석 실행 (인증 필요=개발모드 통과)
- GET    /api/reports                    이력 목록 (비회원 허용)
- GET    /api/reports/{id}               리포트 단건 (비회원 허용)
- DELETE /api/reports/{id}               이력 삭제 (인증 필요=개발모드 통과, 예시는 403)
- GET    /api/reports/{id}/cases         판례 매칭 (비회원 허용)
- GET    /api/reports/{id}/questions     질문 생성 (비회원 허용)

더미 응답은 app/dummy_data.py(앱 더미 그대로 이식)에서 온다. 실제 분석은 Phase E.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile

from .. import dummy_data
from ..dependencies import get_current_user
from ..schemas.contract import CaseMatch, QuestionGroup, Report

router = APIRouter(prefix="/api", tags=["reports"])


@router.post("/analyze", response_model=Report)
async def analyze(
    files: list[UploadFile] = File(..., description="등기부 페이지 이미지(여러 장)"),
    deposit: int = Form(..., description="예정 보증금(원)"),
    marketPrice: Optional[int] = Form(default=None, description="매매 시세(원, 선택)"),
    alias: Optional[str] = Form(default=None, description="매물 별칭(선택)"),
    user: dict = Depends(get_current_user),  # 인증 필요 (개발 모드=항상 통과)
) -> Report:
    """등기부 사진 + 입력값으로 분석해 리포트를 만든다.

    더미 단계에서는 이미지를 실제로 분석하지 않고(수신만) 입력값으로 리포트를 생성한다.
    실단계(E-1)에서 업로드→Information Extract→규칙 엔진으로 교체한다.
    """
    return dummy_data.add_analysis(
        deposit=deposit, market_price=marketPrice, alias=alias
    )


@router.get("/reports", response_model=list[Report])
async def list_reports() -> list[Report]:
    """분석 이력 목록(최신순). 비회원도 예시 리포트를 본다."""
    return dummy_data.get_history()


@router.get("/reports/{report_id}", response_model=Report)
async def get_report(report_id: str) -> Report:
    report = dummy_data.get_report(report_id)
    if report is None:
        raise HTTPException(status_code=404, detail="이 리포트를 불러올 수 없어요")
    return report


@router.delete("/reports/{report_id}", status_code=204)
async def delete_report(
    report_id: str,
    user: dict = Depends(get_current_user),  # 인증 필요 (개발 모드=항상 통과)
) -> None:
    # 예시 리포트는 조회만 허용, 삭제 대상 아님 (계약 §3.4)
    if report_id in dummy_data.EXAMPLE_IDS:
        raise HTTPException(status_code=403, detail="예시 리포트는 삭제할 수 없어요")
    if dummy_data.get_report(report_id) is None:
        raise HTTPException(status_code=404, detail="이 리포트를 찾을 수 없어요")
    dummy_data.remove_report(report_id)
    # 204 No Content (본문 없음)


@router.get("/reports/{report_id}/cases", response_model=list[CaseMatch])
async def report_cases(report_id: str) -> list[CaseMatch]:
    report = dummy_data.get_report(report_id)
    if report is None:
        raise HTTPException(status_code=404, detail="이 리포트를 불러올 수 없어요")
    # 서버가 리포트의 근거에서 위험 패턴을 파생해 매칭 (계약 §2.2 note)
    return dummy_data.matched_cases(dummy_data.risk_labels(report))


@router.get("/reports/{report_id}/questions", response_model=list[QuestionGroup])
async def report_questions(report_id: str) -> list[QuestionGroup]:
    report = dummy_data.get_report(report_id)
    if report is None:
        raise HTTPException(status_code=404, detail="이 리포트를 불러올 수 없어요")
    return dummy_data.question_groups(dummy_data.risk_labels(report))
