"""리포트·분석 관련 라우터 (계약 §3.1~§3.6).

- POST   /api/analyze                    분석 실행
- POST   /api/reports/{id}/compare       다시 뗀 등기부 대조
- GET    /api/reports                    이력 목록 (이 기기 것 + 예시)
- GET    /api/reports/{id}               리포트 단건
- DELETE /api/reports/{id}               이력 삭제 (예시는 403)
- GET    /api/reports/{id}/cases         판례 매칭
- GET    /api/reports/{id}/questions     질문 생성

**기기별 기록 (2026-10-21):** 모든 엔드포인트가 `get_current_user`(= `X-Device-Id` 기기 id)를
받아 **그 기기의 기록만** 다룬다. 다른 기기의 리포트 id를 넣으면 404 — "있는데 못 본다"와
"없다"를 구분해 주지 않는다. 예시 리포트(`dummy-example`)만 모든 기기에 보인다.

E-1c: analyze/이력 실배선(추출→규칙 엔진→저장) 완료.
E-2: 질문은 data/questions.json 템플릿 실연동 완료. 판례만 아직 dummy_data(E-3에서 교체).
"""

from __future__ import annotations

import logging
from typing import Optional

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse

from .. import dummy_data, settings
from ..dependencies import get_current_user, limit_analyze
from ..schemas.contract import CaptureCheck, CaseMatch, CompareResult, QuestionGroup, Report
from ..services import analysis_cache, capture_check, compare, patterns, questions, report_builder, store
from ..services.precedent import service as precedent_service
from ..services.extraction import ExtractionError

router = APIRouter(prefix="/api", tags=["reports"])

# 서버 콘솔 로거 — services 쪽과 같은 이름을 쓴다(main.py가 핸들러를 붙인다).
_log = logging.getLogger("jeonseai")

MAX_UPLOAD_BYTES = 10 * 1024 * 1024  # 파일당 10MB (기존 /api/upload와 동일 상한)


def _read_images(files: list[UploadFile], *, empty_detail: str) -> list[tuple[str, bytes]]:
    """올라온 사진을 읽는다. 장수·용량·빈 요청을 **외부 API를 부르기 전에** 거른다.

    ⚠ 장수는 **내용을 읽기 전에** 센다(2026-10-22) — 사진 수백 장을 보내 OCR(장당 호출) 크레딧을
      태우는 것을 막는다. 앱은 10장까지 보내므로 상한(`settings.MAX_PHOTOS_PER_REQUEST`=20)은 넉넉하다.
    """
    limit = settings.MAX_PHOTOS_PER_REQUEST
    if len(files) > limit:
        raise HTTPException(
            status_code=400,
            detail=f"사진이 너무 많아요. 한 번에 {limit}장까지 올릴 수 있어요",
        )
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
        raise HTTPException(status_code=400, detail=empty_detail)
    return images


def _capture_gate(images: list[tuple[str, bytes]]) -> tuple[CaptureCheck | None, JSONResponse | None]:
    """촬영 검사(P1-1, 2026-10-22) — IE·OCR **전에** 사진 품질을 본다. (검사 결과, 거절 응답).

    심하게 흐리거나 어두운 장이 있으면 **분석하지 않고** 400을 돌려준다(크레딧 0원). 분석 횟수는 1회 센다 —
    라우터가 `limit_analyze` **뒤에** 부른다(검사도 서버 계산을 쓰므로 횟수로 묶어 둔다).
    본문은 일관 에러 형식 그대로 `detail`(한국어 한 줄) + 덧붙인 `captureCheck`(장별 안내)다 —
    옛 앱은 `detail`만 읽고, 새 앱은 `captureCheck`로 "그 장만 다시 찍기"를 그린다.
    가벼운 문제는 통과시킨다(리포트의 `captureCheck`에 실린다).
    """
    check = capture_check.precheck(images)
    if not capture_check.should_reject(check):
        return check, None
    assert check is not None
    message = capture_check.rejection_message(check)
    _log.info(f"[촬영검사] 분석 전 거절 — {message} (크레딧 0원)")
    return check, JSONResponse(
        status_code=400,
        content={"detail": message, "captureCheck": check.model_dump()},
    )


