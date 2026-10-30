"""Solar 모델 고르기 — 첫 모델이 '없는 모델·끝난 모델'로 거절되면 다음 모델로 바꿔 다시 부른다 (2026-10-31).

왜 필요한가:
Upstage가 solar-pro2·solar-pro3·solar-mini의 서비스 종료일을 **2026-10-30(KST)**로 알렸고,
지금 채팅 문서에는 `solar-pro4`·`solar-mini4`만 남아 있다(console.upstage.ai/docs/capabilities/generate/chat).
그런데 10-31 새벽에도 배포 서버의 챗봇은 solar-pro2로 답하고 있었다(규혁 확인). 언제 끊길지 모른다 —
결선 부스(11/3~5) 한가운데 끊기면 설명·판례·챗봇이 전부 준비된 문장으로 떨어진다.

그래서:
- **첫 모델은 지금까지와 같다**(`UPSTAGE_MODEL`, 없으면 solar-pro2). 답하는 동안 말투·길이가 바뀌지 않는다.
- 첫 모델이 **모델 때문에** 거절되면(404·410, 또는 400·403·422인데 응답에 model·deprecated·end of service 같은 말) 그 자리에서
  다음 모델(`UPSTAGE_FALLBACK_MODELS`, 기본 solar-pro4)로 같은 요청을 한 번 더 보낸다. 사용자는 몇 초 늦을 뿐이다.
- 한 번 바꾸면 **이 서버 프로세스가 끝날 때까지** 그 모델을 쓴다 — 요청마다 끝난 모델에 헛걸음하지 않는다.
- 키가 틀렸거나(401)·요청 제한(429)·서버 오류(5xx)는 모델 문제가 아니라 바꾸지 않는다(호출부가 원래대로 처리한다).

추론 설정: solar-pro2·pro3에는 지금까지처럼 `reasoning_effort: "low"`. solar-pro4·mini4는 **값을 빼면 추론이 꺼진 채**
답한다(공식 문서 Reasoning — `none`/`minimal`=끔, `low` 이상=켬). 우리 일(쉬운 문장·표 옮기기)엔 추론이 필요 없어 뺀다.

⚠ 판정과 무관하다. 문장을 쓰는 모델만 고른다.
"""

from __future__ import annotations

import logging
import os
import re
import threading
from pathlib import Path
from typing import Any, Callable

import requests
from dotenv import load_dotenv

_log = logging.getLogger("jeonseai")
_BACKEND_ROOT = Path(__file__).resolve().parents[3]

BASE_URL = "https://api.upstage.ai/v1/solar"
DEFAULT_PRIMARY = "solar-pro2"
DEFAULT_FALLBACKS = ("solar-pro4",)

#: 모델이 없다·끝났다는 뜻의 응답 문구 (대소문자 무시)
_MODEL_GONE = re.compile(
    r"model|deprecat|end[\s_-]*of[\s_-]*service|retired|sunset|discontinu|no longer|not[\s_-]*found|does not exist|unsupported",
    re.I,
)

_lock = threading.Lock()
_active = 0  # 지금 쓰는 모델 자리 (chain() 안의 순번)

Post = Callable[..., requests.Response]


def chain() -> list[str]:
    """[첫 모델, 다음 모델 …] — 같은 이름은 한 번만."""
    load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")  # 이미 있는 환경변수는 덮지 않는다
    primary = os.environ.get("UPSTAGE_MODEL", "").strip() or DEFAULT_PRIMARY
    raw = os.environ.get("UPSTAGE_FALLBACK_MODELS", "").strip()
    rest = [m.strip() for m in raw.split(",") if m.strip()] if raw else list(DEFAULT_FALLBACKS)
    out: list[str] = []
    for m in [primary, *rest]:
        if m not in out:
            out.append(m)
    return out


def current() -> str:
    """지금 부를 모델 이름 (한 번 바꿨으면 바꾼 모델)."""
    models = chain()
    return models[min(_active, len(models) - 1)]


def reasoning_fields(model: str) -> dict[str, Any]:
    """모델에 맞는 추론 설정 — pro2·pro3는 지금까지처럼 low, 그 밖(pro4·mini4)은 빼서 끈 채로."""
    name = model.lower()
    if name.startswith(("solar-pro2", "solar-pro3")):
        return {"reasoning_effort": "low"}
    return {}


def model_gone(status: int, body: str) -> bool:
    """이 거절이 **모델 때문**인가 — 그럴 때만 다음 모델로 바꾼다."""
    if status in (404, 410):
        return True
    if status in (400, 403, 422):
        return bool(_MODEL_GONE.search(body or ""))
    return False


def _advance(from_index: int, models: list[str], status: int) -> bool:
    """다음 모델로 넘어간다. 이미 누가 넘겼으면 그대로 둔다. 더 갈 곳이 없으면 False."""
    global _active
    with _lock:
        if _active != from_index:
            return True  # 다른 요청이 먼저 바꿨다 — 바뀐 모델로 다시 부르면 된다
        if from_index + 1 >= len(models):
            return False
        _active = from_index + 1
    _log.warning(
        f"[Solar] ⚠ {models[from_index]} 이(가) HTTP {status}로 거절 — {models[from_index + 1]}(으)로 바꿔 다시 부릅니다"
        " (이 서버가 다시 켜질 때까지 유지)"
    )
    return True


def post_chat(
    payload: dict[str, Any],
    *,
    api_key: str,
    timeout: float,
    post: Post | None = None,
) -> tuple[requests.Response, str]:
    """`/chat/completions` 한 번 — 모델 때문에 거절되면 다음 모델로 바꿔 다시. (응답, 실제로 부른 모델).

    `payload`에는 model·reasoning_effort를 넣지 않는다(여기서 모델마다 맞춰 넣는다).
    연결 실패(requests 예외)는 그대로 던진다 — 호출부가 하던 대로 처리한다.
    """
    send = post or requests.post
    models = chain()
    tried: set[str] = set()
    while True:
        index = min(_active, len(models) - 1)
        model = models[index]
        body = {**payload, "model": model, **reasoning_fields(model)}
        resp = send(
            f"{BASE_URL}/chat/completions",
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
            json=body,
            timeout=timeout,
        )
        tried.add(model)
        if resp.status_code == 200 or not model_gone(resp.status_code, _text(resp)):
            return resp, model
        if not _advance(index, models, resp.status_code) or current() in tried:
            return resp, model


def _text(resp: requests.Response) -> str:
    try:
        return resp.text[:500]
    except Exception:  # noqa: BLE001 — 응답 본문을 못 읽어도 상태 코드로 판단한다
        return ""


def reset_for_tests() -> None:
    """테스트 전용 — 바꾼 모델을 처음으로 되돌린다."""
    global _active
    with _lock:
        _active = 0
