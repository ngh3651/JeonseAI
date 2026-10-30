"""리포트·분석 관련 라우터 (계약 §3.1~§3.6).

- POST   /api/analyze                    분석 실행
- POST   /api/reports/{id}/compare       다시 뗀 등기부 대조
- GET    /api/reports                    이력 목록 (이 기기 것만)
- GET    /api/reports/{id}               리포트 단건
- DELETE /api/reports/{id}               이력 삭제
- GET    /api/reports/{id}/cases         판례 매칭
- GET    /api/reports/{id}/questions     질문 생성

**기기별 기록 (2026-10-21):** 모든 엔드포인트가 `get_current_user`(= `X-Device-Id` 기기 id)를
받아 **그 기기의 기록만** 다룬다. 다른 기기의 리포트 id를 넣으면 404 — "있는데 못 본다"와
"없다"를 구분해 주지 않는다. (모든 기기에 붙던 예시 리포트 `dummy-example`은 2026-10-29에 없앴다.)

**분석 중 [중단] (2026-10-29):** 앱이 연결을 끊으면 `/analyze`는 아직 시작 안 한 IE·OCR·Solar 호출을 건너뛰고
기록·같은 사진 캐시에 남기지 않으며, `replaces`로 옛 리포트를 지우지도 않는다(`_client_gone`).

E-1c: analyze/이력 실배선(추출→규칙 엔진→저장) 완료.
E-2: 질문은 data/questions.json 템플릿 실연동 완료. E-3: 판례도 실연동(`precedent_service`).
"""

from __future__ import annotations

import io
import logging
from dataclasses import replace as _replace
from typing import Optional

import anyio
from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import JSONResponse
from PIL import Image
from pydantic import BaseModel, Field

from .. import settings
from ..dependencies import get_current_user, limit_global, limit_requester
from ..schemas.contract import AskCards, CaptureCheck, CaseMatch, CompareResult, LossEstimate, QuestionGroup, Report
from ..services import ask_cards, analysis_cache, capture_check, compare, loss_estimate, patterns, questions, report_builder, store
from ..services.precedent import service as precedent_service
from ..services.extraction import ExtractionError

router = APIRouter(prefix="/api", tags=["reports"])

# 서버 콘솔 로거 — services 쪽과 같은 이름을 쓴다(main.py가 핸들러를 붙인다).
_log = logging.getLogger("jeonseai")

MAX_UPLOAD_BYTES = settings.MAX_UPLOAD_BYTES  # 파일당 10MB

#: 앱이 분석을 중단해 연결을 끊었을 때의 상태 코드(nginx 관례 'Client Closed Request') — 받을 사람은 이미 없다.
CLIENT_CLOSED_STATUS = 499


#: 끊김 메시지를 기다려 보는 시간(초). 끊겼으면 메시지가 바로 와 있고, 안 끊겼으면 이만큼만 기다리고 넘어간다.
DISCONNECT_PEEK_SECONDS = 0.02


async def _peek_disconnect(request: Request) -> bool:
    """받은 메시지가 '끊김'인가. 본문은 이미 다 읽었으므로 여기 올 수 있는 메시지는 끊김뿐이다.

    ⚠ `request.is_disconnected()`를 쓰지 않는 이유: 그 함수는 '미리 취소한 범위'에서 한 번만 받아 보는데,
      `@app.middleware("http")`(BaseHTTPMiddleware)가 받기를 작업 묶음으로 감싸 그 안에서는 메시지가 절대 안 온다
      — 실제 uvicorn에서 앱을 끊어 봐도 늘 False였다(2026-10-29 실험). 그래서 아주 짧게 기다려 본다.
    """
    if getattr(request.state, "client_gone", False):
        return True
    with anyio.move_on_after(DISCONNECT_PEEK_SECONDS):
        message = await request.receive()
        if message.get("type") == "http.disconnect":
            request.state.client_gone = True
            return True
    return False


def _client_gone(request: Request) -> bool:
    """앱이 연결을 끊었나 — 분석 중 [중단] (2026-10-29). 확인하지 못하면 '안 끊김'으로 본다(분석은 그대로 간다).

    분석 핸들러는 동기(def)라 스레드풀에서 돈다 → 이벤트 루프에 [_peek_disconnect]를 맡겨 묻는다.
    """
    try:
        return bool(anyio.from_thread.run(_peek_disconnect, request))
    except Exception:  # noqa: BLE001 — 루프 밖(직접 호출한 테스트 등)이면 묻지 못한다
        return False


