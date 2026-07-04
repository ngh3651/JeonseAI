"""큐레이션 콘텐츠 라우터 (계약 §3.7~§3.9).

- GET /api/journey-stages          계약 여정 단계 (비회원 허용)
- GET /api/glossary                용어 목록/추천 칩 (비회원 허용)
- GET /api/glossary/lookup?q=      용어 조회 (비회원 허용, 못 찾으면 404=범위 밖)

더미 응답은 app/dummy_data.py(앱 더미 그대로 이식)에서 온다. 실데이터는 Phase E.
"""

from __future__ import annotations

from fastapi import APIRouter, HTTPException

from .. import dummy_data
from ..schemas.contract import GlossaryTerm, JourneyStage

router = APIRouter(prefix="/api", tags=["content"])


@router.get("/journey-stages", response_model=list[JourneyStage])
async def journey_stages() -> list[JourneyStage]:
    """계약 여정 단계(정적, 모든 사용자 동일). 체크 상태는 앱 로컬 저장이라 응답에 없음."""
    return dummy_data.journey_stages()


@router.get("/glossary", response_model=list[GlossaryTerm])
async def glossary() -> list[GlossaryTerm]:
    """용어 챗봇 추천 칩 목록."""
    return dummy_data.glossary_terms()


@router.get("/glossary/lookup", response_model=GlossaryTerm)
async def glossary_lookup(q: str) -> GlossaryTerm:
    """입력에서 용어를 찾아 설명 반환. 못 찾으면 404(범위 밖) → 앱이 거절 문구 표시(가드레일)."""
    term = dummy_data.lookup_term(q)
    if term is None:
        raise HTTPException(status_code=404, detail="용어를 찾을 수 없어요")
    return term