@router.post("/analyze", response_model=Report)
def analyze(
    request: Request,
    files: list[UploadFile] = File(..., description="등기부 페이지 이미지(여러 장)"),
    deposit: int = Form(..., description="예정 보증금(원)"),
    marketPrice: Optional[int] = Form(default=None, description="매매 시세(원, 선택)"),
    alias: Optional[str] = Form(default=None, description="매물 별칭(선택)"),
    device_id: str = Depends(get_current_user),  # 호출한 기기 (X-Device-Id, 없으면 공용 legacy-device)
) -> Report:
    """등기부 사진 + 입력값으로 분석해 리포트를 만든다 (E-1c 실배선).

    업로드 → Information Extract(여러 장은 PDF 병합 1회 호출) → 규칙 엔진 판정
    → 설명 문구(폴백, E-2에서 LLM 교체) → 이력 저장. Upstage 호출이 수십 초
    걸릴 수 있어 동기(def) 핸들러로 두어 스레드풀에서 실행되게 한다.
    """
    images = _read_images(files, empty_detail="등기부 사진을 1장 이상 올려 주세요")
    # 입력 검사를 모두 통과한 뒤에만 센다 — 형식이 틀린 요청은 분석 기회를 깎지 않는다
    limit_analyze(request, device_id)
    # 같은 사진·같은 입력이면 같은 리포트 (P1-1 — `analysis_cache`). 촬영 검사·IE·OCR 전부 건너뛴다.
    cache_key = analysis_cache.make_key(images, deposit=deposit, market_price=marketPrice)
    cached = analysis_cache.lookup(cache_key, device_id=device_id)
    if cached is not None:
        return analysis_cache.with_alias(cached, alias, device_id=device_id)
    # 사진 품질 — 심하면 여기서 끝(크레딧 0원). ⚠ 횟수는 **센 뒤**다: 검사 자체가 서버 계산(장당 0.2~0.4초)을
    # 쓰므로, 안 세면 흐린 사진을 끝없이 보내 서버를 붙잡을 수 있다(decisions.md 2026-10-22 촬영 품질 검사).
    capture, rejected = _capture_gate(images)
    if rejected is not None:
        return rejected

    try:
        report = report_builder.analyze(
            images,
            deposit=deposit,
            market_price=marketPrice,
            alias=alias,
            device_id=device_id,
            capture=capture,
        )
    except ExtractionError as e:
        raise HTTPException(status_code=e.status_code, detail=e.detail)
    analysis_cache.remember(cache_key, report, device_id=device_id)
    return report


@router.post("/reports/{report_id}/compare", response_model=CompareResult)
def compare_registry(
    request: Request,
    report_id: str,
    files: list[UploadFile] = File(default=[], description="이번에 뗀 등기부 사진(여러 장)"),
    device_id: str = Depends(get_current_user),  # 호출한 기기 (X-Device-Id, 없으면 공용 legacy-device)
) -> CompareResult:
    """기준 리포트의 등기부와 **이번에 뗀 등기부**를 맞춰본다 (계약 여정 S-11).

    흐름: 새 사진을 그대로 분석 파이프라인에 태워(같은 보증금·같은 별칭) 새 리포트를
    만들고, 그 추출 스냅샷을 기준 스냅샷과 견준다. 등급 변화를 말할 수 있는 이유가
    이것이다 — **두 등급 모두 규칙 엔진이 낸 것**이고, 대조는 둘을 나란히 놓을 뿐이다.

    **사진 없이도 부를 수 있다.** 기준 스냅샷이 없으면(이 기능 이전 이력·예시 리포트)
    사진을 받기 전에 '기준 없음'으로 답한다 — 찍게 해 놓고 마지막에 못 한다고 말하지
    않기 위해서다. 기준이 있는데 사진이 없으면 400.
    """
    base_report = store.get(report_id, device_id=device_id)
    if base_report is None:
        raise HTTPException(status_code=404, detail="이 리포트를 불러올 수 없어요")

    baseline = store.get_snapshot(report_id, device_id=device_id)
    if baseline is None:
        _log.info(f"[대조] 기준 없음 — 리포트 {report_id}에 스냅샷이 없습니다(사진 요청 안 함)")
        return compare.no_baseline_result(base_report)

    images = _read_images(files, empty_detail="다시 뗀 등기부 사진을 1장 이상 올려 주세요")
    # 다시 분석하므로 분석과 같은 상한을 쓴다 — 검사를 통과한 뒤, 외부 호출 직전에 센다
    limit_analyze(request, device_id)
    # 대조도 새 사진을 다시 분석한다 — 같은 촬영 검사(심하면 크레딧 0원으로 거절)
    capture, rejected = _capture_gate(images)
    if rejected is not None:
        return rejected

    try:
        # ⚠ 보증금·시세는 **기준 분석과 같은 값**을 쓴다. 다른 값으로 계산하면 등급 차이가
        #   '서류가 달라져서'인지 '입력이 달라져서'인지 알 수 없어진다.
        current_report = report_builder.analyze(
            images,
            deposit=baseline.deposit,
            market_price=baseline.manual_market_price,
            alias=base_report.alias,
            device_id=device_id,
            capture=capture,
        )
    except ExtractionError as e:
        raise HTTPException(status_code=e.status_code, detail=e.detail)

    current = store.get_snapshot(current_report.id, device_id=device_id)
    if current is None:  # 스냅샷 저장이 실패한 경우 — 견줄 재료가 없다
        raise HTTPException(
            status_code=503,
            detail="이번 서류를 기준과 견주지 못했어요. 잠시 후 다시 시도해 주세요",
        )

    result = compare.compare(baseline, current)
    if result.result == "different_property":
        # 다른 집 서류로 만들어진 리포트다. **기준 매물의 보증금으로 계산된 등급**이라
        # 그 집의 판정으로 쓸 수 없고, 이력에 남기면 홈 카드가 틀린 등급을 보여준다.
        store.remove(current_report.id, device_id=device_id)
        _log.info(f"[대조] 다른 집이라 이번 분석({current_report.id})을 이력에서 지웠습니다")
    return result