def _cancelled_response() -> JSONResponse:
    return JSONResponse(status_code=CLIENT_CLOSED_STATUS, content={"detail": "분석을 중단했어요"})


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
    too_big = HTTPException(
        status_code=413,
        detail="사진 용량이 너무 커요. 10MB 이하 사진으로 다시 시도해 주세요",
    )
    images: list[tuple[str, bytes]] = []
    for f in files:
        # 크기를 아는 파일은 읽기 **전에** 거르고, 읽어도 상한 + 1바이트까지만 읽는다(2026-10-30 보안 —
        # 예전엔 통째로 읽은 뒤에 재서, 아주 큰 파일 하나로 서버 메모리를 다 쓸 수 있었다).
        if f.size is not None and f.size > MAX_UPLOAD_BYTES:
            raise too_big
        data = f.file.read(MAX_UPLOAD_BYTES + 1)
        if not data:
            continue
        if len(data) > MAX_UPLOAD_BYTES:
            raise too_big
        _check_pixels(data)
        images.append((f.filename or "page.jpg", data))
    if not images:
        raise HTTPException(status_code=400, detail=empty_detail)
    return images


def _check_pixels(data: bytes) -> None:
    """그림 머리만 읽어 화소 수를 본다 — 압축 폭탄(작은 파일·거대한 화소)을 디코딩 **전에** 막는다.

    그림으로 열리지 않는 파일은 여기서 막지 않는다(뒤의 촬영 검사·문서 검사가 '등기부가 아닌 사진'으로 안내한다).
    """
    try:
        with Image.open(io.BytesIO(data)) as im:
            width, height = im.size
    except Image.DecompressionBombError:
        raise HTTPException(status_code=400, detail=_MSG_TOO_MANY_PIXELS) from None
    except Exception:  # noqa: BLE001 — 그림이 아니면 여기서는 지나간다
        return
    if width * height > settings.MAX_IMAGE_PIXELS:
        raise HTTPException(status_code=400, detail=_MSG_TOO_MANY_PIXELS)


_MSG_TOO_MANY_PIXELS = "사진이 너무 커요. 휴대폰 카메라로 찍은 사진으로 다시 시도해 주세요"


