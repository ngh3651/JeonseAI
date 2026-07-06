"""리포트·분석 관련 라우터 (계약 §3.1~§3.6).

- POST   /api/analyze                    분석 실행 (인증 필요=개발모드 통과)
- GET    /api/reports                    이력 목록 (비회원 허용)
- GET    /api/reports/{id}               리포트 단건 (비회원 허용)
- DELETE /api/reports/{id}               이력 삭제 (인증 필요=개발모드 통과, 예시는 403)
- GET    /api/reports/{id}/cases         판례 매칭 (비회원 허용)
- GET    /api/reports/{id}/questions     질문 생성 (비회원 허용)

E-1c: analyze/이력은 실배선(추출→규칙 엔진→저장, services/) 완료.
판례·질문 응답은 아직 dummy_data — E-2(질문)·E-3(판례)에서 교체한다.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile

from .. import dummy_data
from ..dependencies import get_current_user
from ..schemas.contract import CaseMatch, QuestionGroup, Report
from ..services import report_builder, store
from ..services.extraction import ExtractionError

router = APIRouter(prefix="/api", tags=["reports"])

MAX_UPLOAD_BYTES = 10 * 1024 * 1024  # 파일당 10MB (기존 /api/upload와 동일 상한)


@router.post("/analyze", response_model=Report)
def analyze(
    files: list[UploadFile] = File(..., description="등기부 페이지 이미지(여러 장)"),
    deposit: int = Form(..., description="예정 보증금(원)"),
    marketPrice: Optional[int] = Form(default=None, description="매매 시세(원, 선택)"),
    alias: Optional[str] = Form(default=None, description="매물 별칭(선택)"),
    user: dict = Depends(get_current_user),  # 인증 필요 (개발 모드=항상 통과)
) -> Report:
    """등기부 사진 + 입력값으로 분석해 리포트를 만든다 (E-1c 실배선).

    업로드 → Information Extract(여러 장은 PDF 병합 1회 호출) → 규칙 엔진 판정
    → 설명 문구(폴백, E-2에서 LLM 교체) → 이력 저장. Upstage 호출이 수십 초
    걸릴 수 있어 동기(def) 핸들러로 두어 스레드풀에서 실행되게 한다.
    """
    images: list[tuple[str, bytes]] = []
    for f in files:
        data = f.file.read()
        if not data:
            continue
        if len(data) > MAX_UPLOAD_BYTES:
            raise HTTPException(
                status_code=413,
                detail="사진 용량이 너무 커요. 10MB 이하 사진으로 다시 시도해 주세요",
            )
        images.append((f.filename or "page.jpg", data))
    if not images:
        raise HTTPException(status_code=400, detail="등기부 사진을 1장 이상 올려 주세요")

    try:
        return report_builder.analyze(
            images, deposit=deposit, market_price=marketPrice, alias=alias
        )
    except ExtractionError as e:
        raise HTTPException(status_code=e.status_code, detail=e.detail)


@router.get("/reports", response_model=list[Report])
async def list_reports() -> list[Report]:
    """분석 이력 목록(최신순). 비회원도 예시 리포트를 본다."""
    return store.list_reports()


@router.get("/reports/{report_id}", response_model=Report)
async def get_report(report_id: str) -> Report:
    report = store.get(report_id)
    if report is None:
        raise HTTPException(status_code=404, detail="이 리포트를 불러올 수 없어요")
    return report


@router.delete("/reports/{report_id}", status_code=204)
async def delete_report(
    report_id: str,
    user: dict = Depends(get_current_user),  # 인증 필요 (개발 모드=항상 통과)
) -> None:
    # 예시 리포트는 조회만 허용, 삭제 대상 아님 (계약 §3.4)
    if report_id in store.EXAMPLE_IDS:
        raise HTTPException(status_code=403, detail="예시 리포트는 삭제할 수 없어요")
    if store.get(report_id) is None:
        raise HTTPException(status_code=404, detail="이 리포트를 찾을 수 없어요")
    store.remove(report_id)
    # 204 No Content (본문 없음)


@router.get("/reports/{report_id}/cases", response_model=list[CaseMatch])
async def report_cases(report_id: str) -> list[CaseMatch]:
    report = store.get(report_id)
    if report is None:
        raise HTTPException(status_code=404, detail="이 리포트를 불러올 수 없어요")
    # 서버가 리포트의 근거에서 위험 패턴을 파생해 매칭 (계약 §2.2 note)
    # 판례 응답은 아직 더미 — E-3에서 data/cases.json 큐레이션 매칭으로 교체
    return dummy_data.matched_cases(dummy_data.risk_labels(report))


@router.get("/reports/{report_id}/questions", response_model=list[QuestionGroup])
async def report_questions(report_id: str) -> list[QuestionGroup]:
    report = store.get(report_id)
    if report is None:
        raise HTTPException(status_code=404, detail="이 리포트를 불러올 수 없어요")
    # 질문 응답은 아직 더미 — E-2에서 data/questions.json 템플릿+조건부 변형으로 교체
    return dummy_data.question_groups(dummy_data.risk_labels(report))