@router.get("/reports", response_model=list[Report])
def list_reports(device_id: str = Depends(get_current_user)) -> list[Report]:
    """이 기기의 분석 이력(최신순) + 예시 리포트. 다른 기기의 기록은 섞이지 않는다."""
    return store.list_reports(device_id=device_id)


@router.get("/reports/{report_id}", response_model=Report)
def get_report(report_id: str, device_id: str = Depends(get_current_user)) -> Report:
    report = store.get(report_id, device_id=device_id)
    if report is None:
        raise HTTPException(status_code=404, detail="이 리포트를 불러올 수 없어요")
    return report


@router.delete("/reports/{report_id}", status_code=204)
def delete_report(
    report_id: str,
    device_id: str = Depends(get_current_user),  # 호출한 기기 (X-Device-Id, 없으면 공용 legacy-device)
) -> None:
    # 예시 리포트는 조회만 허용, 삭제 대상 아님 (계약 §3.4)
    if report_id in store.EXAMPLE_IDS:
        raise HTTPException(status_code=403, detail="예시 리포트는 삭제할 수 없어요")
    if store.get(report_id, device_id=device_id) is None:
        raise HTTPException(status_code=404, detail="이 리포트를 찾을 수 없어요")
    store.remove(report_id, device_id=device_id)
    # 204 No Content (본문 없음)


@router.get("/reports/{report_id}/cases", response_model=list[CaseMatch])
def report_cases(
    report_id: str, device_id: str = Depends(get_current_user)
) -> list[CaseMatch]:
    # 동기(def) 핸들러다 (2026-10-21) — 기록 DB 조회와 판례 검색·Solar 호출(수 초)이 모두
    # 막히는 호출이라, async로 두면 그동안 **서버 전체**(다른 사람 요청)가 멈춘다. 스레드풀에서 돌게 한다.
    report = store.get(report_id, device_id=device_id)
    if report is None:
        raise HTTPException(status_code=404, detail="이 리포트를 불러올 수 없어요")
    # E-3 실연동 (2026-08-07): 규칙이 태그를 파생 → 하이브리드 검색 → LLM은 문장만.
    #   판례가 없으면 빈 목록이 나간다 (지어내지 않는다 — PrecedentSection.fallback_text).
    #
    # 결과를 리포트 단위로 캐시한다. 캐시가 없으면 화면에 들어올 때마다 검색 +
    #   판례 수만큼 Solar 호출이 다시 돌아 매번 수 초를 기다리게 된다.
    cached = store.get_cases(report_id, device_id=device_id)
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
    store.put_cases(report_id, cases, device_id=device_id)
    return cases


@router.get("/reports/{report_id}/questions", response_model=list[QuestionGroup])
def report_questions(
    report_id: str, device_id: str = Depends(get_current_user)
) -> list[QuestionGroup]:
    report = store.get(report_id, device_id=device_id)
    if report is None:
        raise HTTPException(status_code=404, detail="이 리포트를 불러올 수 없어요")
    # E-2 실연동: data/questions.json 템플릿 + 조건부 변형 (LLM 미개입)
    return questions.build_question_groups(report)