def _capture_gate(images: list[tuple[str, bytes]]) -> tuple[CaptureCheck | None, JSONResponse | None]:
    """촬영 검사(P1-1, 2026-10-22) — IE·OCR **전에** 사진 품질을 본다. (검사 결과, 거절 응답).

    심하게 흐리거나 어두운 장이 있으면 **분석하지 않고** 400을 돌려준다(크레딧 0원). 분석 횟수는 1회 센다 —
    라우터가 `limit_requester` **뒤에** 부른다(검사도 서버 계산을 쓰므로 횟수로 묶어 둔다).
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
    alias: Optional[str] = Form(default=None, max_length=40, description="매물 별칭(선택, 40자까지)"),
    replaces: Optional[str] = Form(
        default=None,
        description="이 분석이 **대신하는** 리포트 id(선택) — 빠진 쪽을 보충해 다시 낸 경우. 같은 집이면 그 리포트를 지운다",
    ),
    device_id: str = Depends(get_current_user),  # 호출한 기기 (X-Device-Id, 없으면 공용 legacy-device)
) -> Report:
    """등기부 사진 + 입력값으로 분석해 리포트를 만든다 (E-1c 실배선).

    업로드 → Information Extract(여러 장은 PDF 병합 1회 호출) → 규칙 엔진 판정
    → 설명 문구(폴백, E-2에서 LLM 교체) → 이력 저장. Upstage 호출이 수십 초
    걸릴 수 있어 동기(def) 핸들러로 두어 스레드풀에서 실행되게 한다.
    """
    images = _read_images(files, empty_detail="등기부 사진을 1장 이상 올려 주세요")
    # 입력 검사를 모두 통과한 뒤에만 센다 — 형식이 틀린 요청은 분석 기회를 깎지 않는다.
    # 서버 전체 상한은 크레딧을 실제로 쓰기 직전에 따로 센다(아래 limit_global — 2026-10-30 보안)
    limit_requester(request, device_id)
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

    gone = lambda: _client_gone(request)  # noqa: E731 — 분석 단계 사이마다 묻는다
    limit_global()  # 여기서부터 Upstage 크레딧을 쓴다
    try:
        report = report_builder.analyze(
            images,
            deposit=deposit,
            market_price=marketPrice,
            alias=alias,
            device_id=device_id,
            capture=capture,
            cancelled=gone,
        )
    except report_builder.AnalysisCancelled:
        return _cancelled_response()  # 아무것도 저장하지 않았다 · replaces도 그대로
    except ExtractionError as e:
        raise HTTPException(status_code=e.status_code, detail=e.detail)
    if gone():
        # 저장 직후에 끊겼다 — 받을 사람이 없는 리포트를 기록에서 거둔다(대조 기준도 함께). 옛 리포트는 지우지 않는다.
        store.remove(report.id, device_id=device_id)
        _log.info(f"[분석 중단] 앱이 연결을 끊음 — 방금 저장한 리포트 {report.id}를 거뒀습니다")
        return _cancelled_response()
    # 빠진 쪽 보충이면 덜 찍은 리포트를 이 리포트로 **대신한다** — 기록이 두 줄로 남지 않게, 그리고
    # 바로 전 리포트가 덜 찍은 것이 되어 틀린 변동이 잡히지 않게 (2026-10-27). 견주기 **전에** 지운다.
    _drop_replaced(report, replaces, device_id=device_id)
    # 같은 집 바로 전 리포트와 견준 결과를 싣는다 — 홈에서 다시 분석해도 '등기부 변동 기록'에 남게 (2026-10-27)
    report = _attach_change(report, device_id=device_id)
    analysis_cache.remember(cache_key, report, device_id=device_id)
    # 같은 집은 최신 5건만 (화면엔 최신 1개 — 앱이 고유번호·주소로 묶는다)
    store.prune_versions(report, device_id=device_id)
    return report


class InputsUpdate(BaseModel):
    """리포트 입력값 고치기 (2026-10-29) — 앱은 **고친 뒤의 전체 값**을 보낸다."""

    alias: Optional[str] = Field(default=None, max_length=40, description="매물 별칭(비우면 그대로)")
    deposit: int = Field(..., ge=1, description="예정 보증금(원)")
    marketPrice: Optional[int] = Field(
        default=None, ge=1, description="매매 시세(원). 없으면(null) 자동 조회 값을 쓴다"
    )


#: 재료가 없는 옛 리포트 — 앱이 이 말을 보면 폰에 남은 사진으로 다시 분석한다
NO_KIT_DETAIL = "이 리포트는 사진으로 다시 분석해야 고칠 수 있어요"


@router.patch("/reports/{report_id}", response_model=Report)
def update_inputs(
    request: Request,
    report_id: str,
    body: InputsUpdate,
    device_id: str = Depends(get_current_user),
) -> Report:
    """보증금·시세·별칭 고치기 — **같은 리포트**를 고친다(기록이 두 줄로 남지 않는다).

    - 별칭만 바뀌면: 이름만 바꾼다(다시 판정하지 않음).
    - 보증금·시세가 바뀌면: 분석 때 남긴 등기부 내용으로 **판정만 다시** 한다 — 사진을 다시 읽지 않는다(IE·OCR 0회,
      설명 문장만 AI). 판정은 규칙 엔진이 새로 낸다.
    재료가 없는 옛 리포트는 409 — 앱이 폰에 남은 사진으로 다시 분석한다.
    """
    if report_id in getattr(store, "EXAMPLE_IDS", ()):
        raise HTTPException(status_code=403, detail="예시 리포트는 고칠 수 없어요")
    old = store.get(report_id, device_id=device_id)
    if old is None:
        raise HTTPException(status_code=404, detail="리포트를 찾을 수 없어요")
    alias = (body.alias or "").strip() or old.alias
    old_manual = old.marketPrice if old.marketPriceSource == "manual" else None
    same_numbers = body.deposit == old.deposit and body.marketPrice == old_manual

    if same_numbers:
        if alias == old.alias:
            return old
        updated = old.model_copy(update={"alias": alias})
    else:
        kit = store.get_rejudge_kit(report_id, device_id=device_id)
        if kit is None:
            raise HTTPException(status_code=409, detail=NO_KIT_DETAIL)
        limit_requester(request, device_id)  # 설명 문장에 AI를 한 번 쓴다 — 분석 횟수로 센다
        limit_global()
        updated = report_builder.rejudge(
            old, kit, deposit=body.deposit, market_price=body.marketPrice, alias=alias
        )
        analysis_cache.forget_report(report_id, device_id=device_id)
        store.clear_cases(report_id, device_id=device_id)
    store.update(updated, device_id=device_id)
    try:  # 대조 기준의 입력값도 맞춘다 — 다음 대조가 고친 보증금을 기준으로 보게
        snap = store.get_snapshot(report_id, device_id=device_id)
        if snap is not None:
            store.put_snapshot(
                report_id,
                _replace(
                    snap,
                    alias=updated.alias,
                    deposit=updated.deposit,
                    grade=updated.grade,
                    manual_market_price=body.marketPrice,
                ),
                device_id=device_id,
            )
    except Exception as e:  # noqa: BLE001 — 대조 기준 맞추기 실패로 고친 결과를 잃지 않는다
        _log.error(f"[대조] ⚠ 고친 입력값을 대조 기준에 반영하지 못함 ({type(e).__name__})")
    _log.info(
        f"[고치기] {report_id} — {'별칭만' if same_numbers else '다시 판정'}"
        f" (등급 {old.grade} → {updated.grade})"
    )
    return updated


def _drop_replaced(
    new: Report, replaces: Optional[str], *, device_id: str, keep: frozenset[str] = frozenset()
) -> None:
    """[new]가 대신하는 리포트([replaces])를 지운다 — **같은 집일 때만**. 아니면 그대로 둔다.

    빠진 쪽을 보충한 분석은 새 분석이 아니라 **같은 서류를 마저 낸 것**이다. 덜 찍은 리포트가 남으면
    '등기부 변동 기록'이 두 줄이 되고, 다음 대조가 덜 찍은 서류를 기준으로 삼는다.
    """
    if not replaces or replaces == new.id or replaces in keep:
        return
    try:
        old = store.get(replaces, device_id=device_id)
        if old is None:
            return
        if not store.same_property(old, new):
            _log.info(f"[이력] 대신할 리포트 {replaces}가 다른 집이라 그대로 둡니다")
            return
        store.remove(replaces, device_id=device_id)
        _log.info(f"[이력] 빠진 쪽 보충 — 덜 찍은 리포트 {replaces}를 {new.id}로 대신했습니다")
    except Exception as e:  # noqa: BLE001 — 정리 실패로 분석 결과를 잃지 않는다
        _log.error(f"[이력] ⚠ 덜 찍은 리포트를 지우지 못함 — 두 줄로 남습니다 ({type(e).__name__})")


def _attach_change(report: Report, *, device_id: str) -> Report:
    """같은 집 바로 전 리포트 ↔ 이번 리포트의 대조 결과를 `changeFromPrevious`에 넣고 다시 저장한다.

    사진·AI 호출 없이 두 대조 기준(스냅샷)만 맞춰 본다. **판정은 바뀌지 않는다** — 대조는 새 판정을 만들지 않는다.
    전 리포트가 없거나, 스냅샷이 없거나, 다른 집으로 나오면 그대로 둔다. 실패해도 리포트는 그대로 나간다.
    """
    try:
        prev = store.previous_version(report, device_id=device_id)
        if prev is None:
            return report
        base = store.get_snapshot(prev.id, device_id=device_id)
        cur = store.get_snapshot(report.id, device_id=device_id)
        if base is None or cur is None:
            return report
        result = compare.compare(base, cur)
        if result.result == "different_property":
            return report
        updated = report.model_copy(update={"changeFromPrevious": result})
        store.add(updated, device_id=device_id)
        return updated
    except Exception as e:  # noqa: BLE001 — 기록 한 줄 때문에 분석 결과를 잃지 않는다
        _log.error(f"[이력] ⚠ 전 리포트와 견주지 못함 — 기록 없이 계속 ({type(e).__name__})")
        return report


@router.post("/reports/{report_id}/compare", response_model=CompareResult)
def compare_registry(
    request: Request,
    report_id: str,
    files: list[UploadFile] = File(default=[], description="이번에 뗀 등기부 사진(여러 장)"),
    replaces: Optional[str] = Form(
        default=None,
        description="이 대조가 **대신하는** 리포트 id(선택) — 빠진 쪽을 더 찍어 다시 대조한 경우(앞 대조로 생긴 리포트)",
    ),
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
    limit_requester(request, device_id)
    # 대조도 새 사진을 다시 분석한다 — 같은 촬영 검사(심하면 크레딧 0원으로 거절)
    capture, rejected = _capture_gate(images)
    if rejected is not None:
        return rejected
    limit_global()  # 여기서부터 Upstage 크레딧을 쓴다

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
    else:
        # 이 대조 결과를 새 리포트에도 싣는다 — '등기부 변동 기록'이 홈 다시 분석과 같은 모양으로 남게 (2026-10-27)
        try:
            current_report = current_report.model_copy(update={"changeFromPrevious": result})
            store.add(current_report, device_id=device_id)
        except Exception as e:  # noqa: BLE001
            _log.error(f"[대조] ⚠ 대조 결과를 리포트에 싣지 못함 ({type(e).__name__})")
        # 빠진 쪽을 더 찍어 다시 대조했으면 앞 대조로 생긴(덜 찍은) 리포트를 지운다 — 기준 리포트는 지키고 (2026-10-27)
        _drop_replaced(current_report, replaces, device_id=device_id, keep=frozenset({report_id}))
        # 새 등기부로 만든 리포트가 그 집의 최신 리포트가 된다 — 같은 집은 최신 5건만
        store.prune_versions(current_report, device_id=device_id)
    return result


@router.get("/reports", response_model=list[Report])
def list_reports(device_id: str = Depends(get_current_user)) -> list[Report]:
    """이 기기의 분석 이력(최신순). 다른 기기의 기록은 섞이지 않는다. 없으면 빈 목록."""
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
    if store.get(report_id, device_id=device_id) is None:
        raise HTTPException(status_code=404, detail="이 리포트를 찾을 수 없어요")
    store.remove(report_id, device_id=device_id)
    # 204 No Content (본문 없음)


@router.get("/reports/{report_id}/loss-estimate", response_model=LossEstimate)
def report_loss_estimate(
    report_id: str,
    price: int | None = Query(default=None, ge=1, le=100_000_000_000_000),
    device_id: str = Depends(get_current_user),
) -> LossEstimate:
    """손실 시뮬레이터 (2026-10-28) — 이 집이 경매로 넘어가면 보증금이 얼마나 돌아오나. 규칙 계산, AI 없음.

    리포트에 저장하지 않고 **부를 때마다 계산한다** — 매각가율 자료(`data/auction_sale_rates.json`)를 새로 넣으면
    예전 리포트도 바로 새 숫자를 받는다. 판정과 무관하다.

    `price`(원): 시뮬레이터 화면에서 사용자가 넣은 매매 시세. 이번 계산에만 쓰고 리포트는 바꾸지 않는다.
    """
    report = store.get(report_id, device_id=device_id)
    if report is None:
        raise HTTPException(status_code=404, detail="이 리포트를 불러올 수 없어요")
    return loss_estimate.estimate(report, price=price)


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


@router.get("/reports/{report_id}/ask-cards", response_model=AskCards)
def report_ask_cards(
    report_id: str, polish: bool = False, device_id: str = Depends(get_current_user)
) -> AskCards:
    """리포트 4장 '중개사에게 물어볼 질문' (2026-10-29) — 규칙이 고르고 합격선을 계산한다. 최대 4개.

    `polish=true`(상세 화면)면 why 문장만 AI가 이 집 숫자로 다시 쓴다(검사 통과분만, 리포트당 1번 — 결과는 메모리에 둔다).
    """
    report = store.get(report_id, device_id=device_id)
    if report is None:
        raise HTTPException(status_code=404, detail="이 리포트를 불러올 수 없어요")
    bundle = ask_cards.build(report)
    return ask_cards.polish(report, bundle) if polish else bundle


@router.get("/reports/{report_id}/questions", response_model=list[QuestionGroup])
def report_questions(
    report_id: str, device_id: str = Depends(get_current_user)
) -> list[QuestionGroup]:
    report = store.get(report_id, device_id=device_id)
    if report is None:
        raise HTTPException(status_code=404, detail="이 리포트를 불러올 수 없어요")
    # E-2 실연동: data/questions.json 템플릿 + 조건부 변형 (LLM 미개입)
    return questions.build_question_groups(report)
