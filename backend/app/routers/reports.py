"""리포트·분석 관련 라우터 (계약 §3.1~§3.6).

- POST   /api/analyze                    분석 실행 (인증 필요=개발모드 통과)
- GET    /api/reports                    이력 목록 (비회원 허용)
- GET    /api/reports/{id}               리포트 단건 (비회원 허용)
- DELETE /api/reports/{id}               이력 삭제 (인증 필요=개발모드 통과, 예시는 403)
- GET    /api/reports/{id}/cases         판례 매칭 (비회원 허용)
- GET    /api/reports/{id}/questions     질문 생성 (비회원 허용)

E-1c: analyze/이력 실배선(추출→규칙 엔진→저장) 완료.
E-2: 질문은 data/questions.json 템플릿 실연동 완료. 판례만 아직 dummy_data(E-3에서 교체).
"""

from __future__ import annotations

import logging
from typing import Optional

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile

from .. import dummy_data
from ..dependencies import get_current_user
from ..schemas.contract import CaseMatch, QuestionGroup, Report
from ..services import patterns, questions, report_builder, store
from ..services.precedent import service as precedent_service
from ..services.extraction import ExtractionError

router = APIRouter(prefix="/api", tags=["reports"])

# 서버 콘솔 로거 — services 쪽과 같은 이름을 쓴다(main.py가 핸들러를 붙인다).
_log = logging.getLogger("jeonseai")

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
    # E-3 실연동 (2026-08-07): 규칙이 태그를 파생 → 하이브리드 검색 → LLM은 문장만.
    #   판례가 없으면 빈 목록이 나간다 (지어내지 않는다 — PrecedentSection.fallback_text).
    #
    # 결과를 리포트 단위로 캐시한다. 캐시가 없으면 화면에 들어올 때마다 검색 +
    #   판례 수만큼 Solar 호출이 다시 돌아 매번 수 초를 기다리게 된다.
    cached = store.get_cases(report_id)
    if cached is not None:
        return cached

    # ⚠ 이 경로 전체를 감싼다 (2026-08-14 D7). 판례 매칭은 임베딩 호출 → 벡터 검색 →
    #   Solar 설명 생성으로 이어지는데, 그 어느 단계든 밖에서 끊길 수 있다(크레딧 소진,
    #   인덱스 미적재, 네트워크). 지금까지는 그때 500이 나가 화면이 **에러**로 덮였다.
    #
    #   판례가 없는 것은 이미 정상 상태다 — 앱은 빈 목록을 받으면 "딱 맞는 판례가 아직
    #   없어요. 위험이 없다는 뜻은 아니니…"를 띄운다(case_match_screen.dart). 촬영 중
    #   크레딧이 끊겨도 심사위원에게 보일 것은 에러 화면이 아니라 그 문구여야 한다.
    #
    #   ⚠ 실패한 결과는 **캐시하지 않는다.** 캐시하면 원인이 사라진 뒤에도 이 리포트는
    #     영원히 판례 없음으로 굳는다. 다시 들어오면 다시 시도하게 둔다.
    try:
        section = precedent_service.get_service().match_for_report(report, explain=True)
        cases = [CaseMatch.model_validate(c) for c in section.cases]
    except Exception:  # noqa: BLE001 — 판례가 리포트 화면을 깨뜨리지 못하게 하는 방어선
        _log.error(
            "[판례] ⚠ 매칭 실패 — 빈 목록으로 응답합니다"
            f" (리포트 {report_id}). 앱에는 '딱 맞는 판례가 아직 없어요'가 뜹니다",
            exc_info=True,
        )
        return []
    store.put_cases(report_id, cases)
    return cases


@router.get("/reports/{report_id}/questions", response_model=list[QuestionGroup])
async def report_questions(report_id: str) -> list[QuestionGroup]:
    report = store.get(report_id)
    if report is None:
        raise HTTPException(status_code=404, detail="이 리포트를 불러올 수 없어요")
    # E-2 실연동: data/questions.json 템플릿 + 조건부 변형 (LLM 미개입)
    return questions.build_question_groups(report)
